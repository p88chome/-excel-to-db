-- ======================================================================
-- K06 用量 vs 請購量 vs 庫存
--
-- 【抓什麼】請購的時候，手上的庫存加上已經下單還沒到的貨（在途），已經夠用好幾個月了，還是再請購。
-- 【為什麼有風險】買太多會變成呆滯庫存、占用資金；也可能是故意幫特定供應商衝量。
--
-- 【怎麼判斷】
--   第 1 步：觀察期間內有料號、有工廠的 PR 項目（通用料號除外：一個料號底下是很多種東西，庫存和耗用不能比）。
--   第 2 步：算請購當天的三個數字（都是基本單位）：
--            庫存 = kri.StockAt 從庫存快照回推到請購當天；
--            在途 = 請購當天以前下的 PO（兩年內）還沒收的數量；當天已收多少用 kri.PoReceivedAt 算，
--                   已結案的、這張 PR 自己轉出的 PO 不算；PO 單位用 BasePerUnit 換成基本單位；
--            平均月耗用 = 過去 UsageMonths 個月的耗用（ConsumptionMovementType 的異動，領用加、沖回減）÷ 月數。
--   第 3 步：覆蓋月數 =（庫存 + 在途）÷ 平均月耗用。
--   第 4 步：覆蓋月數 > MaxCoverageMonths → 標記；
--            FlagNoUsage = 1 時，過去沒有耗用、手上又有庫存或在途的也標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K06'）
--   MaxCoverageMonths  庫存 + 在途可用超過幾個月仍請購
--   UsageMonths        平均月耗用看過去幾個月
--   FlagNoUsage        1 = 沒有耗用但有庫存或在途仍請購也標記
--
-- 【名單】（kri.ValueList）
--   ConsumptionMovementType  哪些異動類型算耗用（201 領用至成本中心、261 領用至工單…，含沖回）
--   GenericMaterial          通用料號（KriCode = '*'），這題排除
--
-- 【明細表 kri.K06_Detail 怎麼看】一列 = 一個 PR 項目
--   StockAtPr       請購當天的工廠庫存
--   OpenPoQty       請購當天的在途數量
--   AvgMonthlyUse   平均月耗用
--   CoverageMonths  （庫存 + 在途）÷ 平均月耗用
--   Status          已比對 / 無耗用 / 無庫存資料
--   Amount          PR 數量 × 評價價格（PR 幣別）
--
-- 【限制】
--   庫存只有一份快照，往回推的準度取決於異動資料完不完整。
--   收貨資料和 PO 單位不同時，用收貨量 ÷ PO 已收數量推估換算比例；沒收過貨當 1。
-- ======================================================================
IF OBJECT_ID(N'kri.K06_Detail', N'U') IS NULL
CREATE TABLE kri.K06_Detail (
    RunId          INT           NOT NULL,
    PrNumber       NVARCHAR(10)  NOT NULL,
    PrItem         NVARCHAR(5)   NOT NULL,
    PrDate         DATE          NULL,
    Material       NVARCHAR(18)  NULL,
    Plant          NVARCHAR(4)   NULL,
    CostCenter     NVARCHAR(10)  NULL,
    ReqQty         DECIMAL(19,4) NULL,
    Uom            NVARCHAR(3)   NULL,
    StockAtPr      DECIMAL(19,4) NULL,
    OpenPoQty      DECIMAL(19,4) NULL,
    AvgMonthlyUse  DECIMAL(19,4) NULL,
    CoverageMonths DECIMAL(19,4) NULL,
    Status         NVARCHAR(10)  NOT NULL,  -- 已比對 / 無耗用 / 無庫存資料
    Amount         DECIMAL(19,4) NULL,      -- PR 數量 × 評價價格（PR 幣別）
    Currency       NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K06_Detail PRIMARY KEY (RunId, PrNumber, PrItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K06
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @maxCoverage DECIMAL(19,4) = kri.Param('K06', 'MaxCoverageMonths'),   -- 夠用幾個月以上仍請購就標記
            @usageMonths INT           = kri.Param('K06', 'UsageMonths'),         -- 平均月耗用看過去幾個月
            @flagNoUsage INT           = kri.Param('K06', 'FlagNoUsage');         -- 1 = 沒耗用但有庫存也標記

    -- 第 1 步：觀察期間內有料號、有工廠的 PR 項目
    SELECT r.PrNumber, r.PrItem, r.PrDate, r.Material, r.Plant, r.CostCenter, r.ReqQty, r.Uom, r.Currency,
           CAST(r.ReqQty * r.ValPrice AS DECIMAL(19,4)) AS Amount
    INTO #Pr
    FROM prc.PurchaseRequisition r
    WHERE r.PrDate BETWEEN @PeriodFrom AND @PeriodTo
      AND ISNULL(r.DeletionInd, '') = '' AND r.ReqQty > 0
      AND ISNULL(r.Material, '') <> '' AND ISNULL(r.Plant, '') <> ''
      AND NOT EXISTS (SELECT 1 FROM kri.IsGeneric('K06', r.Material));    -- 通用料號的庫存、耗用不能比

    -- 第 2 步：請購當天的庫存、在途、平均月耗用
    SELECT r.*,
           st.StockQty                          AS StockAtPr,
           ISNULL(op.Qty, 0)                    AS OpenPoQty,
           ISNULL(u.Qty, 0) / @usageMonths      AS AvgMonthlyUse
    INTO #PrPosition
    FROM #Pr r
    -- 庫存：從快照回推到請購當天
    OUTER APPLY kri.StockAt(r.Material, r.Plant, r.PrDate) st
    -- 在途：請購當天以前下的 PO，當天還沒收的數量（換成基本單位，和庫存、耗用一致）
    OUTER APPLY (
        SELECT SUM(CASE WHEN p.OrderQty - g.ReceivedQty > 0
                        THEN (p.OrderQty - g.ReceivedQty) * g.BasePerUnit ELSE 0 END) AS Qty
        FROM prc.PurchaseOrderDetail p
        CROSS APPLY kri.PoReceivedAt(p.PoNumber, p.PoItem, p.GrQty, p.DelivComplInd, p.PoDate, r.PrDate) g
        WHERE p.Material = r.Material AND p.Plant = r.Plant
          AND p.PoDate <= r.PrDate
          AND p.PoDate > DATEADD(YEAR, -2, r.PrDate)                   -- 只看兩年內的 PO
          AND ISNULL(p.DeletionInd, '') = '' AND p.OrderQty > 0
          AND NOT (ISNULL(p.PrNumber, '') = r.PrNumber AND ISNULL(p.PrItem, '') = r.PrItem)   -- 這張 PR 自己轉的 PO 不算
          AND g.IsClosed = 0                                           -- 請購當天已結案的不算
    ) op
    -- 耗用：過去 UsageMonths 個月的領用（貸方 H = 領出，算正的；借方 = 沖回，算負的）
    OUTER APPLY (
        SELECT SUM(CASE WHEN m.DebitCreditInd = 'H' THEN m.Quantity ELSE -m.Quantity END) AS Qty
        FROM inv.MaterialMovement m
        WHERE m.Material = r.Material AND m.Plant = r.Plant
          AND m.PostingDate > DATEADD(MONTH, -@usageMonths, r.PrDate) AND m.PostingDate <= r.PrDate
          AND m.MovementType IN (SELECT Value FROM kri.List('K06', 'ConsumptionMovementType'))
    ) u;

    -- 第 3 步：能不能比、覆蓋月數
    SELECT x.*,
           CASE WHEN StockAtPr IS NULL   THEN N'無庫存資料'
                WHEN AvgMonthlyUse <= 0  THEN N'無耗用'
                ELSE N'已比對' END AS Status,
           CASE WHEN AvgMonthlyUse > 0 THEN (ISNULL(StockAtPr, 0) + OpenPoQty) / AvgMonthlyUse END AS Coverage
    INTO #Coverage
    FROM #PrPosition x;

    -- 第 4 步：夠用太久仍請購（或沒耗用卻有庫存）→ 標記；寫進明細
    INSERT kri.K06_Detail (RunId, PrNumber, PrItem, PrDate, Material, Plant, CostCenter, ReqQty, Uom,
                           StockAtPr, OpenPoQty, AvgMonthlyUse, CoverageMonths, Status, Amount, Currency, IsFlagged)
    SELECT @RunId, PrNumber, PrItem, PrDate, Material, Plant, CostCenter, ReqQty, Uom,
           StockAtPr, OpenPoQty, AvgMonthlyUse, Coverage, Status, Amount, Currency,
           CASE WHEN Status = N'已比對' AND Coverage > @maxCoverage THEN 1
                WHEN Status = N'無耗用' AND @flagNoUsage = 1 AND StockAtPr + OpenPoQty > 0 THEN 1
                ELSE 0 END
    FROM #Coverage;

    -- 寫標記（PR 沒有匯率，影響金額以 PR 幣別計）
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocNumber, DocItem, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K06', CONCAT(PrNumber, '-', PrItem), 'PR', Plant, Material, PrNumber, PrItem, PrDate,
           CoverageMonths, @maxCoverage, Amount, Currency,
           CASE WHEN Status = N'無耗用'
                THEN CONCAT(N'過去 ', @usageMonths, N' 個月沒有耗用，庫存 + 在途 ', FORMAT(StockAtPr + OpenPoQty, 'N0'), N' 仍請購')
                ELSE CONCAT(N'庫存 + 在途可用 ', FORMAT(CoverageMonths, 'N1'), N' 個月仍請購') END
    FROM kri.K06_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'有料號的 PR 項目 ', COUNT(*), N'；無耗用 ', COUNT(CASE WHEN Status = N'無耗用' THEN 1 END),
                          N'；無庫存資料 ', COUNT(CASE WHEN Status = N'無庫存資料' THEN 1 END))
    FROM kri.K06_Detail WHERE RunId = @RunId;
END;
GO
