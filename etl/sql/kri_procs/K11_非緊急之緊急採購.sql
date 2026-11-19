-- ======================================================================
-- K11 非緊急之緊急採購
--
-- 【抓什麼】走「緊急採購」的 PO，但下單前手上其實還有庫存，或零件系統顯示根本不急。
-- 【為什麼有風險】緊急採購通常可以少比價、少簽核；不急卻走緊急，可能是在規避正常流程，
--                 或指定特定供應商。
--
-- 【怎麼判斷】
--   第 1 步：找出觀察期間內的緊急採購 PO 項目：PO 類型在 EmergencyPoType，
--            或任何一筆收貨說明符合 EmergencyTextPattern（只看基準日以前已輸入的收貨）。
--   第 2 步：查下單前一天的工廠庫存（kri.StockAt 從庫存快照回推），
--            和零件系統下單前最近一次的 MOU、待用量（ext.PartUsage）。
--   第 3 步：下單前庫存 > MinStockQty，或 MOU > MaxMou，或待用量 >= MinWaitingForUse → 不該走緊急 → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K11'）
--   MinStockQty       下單前庫存超過多少算不急
--   MaxMou            MOU 超過多少算不急
--   MinWaitingForUse  待用量達多少算不急
--
-- 【名單】（kri.ValueList）
--   EmergencyPoType       算緊急採購的 PO 類型
--   EmergencyTextPattern  收貨說明符合這些關鍵字（LIKE 樣式）算緊急採購
--
-- 【明細表 kri.K11_Detail 怎麼看】（只留緊急採購的 PO 項目）
--   EmergencyBy    怎麼認定是緊急的：PO類型 / 說明文字
--   StockAtPo      下單前一天的工廠庫存；NULL = 沒有庫存資料
--   Mou、WaitingForUse  零件系統下單前最近一次的數字；NULL = 沒有資料
--
-- 【限制】
--   沒有設定緊急採購的判斷條件時不會有資料（備註會提示）；ext.PartUsage 沒資料時只看庫存。
--   庫存是從目前的快照回推，準度看異動資料是否完整。
-- ======================================================================
IF OBJECT_ID(N'kri.K11_Detail', N'U') IS NULL
CREATE TABLE kri.K11_Detail (
    RunId         INT           NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    PoDate        DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    Material      NVARCHAR(18)  NULL,
    EmergencyBy   NVARCHAR(10)  NOT NULL,  -- PO類型 / 說明文字
    StockAtPo     DECIMAL(19,4) NULL,      -- 下單前一天的工廠庫存
    Mou           DECIMAL(19,4) NULL,
    WaitingForUse DECIMAL(19,4) NULL,
    AmountLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K11_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K11
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @minStockQty      DECIMAL(19,4) = kri.Param('K11', 'MinStockQty'),       -- 庫存超過多少算不急
            @maxMou           DECIMAL(19,4) = kri.Param('K11', 'MaxMou'),            -- MOU 超過多少算不急
            @minWaitingForUse DECIMAL(19,4) = kri.Param('K11', 'MinWaitingForUse');  -- 待用量達多少算不急

    -- 第 1 步：緊急採購的 PO 項目（PO 類型優先，其次看收貨說明）
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.Material,
           b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate,
           CASE WHEN p.PoType IN (SELECT Value FROM kri.List('K11', 'EmergencyPoType')) THEN N'PO類型'
                WHEN EXISTS (SELECT 1
                             FROM prc.GoodsReceipt g
                             JOIN kri.List('K11', 'EmergencyTextPattern') l ON g.ItemText LIKE l.Value
                             WHERE g.PoNumber = b.PoNumber AND g.PoItem = b.PoItem
                               AND ISNULL(g.EntryDate, g.PostingDate) <= @AsOfDate) THEN N'說明文字'
           END AS EmergencyBy
    INTO #Emergency
    FROM kri.PoBase('K11', @PeriodFrom, @PeriodTo) b
    JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
    WHERE ISNULL(b.Material, '') <> '';

    DELETE #Emergency WHERE EmergencyBy IS NULL;       -- 不是緊急採購的不看

    -- 第 2 步：下單前一天的庫存、零件系統下單前最近一次的 MOU 和待用量
    SELECT e.*, st.StockQty AS StockAtPo, u.Mou, u.WaitingForUse
    INTO #Urgency
    FROM #Emergency e
    OUTER APPLY kri.StockAt(e.Material, e.Plant, DATEADD(DAY, -1, e.PoDate)) st
    OUTER APPLY (SELECT TOP 1 x.Mou, x.WaitingForUse
                 FROM ext.PartUsage x
                 WHERE x.Material = e.Material AND x.Plant = e.Plant AND x.SnapshotDate < e.PoDate
                 ORDER BY x.SnapshotDate DESC) u;

    -- 第 3 步：有庫存、或 MOU 高、或待用量多 → 標記；寫進明細
    INSERT kri.K11_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, Material,
                           EmergencyBy, StockAtPo, Mou, WaitingForUse, AmountLocal, LocalCurrency, IsFlagged)
    SELECT @RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, Material,
           EmergencyBy, StockAtPo, Mou, WaitingForUse,
           kri.ToLocal(NetValue, Currency, LocalCurrency, ExchangeRate), LocalCurrency,
           CASE WHEN StockAtPo > @minStockQty OR Mou > @maxMou OR WaitingForUse >= @minWaitingForUse
                THEN 1 ELSE 0 END
    FROM #Urgency;

    -- 寫標記（說明只列出有超過的那幾項）
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K11', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, StockAtPo, @minStockQty, AmountLocal, LocalCurrency,
           CONCAT(N'緊急採購（', EmergencyBy, N'）但',
                  CONCAT_WS(N'、',
                            CASE WHEN StockAtPo > @minStockQty THEN CONCAT(N'下單前庫存 ', FORMAT(StockAtPo, 'N0')) END,
                            CASE WHEN Mou > @maxMou THEN CONCAT(N'MOU ', FORMAT(Mou, 'N1')) END,
                            CASE WHEN WaitingForUse >= @minWaitingForUse THEN CONCAT(N'待用 ', FORMAT(WaitingForUse, 'N0')) END))
    FROM kri.K11_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'緊急採購 PO 項目 ', COUNT(*), N'；沒有庫存資料 ', COUNT(CASE WHEN StockAtPo IS NULL THEN 1 END),
                          CASE WHEN NOT EXISTS (SELECT 1 FROM ext.PartUsage)
                               THEN N'（ext.PartUsage 沒有資料，只看庫存）' ELSE N'' END,
                          CASE WHEN NOT EXISTS (SELECT 1 FROM kri.List('K11', 'EmergencyPoType'))
                                AND NOT EXISTS (SELECT 1 FROM kri.List('K11', 'EmergencyTextPattern'))
                               THEN N'（沒有設定緊急採購的判斷條件）' ELSE N'' END)
    FROM kri.K11_Detail WHERE RunId = @RunId;
END;
GO
