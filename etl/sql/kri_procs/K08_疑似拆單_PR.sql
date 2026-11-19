-- ======================================================================
-- K08 疑似拆單（PR）
--
-- 【抓什麼】同一個成本中心、同一家供應商，短時間內開了好幾張 PR，每張單獨看金額都不大，
--           加起來卻需要更高層級的人核准。
-- 【為什麼有風險】把一筆大採購拆成幾張小 PR，可以避開高層級的簽核。
--
-- 【怎麼判斷】
--   第 1 步：找出 PR 項目和金額（數量 × 評價價格）。供應商用 PR 指定的固定供應商；
--            沒有指定時，用這張 PR 轉出、基準日以前已經下的 PO 的供應商。
--            成本中心或供應商空白的不分群。為了算滾動視窗，PR 日期往前多抓 WindowDays 天。
--   第 2 步：觀察期間內的每個 PR 項目，往前 WindowDays 天（含當天）內，同成本中心 + 同供應商 + 同幣別的
--            PR 金額加總，並數有幾張 PR。少於 MinCount 張的不看。
--   第 3 步：用核決權限表（kri.ApprovalMatrix，DocType = 'PR'）分別查「這一筆自己」和「視窗合計」
--            需要第幾層核決。合計需要的層級比單筆高 → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K08'）
--   WindowDays  滾動視窗天數
--   MinCount    視窗內至少幾張 PR 才算
--
-- 【明細表 kri.K08_Detail 怎麼看】
--   Amount         這個 PR 項目的金額（PR 幣別）
--   WindowAmount   視窗內同成本中心、同供應商、同幣別的 PR 金額合計
--   WindowPrCount  視窗內有幾張 PR（張數，不是項目數）
--   OwnLevel       單筆金額需要的核決層級；WindowLevel 是合計金額需要的層級
--
-- 【限制】
--   單筆金額低於核決表的最低區間，當作第 0 層（不用簽核）；合計金額要落在核決表的區間裡才會標記。
--   沒有填 kri.ApprovalMatrix 的 PR 核決權限時不會標記任何資料（備註會提示）。
--   PR 的價格單位不在規格內，金額先當價格單位 = 1；PR 沒有匯率，影響金額以 PR 幣別計。
--   部門暫時用成本中心代表。
-- ======================================================================
IF OBJECT_ID(N'kri.K08_Detail', N'U') IS NULL
CREATE TABLE kri.K08_Detail (
    RunId         INT           NOT NULL,
    PrNumber      NVARCHAR(10)  NOT NULL,
    PrItem        NVARCHAR(5)   NOT NULL,
    PrDate        DATE          NULL,
    CostCenter    NVARCHAR(10)  NULL,
    Vendor        NVARCHAR(10)  NULL,
    Material      NVARCHAR(18)  NULL,
    Plant         NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Currency      NVARCHAR(5)   NULL,
    Amount        DECIMAL(19,4) NULL,
    WindowAmount  DECIMAL(19,4) NULL,
    WindowPrCount INT           NULL,
    OwnLevel      INT           NULL,
    WindowLevel   INT           NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K08_Detail PRIMARY KEY (RunId, PrNumber, PrItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K08
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @windowDays INT = kri.Param('K08', 'WindowDays'),   -- 滾動視窗天數
            @minPrCount INT = kri.Param('K08', 'MinCount');     -- 視窗內至少幾張 PR

    -- 第 1 步：PR 項目、金額、供應商（往前多抓一個視窗的天數）
    SELECT r.PrNumber, r.PrItem, r.PrDate, r.CostCenter, r.Material, r.Plant, r.PurchOrg, r.Currency,
           COALESCE(NULLIF(r.Vendor, ''), po.Vendor) AS Vendor,        -- PR 沒指定供應商，用轉出的 PO 的
           CAST(r.ReqQty * r.ValPrice AS DECIMAL(19,4)) AS Amount
    INTO #Pr
    FROM prc.PurchaseRequisition r
    LEFT JOIN prc.PurchaseOrderDetail po
           ON po.PoNumber = r.PoNumber AND po.PoItem = r.PoItem
          AND po.PoDate <= @AsOfDate                                   -- 回補時不能用到基準日之後才開的 PO
    WHERE r.PrDate BETWEEN DATEADD(DAY, -(@windowDays - 1), @PeriodFrom) AND @PeriodTo
      AND ISNULL(r.DeletionInd, '') = ''
      AND r.ReqQty > 0 AND r.ValPrice > 0;

    DELETE #Pr WHERE ISNULL(CostCenter, '') = '' OR ISNULL(Vendor, '') = '';   -- 成本中心、供應商空白的不分群

    -- 第 2 步：觀察期間內每個 PR 項目，往前 WindowDays 天內同成本中心 + 同供應商 + 同幣別的合計
    SELECT i.PrNumber, i.PrItem,
           SUM(j.Amount)              AS WindowAmount,
           COUNT(DISTINCT j.PrNumber) AS WindowPrCount
    INTO #Window
    FROM #Pr i
    JOIN #Pr j ON j.CostCenter = i.CostCenter AND j.Vendor = i.Vendor AND j.Currency = i.Currency
              AND j.PrDate BETWEEN DATEADD(DAY, -(@windowDays - 1), i.PrDate) AND i.PrDate
    WHERE i.PrDate BETWEEN @PeriodFrom AND @PeriodTo
    GROUP BY i.PrNumber, i.PrItem
    HAVING COUNT(DISTINCT j.PrNumber) >= @minPrCount;

    -- 第 3 步：單筆、合計各需要第幾層核決；合計的層級比較高 → 標記；寫進明細
    INSERT kri.K08_Detail (RunId, PrNumber, PrItem, PrDate, CostCenter, Vendor, Material, Plant, PurchOrg,
                           Currency, Amount, WindowAmount, WindowPrCount, OwnLevel, WindowLevel, IsFlagged)
    SELECT @RunId, p.PrNumber, p.PrItem, p.PrDate, p.CostCenter, p.Vendor, p.Material, p.Plant, p.PurchOrg,
           p.Currency, p.Amount, w.WindowAmount, w.WindowPrCount, ISNULL(own.Lvl, 0), win.Lvl,                -- 單筆低於核決表最低區間 = 第 0 層（不用簽核）
           CASE WHEN win.Lvl > ISNULL(own.Lvl, 0) THEN 1 ELSE 0 END
    FROM #Window w
    JOIN #Pr p ON p.PrNumber = w.PrNumber AND p.PrItem = w.PrItem
    OUTER APPLY (SELECT TOP 1 a.ApprovalLevel AS Lvl            -- 單筆金額落在哪個核決區間
                 FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'PR' AND a.CompanyCode = '*' AND a.Currency = p.Currency
                   AND p.Amount >= a.MinAmount AND p.Amount < a.MaxAmount
                   AND p.PrDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY a.ApprovalLevel DESC) own
    OUTER APPLY (SELECT TOP 1 a.ApprovalLevel AS Lvl            -- 視窗合計落在哪個核決區間
                 FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'PR' AND a.CompanyCode = '*' AND a.Currency = p.Currency
                   AND w.WindowAmount >= a.MinAmount AND w.WindowAmount < a.MaxAmount
                   AND p.PrDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY a.ApprovalLevel DESC) win;

    -- 寫標記（PR 沒有匯率，影響金額先以 PR 幣別計）
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, PurchOrg, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K08', CONCAT(PrNumber, '-', PrItem), 'PR', Plant, PurchOrg, Vendor, Material,
           PrNumber, PrItem, PrDate, WindowAmount, NULL, Amount, Currency,
           CONCAT(@windowDays, N' 天內同成本中心同供應商 ', WindowPrCount, N' 張 PR，合計需第 ', WindowLevel,
                  N' 層核決，單筆只需第 ', OwnLevel, N' 層')
    FROM kri.K08_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    IF NOT EXISTS (SELECT 1 FROM kri.ApprovalMatrix WHERE DocType = 'PR')
        SET @Note = N'kri.ApprovalMatrix 沒有 PR 的核決權限，這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'候選 PR 項目 ', COUNT(*)) FROM kri.K08_Detail WHERE RunId = @RunId;
END;
GO
