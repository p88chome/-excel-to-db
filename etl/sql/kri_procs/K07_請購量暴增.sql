-- ======================================================================
-- K07 本期 vs 預期請購量
--
-- 【抓什麼】某個料號在某個工廠，某個月的請購量突然是平常（或預期）的好幾倍。
-- 【為什麼有風險】請購量暴增可能是重複請購、囤貨、或藉大量請購換取供應商好處；也可能是需求預測失準。
--
-- 【怎麼判斷】
--   第 1 步：把 PR 依「料號 × 工廠 × 單位 × 月份」加總請購數量。
--            往前多抓 12 個月，用來算歷史平均。通用料號（GenericMaterial）不看。
--   第 2 步：觀察期間內的每個月，找出它的「預期量」：
--            有 ext.ExpectedDemand（預期請購量表）就用表上的數字；
--            沒有就用過去 12 個月「有請購的月份」的平均（有請購的月份少於 MinHistoryMonths 不判斷）。
--   第 3 步：當月請購量 ÷ 預期量 > Multiplier → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K07'）
--   Multiplier        當月請購量是預期量的幾倍以上才標記
--   MinHistoryMonths  沒有預期量表時，過去 12 個月至少要有幾個月有請購才判斷
--
-- 【名單】（kri.ValueList）
--   GenericMaterial   通用、雜項料號：一個料號底下是很多種東西，數量加總沒有意義，不看
--
-- 【明細表 kri.K07_Detail 怎麼看】
--   Month           月份（當月 1 日）
--   MonthQty        當月請購數量合計
--   ExpectedQty     預期量；ExpectedSource 說明來源（預期量表 / 歷史平均），NULL = 歷史不足不判斷
--   HistoryMonths   過去 12 個月有請購的月份數
--   Ratio           MonthQty ÷ ExpectedQty
--
-- 【限制】
--   歷史平均只算「有請購的月份」，零星採購的料號不會被沒請購的月份（0）拉低。
--   不同單位分開算，不換算。
-- ======================================================================
IF OBJECT_ID(N'kri.K07_Detail', N'U') IS NULL
CREATE TABLE kri.K07_Detail (
    RunId          INT           NOT NULL,
    Material       NVARCHAR(18)  NOT NULL,
    Plant          NVARCHAR(4)   NOT NULL,
    Uom            NVARCHAR(3)   NOT NULL,
    Month          DATE          NOT NULL,
    MonthQty       DECIMAL(19,4) NULL,
    ExpectedQty    DECIMAL(19,4) NULL,
    ExpectedSource NVARCHAR(10)  NULL,      -- 預期量表 / 歷史平均
    HistoryMonths  INT           NULL,      -- 過去 12 個月有請購的月份數
    Ratio          DECIMAL(19,6) NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K07_Detail PRIMARY KEY (RunId, Material, Plant, Uom, Month)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K07
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @multiplier       DECIMAL(19,6) = kri.Param('K07', 'Multiplier'),        -- 幾倍以上標記
            @minHistoryMonths INT           = kri.Param('K07', 'MinHistoryMonths');  -- 歷史至少幾個月才判斷

    -- 觀察期間第一個月的 1 日；歷史從它往前 12 個月開始抓
    DECLARE @firstMonth   DATE = DATEFROMPARTS(YEAR(@PeriodFrom), MONTH(@PeriodFrom), 1);
    DECLARE @historyStart DATE = DATEADD(MONTH, -12, @firstMonth);

    -- 第 1 步：每個料號 × 工廠 × 單位 × 月份的請購數量（含往前 12 個月的歷史）
    SELECT Material, Plant, ISNULL(Uom, '') AS Uom,
           DATEFROMPARTS(YEAR(PrDate), MONTH(PrDate), 1) AS Month,
           SUM(ReqQty) AS Qty
    INTO #MonthQty
    FROM prc.PurchaseRequisition
    WHERE PrDate BETWEEN @historyStart AND @PeriodTo
      AND ISNULL(DeletionInd, '') = ''                    -- 沒刪除
      AND ReqQty > 0
      AND ISNULL(Material, '') <> '' AND ISNULL(Plant, '') <> ''
      AND NOT EXISTS (SELECT 1 FROM kri.IsGeneric('K07', Material))   -- 通用料號的數量是不同東西加總
    GROUP BY Material, Plant, ISNULL(Uom, ''), DATEFROMPARTS(YEAR(PrDate), MONTH(PrDate), 1);

    -- 第 2 步：觀察期間內每個月的預期量（預期量表優先，沒有用過去 12 個月有請購月份的平均）
    SELECT m.Material, m.Plant, m.Uom, m.Month, m.Qty,
           h.Qty    AS HistQty,       -- 過去 12 個月的請購量合計
           h.Months AS HistMonths,    -- 過去 12 個月有請購的月份數
           e.Qty    AS TableQty       -- 預期量表上的數字
    INTO #WithHistory
    FROM #MonthQty m
    OUTER APPLY (SELECT SUM(x.Qty) AS Qty, COUNT(*) AS Months
                 FROM #MonthQty x
                 WHERE x.Material = m.Material AND x.Plant = m.Plant AND x.Uom = m.Uom
                   AND x.Month >= DATEADD(MONTH, -12, m.Month) AND x.Month < m.Month) h
    LEFT JOIN ext.ExpectedDemand e ON e.Material = m.Material AND e.Plant = m.Plant AND e.Month = m.Month
    WHERE m.Month >= @firstMonth;                         -- 歷史月份只用來算平均，不進明細

    SELECT w.*,
           CASE WHEN w.TableQty IS NOT NULL            THEN w.TableQty
                WHEN w.HistMonths >= @minHistoryMonths THEN w.HistQty / w.HistMonths
           END AS Expected,
           CASE WHEN w.TableQty IS NOT NULL            THEN N'預期量表'
                WHEN w.HistMonths >= @minHistoryMonths THEN N'歷史平均'
           END AS Src                                     -- NULL = 歷史不足、不判斷
    INTO #Expected
    FROM #WithHistory w;

    -- 第 3 步：當月請購量超過預期量 Multiplier 倍 → 標記；寫進明細
    INSERT kri.K07_Detail (RunId, Material, Plant, Uom, Month, MonthQty, ExpectedQty, ExpectedSource,
                           HistoryMonths, Ratio, IsFlagged)
    SELECT @RunId, Material, Plant, Uom, Month, Qty, Expected, Src, HistMonths,
           Qty / NULLIF(Expected, 0),
           CASE WHEN Expected > 0 AND Qty / Expected > @multiplier THEN 1 ELSE 0 END
    FROM #Expected;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocDate,
                     MetricValue, ThresholdValue, Reason)
    SELECT RunId, 'K07', CONCAT(Material, '-', Plant, '-', Uom, '-', FORMAT(Month, 'yyyyMM')), 'MATERIAL', Plant, Material, Month,
           Ratio, @multiplier,
           CONCAT(FORMAT(Month, 'yyyy-MM'), N' 請購 ', FORMAT(MonthQty, 'N0'), N'，是', ExpectedSource, N' ',
                  FORMAT(ExpectedQty, 'N1'), N' 的 ', FORMAT(Ratio, 'N1'), N' 倍')
    FROM kri.K07_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'料號×工廠×月 ', COUNT(*), N'；用預期量表 ', COUNT(CASE WHEN ExpectedSource = N'預期量表' THEN 1 END),
                          N'；歷史不足不判斷（過去 12 個月有請購的月份少於 ', @minHistoryMonths, N'）',
                          COUNT(CASE WHEN ExpectedSource IS NULL THEN 1 END))
    FROM kri.K07_Detail WHERE RunId = @RunId;
END;
GO
