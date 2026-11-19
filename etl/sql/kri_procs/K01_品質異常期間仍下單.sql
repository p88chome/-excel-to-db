-- ======================================================================
-- K01 品質異常期間仍下單
--
-- 【抓什麼】供應商有品質異常單還沒結案的期間，仍然對它下 PO。
-- 【為什麼有風險】品質問題還沒解決就繼續買，可能買到同樣有問題的東西；
--                 也可能是採購刻意忽略品質部門的警示。
--
-- 【怎麼判斷】
--   第 1 步：讀品質異常單（ext.QualityIssue），算出每張單「開立日 → 結案日」的期間。
--            還沒結案、或結案日在基準日之後（回補過去的基準日）的，算到基準日為止。
--            供應商、料號是純數字的補前導零，才對得到 SAP 的代碼。
--   第 2 步：找出觀察期間內、下單日落在這段期間的同供應商 PO 項目。
--            RequireSameMaterial = 1 時只算跟異常單同料號的 PO。
--   第 3 步：一張異常單期間內的 PO 項目數 >= MinPoCount → 這些 PO 項目標記。
--   第 4 步：一個 PO 項目可能同時落在好幾張異常單的期間內，標記時以 PO 項目為單位、列出張數。
--
-- 【門檻】（kri.Parameter，KriCode = 'K01'）
--   MinPoCount           一張異常單期間內至少幾筆 PO 項目才標記
--   RequireSameMaterial  1 = 只看和異常單同料號的 PO；0 = 同供應商就算
--
-- 【明細表 kri.K01_Detail 怎麼看】一列 = 一張異常單 × 一個 PO 項目
--   WindowEnd     異常單期間的結束日（結案日；未結案 = 基準日）
--   SameMaterial  1 = PO 的料號跟異常單一樣
--   IssuePoCount  這張異常單期間內同供應商的 PO 項目數
--
-- 【限制】
--   已結案但沒有結案日的異常單不知道期間到哪天，略過，筆數寫在執行結果的說明裡。
-- ======================================================================
IF OBJECT_ID(N'kri.K01_Detail', N'U') IS NULL
CREATE TABLE kri.K01_Detail (
    RunId         INT           NOT NULL,
    IssueNo       NVARCHAR(50)  NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    IssueStatus   NVARCHAR(50)  NULL,
    OpenedOn      DATE          NULL,
    WindowEnd     DATE          NULL,      -- 結案日；未結案 = 基準日
    PoDate        DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    VendorName    NVARCHAR(80)  NULL,
    Material      NVARCHAR(18)  NULL,
    IssueMaterial NVARCHAR(40)  NULL,
    SameMaterial  BIT           NOT NULL,
    IssuePoCount  INT           NULL,      -- 這張單期間內同供應商的 PO 項目數
    AmountLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K01_Detail PRIMARY KEY (RunId, IssueNo, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K01
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @minPoCount      INT = kri.Param('K01', 'MinPoCount'),            -- 一張單期間內至少幾筆 PO 項目
            @requireSameMat  INT = kri.Param('K01', 'RequireSameMaterial');   -- 1 = 只算同料號

    -- 第 1 步：異常單和它的期間（開立日 → 結案日；還沒結案算到基準日）
    SELECT IssueNo, Status, OpenedOn,
           CASE WHEN IsClosed = 1 AND ClosedOn <= @AsOfDate THEN ClosedOn
                ELSE @AsOfDate END AS WindowEnd,           -- 結案日晚於基準日 = 基準日當時還沒結案
           -- 純數字的代碼補前導零：供應商 10 碼、料號 18 碼
           CASE WHEN Vendor NOT LIKE '%[^0-9]%' AND LEN(Vendor) < 10
                THEN RIGHT(REPLICATE('0', 10) + Vendor, 10) ELSE Vendor END AS Vendor,
           CASE WHEN ISNULL(Material, '') <> '' AND Material NOT LIKE '%[^0-9]%' AND LEN(Material) < 18
                THEN RIGHT(REPLICATE('0', 18) + Material, 18) ELSE Material END AS Material
    INTO #Issue
    FROM ext.QualityIssue
    WHERE ISNULL(Vendor, '') <> ''
      AND OpenedOn <= @PeriodTo                            -- 觀察期間結束前開立
      AND (IsClosed = 0 OR ClosedOn >= @PeriodFrom);       -- 觀察期間開始時還沒結案（沒有結案日的已結案單會被排除）

    -- 第 2 步：異常單期間內，同供應商下的 PO 項目
    SELECT q.IssueNo, q.Status, q.OpenedOn, q.WindowEnd, q.Material AS IssueMaterial,
           b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
           b.Material, b.LocalCurrency,
           CASE WHEN ISNULL(q.Material, '') <> '' AND b.Material = q.Material THEN 1 ELSE 0 END AS SameMaterial,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal
    INTO #IssuePo
    FROM #Issue q
    JOIN kri.PoBase('K01', @PeriodFrom, @PeriodTo) b                -- 整段期間的 PO 抓一次，再依每張單的期間對
      ON b.Vendor = q.Vendor
     AND b.PoDate BETWEEN q.OpenedOn AND q.WindowEnd
    WHERE @requireSameMat = 0
       OR (ISNULL(q.Material, '') <> '' AND b.Material = q.Material);

    -- 第 3 步：每張異常單期間內有幾筆 PO 項目，達門檻的標記；寫進明細
    INSERT kri.K01_Detail (RunId, IssueNo, PoNumber, PoItem, IssueStatus, OpenedOn, WindowEnd, PoDate,
                           CompanyCode, PurchOrg, Plant, Vendor, VendorName, Material, IssueMaterial,
                           SameMaterial, IssuePoCount, AmountLocal, LocalCurrency, IsFlagged)
    SELECT @RunId, IssueNo, PoNumber, PoItem, Status, OpenedOn, WindowEnd, PoDate,
           CompanyCode, PurchOrg, Plant, Vendor, VendorName, Material, IssueMaterial,
           SameMaterial, IssuePoCount, AmountLocal, LocalCurrency,
           CASE WHEN IssuePoCount >= @minPoCount THEN 1 ELSE 0 END
    FROM (SELECT p.*, COUNT(*) OVER (PARTITION BY p.IssueNo) AS IssuePoCount FROM #IssuePo p) x;

    -- 第 4 步（寫標記）：一個 PO 項目可能落在好幾張單的期間內，以 PO 項目為單位、列出張數
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT @RunId, 'K01', CONCAT(PoNumber, '-', PoItem), 'PO', MAX(CompanyCode), MAX(PurchOrg), MAX(Plant),
           MAX(Vendor), MAX(Material), PoNumber, PoItem, MAX(PoDate), MAX(IssuePoCount), @minPoCount,
           MAX(AmountLocal), MAX(LocalCurrency),
           CONCAT(N'下單時供應商有 ', COUNT(*), N' 張品質異常單未結案（', MIN(IssueNo),
                  CASE WHEN COUNT(*) > 1 THEN N' 等' ELSE N'' END, N'）',
                  CASE WHEN MAX(CAST(SameMaterial AS INT)) = 1 THEN N'，含同料號' ELSE N'' END)
    FROM kri.K01_Detail
    WHERE RunId = @RunId AND IsFlagged = 1
    GROUP BY PoNumber, PoItem;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'異常單 ', (SELECT COUNT(*) FROM ext.QualityIssue),
                          N' 張（未結案 ', (SELECT COUNT(*) FROM ext.QualityIssue WHERE IsClosed = 0),
                          N'、已結案但沒有結案日略過 ',
                          (SELECT COUNT(*) FROM ext.QualityIssue WHERE IsClosed = 1 AND ClosedOn IS NULL),
                          N'）；期間內對到的 PO 項目 ', COUNT(DISTINCT CONCAT(PoNumber, '-', PoItem)))
    FROM kri.K01_Detail WHERE RunId = @RunId;
END;
GO
