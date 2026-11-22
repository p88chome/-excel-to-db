-- ======================================================================
-- K15 已屆呆滯之警示
--
-- 【抓什麼】基準日還有庫存、還沒認列呆滯，但再過不久（WarnDays 天內）就會認列呆滯的料號 × 工廠。
-- 【為什麼有風險】料一旦認列呆滯就要提列跌價損失。提前警示，讓使用單位還來得及領用、調撥或退回。
--
-- 【怎麼判斷】
--   第 1 步：決定要看哪些料號 × 工廠：有呆滯報表（ext.SlowMoving）就用基準日以前最新一份報表裡的料；
--            沒有報表就用庫存表（inv.InventoryBalance）裡的料。
--   第 2 步：每個料號 × 工廠查呆滯狀態（kri.SlowStatusAt）：
--            有報表 → 用報表的認列呆滯日（SlowOn）、庫存數量、金額；
--            沒報表 → 認列呆滯日 = 最後一次領用日 + SlowDays（收貨、移倉不算，沒領用過用第一次異動日），庫存數量用 kri.StockAt 回推到基準日，
--                     金額按目前庫存金額 × 基準日數量比例換算。
--   第 3 步：離認列呆滯還有 0～WarnDays 天、而且有庫存 → 標記。推估的只留基準日有庫存的料。
--
-- 【門檻】（kri.Parameter，KriCode = 'K15'）
--   WarnDays        幾天內會認列呆滯就警示
--   SlowDays        沒有呆滯報表時：最後領用後幾天算呆滯
--   UseSapFallback  1 = 沒有呆滯報表時用最後領用日推估；0 = 沒報表就不判斷
--
-- 【名單】（kri.ValueList）
--   ConsumptionMovementType  哪些異動類型算領用（201、221、261、281）；只算從庫存扣出的（貸方）
--
-- 【明細表 kri.K15_Detail 怎麼看】
--   Source       呆滯報表 / SAP推估
--   SlowOn       認列呆滯的日期；DaysToSlow = 認列日 − 基準日（負數 = 已經呆滯）
--   LastMoveDate 最後一次領用日（推估時才有；沒領用過 = 第一次異動日）
--   StockQty、StockValue、Currency  基準日的庫存數量、金額、幣別
--
-- 【限制】
--   推估時的庫存是從目前的庫存快照往回推，準度看異動資料是否完整。
--   呆滯報表沒填數量時，當作有庫存。
-- ======================================================================
IF OBJECT_ID(N'kri.K15_Detail', N'U') IS NULL
CREATE TABLE kri.K15_Detail (
    RunId        INT           NOT NULL,
    Material     NVARCHAR(18)  NOT NULL,
    Plant        NVARCHAR(4)   NOT NULL,
    Source       NVARCHAR(10)  NOT NULL,   -- 呆滯報表 / SAP推估
    SnapshotDate DATE          NULL,
    Status       NVARCHAR(20)  NULL,
    LastMoveDate DATE          NULL,
    SlowOn       DATE          NULL,
    DaysToSlow   INT           NULL,
    StockQty     DECIMAL(19,4) NULL,
    StockValue   DECIMAL(19,4) NULL,
    IsFlagged    BIT           NOT NULL,
    CONSTRAINT PK_kri_K15_Detail PRIMARY KEY (RunId, Material, Plant)
);
GO
IF COL_LENGTH('kri.K15_Detail', 'Currency') IS NULL
    ALTER TABLE kri.K15_Detail ADD Currency NVARCHAR(5) NULL;
GO

