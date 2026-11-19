-- ======================================================================
-- K18 Open PO 收貨進度異常
--
-- 【抓什麼】交貨日已經過了一段時間，貨還收不到一定比例的 PO 項目。
-- 【為什麼有風險】供應商可能交不出貨，或者 PO 早該結案卻一直掛著、占用預算和額度。
--
-- 【怎麼判斷】
--   第 1 步：找出觀察期間內下單、基準日當時還沒結案、已經過了交貨日的 PO 項目。
--            「基準日當時」已收多少用 kri.PoReceivedAt 算，基準日之後才收的貨不算。
--   第 2 步：算出還沒收的數量、已收比例、逾期天數。
--   第 3 步：逾期超過 OverdueDays 天，而且已收比例低於 MinReceivedRatio → 標記。
--            影響金額 = 還沒收的數量 × PO 單價（換成本幣）。
--
-- 【門檻】（kri.Parameter，KriCode = 'K18'）
--   OverdueDays       超過交貨日幾天才算逾期
--   MinReceivedRatio  已收比例低於多少才標記（0.5 = 50%）
--   WindowMonths      觀察期間：只看最近幾個月下的 PO（預設 36）
--
-- 【明細表 kri.K18_Detail 怎麼看】
--   GrQty          基準日當時已收的數量（PO 訂購單位）
--   OpenQty        還沒收的數量 = 訂購數量 − GrQty
--   ReceivedRatio  已收比例 = GrQty ÷ 訂購數量
--   OverdueDays    基準日 − 交貨日
--   OpenAmountDoc  還沒收的金額（PO 幣別）；EffectLocal 是標記列換成本幣的金額
--
-- 【限制】
--   收貨比例用數量算，不用金額：收貨金額是本幣、PO 金額是文件幣別，不能直接相除。
--   交貨完成碼只有「現在」的值；有勾、而且最後一次收貨在基準日以前，就當作基準日時已結案。
-- ======================================================================
IF OBJECT_ID(N'kri.K18_Detail', N'U') IS NULL
CREATE TABLE kri.K18_Detail (
    RunId         INT           NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    PoDate        DATE          NULL,
    DelivDate     DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    VendorName    NVARCHAR(80)  NULL,
    Material      NVARCHAR(18)  NULL,
    OrderQty      DECIMAL(19,4) NULL,
    GrQty         DECIMAL(19,4) NULL,      -- 基準日當時已收
    OpenQty       DECIMAL(19,4) NULL,
    ReceivedRatio DECIMAL(19,6) NULL,
    OverdueDays   INT           NULL,
    Currency      NVARCHAR(5)   NULL,
    UnitPrice     DECIMAL(19,6) NULL,
    OpenAmountDoc DECIMAL(19,4) NULL,
    IsFlagged     BIT           NOT NULL,
    EffectLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    CONSTRAINT PK_kri_K18_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K18
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @overdueDays INT           = kri.Param('K18', 'OverdueDays'),        -- 逾期幾天
            @minRatio    DECIMAL(19,6) = kri.Param('K18', 'MinReceivedRatio');   -- 已收比例低於多少

    -- 第 1 步：基準日當時還沒結案、已過交貨日的 PO 項目，和當時已收的數量
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.DelivDate, b.CompanyCode, b.PurchOrg, b.Plant,
           b.Vendor, b.VendorName, b.Material, b.OrderQty, b.Currency, b.UnitPrice,
           b.LocalCurrency, b.ExchangeRate,
           r.ReceivedQty
    INTO #OpenPo
    FROM kri.PoBase('K18', @PeriodFrom, @PeriodTo) b
    CROSS APPLY kri.PoReceivedAt(b.PoNumber, b.PoItem, b.GrQty, b.DelivComplInd, b.PoDate, @AsOfDate) r
    WHERE r.IsClosed = 0                    -- 基準日當時還沒結案
      AND r.ReceivedQty < b.OrderQty        -- 還沒收齊
      AND b.DelivDate < @AsOfDate;          -- 已經過了交貨日

    -- 第 2 步：還沒收的數量、已收比例、逾期天數
    SELECT o.*,
           o.OrderQty - o.ReceivedQty               AS OpenQty,
           o.ReceivedQty / o.OrderQty               AS ReceivedRatio,
           DATEDIFF(DAY, o.DelivDate, @AsOfDate)    AS OverdueDays
    INTO #Progress
    FROM #OpenPo o;

    -- 第 3 步：逾期太久、收得太少 → 標記；寫進明細
    INSERT kri.K18_Detail (RunId, PoNumber, PoItem, PoDate, DelivDate, CompanyCode, PurchOrg, Plant,
                           Vendor, VendorName, Material, OrderQty, GrQty, OpenQty, ReceivedRatio, OverdueDays,
                           Currency, UnitPrice, OpenAmountDoc, IsFlagged, EffectLocal, LocalCurrency)
    SELECT @RunId, p.PoNumber, p.PoItem, p.PoDate, p.DelivDate, p.CompanyCode, p.PurchOrg, p.Plant,
           p.Vendor, p.VendorName, p.Material, p.OrderQty, p.ReceivedQty, p.OpenQty, p.ReceivedRatio, p.OverdueDays,
           p.Currency, p.UnitPrice,
           p.OpenQty * p.UnitPrice,                                                    -- 還沒收的金額（PO 幣別）
           f.IsFlagged,
           CASE WHEN f.IsFlagged = 1
                THEN kri.ToLocal(p.OpenQty * p.UnitPrice, p.Currency, p.LocalCurrency, p.ExchangeRate) END,
           p.LocalCurrency
    FROM #Progress p
    CROSS APPLY (SELECT CASE WHEN p.OverdueDays > @overdueDays AND p.ReceivedRatio < @minRatio
                             THEN 1 ELSE 0 END AS IsFlagged) f;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K18', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, ReceivedRatio, @minRatio, EffectLocal, LocalCurrency,
           CONCAT(N'逾期 ', OverdueDays, N' 天，只收貨 ', FORMAT(ReceivedRatio, 'P0'))
    FROM kri.K18_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'已過交貨日的 Open PO 項目 ', COUNT(*))
    FROM kri.K18_Detail WHERE RunId = @RunId;
END;
GO
