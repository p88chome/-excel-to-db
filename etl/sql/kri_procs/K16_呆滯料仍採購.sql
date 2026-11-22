-- ======================================================================
-- K16 呆滯料仍進行採購
--
-- 【抓什麼】料號在下單時已經是呆滯料、手上還有庫存，卻還繼續下 PO；
--          而且最近 3 個月裡有好幾個月都這樣下單。
-- 【為什麼有風險】呆滯料已經用不完還在買，會讓呆滯越積越多、資金卡在倉庫，
--                 也可能是請購單位沒查庫存，或刻意替供應商消化訂單。
--
-- 【怎麼判斷】
--   第 1 步：找出 PO 項目（觀察期間，再往前多抓兩個月，用來算月數），查下單前一天的呆滯狀態
--            （kri.SlowStatusAt）：認列呆滯日 <= 下單日，或呆滯報表的狀態在 SlowStatus 名單裡 = 已呆滯。
--            沒有呆滯報表時用最後領用日 + SlowDays 推估（收貨、移倉不算，所以一直收貨也不會讓呆滯重新計算），而且要下單前一天有庫存（kri.StockAt 回推）。
--   第 2 步：每一筆算「同料號 × 工廠，最近 3 個月（含當月）有幾個月這樣下單」。
--   第 3 步：多抓的前兩個月只用來算月數，刪掉；月數 >= MinConsecMonths → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K16'）
--   MinConsecMonths  最近 3 個月有幾個月呆滯仍下單才標記
--   SlowDays         沒有呆滯報表時：最後領用後幾天算呆滯
--   UseSapFallback   1 = 沒有呆滯報表時用最後領用日推估
--
-- 【名單】（kri.ValueList）
--   SlowStatus               呆滯報表裡代表「已呆滯」的狀態值
--   ConsumptionMovementType  哪些異動類型算領用（201、221、261、281）；只算從庫存扣出的（貸方）
--
-- 【明細表 kri.K16_Detail 怎麼看】
--   Source         呆滯報表 / SAP推估
--   SlowStatus、SlowOn  呆滯報表的狀態、認列呆滯日（推估時 SlowOn = 最後領用 + SlowDays）
--   StockAtPo      下單前一天的庫存（推估時才有）
--   SlowMonths     最近 3 個月有幾個月呆滯仍下單
--   AmountLocal    這個 PO 項目的本幣金額
--
-- 【限制】
--   推估的庫存是從目前庫存快照往回推，準度看異動資料是否完整。
--   有呆滯報表時不看庫存（報表本身就是有庫存的料）。
-- ======================================================================
IF OBJECT_ID(N'kri.K16_Detail', N'U') IS NULL
CREATE TABLE kri.K16_Detail (
    RunId         INT           NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    PoDate        DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    Material      NVARCHAR(18)  NULL,
    Source        NVARCHAR(10)  NOT NULL,
    SlowStatus    NVARCHAR(20)  NULL,
    SlowOn        DATE          NULL,
    LastMoveDate  DATE          NULL,
    StockAtPo     DECIMAL(19,4) NULL,
    SlowMonths    INT           NULL,      -- 最近 3 個月（含當月）有呆滯仍下單的月數
    AmountLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K16_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K16
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @minMonths      INT = kri.Param('K16', 'MinConsecMonths'),   -- 最近 3 個月有幾個月才標記
            @slowDays       INT = kri.Param('K16', 'SlowDays'),          -- 推估：最後異動後幾天算呆滯
            @useSapFallback INT = kri.Param('K16', 'UseSapFallback');    -- 1 = 沒報表時用 SAP 推估

    -- 往前多抓兩個月（從期間起始月的前兩個月 1 日開始），才算得出期間第一個月的「最近 3 個月」
    DECLARE @fetchFrom DATE = DATEADD(MONTH, -2, DATEFROMPARTS(YEAR(@PeriodFrom), MONTH(@PeriodFrom), 1));

    -- 第 1 步：下單時已呆滯、有庫存的 PO 項目
    INSERT kri.K16_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, Material,
                           Source, SlowStatus, SlowOn, LastMoveDate, StockAtPo, SlowMonths,
                           AmountLocal, LocalCurrency, IsFlagged)
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.Material,
           s.Source, s.Status, s.SlowOn, s.LastMoveDate, st.StockQty,
           NULL,                                                         -- 月數第 2 步再算
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate), b.LocalCurrency,
           0
    FROM kri.PoBase('K16', @fetchFrom, @PeriodTo) b
    -- 下單前一天的呆滯狀態
    CROSS APPLY kri.SlowStatusAt('K16', b.Material, b.Plant, DATEADD(DAY, -1, b.PoDate), @slowDays, @useSapFallback) s
    -- 推估時才需要：下單前一天的庫存（有呆滯報表時不用回推庫存）
    OUTER APPLY (SELECT StockQty FROM kri.StockAt(b.Material, b.Plant, DATEADD(DAY, -1, b.PoDate))
                 WHERE s.Source = N'SAP推估') st
    WHERE ISNULL(b.Material, '') <> ''
      AND (   s.SlowOn <= b.PoDate                                          -- 下單時已過認列呆滯日
           OR s.Status IN (SELECT Value FROM kri.List('K16', 'SlowStatus'))) -- 或報表狀態是呆滯
      AND (s.Source = N'呆滯報表' OR st.StockQty > 0);                       -- 推估時要有庫存

    -- 第 2 步：同料號 × 工廠，最近 3 個月（含當月）有幾個月這樣下單
    UPDATE d SET SlowMonths = m.Months
    FROM kri.K16_Detail d
    CROSS APPLY (SELECT COUNT(DISTINCT DATEFROMPARTS(YEAR(x.PoDate), MONTH(x.PoDate), 1)) AS Months
                 FROM kri.K16_Detail x
                 WHERE x.RunId = d.RunId AND x.Material = d.Material AND x.Plant = d.Plant
                   AND x.PoDate >= DATEADD(MONTH, -2, DATEFROMPARTS(YEAR(d.PoDate), MONTH(d.PoDate), 1))
                   AND x.PoDate <= d.PoDate) m
    WHERE d.RunId = @RunId;

    -- 第 3 步：多抓的只用來算月數，刪掉；月數夠多 → 標記
    DELETE kri.K16_Detail WHERE RunId = @RunId AND PoDate < @PeriodFrom;
    UPDATE kri.K16_Detail SET IsFlagged = 1 WHERE RunId = @RunId AND SlowMonths >= @minMonths;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K16', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, SlowMonths, @minMonths, AmountLocal, LocalCurrency,
           CONCAT(N'料號 ',
                  CASE WHEN Source = N'SAP推估'
                       THEN CONCAT(N'最後異動 ', LastMoveDate, N'、推估 ', SlowOn, N' 已呆滯')
                       ELSE CONCAT(N'呆滯報表 ', ISNULL(SlowStatus, N''), N' ', ISNULL(CONVERT(NVARCHAR(10), SlowOn), N'')) END,
                  N'，仍下單；最近 3 個月有 ', SlowMonths, N' 個月這樣下單')
    FROM kri.K16_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'呆滯仍下單的 PO 項目 ', COUNT(*), N'；來源 ', ISNULL(MAX(Source), N'—'))
    FROM kri.K16_Detail WHERE RunId = @RunId;
END;
GO
