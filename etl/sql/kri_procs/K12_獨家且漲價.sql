-- ======================================================================
-- K12 集中且買貴
--
-- 【抓什麼】兩年內只跟一家供應商買的料號，今年的單價比去年漲很多，而且漲得比同類料號多。
-- 【為什麼有風險】只有一家可以買，供應商就有議價優勢；漲幅明顯比同類東西高，
--                 可能是被綁住、沒有在找替代來源，或有利益關係。
--
-- 【怎麼判斷】
--   第 1 步：抓前一年 + 本期（兩個期間）的 PO，分成「前一年」「本期」。通用料號（GenericMaterial）不看。
--   第 2 步：數每個料號兩個期間內有幾家供應商。這一步不套工廠、採購組織等排除條件，
--            免得被排掉的供應商讓料號看起來像獨家；只排除刻意排除的供應商（ExcludeVendorPrefix）。
--   第 3 步：每個「料號 × 供應商 × 幣別 × 單位」算前一年、本期的加權均價（金額 ÷ 數量）和漲幅。
--            兩期都要有採購才比。
--   第 4 步：同物料群組、同幣別、同單位的「其他」料號平均漲幅當基準（一個料號算一次）。
--            群組可比的料號不到 MinGroupMaterials 個時，基準當 0（只看自己漲多少）。
--   第 5 步：只有一家供應商、不在合理獨家名單（AllowedSingleSource），
--            而且漲幅 − 基準 > PriceTolerance → 標記。
--            影響金額 =（本期均價 − 前一年均價 ×（1 + 基準））× 本期數量，換成本幣。
--
-- 【門檻】（kri.Parameter，KriCode = 'K12'）
--   PriceTolerance     漲幅比群組基準多出多少才標記
--   MinGroupMaterials  群組內至少幾個其他料號可比才當基準；不夠以 0 計
--
-- 【名單】（kri.ValueList）
--   AllowedSingleSource  合理的獨家料號，不標記
--   ExcludeVendorPrefix  刻意排除的供應商（關係企業等），不算一個來源
--   GenericMaterial      通用、雜項料號，不看
--
-- 【明細表 kri.K12_Detail 怎麼看】（兩期都有採購的 料號 × 供應商）
--   VendorCount     兩個期間內這個料號有幾家供應商（1 = 獨家）
--   PriorPrice / CurPrice  前一年 / 本期的加權均價
--   PriceChange     本期均價 ÷ 前一年均價 − 1
--   GroupChange     同群組其他料號的平均漲幅；NULL = 可比的不夠（基準以 0 計）
--   ExcessChange    PriceChange − 基準
--
-- 【限制】
--   獨家先用 PO 資料判斷（客戶的獨家料號清單、製造商料號進來後改用）。
--   沒有物料群組的料號不當別人的基準。
-- ======================================================================
IF OBJECT_ID(N'kri.K12_Detail', N'U') IS NULL
CREATE TABLE kri.K12_Detail (
    RunId          INT           NOT NULL,
    Material       NVARCHAR(18)  NOT NULL,
    Vendor         NVARCHAR(10)  NOT NULL,
    Currency       NVARCHAR(5)   NOT NULL,
    OrderUom       NVARCHAR(10)  NOT NULL,
    MaterialGroup  NVARCHAR(20)  NULL,
    VendorCount    INT           NULL,      -- 兩個期間內這個料號的供應商家數
    PriorQty       DECIMAL(19,4) NULL,
    PriorPrice     DECIMAL(19,6) NULL,
    CurQty         DECIMAL(19,4) NULL,
    CurPrice       DECIMAL(19,6) NULL,
    PriceChange    DECIMAL(19,6) NULL,      -- 本期均價 ÷ 前一年均價 − 1
    GroupChange    DECIMAL(19,6) NULL,      -- 同群組其他料號的平均漲幅；NULL = 可比的不夠
    GroupMaterials INT           NULL,
    ExcessChange   DECIMAL(19,6) NULL,      -- PriceChange − 基準
    EffectLocal    DECIMAL(19,4) NULL,      -- （本期均價 − 前一年均價 ×（1 + 基準））× 本期數量
    LocalCurrency  NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K12_Detail PRIMARY KEY (RunId, Material, Vendor, Currency, OrderUom)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K12
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @tolerance         DECIMAL(19,6) = kri.Param('K12', 'PriceTolerance'),     -- 比基準多漲多少
            @minGroupMaterials INT           = kri.Param('K12', 'MinGroupMaterials');  -- 群組至少幾個料號才當基準

    DECLARE @priorFrom DATE = DATEADD(YEAR, -1, @PeriodFrom);     -- 前一年的開始

    -- 第 1 步：前一年 + 本期的 PO（IsCurrent = 1 是本期）
    SELECT b.Material, b.Vendor, b.Currency, b.OrderUom, b.MaterialGroup, b.OrderQty, b.NetValue,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal,
           b.LocalCurrency,
           CASE WHEN b.PoDate >= @PeriodFrom THEN 1 ELSE 0 END AS IsCurrent
    INTO #Po
    FROM kri.PoBase('K12', @priorFrom, @PeriodTo) b
    WHERE ISNULL(b.Material, '') <> '' AND b.IsGeneric = 0
      AND ISNULL(b.Vendor, '') <> '' AND b.NetValue IS NOT NULL;

    -- 第 2 步：每個料號兩個期間內有幾家供應商（不套工廠、採購組織等排除條件）
    SELECT d.Material, COUNT(DISTINCT d.Vendor) AS VendorCount
    INTO #VendorCount
    FROM prc.PurchaseOrderDetail d
    WHERE d.PoDate BETWEEN @priorFrom AND @PeriodTo
      AND ISNULL(d.DeletionInd, '') = '' AND ISNULL(d.Vendor, '') <> '' AND d.OrderQty > 0
      AND d.Material IN (SELECT Material FROM #Po)
      AND NOT EXISTS (SELECT 1 FROM kri.List('K12', 'ExcludeVendorPrefix') x    -- 刻意排除的供應商不算來源
                      WHERE d.Vendor LIKE x.Value + '%')
    GROUP BY d.Material;

    -- 第 3 步：每個 料號 × 供應商 × 幣別 × 單位，前一年、本期的數量和金額
    SELECT Material, Vendor, Currency, OrderUom, MAX(MaterialGroup) AS MaterialGroup,
           SUM(CASE WHEN IsCurrent = 0 THEN OrderQty ELSE 0 END)    AS PriorQty,
           SUM(CASE WHEN IsCurrent = 0 THEN NetValue ELSE 0 END)    AS PriorAmt,
           SUM(CASE WHEN IsCurrent = 1 THEN OrderQty ELSE 0 END)    AS CurQty,
           SUM(CASE WHEN IsCurrent = 1 THEN NetValue ELSE 0 END)    AS CurAmt,
           SUM(CASE WHEN IsCurrent = 1 THEN AmountLocal ELSE 0 END) AS CurAmtLocal,
           COUNT(CASE WHEN IsCurrent = 1 AND AmountLocal IS NULL THEN 1 END) AS CurNoLocal,   -- 本期換不出本幣的筆數
           CASE WHEN COUNT(DISTINCT LocalCurrency) = 1 THEN MAX(LocalCurrency) END AS LocalCurrency
    INTO #Pair
    FROM #Po
    GROUP BY Material, Vendor, Currency, OrderUom;

    --   均價與漲幅；兩期都要有採購
    SELECT p.*, vc.VendorCount,
           p.PriorAmt / NULLIF(p.PriorQty, 0) AS PriorPrice,
           p.CurAmt / NULLIF(p.CurQty, 0)     AS CurPrice,
           (p.CurAmt / NULLIF(p.CurQty, 0)) / NULLIF(p.PriorAmt / NULLIF(p.PriorQty, 0), 0) - 1 AS PriceChange
    INTO #Change
    FROM #Pair p
    JOIN #VendorCount vc ON vc.Material = p.Material
    WHERE p.PriorQty > 0 AND p.CurQty > 0;

    -- 第 4 步：同群組其他料號的平均漲幅
    --   先算每個料號自己的漲幅（多家供應商的料號合併算一次）；沒有物料群組的不比
    SELECT Material, Currency, OrderUom, MaterialGroup,
           (SUM(CurAmt) / SUM(CurQty)) / NULLIF(SUM(PriorAmt) / SUM(PriorQty), 0) - 1 AS MatChange
    INTO #MaterialChange
    FROM #Change
    WHERE MaterialGroup IS NOT NULL
    GROUP BY Material, Currency, OrderUom, MaterialGroup;

    --   每一列跟同群組、同幣別、同單位的「其他」料號比
    SELECT c.*, pe.n AS GroupMaterials, pe.AvgChange AS GroupAvg
    INTO #Group
    FROM #Change c
    OUTER APPLY (SELECT COUNT(*) AS n, AVG(m.MatChange) AS AvgChange
                 FROM #MaterialChange m
                 WHERE m.MaterialGroup = c.MaterialGroup AND m.Currency = c.Currency AND m.OrderUom = c.OrderUom
                   AND m.Material <> c.Material) pe;

    --   可比的料號夠多才當基準（GroupChange），不夠的基準以 0 計
    SELECT g.*,
           CASE WHEN g.GroupMaterials >= @minGroupMaterials THEN g.GroupAvg END AS GroupChange
    INTO #Baseline
    FROM #Group g;

    -- 第 5 步：獨家、不在合理獨家名單、漲幅比基準多超過 PriceTolerance → 標記；寫進明細
    INSERT kri.K12_Detail (RunId, Material, Vendor, Currency, OrderUom, MaterialGroup, VendorCount, PriorQty,
                           PriorPrice, CurQty, CurPrice, PriceChange, GroupChange, GroupMaterials, ExcessChange,
                           EffectLocal, LocalCurrency, IsFlagged)
    SELECT @RunId, b.Material, b.Vendor, b.Currency, b.OrderUom, b.MaterialGroup, b.VendorCount, b.PriorQty,
           b.PriorPrice, b.CurQty, b.CurPrice, b.PriceChange, b.GroupChange, b.GroupMaterials, x.ExcessChange,
           -- 影響金額：本期換不出本幣、或跨不同本幣的不算
           CASE WHEN f.IsFlagged = 1 AND b.CurNoLocal = 0 AND b.LocalCurrency IS NOT NULL
                THEN (b.CurPrice - b.PriorPrice * (1 + ISNULL(b.GroupChange, 0))) * b.CurQty
                     * b.CurAmtLocal / NULLIF(b.CurAmt, 0) END,                  -- × 本期的平均匯率換成本幣
           b.LocalCurrency, f.IsFlagged
    FROM #Baseline b
    CROSS APPLY (SELECT b.PriceChange - ISNULL(b.GroupChange, 0) AS ExcessChange) x
    CROSS APPLY (SELECT CASE WHEN b.VendorCount = 1
                              AND x.ExcessChange > @tolerance
                              AND b.Material NOT IN (SELECT Value FROM kri.List('K12', 'AllowedSingleSource'))
                             THEN 1 ELSE 0 END AS IsFlagged) f;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Vendor, Material,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K12', CONCAT(Material, '-', Vendor, '-', Currency, '-', OrderUom), 'MATERIAL', Vendor, Material,
           ExcessChange, @tolerance, EffectLocal, LocalCurrency,
           CONCAT(N'獨家供應料號，單價一年漲 ', FORMAT(PriceChange, 'P1'),
                  CASE WHEN GroupChange IS NULL THEN N'（群組可比料號不足，基準以 0 計）'
                       ELSE CONCAT(N'，同群組平均 ', FORMAT(GroupChange, 'P1')) END)
    FROM kri.K12_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'兩期都有採購的料號×供應商 ', COUNT(*), N'；獨家 ', COUNT(CASE WHEN VendorCount = 1 THEN 1 END),
                          N'；群組可比料號不足 ', COUNT(CASE WHEN VendorCount = 1 AND GroupChange IS NULL THEN 1 END))
    FROM kri.K12_Detail WHERE RunId = @RunId;
END;
GO