CREATE OR ALTER PROCEDURE kri.Run_K15
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @warnDays       INT = kri.Param('K15', 'WarnDays'),         -- 幾天內會呆滯就警示
            @slowDays       INT = kri.Param('K15', 'SlowDays'),         -- 推估：最後異動後幾天算呆滯
            @useSapFallback INT = kri.Param('K15', 'UseSapFallback');   -- 1 = 沒報表時用 SAP 推估

    -- 基準日以前最新一份呆滯報表的日期（沒有報表 = NULL）
    DECLARE @lastSnapshot DATE = (SELECT MAX(SnapshotDate) FROM ext.SlowMoving WHERE SnapshotDate <= @AsOfDate);

    -- 第 1 步：要看的料號 × 工廠
    SELECT Material, Plant
    INTO #Items
    FROM ext.SlowMoving
    WHERE SnapshotDate = @lastSnapshot                     -- 有報表：報表裡的料
    UNION
    SELECT Material, Plant
    FROM inv.InventoryBalance
    WHERE @lastSnapshot IS NULL                            -- 沒報表：庫存表裡的料
    GROUP BY Material, Plant;

    -- 第 2 步：每個料的呆滯狀態、基準日庫存數量和金額
    SELECT i.Material, i.Plant, s.Source, s.SnapshotDate, s.Status, s.LastMoveDate, s.SlowOn,
           CASE WHEN s.Source = N'呆滯報表' THEN s.StockQty ELSE st.StockQty END AS Qty,
           -- 推估：金額用目前的庫存金額按基準日數量比例換算
           CASE WHEN s.Source = N'呆滯報表' THEN s.StockValue
                ELSE ib.Value * st.StockQty / NULLIF(ib.Qty, 0) END AS Value,
           CASE WHEN s.Source = N'呆滯報表' THEN s.Currency ELSE cc.LocalCurrency END AS Currency
    INTO #SlowStatus
    FROM #Items i
    CROSS APPLY kri.SlowStatusAt('K15', i.Material, i.Plant, @AsOfDate, @slowDays, @useSapFallback) s
    -- 推估時才需要：回推到基準日的庫存數量
    OUTER APPLY (SELECT StockQty FROM kri.StockAt(i.Material, i.Plant, @AsOfDate)
                 WHERE s.Source = N'SAP推估') st
    -- 推估時才需要：目前的庫存數量和金額
    OUTER APPLY (SELECT SUM(ISNULL(StockQty, 0) + ISNULL(QualityStock, 0) + ISNULL(BlockedStock, 0)) AS Qty,
                        MAX(StockValue) AS Value          -- 庫存金額是工廠層級，每個倉都重複，不能加總
                 FROM inv.InventoryBalance ib
                 WHERE ib.Material = i.Material AND ib.Plant = i.Plant AND s.Source = N'SAP推估') ib
    -- 推估時才需要：工廠的本幣，從最近一筆異動的公司別帶
    OUTER APPLY (SELECT TOP 1 c.LocalCurrency FROM inv.MaterialMovement m
                 JOIN kri.vCompanyCurrency c ON c.CompanyCode = m.CompanyCode
                 WHERE m.Material = i.Material AND m.Plant = i.Plant AND s.Source = N'SAP推估'
                 ORDER BY m.PostingDate DESC) cc;

    -- 第 3 步：快要呆滯、又有庫存 → 標記；寫進明細
    INSERT kri.K15_Detail (RunId, Material, Plant, Source, SnapshotDate, Status, LastMoveDate, SlowOn, DaysToSlow,
                           StockQty, StockValue, IsFlagged, Currency)
    SELECT @RunId, s.Material, s.Plant, s.Source, s.SnapshotDate, s.Status, s.LastMoveDate, s.SlowOn, d.DaysToSlow,
           s.Qty, s.Value,
           CASE WHEN d.DaysToSlow BETWEEN 0 AND @warnDays
                 AND (s.Qty > 0 OR (s.Source = N'呆滯報表' AND s.Qty IS NULL))   -- 報表沒填數量當有庫存
                THEN 1 ELSE 0 END,
           s.Currency
    FROM #SlowStatus s
    CROSS APPLY (SELECT DATEDIFF(DAY, @AsOfDate, s.SlowOn) AS DaysToSlow) d   -- 還有幾天認列呆滯
    WHERE s.Source = N'呆滯報表' OR s.Qty > 0;           -- 推估時只留基準日有庫存的

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K15', CONCAT(Material, '-', Plant), 'MATERIAL', Plant, Material, SlowOn,
           DaysToSlow, @warnDays,
           CASE WHEN Currency IS NOT NULL THEN StockValue END,   -- 不知道幣別的金額不填
           Currency,
           CONCAT(N'再 ', DaysToSlow, N' 天（', SlowOn, N'）認列呆滯；庫存 ', FORMAT(StockQty, 'N0'),
                  CASE WHEN Source = N'SAP推估' THEN CONCAT(N'（最後異動 ', LastMoveDate, N'，推估）') ELSE N'' END)
    FROM kri.K15_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'料號×工廠 ', COUNT(*), N'；來源 ', ISNULL(MAX(Source), N'—'),
                          N'；已呆滯 ', COUNT(CASE WHEN DaysToSlow < 0 THEN 1 END))
    FROM kri.K15_Detail WHERE RunId = @RunId;
END;
GO
