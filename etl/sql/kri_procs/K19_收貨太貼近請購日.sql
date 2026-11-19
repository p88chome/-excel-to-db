-- ======================================================================
-- K19 GR 日期異常貼近 PR/PO 建立日
--
-- 【抓什麼】請購單（PR）開出來沒幾天（MaxGapDays 天內）、甚至還沒開，貨就已經收進來的 PO 項目。
--          沒有 PR 的 PO，用 PO 日來比。
-- 【為什麼有風險】正常流程是請購 → 採購 → 供應商備貨 → 收貨，需要時間。收貨太貼近請購日，
--                 代表很可能是貨先到了才補開 PR、PO，事前的請購審核形同虛設。
--
-- 【怎麼判斷】
--   第 1 步：找出觀察期間內、基準日以前有收貨的 PO 項目（kri.PoReceipt：只算收貨異動類型、
--            收貨日取過帳日和系統輸入日較早的那個），帶出 PO 參照的 PR 和 PR 建立日。
--   第 2 步：比較的起點：有 PR 用 PR 日，沒有 PR 用 PO 日。間隔天數 = 第一次收貨日 − 起點。
--            有 PR 號碼但 PR 不在資料裡的，不退回 PO 日（會低估間隔），間隔留空、不判斷。
--   第 3 步：間隔 <= MaxGapDays（含負數 = 收貨早於 PR），而且收貨說明沒有排除關鍵字 → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K19'）
--   MaxGapDays  PR（或 PO）建立日到第一次收貨在幾天內就標記
--
-- 【名單】（kri.ValueList）
--   GrMovementType      算收貨的異動類型（例：101）
--   ExcludeTextPattern  收貨說明有這些關鍵字的不標記（例：緊急採購），LIKE 樣式
--
-- 【明細表 kri.K19_Detail 怎麼看】
--   RefType、RefDate   比較起點是 PR 還是 PO、起點日期
--   FirstGrDate        第一次收貨的過帳日；FirstGrEntryDate 第一次收貨的系統輸入日
--   GapDays            較早的收貨日 − 起點日；負數 = 收貨早於 PR/PO
--   HasExcludedText    收貨說明有排除關鍵字
--
-- 【限制】
--   和 K10 共用收貨日。K10 看 PO → 收貨，K19 看 PR → 收貨，同一筆可能兩題都標。
--   沖銷的收貨不扣回，沖銷後重收的，第一次收貨日仍是被沖銷那筆。
-- ======================================================================
IF OBJECT_ID(N'kri.K19_Detail', N'U') IS NULL
CREATE TABLE kri.K19_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoItem           NVARCHAR(5)   NOT NULL,
    PrNumber         NVARCHAR(10)  NULL,
    PrItem           NVARCHAR(5)   NULL,
    RefType          NVARCHAR(2)   NOT NULL, -- PR / PO（沒有 PR 時用 PO 日）
    RefDate          DATE          NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Plant            NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    Material         NVARCHAR(18)  NULL,
    FirstGrDate      DATE          NULL,
    FirstGrEntryDate DATE          NULL,
    GapDays          INT           NULL,
    HasExcludedText  BIT           NOT NULL,
    ItemAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    IsFlagged        BIT           NOT NULL,
    CONSTRAINT PK_kri_K19_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K19
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @maxGapDays INT = kri.Param('K19', 'MaxGapDays');   -- 建立後幾天內就收貨算太快

    -- 第 1 步：有收貨的 PO 項目，帶出 PR 和 PR 建立日
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.Material,
           b.LocalCurrency, p.PrNumber, p.PrItem, pr.PrDate,
           r.FirstGrDate, r.FirstGrEntryDate, r.FirstDate, r.HasExcludedText,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS ItemAmountLocal
    INTO #Received
    FROM kri.PoBase('K19', @PeriodFrom, @PeriodTo) b
    JOIN kri.PoReceipt('K19', @AsOfDate) r ON r.PoNumber = b.PoNumber AND r.PoItem = b.PoItem   -- 只留有收貨的
    JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
    LEFT JOIN prc.PurchaseRequisition pr ON pr.PrNumber = p.PrNumber AND pr.PrItem = p.PrItem;

    -- 第 2 步：比較起點（有 PR 用 PR 日，沒有用 PO 日）和間隔天數
    SELECT r.*, x.RefType,
           CASE WHEN x.RefType = 'PR' THEN r.PrDate ELSE r.PoDate END AS RefDate,
           -- 有 PR 號碼但 PR 不在資料裡：PrDate 是空的，間隔也是空的，不判斷
           DATEDIFF(DAY, CASE WHEN x.RefType = 'PR' THEN r.PrDate ELSE r.PoDate END, r.FirstDate) AS GapDays
    INTO #Gap
    FROM #Received r
    CROSS APPLY (SELECT CASE WHEN ISNULL(r.PrNumber, '') <> '' THEN 'PR' ELSE 'PO' END AS RefType) x;

    -- 第 3 步：收貨太快、又沒有排除關鍵字 → 標記；寫進明細
    INSERT kri.K19_Detail (RunId, PoNumber, PoItem, PrNumber, PrItem, RefType, RefDate, PoDate, CompanyCode,
                           PurchOrg, Plant, Vendor, Material, FirstGrDate, FirstGrEntryDate, GapDays,
                           HasExcludedText, ItemAmountLocal, LocalCurrency, IsFlagged)
    SELECT @RunId, PoNumber, PoItem, PrNumber, PrItem, RefType, RefDate, PoDate, CompanyCode,
           PurchOrg, Plant, Vendor, Material, FirstGrDate, FirstGrEntryDate, GapDays,
           HasExcludedText, ItemAmountLocal, LocalCurrency,
           CASE WHEN GapDays <= @maxGapDays AND HasExcludedText = 0 THEN 1 ELSE 0 END
    FROM #Gap;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K19', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, GapDays, @maxGapDays, ItemAmountLocal, LocalCurrency,
           CASE WHEN GapDays < 0 THEN CONCAT(N'收貨早於 ', RefType, N' ', -GapDays, N' 天')
                ELSE CONCAT(RefType, N' 建立後 ', GapDays, N' 天就收貨') END
    FROM kri.K19_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'有收貨的 PO 項目 ', COUNT(*), N'（有 PR ', COUNT(CASE WHEN RefType = 'PR' THEN 1 END),
                          N'，PR 找不到 ', COUNT(CASE WHEN RefType = 'PR' AND RefDate IS NULL THEN 1 END),
                          N'）；排除關鍵字 ', COUNT(CASE WHEN HasExcludedText = 1 THEN 1 END))
    FROM kri.K19_Detail WHERE RunId = @RunId;
END;
GO
