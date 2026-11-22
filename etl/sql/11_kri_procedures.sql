-- 由 etl/build_kri_sql.py 把 etl/sql/kri_procs/ 底下每一題的檔合併產生，不要手改這個檔。
-- 要改某一題：改 kri_procs/ 底下那一題的檔，再跑 python etl/build_kri_sql.py。
--
-- 每題一張明細表 kri.Kxx_Detail（每次執行一個 RunId），被標記的列另外寫一列到 kri.Flag。
-- 程序由 kri.RunAll 呼叫；交易與執行紀錄由 RunAll 處理，程序本身不開交易。
-- 明細表只在不存在時建立；改了欄位要先手動 DROP 那張明細表再跑。
--
-- 目錄：
--   K01  品質異常期間仍下單
--   K02  關聯供應商
--   K03  停用供應商短暫啟用
--   K04  付款條件比主檔差
--   K05  OpenPO超過資本額
--   K06  庫存足夠仍請購
--   K07  請購量暴增
--   K08  疑似拆單_PR
--   K09  疑似拆單_AP
--   K10  先收貨後補PO
--   K11  非緊急之緊急採購
--   K12  獨家且漲價
--   K13  跨據點單價差異
--   K14  PO單價高於主檔價
--   K15  即將呆滯
--   K16  呆滯料仍採購
--   K17  重大工程未簽約
--   K18  OpenPO收貨進度落後
--   K19  收貨太貼近請購日
--   K20  驗退未及時處理

-- ######################################################################
-- 檔案：kri_procs/K01_品質異常期間仍下單.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K02_關聯供應商.sql
-- ######################################################################
-- ======================================================================
-- K02 工商登記關聯供應商（先做 SAP 內部版）
--
-- 【抓什麼】不同的供應商代碼，其實是同一家或關係企業：統編、電話、地址、銀行帳號相同，
--           或商工登記列為關聯。再看這兩家有沒有可疑的交易：
--           ① 其中一家已凍結，另一家期間內仍有 PO（凍結了換個代碼繼續做生意）；
--           ② 兩家期間內買過同樣的料號（關係企業互相陪標、輪流得標）。
-- 【為什麼有風險】凍結的供應商換殼繼續交易、關係企業圍標，都是常見的舞弊手法。
--
-- 【怎麼判斷】
--   第 1 步：算出每家供應商「基準日當時」有沒有凍結。主檔是現在的值，基準日之後才改的凍結欄位
--            用 kri.VendorValueAt 從異動紀錄還原。凍結 = 中央凍結，或每個採購組織／公司別都凍結
--            （只凍結其中一個組織不算）。帳戶群組在 ExcludeAccountGroup 的不算凍結。
--   第 2 步：整理每家供應商拿來比對的值：統編、電話（去掉 - 空白 +）、地址（去掉空白和標點、轉大寫）、
--            銀行帳號（國家-銀行代碼-帳號）。填充值（NA、0000000000、XXXXXXXXXX、----）不拿來比：
--            統編至少 4 個數字、電話和銀行帳號至少 6 個數字、地址至少 6 個字，而且不能是 kri.IsPlaceholder。
--   第 3 步：兩家的值一樣 → 配成一對。同一個值超過 MaxGroupSize 家共用（代理商、園區總機）的不配。
--            商工登記的關聯（ext.VendorRelation）另外配，A、B 正反兩筆、多種關係併成一對。
--   第 4 步：抓這些供應商在觀察期間內的 PO。
--   第 5 步：看每一對的情境，符合 ① 或 ② → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K02'）
--   MaxGroupSize  同一個統編／電話／地址／帳號超過幾家共用就不配對
--
-- 【名單】（kri.ValueList）
--   MatchAttribute       要比對哪些欄位：TaxNumber、Phone、Address、BankAccount
--   ExcludeAccountGroup  這些帳戶群組的供應商就算凍結也不算（例如一次性供應商）
--
-- 【明細表 kri.K02_Detail 怎麼看】一列 = 一對供應商 × 一種相同的欄位
--   MatchType / MatchValue  哪個欄位相同、相同的值（商工登記 = 關係類型）
--   ABlocked / BBlocked     基準日當時有沒有凍結
--   APoCount / BPoCount     觀察期間內各自的 PO 項目數；金額跨不同本幣時留空
--   CommonMaterials         兩家都買過的料號數
--   Scenario                凍結廠商關聯交易 / 關聯廠商同料號
--
-- 【限制】
--   供應商名稱在資料裡被遮罩成 -，不能拿來比對。
--   銀行帳號直接讀 SAP 原表 LFBK（kri.vVendorBank），環境裡沒有這張表時不比帳號。
--   銀行帳號是現在的資料：回補過去的基準日時，之後才新增、刪除的帳號沒有還原（異動紀錄目前沒有 LFBK）。
--   兩家共用好幾個帳號時併成一對，MatchValue 用「；」列出全部共用的帳號。
-- ======================================================================
IF OBJECT_ID(N'kri.K02_Detail', N'U') IS NULL
CREATE TABLE kri.K02_Detail (
    RunId           INT           NOT NULL,
    VendorA         NVARCHAR(10)  NOT NULL,
    VendorB         NVARCHAR(10)  NOT NULL,
    MatchType       NVARCHAR(30)  NOT NULL,   -- TaxNumber / Phone / Address / BankAccount / 商工登記
    MatchValue      NVARCHAR(200) NULL,
    ABlocked        BIT           NOT NULL,
    BBlocked        BIT           NOT NULL,
    APoCount        INT           NULL,
    BPoCount        INT           NULL,
    APoAmountLocal  DECIMAL(19,4) NULL,
    BPoAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency   NVARCHAR(5)   NULL,
    CommonMaterials INT           NULL,
    Scenario        NVARCHAR(30)  NULL,       -- 凍結廠商關聯交易 / 關聯廠商同料號
    IsFlagged       BIT           NOT NULL,
    CONSTRAINT PK_kri_K02_Detail PRIMARY KEY (RunId, VendorA, VendorB, MatchType)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K02
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @maxGroupSize INT = kri.Param('K02', 'MaxGroupSize');   -- 超過幾家共用同一個值就不配對

    -- 第 1 步：每家供應商基準日當時有沒有凍結
    --   mst.Vendor 一家會有好幾列（採購組織 × 公司別），先每列判斷，再整家合起來
    SELECT v.Vendor,
           CASE WHEN ex.Value IS NOT NULL THEN 1 ELSE 0 END AS ExcludedGroup,     -- 排除的帳戶群組
           -- 中央凍結（LFA1）：採購凍結或過帳凍結任一有值
           CASE WHEN COALESCE(a1.ValueThen, v.CentralPurchBlock, '') <> ''
                  OR COALESCE(a2.ValueThen, v.CentralPostingBlock, '') <> '' THEN 1 ELSE 0 END AS CentralBlocked,
           -- 這一列的採購組織（LFM1）或公司別（LFB1）凍結
           CASE WHEN COALESCE(m1.ValueThen, v.PurchasingBlock, '') <> ''
                  OR COALESCE(b1.ValueThen, v.PostingBlock, '') <> '' THEN 1 ELSE 0 END AS OrgBlocked
    INTO #VendorRow
    FROM mst.Vendor v
    LEFT JOIN kri.List('K02', 'ExcludeAccountGroup') ex ON ex.Value = v.VendorAccountGroup
    -- 基準日之後改過的話，用基準日當時的值（沒改過 = NULL，用主檔現在的值）
    OUTER APPLY kri.VendorValueAt(v.Vendor, 'LFA1', 'SPERM', '', @AsOfDate) a1
    OUTER APPLY kri.VendorValueAt(v.Vendor, 'LFA1', 'SPERR', '', @AsOfDate) a2
    OUTER APPLY (SELECT ValueThen FROM kri.VendorValueAt(v.Vendor, 'LFM1', 'SPERM', v.PurchOrg, @AsOfDate)
                 WHERE ISNULL(v.PurchOrg, '') <> '') m1
    OUTER APPLY (SELECT ValueThen FROM kri.VendorValueAt(v.Vendor, 'LFB1', 'SPERR', v.CompanyCode, @AsOfDate)
                 WHERE ISNULL(v.CompanyCode, '') <> '') b1;

    SELECT Vendor,
           CASE WHEN MAX(ExcludedGroup) = 0
                 AND (MAX(CentralBlocked) = 1 OR MIN(OrgBlocked) = 1) THEN 1 ELSE 0 END AS Blocked
    INTO #VendorBlock
    FROM #VendorRow
    GROUP BY Vendor;

    -- 第 2 步：每家供應商拿來比對的值（先整理格式，再去掉填充值）
    SELECT v.Vendor,
           NULLIF(LTRIM(RTRIM(v.TaxNumber)), '')                                              AS Tax,
           NULLIF(REPLACE(REPLACE(REPLACE(v.Phone, '-', ''), ' ', ''), '+', ''), '')         AS Phone,
           NULLIF(UPPER(REPLACE(REPLACE(REPLACE(v.Address, ' ', ''), ',', ''), '.', '')), '') AS Addr
    INTO #VendorValue
    FROM mst.Vendor v;

    SELECT Vendor, CAST('TaxNumber' AS NVARCHAR(30)) AS MatchType, CAST(Tax AS NVARCHAR(200)) AS MatchValue
    INTO #Attr
    FROM #VendorValue
    WHERE kri.DigitCount(Tax) >= 4 AND kri.IsPlaceholder(Tax) = 0
    UNION      -- UNION 去重複：同一家好幾列是同一個值時只留一筆
    SELECT Vendor, 'Phone', Phone
    FROM #VendorValue
    WHERE kri.DigitCount(Phone) >= 6 AND kri.IsPlaceholder(Phone) = 0
    UNION
    SELECT Vendor, 'Address', Addr
    FROM #VendorValue
    WHERE LEN(Addr) >= 6 AND kri.IsPlaceholder(Addr) = 0
    UNION      -- 銀行帳號：一家可以有好幾個
    SELECT Vendor, 'BankAccount', CONCAT(BankCountry, '-', BankKey, '-', Account)
    FROM (SELECT Vendor, BankCountry, BankKey,
                 REPLACE(REPLACE(BankAccount, ' ', ''), '-', '') AS Account
          FROM kri.vVendorBank) b
    WHERE kri.DigitCount(Account) >= 6 AND kri.IsPlaceholder(Account) = 0;

    -- 一家同一種欄位只留一個值（例：統編在不同公司別各填一次），帳號除外
    DELETE a FROM #Attr a
    WHERE a.MatchType <> 'BankAccount'
      AND a.MatchValue < (SELECT MAX(x.MatchValue) FROM #Attr x WHERE x.Vendor = a.Vendor AND x.MatchType = a.MatchType);

    -- 第 3 步：配對
    --   (1) 同一個值的兩家供應商；只比 MatchAttribute 白名單裡的欄位，共用家數超過門檻的不配
    SELECT a.*, COUNT(*) OVER (PARTITION BY a.MatchType, a.MatchValue) AS SharedBy
    INTO #AttrShared
    FROM #Attr a
    WHERE a.MatchType IN (SELECT Value FROM kri.List('K02', 'MatchAttribute'));

    --   兩家共用好幾個銀行帳號時併成一對，帳號用「；」串起來
    SELECT x.Vendor AS VendorA, y.Vendor AS VendorB, x.MatchType,
           LEFT(STRING_AGG(CAST(x.MatchValue AS NVARCHAR(MAX)), N'；') WITHIN GROUP (ORDER BY x.MatchValue), 200) AS MatchValue
    INTO #Pair
    FROM #AttrShared x
    JOIN #AttrShared y ON y.MatchType = x.MatchType AND y.MatchValue = x.MatchValue AND x.Vendor < y.Vendor
    WHERE x.SharedBy <= @maxGroupSize
    GROUP BY x.Vendor, y.Vendor, x.MatchType;

    --   (2) 商工登記的關聯：A、B 正反兩筆、多種關係都併成一對
    INSERT #Pair (VendorA, VendorB, MatchType, MatchValue)
    SELECT VendorA, VendorB, N'商工登記',
           LEFT(STRING_AGG(CAST(Rel AS NVARCHAR(MAX)), N'；') WITHIN GROUP (ORDER BY Rel), 200)
    FROM (SELECT DISTINCT
                 CASE WHEN VendorA < VendorB THEN VendorA ELSE VendorB END AS VendorA,   -- 小的放 A
                 CASE WHEN VendorA < VendorB THEN VendorB ELSE VendorA END AS VendorB,
                 RelationType + ISNULL(N'（' + Note + N'）', N'') AS Rel
          FROM ext.VendorRelation
          WHERE VendorA <> VendorB) r
    GROUP BY VendorA, VendorB;

    -- 第 4 步：有配對的供應商在觀察期間內的 PO
    SELECT b.Vendor, b.Material, b.LocalCurrency,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal
    INTO #Po
    FROM kri.PoBase('K02', @PeriodFrom, @PeriodTo) b
    WHERE b.Vendor IN (SELECT VendorA FROM #Pair UNION SELECT VendorB FROM #Pair);

    SELECT Vendor, COUNT(*) AS PoCount, SUM(AmountLocal) AS Amount,
           COUNT(DISTINCT LocalCurrency) AS Currencies, MAX(LocalCurrency) AS Currency
    INTO #PoSum
    FROM #Po
    GROUP BY Vendor;

    -- 第 5 步：每一對的情境，寫進明細
    SELECT p.VendorA, p.VendorB, p.MatchType, p.MatchValue,
           va.Blocked AS ABlocked, vb.Blocked AS BBlocked,
           ISNULL(sa.PoCount, 0) AS APoCount, ISNULL(sb.PoCount, 0) AS BPoCount,
           sa.Amount AS AAmount, sb.Amount AS BAmount, sa.Currencies AS ACurrencies, sb.Currencies AS BCurrencies,
           sa.Currency AS ACurrency, sb.Currency AS BCurrency,
           cm.n AS CommonMaterials,
           -- ① 一家凍結、另一家期間內仍有 PO
           CASE WHEN (va.Blocked = 1 AND sb.PoCount > 0) OR (vb.Blocked = 1 AND sa.PoCount > 0) THEN 1 ELSE 0 END AS BlockedTrade
    INTO #PairResult
    FROM #Pair p
    JOIN #VendorBlock va ON va.Vendor = p.VendorA          -- 兩家都要在供應商主檔裡
    JOIN #VendorBlock vb ON vb.Vendor = p.VendorB
    LEFT JOIN #PoSum sa ON sa.Vendor = p.VendorA
    LEFT JOIN #PoSum sb ON sb.Vendor = p.VendorB
    OUTER APPLY (SELECT COUNT(*) AS n                       -- ② 兩家都買過的料號數
                 FROM (SELECT DISTINCT Material FROM #Po WHERE Vendor = p.VendorA AND ISNULL(Material, '') <> ''
                       INTERSECT
                       SELECT DISTINCT Material FROM #Po WHERE Vendor = p.VendorB) m) cm;

    INSERT kri.K02_Detail (RunId, VendorA, VendorB, MatchType, MatchValue, ABlocked, BBlocked, APoCount, BPoCount,
                           APoAmountLocal, BPoAmountLocal, LocalCurrency, CommonMaterials, Scenario, IsFlagged)
    SELECT @RunId, r.VendorA, r.VendorB, r.MatchType, r.MatchValue, r.ABlocked, r.BBlocked, r.APoCount, r.BPoCount,
           CASE WHEN c.SameCurrency = 1 THEN r.AAmount END,
           CASE WHEN c.SameCurrency = 1 THEN r.BAmount END,
           COALESCE(r.ACurrency, r.BCurrency),
           r.CommonMaterials,
           CASE WHEN r.BlockedTrade = 1     THEN N'凍結廠商關聯交易'
                WHEN r.CommonMaterials > 0  THEN N'關聯廠商同料號' END,
           CASE WHEN r.BlockedTrade = 1 OR r.CommonMaterials > 0 THEN 1 ELSE 0 END
    FROM #PairResult r
    -- 金額只在兩家都是同一個本幣時才填（跨幣別不能相加比較）
    CROSS APPLY (SELECT CASE WHEN ISNULL(r.ACurrencies, 1) = 1 AND ISNULL(r.BCurrencies, 1) = 1
                              AND (r.ACurrency IS NULL OR r.BCurrency IS NULL OR r.ACurrency = r.BCurrency)
                             THEN 1 ELSE 0 END AS SameCurrency) c;

    -- 寫標記：凍結廠商的情境，影響金額 = 沒凍結那一家的 PO；同料號的情境 = 兩家合計
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Vendor, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K02', CONCAT(VendorA, '-', VendorB, '-', MatchType), 'VENDOR', VendorA, CommonMaterials, NULL,
           CASE WHEN Scenario = N'凍結廠商關聯交易'
                THEN CASE WHEN ABlocked = 1 THEN BPoAmountLocal ELSE APoAmountLocal END
                ELSE ISNULL(APoAmountLocal, 0) + ISNULL(BPoAmountLocal, 0) END,
           LocalCurrency,
           CONCAT(N'供應商 ', VendorA, N' 和 ', VendorB, N' ', MatchType, N' 相同；', Scenario,
                  CASE WHEN CommonMaterials > 0 THEN CONCAT(N'（共同料號 ', CommonMaterials, N'）') ELSE N'' END)
    FROM kri.K02_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'關聯供應商配對 ', COUNT(*), N'（商工登記 ', COUNT(CASE WHEN MatchType = N'商工登記' THEN 1 END),
                          N'）；有凍結的配對 ', COUNT(CASE WHEN ABlocked = 1 OR BBlocked = 1 THEN 1 END))
    FROM kri.K02_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K03_停用供應商短暫啟用.sql
-- ######################################################################
-- ======================================================================
-- K03 已停用供應商短暫啟用交易
--
-- 【抓什麼】已經凍結的供應商被解凍，交易做完沒多久又凍結回去。
-- 【為什麼有風險】「解凍 → 下單或付款 → 再凍結」是繞過凍結控制的典型手法：
--                 主檔平常看起來是凍結的，交易卻做成了。
--
-- 【怎麼判斷】
--   第 1 步：從供應商異動紀錄找出凍結欄位（BlockField 名單）的每一筆異動，算出精確的異動時間。
--   第 2 步：解凍 = 凍結欄位從有值改成空白，只看觀察期間內的解凍。
--            LFM1（採購組織層）、LFB1（公司別層）記下是哪個組織（TableKey 第 14 碼起 4 碼）。
--   第 3 步：找每次解凍之後、同一個欄位下一次改回有值 = 再凍結（只看基準日以前的異動）。
--   第 4 步：數解凍期間內的交易：
--            PO 項目（採購凍結 SPERM 擋的是 PO；LFM1 只看那個採購組織、LFB1 只看那個公司別）；
--            應付傳票（過帳凍結 SPERR 擋的是傳票；用系統輸入日判斷，過帳日倒填也抓得到）。
--            其他凍結欄位兩種交易都算。
--   第 5 步：解凍後 MaxOpenDays 天內就再凍結，而且期間內有 PO 或應付傳票 → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K03'）
--   MaxOpenDays  解凍後幾天內又凍結算「短暫」
--
-- 【名單】（kri.ValueList）
--   BlockField  哪些欄位算凍結欄位（SPERM 採購凍結、SPERR 過帳凍結）
--
-- 【明細表 kri.K03_Detail 怎麼看】一列 = 一次解凍
--   UnblockChange  解凍那筆異動的異動編號
--   Scope          LFM1 = 採購組織、LFB1 = 公司別、LFA1 = 空白（整家）
--   ReblockDate    再凍結的日期；還沒再凍結 = 空白
--   OpenDays       解凍了幾天（還沒再凍結的算到基準日）
--   PoCount / ApCount  解凍期間內的 PO 項目數、應付傳票張數；PO 跨不同本幣時金額留空
--
-- 【限制】
--   還沒再凍結的解凍事件留在明細、不標記。異動紀錄要涵蓋觀察期間之前的狀態才完整。
-- ======================================================================
IF OBJECT_ID(N'kri.K03_Detail', N'U') IS NULL
CREATE TABLE kri.K03_Detail (
    RunId          INT           NOT NULL,
    Vendor         NVARCHAR(10)  NOT NULL,
    TableName      NVARCHAR(30)  NOT NULL,
    TableKey       NVARCHAR(70)  NOT NULL,
    FieldName      NVARCHAR(30)  NOT NULL,
    UnblockChange  NVARCHAR(10)  NOT NULL,
    Scope          NVARCHAR(4)   NULL,      -- LFM1 = 採購組織、LFB1 = 公司別、LFA1 = 空白（全部）
    UnblockDate    DATE          NULL,
    UnblockedBy    NVARCHAR(12)  NULL,
    ReblockDate    DATE          NULL,      -- 還沒再凍結 = NULL
    ReblockedBy    NVARCHAR(12)  NULL,
    OpenDays       INT           NULL,      -- 沒再凍結的算到基準日
    PoCount        INT           NULL,
    PoAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency  NVARCHAR(5)   NULL,      -- PO 跨不同本幣時留 NULL、金額也留 NULL
    ApCount        INT           NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K03_Detail PRIMARY KEY (RunId, Vendor, TableName, TableKey, FieldName, UnblockChange)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K03
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @maxOpenDays INT = kri.Param('K03', 'MaxOpenDays');   -- 解凍後幾天內又凍結算「短暫」

    -- 第 1 步：凍結欄位的所有異動，加上精確的異動時間（日期 + 時間）
    SELECT h.Vendor, h.ChangeNumber, h.ChangeDate, h.ChangedBy, h.TableName, h.TableKey, h.FieldName,
           h.OldValue, h.NewValue,
           DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME), ISNULL(h.ChangeTime, '00:00')),
                   CAST(h.ChangeDate AS DATETIME2(0))) AS ChangeAt
    INTO #BlockChange
    FROM mst.VendorChangeHistory h
    WHERE h.FieldName IN (SELECT Value FROM kri.List('K03', 'BlockField'));

    -- 第 2 步：觀察期間內的解凍（有值 → 空白）
    SELECT c.*,
           CASE WHEN c.TableName IN ('LFM1', 'LFB1') THEN SUBSTRING(c.TableKey, 14, 4) ELSE '' END AS Scope
    INTO #Unblock
    FROM #BlockChange c
    WHERE ISNULL(c.OldValue, '') <> '' AND ISNULL(c.NewValue, '') = ''
      AND c.ChangeDate BETWEEN @PeriodFrom AND @PeriodTo;

    -- 第 3 步：每次解凍之後，同一個欄位第一次改回有值 = 再凍結
    SELECT u.*, r.ChangeDate AS ReblockDate, r.ChangedBy AS ReblockedBy
    INTO #Event
    FROM #Unblock u
    OUTER APPLY (SELECT TOP 1 x.ChangeDate, x.ChangedBy
                 FROM #BlockChange x
                 WHERE x.Vendor = u.Vendor AND x.TableName = u.TableName AND x.TableKey = u.TableKey
                   AND x.FieldName = u.FieldName
                   AND ISNULL(x.NewValue, '') <> ''
                   AND (x.ChangeAt > u.ChangeAt OR (x.ChangeAt = u.ChangeAt AND x.ChangeNumber > u.ChangeNumber))
                   AND x.ChangeDate <= @AsOfDate          -- 回補過去的基準日時，不能看到基準日之後的異動
                 ORDER BY x.ChangeAt, x.ChangeNumber) r;

    -- 第 4 步：解凍期間內的 PO 和應付傳票
    SELECT e.*, ISNULL(e.ReblockDate, @AsOfDate) AS OpenUntil,
           po.Cnt AS PoCount, po.Currencies, po.Cur, po.Amount, ap.Cnt AS ApCount
    INTO #EventTrade
    FROM #Event e
    OUTER APPLY (
        SELECT COUNT(*) AS Cnt, COUNT(DISTINCT b.LocalCurrency) AS Currencies, MAX(b.LocalCurrency) AS Cur,
               SUM(kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate)) AS Amount
        FROM kri.PoBase('K03', e.ChangeDate, ISNULL(e.ReblockDate, @AsOfDate)) b
        WHERE b.Vendor = e.Vendor
          AND e.FieldName <> 'SPERR'                            -- 過帳凍結只擋傳票，不算 PO
          AND (e.TableName <> 'LFM1' OR b.PurchOrg = e.Scope)
          AND (e.TableName <> 'LFB1' OR b.CompanyCode = e.Scope)
    ) po
    OUTER APPLY (
        SELECT COUNT(DISTINCT CONCAT(a.CompanyCode, '-', a.AccountingDoc, '-', a.FiscalYear)) AS Cnt
        FROM fin.AccountsPayable a
        WHERE a.Vendor = e.Vendor
          AND e.FieldName <> 'SPERM'                            -- 採購凍結只擋 PO，不算傳票
          -- 凍結擋的是輸入當下：系統輸入日（沒有才用過帳日）落在解凍期間才算
          AND ISNULL(a.EntryDate, a.PostingDate) BETWEEN e.ChangeDate AND ISNULL(e.ReblockDate, @AsOfDate)
          AND ISNULL(a.EntryDate, a.PostingDate) <= @AsOfDate   -- 基準日之後才補入帳的不算
          AND (e.TableName <> 'LFB1' OR a.CompanyCode = e.Scope)
    ) ap;

    -- 第 5 步：短暫解凍又有交易 → 標記；寫進明細
    INSERT kri.K03_Detail (RunId, Vendor, TableName, TableKey, FieldName, UnblockChange, Scope,
                           UnblockDate, UnblockedBy, ReblockDate, ReblockedBy, OpenDays,
                           PoCount, PoAmountLocal, LocalCurrency, ApCount, IsFlagged)
    SELECT @RunId, t.Vendor, t.TableName, t.TableKey, t.FieldName, t.ChangeNumber, t.Scope,
           t.ChangeDate, t.ChangedBy, t.ReblockDate, t.ReblockedBy,
           DATEDIFF(DAY, t.ChangeDate, t.OpenUntil),
           ISNULL(t.PoCount, 0),
           CASE WHEN t.Currencies = 1 THEN t.Amount END,         -- PO 跨不同本幣時不加總
           CASE WHEN t.Currencies = 1 THEN t.Cur END,
           ISNULL(t.ApCount, 0),
           CASE WHEN t.ReblockDate IS NOT NULL
                 AND DATEDIFF(DAY, t.ChangeDate, t.ReblockDate) <= @maxOpenDays
                 AND ISNULL(t.PoCount, 0) + ISNULL(t.ApCount, 0) > 0 THEN 1 ELSE 0 END
    FROM #EventTrade t;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, PurchOrg, CompanyCode, Vendor,
                     DocNumber, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K03', CONCAT(Vendor, '-', TableName, '-', Scope, '-', FieldName, '-', UnblockChange), 'VENDOR',
           CASE WHEN TableName = 'LFM1' THEN Scope END,
           CASE WHEN TableName = 'LFB1' THEN Scope END,
           Vendor, UnblockChange, UnblockDate, OpenDays, @maxOpenDays, PoAmountLocal, LocalCurrency,
           CONCAT(TableName, N'.', FieldName, N' 解凍 ', OpenDays, N' 天後再凍結；期間內 PO 項目 ', PoCount,
                  N' 筆、應付傳票 ', ApCount, N' 張',
                  CASE WHEN UnblockedBy = ReblockedBy THEN N'；解凍與再凍結同一人' ELSE N'' END)
    FROM kri.K03_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'解凍事件 ', COUNT(*), N'；尚未再凍結 ', COUNT(CASE WHEN ReblockDate IS NULL THEN 1 END))
    FROM kri.K03_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K04_付款條件比主檔差.sql
-- ######################################################################
-- ======================================================================
-- K04 付款條件比主檔差
--
-- 【抓什麼】PO 上的付款條件比供應商主檔的條件更早付款，或者應付傳票（發票）上的條件比 PO 更早付款。
-- 【為什麼有風險】提早付款等於把錢先給供應商，公司損失資金成本；
--                 個別採購或會計把條件改得對供應商比較好，可能是圖利。
--
-- 【怎麼判斷】
--   第 1 步：觀察期間內的 PO 項目，帶出 PO 的付款條件，和「下單當時」主檔的付款條件：
--            採購組織層（LFM1，PO 預設帶這個）和公司別層（LFB1，參考用）。
--            主檔是現在的值，下單之後改過的話，用 kri.VendorValueAt 從異動紀錄還原成下單當時的值。
--   第 2 步：找出這些 PO 項目的應付傳票上出現過的付款條件（只看基準日當時已入帳的貸方傳票）。
--   第 3 步：把每個付款條件代碼換成天數（kri.TermDays：先查 kri.PaymentTerm 對照表，沒有就從代碼推估）。
--   第 4 步：每個 PO 項目挑一個應付條件來比：和 PO 不同的優先，再挑天數最少（最早付款）的。
--   第 5 步：比兩件事：
--            PO 和主檔是否不同（MasterLevel = 2 時，跟公司別層一樣也算一致）；
--            應付和 PO 是否不同。
--            PO 條件空白時，發票會帶主檔的條件，所以有應付就用應付的條件當作 PO 的實際條件；
--            沒有應付才當立即付款（0 天）。
--   第 6 步：提早的天數 >= MinDaysWorse → 標記。
--            影響金額 = PO 本幣金額 × 提早天數 ÷ 365 × AnnualRate（提早付款的資金成本）。
--
-- 【門檻】（kri.Parameter，KriCode = 'K04'）
--   MinDaysWorse  提早幾天以上付款才標記
--   AnnualRate    資金成本年利率，用來換算影響金額
--   MasterLevel   1 = PO 只跟採購組織層（LFM1）比；2 = 跟公司別層（LFB1）一樣也算一致
--
-- 【明細表 kri.K04_Detail 怎麼看】
--   PoTerm / MasterTerm / CompanyTerm / ApTerm  PO、主檔（採購組織層、公司別層，下單當時）、應付的付款條件
--   PoDays / MasterDays / ApDays                 換成天數
--   Status         一致 / 同公司別主檔 / PO與主檔不同 / AP與PO不同 / 都不同 / 缺主檔
--   WorseDays      提早幾天付款（兩項比較取比較多的那個）
--   DaysEstimated  1 = 用到的天數有從代碼推估的（不在 kri.PaymentTerm），要拿 T052 確認
--
-- 【限制】
--   付款條件天數在 kri.PaymentTerm 填好之前是推估的。主檔異動紀錄要有 ZTERM 才還原得了下單當時的值。
-- ======================================================================
IF OBJECT_ID(N'kri.K04_Detail', N'U') IS NULL
CREATE TABLE kri.K04_Detail (
    RunId          INT           NOT NULL,
    PoNumber       NVARCHAR(10)  NOT NULL,
    PoItem         NVARCHAR(5)   NOT NULL,
    PoDate         DATE          NULL,
    CompanyCode    NVARCHAR(4)   NULL,
    PurchOrg       NVARCHAR(4)   NULL,
    Vendor         NVARCHAR(10)  NULL,
    VendorName     NVARCHAR(80)  NULL,
    PoTerm         NVARCHAR(4)   NULL,
    MasterTerm     NVARCHAR(4)   NULL,      -- LFM1（PO 預設帶這個）
    CompanyTerm    NVARCHAR(4)   NULL,      -- LFB1（參考）
    ApTerm         NVARCHAR(4)   NULL,      -- 這個 PO 項目的應付傳票中，天數最少的付款條件
    PoDays         INT           NULL,
    MasterDays     INT           NULL,
    ApDays         INT           NULL,
    Status         NVARCHAR(20)  NOT NULL,  -- 一致 / 同公司別主檔 / PO與主檔不同 / AP與PO不同 / 都不同 / 缺主檔
    WorseDays      INT           NULL,      -- 提早幾天付款（兩項比較取較大者）
    AmountLocal    DECIMAL(19,4) NULL,
    LocalCurrency  NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    EffectLocal    DECIMAL(19,4) NULL,
    DaysEstimated  BIT           NULL,      -- 1 = 用到的天數有從代碼推估的（不在 kri.PaymentTerm）
    CONSTRAINT PK_kri_K04_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO
IF COL_LENGTH('kri.K04_Detail', 'DaysEstimated') IS NULL
    ALTER TABLE kri.K04_Detail ADD DaysEstimated BIT NULL;
GO

CREATE OR ALTER PROCEDURE kri.Run_K04
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @minDaysWorse INT           = kri.Param('K04', 'MinDaysWorse'),   -- 提早幾天以上才標記
            @annualRate   DECIMAL(19,6) = kri.Param('K04', 'AnnualRate'),     -- 資金成本年利率
            @masterLevel  INT           = kri.Param('K04', 'MasterLevel');    -- 1 = 只認 LFM1；2 = 跟 LFB1 一樣也算一致

    -- 第 1 步：PO 項目、PO 的付款條件、主檔現在的付款條件
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Vendor, b.VendorName,
           b.LocalCurrency,
           ISNULL(p.PaymentTerm, '') AS PoTerm,                     -- 空白 = 沒填（發票會帶主檔條件）
           (SELECT TOP 1 v.PurchOrgPaymentTerms FROM mst.Vendor v    -- 採購組織層（LFM1）現在的條件
            WHERE v.Vendor = b.Vendor AND v.PurchOrg = b.PurchOrg AND ISNULL(v.PurchOrgPaymentTerms, '') <> ''
            ORDER BY v.CompanyCode) AS MasterTermNow,
           (SELECT TOP 1 v.PaymentTerms FROM mst.Vendor v            -- 公司別層（LFB1）現在的條件
            WHERE v.Vendor = b.Vendor AND v.CompanyCode = b.CompanyCode AND ISNULL(v.PaymentTerms, '') <> ''
            ORDER BY v.PurchOrg) AS CompanyTermNow,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal
    INTO #PoNow
    FROM kri.PoBase('K04', @PeriodFrom, @PeriodTo) b
    JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
    WHERE ISNULL(b.Vendor, '') <> '';

    --   主檔條件換成下單當時的值：下單之後改過的，用異動紀錄的舊值；沒改過就用現在的值
    SELECT n.PoNumber, n.PoItem, n.PoDate, n.CompanyCode, n.PurchOrg, n.Vendor, n.VendorName,
           n.LocalCurrency, n.PoTerm, n.AmountLocal,
           CAST(NULLIF(COALESCE(hm.ValueThen, n.MasterTermNow), '') AS NVARCHAR(4))  AS MasterTerm,
           CAST(NULLIF(COALESCE(hc.ValueThen, n.CompanyTermNow), '') AS NVARCHAR(4)) AS CompanyTerm
    INTO #Po
    FROM #PoNow n
    OUTER APPLY (SELECT ValueThen FROM kri.VendorValueAt(n.Vendor, 'LFM1', 'ZTERM', n.PurchOrg, n.PoDate)
                 WHERE ISNULL(n.PurchOrg, '') <> '') hm
    OUTER APPLY (SELECT ValueThen FROM kri.VendorValueAt(n.Vendor, 'LFB1', 'ZTERM', n.CompanyCode, n.PoDate)
                 WHERE ISNULL(n.CompanyCode, '') <> '') hc;

    -- 第 2 步：應付傳票上出現過的付款條件（只看基準日當時已入帳的）
    SELECT DISTINCT a.PoNumber, a.PoItem, a.PaymentTerms AS Code
    INTO #ApTerm
    FROM fin.AccountsPayable a
    JOIN #Po b ON b.PoNumber = a.PoNumber AND b.PoItem = a.PoItem
    WHERE ISNULL(a.PaymentTerms, '') <> ''
      AND ISNULL(a.DebitCreditInd, '') <> 'S'   -- 排除借方（貸項通知單、預付沖回，條件常是立即）；借貸別空白的照樣比
      AND a.PostingDate <= @AsOfDate
      AND ISNULL(a.EntryDate, a.PostingDate) <= @AsOfDate;

    -- 第 3 步：每個付款條件代碼換成天數（每個代碼只算一次）
    --   Estimated = 1：不在 kri.PaymentTerm 對照表，天數是從代碼推估的
    SELECT c.Code, kri.TermDays(c.Code) AS Days,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM kri.PaymentTerm t WHERE t.Code = c.Code) THEN 0 ELSE 1 END AS BIT) AS Estimated
    INTO #TermDays
    FROM (SELECT PoTerm AS Code FROM #Po
          UNION SELECT MasterTerm  FROM #Po
          UNION SELECT CompanyTerm FROM #Po
          UNION SELECT Code        FROM #ApTerm) c
    WHERE ISNULL(c.Code, '') <> '';

    -- 第 4 步：每個 PO 項目挑一個應付條件：和 PO 不同的優先（PO 空白時跟主檔比），再挑天數最少的
    SELECT PoNumber, PoItem, Code
    INTO #ApPick
    FROM (SELECT a.PoNumber, a.PoItem, a.Code,
                 ROW_NUMBER() OVER (PARTITION BY a.PoNumber, a.PoItem
                                    ORDER BY CASE WHEN a.Code = CASE WHEN b.PoTerm = '' THEN b.MasterTerm ELSE b.PoTerm END
                                                  THEN 1 ELSE 0 END,                 -- 一樣的排後面
                                             ISNULL(t.Days, 2147483647),             -- 天數少的排前面
                                             a.Code) AS rn
          FROM #ApTerm a
          JOIN #TermDays t ON t.Code = a.Code
          JOIN #Po b ON b.PoNumber = a.PoNumber AND b.PoItem = a.PoItem) x
    WHERE rn = 1;

    -- 第 5 步：比 PO vs 主檔、應付 vs PO
    SELECT b.*, ap.Code AS ApTerm, eff.Term AS EffTerm,
           -- PO 的天數：PO 條件空白時，有應付就用應付的天數，沒有應付當立即付款（0 天）
           CASE WHEN b.PoTerm = '' THEN CASE WHEN ap.Code IS NULL THEN 0 ELSE ta.Days END
                ELSE tp.Days END AS PoDays,
           tm.Days AS MasterDays,
           ta.Days AS ApDays,
           -- PO（實際條件）和主檔不同；MasterLevel = 2 時跟公司別層一樣也算一致
           CASE WHEN eff.Term <> b.MasterTerm
                 AND NOT (@masterLevel = 2 AND ISNULL(b.CompanyTerm, '') <> '' AND eff.Term = b.CompanyTerm)
                THEN 1 ELSE 0 END AS PoDiff,
           -- 應付和 PO（實際條件）不同
           CASE WHEN ap.Code IS NOT NULL AND ap.Code <> eff.Term THEN 1 ELSE 0 END AS ApDiff,
           CASE WHEN b.PoTerm = '' THEN CASE WHEN ap.Code IS NULL THEN 0 ELSE ta.Estimated END
                ELSE tp.Estimated END AS PoEst,
           tm.Estimated AS MasterEst,
           ta.Estimated AS ApEst
    INTO #Compare
    FROM #Po b
    LEFT JOIN #ApPick ap   ON ap.PoNumber = b.PoNumber AND ap.PoItem = b.PoItem
    LEFT JOIN #TermDays tp ON tp.Code = b.PoTerm
    LEFT JOIN #TermDays tm ON tm.Code = b.MasterTerm
    LEFT JOIN #TermDays ta ON ta.Code = ap.Code
    -- PO 的實際條件：PO 空白而且有應付 = 應付的條件（發票帶主檔），用它跟主檔比、應付不再跟 PO 比
    CROSS APPLY (SELECT CASE WHEN b.PoTerm = '' AND ap.Code IS NOT NULL THEN ap.Code ELSE b.PoTerm END AS Term) eff;

    SELECT c.*,
           CASE WHEN MasterTerm IS NULL           THEN N'缺主檔'
                WHEN PoDiff = 1 AND ApDiff = 1    THEN N'都不同'
                WHEN PoDiff = 1                   THEN N'PO與主檔不同'
                WHEN ApDiff = 1                   THEN N'AP與PO不同'
                WHEN EffTerm <> MasterTerm        THEN N'同公司別主檔'
                ELSE N'一致' END AS Status,
           -- 提早幾天：兩項比較取比較多的
           (SELECT MAX(v) FROM (VALUES (CASE WHEN PoDiff = 1 THEN MasterDays - PoDays END),
                                       (CASE WHEN ApDiff = 1 THEN PoDays - ApDays END)) x(v)) AS WorseDays,
           -- 用到的天數裡有推估的
           CAST(CASE WHEN PoEst = 1 OR (PoDiff = 1 AND MasterEst = 1) OR (ApDiff = 1 AND ApEst = 1)
                     THEN 1 ELSE 0 END AS BIT) AS DaysEstimated
    INTO #Result
    FROM #Compare c;

    -- 第 6 步：提早天數達門檻 → 標記；寫進明細
    INSERT kri.K04_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Vendor, VendorName,
           PoTerm, MasterTerm, CompanyTerm, ApTerm, PoDays, MasterDays, ApDays, Status, WorseDays,
           AmountLocal, LocalCurrency, IsFlagged, EffectLocal, DaysEstimated)
    SELECT @RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Vendor, VendorName,
           PoTerm, MasterTerm, CompanyTerm, ApTerm, PoDays, MasterDays, ApDays, Status, WorseDays,
           AmountLocal, LocalCurrency,
           CASE WHEN WorseDays >= @minDaysWorse THEN 1 ELSE 0 END,
           CASE WHEN WorseDays >= @minDaysWorse THEN AmountLocal * WorseDays / 365.0 * @annualRate END,
           DaysEstimated
    FROM #Result;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Vendor,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K04', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Vendor,
           PoNumber, PoItem, PoDate, WorseDays, @minDaysWorse, EffectLocal, LocalCurrency,
           CONCAT(N'付款條件 PO ', CASE WHEN PoTerm = '' THEN N'（空白）' ELSE PoTerm END, N' / 主檔 ', MasterTerm,
                  CASE WHEN ApTerm IS NOT NULL THEN CONCAT(N' / 應付 ', ApTerm) ELSE N'' END,
                  N'，提早 ', WorseDays, N' 天付款',
                  CASE WHEN DaysEstimated = 1 THEN N'（天數為推估）' ELSE N'' END)
    FROM kri.K04_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'PO 項目 ', COUNT(*), N'；PO與主檔不同 ', COUNT(CASE WHEN Status IN (N'PO與主檔不同', N'都不同') THEN 1 END),
                          N'、AP與PO不同 ', COUNT(CASE WHEN Status IN (N'AP與PO不同', N'都不同') THEN 1 END),
                          N'、缺主檔 ', COUNT(CASE WHEN Status = N'缺主檔' THEN 1 END),
                          N'、PO 條件空白 ', COUNT(CASE WHEN PoTerm = '' THEN 1 END),
                          N'、和 LFM1 不同但同 LFB1 ', COUNT(CASE WHEN Status = N'同公司別主檔' THEN 1 END),
                          N'；條件不同但推不出天數 ',
                          COUNT(CASE WHEN Status NOT IN (N'一致', N'缺主檔', N'同公司別主檔') AND WorseDays IS NULL THEN 1 END),
                          N'；標記中天數為推估 ', COUNT(CASE WHEN IsFlagged = 1 AND DaysEstimated = 1 THEN 1 END))
    FROM kri.K04_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K05_OpenPO超過資本額.sql
-- ######################################################################
-- ======================================================================
-- K05 Open PO 超過供應商資本額
--
-- 【抓什麼】給一家供應商的未交貨 PO 金額，比它的實收資本額還大很多。
-- 【為什麼有風險】小公司接遠超過自己規模的訂單，可能交不出貨（供應風險），
--                 也可能是人頭公司、空殼公司（舞弊風險）。
--
-- 【怎麼判斷】
--   第 1 步：觀察期間內下單、基準日當時還沒結案、還沒收齊的 PO 項目，算出未收金額（換成本幣）。
--            基準日當時已收多少用 kri.PoReceivedAt 算，基準日之後才收的貨不算已收。
--   第 2 步：每家供應商的未收金額合計。有任何一個項目換不出本幣，合計就不算（未判斷）。
--   第 3 步：找供應商的實收資本額（ext.VendorCapital）：先用供應商代碼對，對不到再用統編對；
--            同一家有好幾筆時取基準日以前最新的一筆。
--   第 4 步：未收金額 ÷ 資本額 > CapitalRatio → 標記。
--            影響金額 = 超過的部分（未收金額 − 資本額 × CapitalRatio）。
--
-- 【門檻】（kri.Parameter，KriCode = 'K05'）
--   CapitalRatio  Open PO 未收金額 ÷ 實收資本額超過多少（1 = 超過資本額）
--   WindowMonths  只看最近幾個月下的 PO（預設 36）
--
-- 【明細表 kri.K05_Detail 怎麼看】一列 = 一家有 Open PO 的供應商
--   OpenAmountLocal  基準日當時的未收金額合計（本幣）
--   Capital          實收資本額；CapitalCurrency 是它的幣別
--   Ratio            未收金額 ÷ 資本額
--   Status           已比對 / 無資本額（例如國外廠商查不到）/ 未判斷（幣別不同、跨本幣、換不出本幣）
--
-- 【限制】
--   資本額要從商工登記另外整理進 ext.VendorCapital；不同幣別不換算，直接列「未判斷」。
-- ======================================================================
IF OBJECT_ID(N'kri.K05_Detail', N'U') IS NULL
CREATE TABLE kri.K05_Detail (
    RunId            INT           NOT NULL,
    Vendor           NVARCHAR(10)  NOT NULL,
    VendorName       NVARCHAR(80)  NULL,
    OpenPoCount      INT           NULL,
    OpenAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    Capital          DECIMAL(19,2) NULL,
    CapitalCurrency  NVARCHAR(5)   NULL,
    Ratio            DECIMAL(19,6) NULL,
    Status           NVARCHAR(10)  NOT NULL,  -- 已比對 / 無資本額 / 未判斷
    IsFlagged        BIT           NOT NULL,
    CONSTRAINT PK_kri_K05_Detail PRIMARY KEY (RunId, Vendor)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K05
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @capitalRatio DECIMAL(19,6) = kri.Param('K05', 'CapitalRatio');   -- 未收金額 ÷ 資本額超過多少

    -- 第 1 步：基準日當時還沒結案、還沒收齊的 PO 項目，和未收金額（本幣）
    SELECT b.Vendor, b.VendorName, b.LocalCurrency,
           kri.ToLocal((b.OrderQty - r.ReceivedQty) * b.UnitPrice, b.Currency, b.LocalCurrency, b.ExchangeRate) AS OpenLocal
    INTO #OpenPo
    FROM kri.PoBase('K05', @PeriodFrom, @PeriodTo) b
    CROSS APPLY kri.PoReceivedAt(b.PoNumber, b.PoItem, b.GrQty, b.DelivComplInd, b.PoDate, @AsOfDate) r
    WHERE ISNULL(b.Vendor, '') <> ''
      AND r.IsClosed = 0                    -- 基準日當時還沒結案
      AND r.ReceivedQty < b.OrderQty;       -- 還沒收齊

    -- 第 2 步：每家供應商的未收金額合計
    SELECT Vendor, MAX(VendorName) AS VendorName, COUNT(*) AS OpenPoCount,
           CASE WHEN COUNT(*) = COUNT(OpenLocal) THEN SUM(OpenLocal) END AS OpenAmount,   -- 有任一項目換不了本幣就不算
           COUNT(DISTINCT LocalCurrency) AS Currencies,
           MAX(LocalCurrency) AS LocalCurrency
    INTO #VendorOpen
    FROM #OpenPo
    GROUP BY Vendor;

    -- 第 3 步：找實收資本額（供應商代碼優先，其次統編；取基準日以前最新的）
    SELECT o.*, c.Capital, c.Currency AS CapitalCurrency
    INTO #WithCapital
    FROM #VendorOpen o
    OUTER APPLY (SELECT TOP 1 x.Capital, x.Currency
                 FROM ext.VendorCapital x
                 WHERE (x.Vendor = o.Vendor
                        OR (x.Vendor IS NULL
                            AND x.TaxNumber IN (SELECT NULLIF(LTRIM(RTRIM(v.TaxNumber)), '')
                                                FROM mst.Vendor v WHERE v.Vendor = o.Vendor)))
                   AND (x.DataDate IS NULL OR x.DataDate <= @AsOfDate)
                 ORDER BY CASE WHEN x.Vendor IS NULL THEN 1 ELSE 0 END,    -- 代碼對到的優先
                          x.DataDate DESC) c;

    -- 第 4 步：能不能比、比例多少，超過門檻 → 標記；寫進明細
    SELECT w.*,
           CASE WHEN w.Capital IS NULL OR w.Capital <= 0                         THEN N'無資本額'
                WHEN w.Currencies <> 1 OR w.LocalCurrency <> w.CapitalCurrency
                     OR w.OpenAmount IS NULL                                     THEN N'未判斷'
                ELSE N'已比對' END AS Status
    INTO #Result
    FROM #WithCapital w;

    INSERT kri.K05_Detail (RunId, Vendor, VendorName, OpenPoCount, OpenAmountLocal, LocalCurrency,
                           Capital, CapitalCurrency, Ratio, Status, IsFlagged)
    SELECT @RunId, Vendor, VendorName, OpenPoCount,
           CASE WHEN Currencies = 1 THEN OpenAmount END,        -- 跨不同本幣不加總
           CASE WHEN Currencies = 1 THEN LocalCurrency END,
           Capital, CapitalCurrency,
           CASE WHEN Status = N'已比對' THEN OpenAmount / Capital END,
           Status,
           CASE WHEN Status = N'已比對' AND OpenAmount / Capital > @capitalRatio THEN 1 ELSE 0 END
    FROM #Result;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Vendor, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K05', Vendor, 'VENDOR', Vendor, Ratio, @capitalRatio,
           OpenAmountLocal - Capital * @capitalRatio,             -- 超過的部分
           LocalCurrency,
           CONCAT(N'Open PO 未收金額 ', FORMAT(OpenAmountLocal, 'N0'), N' 是實收資本額的 ', FORMAT(Ratio, 'P0'))
    FROM kri.K05_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'有 Open PO 的供應商 ', COUNT(*), N'；已比對 ', COUNT(CASE WHEN Status = N'已比對' THEN 1 END),
                          N'、無資本額 ', COUNT(CASE WHEN Status = N'無資本額' THEN 1 END),
                          N'、未判斷 ', COUNT(CASE WHEN Status = N'未判斷' THEN 1 END),
                          CASE WHEN NOT EXISTS (SELECT 1 FROM ext.VendorCapital) THEN N'（ext.VendorCapital 沒有資料）' ELSE N'' END)
    FROM kri.K05_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K06_庫存足夠仍請購.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K07_請購量暴增.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K08_疑似拆單_PR.sql
-- ######################################################################
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
--   PR 沒有公司別，只用 CompanyCode = '*' 的 PR 核決權限；只填了特定公司別的 PR 權限不會用到（備註會提示）。
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
    ELSE IF NOT EXISTS (SELECT 1 FROM kri.ApprovalMatrix WHERE DocType = 'PR' AND CompanyCode = '*')
        SET @Note = N'kri.ApprovalMatrix 的 PR 核決權限只有特定公司別；PR 沒有公司別，要填 CompanyCode = ''*'' 才會用到，這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'候選 PR 項目 ', COUNT(*)) FROM kri.K08_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K09_疑似拆單_AP.sql
-- ######################################################################
-- ======================================================================
-- K09 疑似拆單（direct AP）
--
-- 【抓什麼】沒有走 PO、直接請款的應付傳票，同一家供應商（同成本中心）短時間內好幾張，
--           每張單獨看金額不大，加起來卻需要更高層級的人核准。
-- 【為什麼有風險】不經採購直接請款，再拆成小額，可以同時避開採購流程和高層級簽核。
--
-- 【怎麼判斷】
--   第 1 步：找出沒有 PO 的應付傳票。一張傳票 + 一家供應商算一筆，本幣金額加總。
--            排除借方（貸項、沖回）、自己清自己的付款或清帳傳票、排除的傳票類型（ExcludeDocType）、
--            排除的供應商（ExcludeVendorPrefix）；有設定 IncludeDocType 時只看那些類型。
--            只看基準日以前已經輸入的傳票。為了算滾動視窗，過帳日往前多抓 WindowDays 天。
--   第 2 步：觀察期間內的每張傳票，往前 WindowDays 天（含當天）內，同公司別 + 同供應商 + 同成本中心的
--            傳票金額加總，並數有幾張。少於 MinCount 張的不看。
--   第 3 步：用核決權限表（kri.ApprovalMatrix，DocType = 'AP'）分別查「這張自己」和「視窗合計」
--            需要第幾層核決。合計需要的層級比單張高 → 標記。公司別有自己的核決表就用，沒有用 '*'。
--
-- 【門檻】（kri.Parameter，KriCode = 'K09'）
--   WindowDays  滾動視窗天數
--   MinCount    視窗內至少幾張傳票才算
--
-- 【名單】（kri.ValueList）
--   ExcludeDocType       不看的傳票類型（付款、清帳傳票等）
--   IncludeDocType       只看這些傳票類型（沒設定 = 全部）
--   ExcludeVendorPrefix  不看的供應商（代碼開頭）
--
-- 【明細表 kri.K09_Detail 怎麼看】
--   Amount          這張傳票、這家供應商的本幣金額
--   CostCenter      供應商行上的成本中心；空白 = 沒有成本中心，整家供應商算一群
--   WindowAmount    視窗內合計；WindowDocCount 視窗內幾張傳票
--   OwnLevel        單張需要的核決層級；WindowLevel 合計需要的層級
--
-- 【限制】
--   單筆金額低於核決表的最低區間，當作第 0 層（不用簽核）；合計金額要落在核決表的區間裡才會標記。
--   沒有填 kri.ApprovalMatrix 的 AP 核決權限時不會標記任何資料（備註會提示）。
--   成本中心目前只看供應商行；沖銷傳票要等 BKPF.STBLG 進來才能排除。
-- ======================================================================
IF OBJECT_ID(N'kri.K09_Detail', N'U') IS NULL
CREATE TABLE kri.K09_Detail (
    RunId          INT           NOT NULL,
    CompanyCode    NVARCHAR(4)   NOT NULL,
    AccountingDoc  NVARCHAR(10)  NOT NULL,
    FiscalYear     NVARCHAR(4)   NOT NULL,
    Vendor         NVARCHAR(10)  NOT NULL,
    VendorName     NVARCHAR(80)  NULL,
    PostingDate    DATE          NULL,
    DocumentType   NVARCHAR(2)   NULL,
    CostCenter     NVARCHAR(10)  NULL,      -- 空白 = 供應商行沒有成本中心，整個供應商算一群
    LocalCurrency  NVARCHAR(5)   NULL,
    Amount         DECIMAL(19,4) NULL,
    WindowAmount   DECIMAL(19,4) NULL,
    WindowDocCount INT           NULL,
    OwnLevel       INT           NULL,
    WindowLevel    INT           NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K09_Detail PRIMARY KEY (RunId, CompanyCode, AccountingDoc, FiscalYear, Vendor)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K09
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @windowDays  INT = kri.Param('K09', 'WindowDays'),   -- 滾動視窗天數
            @minDocCount INT = kri.Param('K09', 'MinCount');     -- 視窗內至少幾張傳票

    -- 有沒有設定「只看這些傳票類型」（0 = 沒設定，全部都看）
    DECLARE @includeTypeCount INT = (SELECT COUNT(*) FROM kri.List('K09', 'IncludeDocType'));

    -- 第 1 步：沒有 PO 的應付傳票，一張傳票 + 一家供應商一筆（往前多抓一個視窗的天數）
    SELECT a.CompanyCode, a.AccountingDoc, a.FiscalYear, a.Vendor,
           MAX(a.VendorName)                         AS VendorName,
           MIN(a.PostingDate)                        AS PostingDate,
           MAX(a.DocumentType)                       AS DocumentType,
           ISNULL(MAX(NULLIF(a.CostCenter, '')), '') AS CostCenter,
           MAX(c.LocalCurrency)                      AS LocalCurrency,
           SUM(a.LocalAmount)                        AS Amount
    INTO #Doc
    FROM fin.AccountsPayable a
    LEFT JOIN kri.vCompanyCurrency c ON c.CompanyCode = a.CompanyCode
    WHERE ISNULL(a.PoNumber, '') = ''                                -- 沒有 PO
      AND ISNULL(a.Vendor, '') <> ''
      AND ISNULL(a.DebitCreditInd, '') <> 'S'                        -- 借方（貸項、沖回）不算
      AND ISNULL(a.ClearingDoc, '') <> a.AccountingDoc               -- 付款、清帳傳票自己清自己，不是發票
      AND ISNULL(a.DocumentType, '') NOT IN (SELECT Value FROM kri.List('K09', 'ExcludeDocType'))
      AND (@includeTypeCount = 0 OR a.DocumentType IN (SELECT Value FROM kri.List('K09', 'IncludeDocType')))
      AND NOT EXISTS (SELECT 1 FROM kri.List('K09', 'ExcludeVendorPrefix') x WHERE a.Vendor LIKE x.Value + '%')
      AND a.PostingDate BETWEEN DATEADD(DAY, -(@windowDays - 1), @PeriodFrom) AND @PeriodTo
      AND ISNULL(a.EntryDate, a.PostingDate) <= @AsOfDate            -- 基準日之後才輸入的不算
    GROUP BY a.CompanyCode, a.AccountingDoc, a.FiscalYear, a.Vendor
    HAVING SUM(a.LocalAmount) > 0;
    CREATE CLUSTERED INDEX cx ON #Doc (CompanyCode, Vendor, CostCenter, PostingDate);   -- 下一步自己跟自己比日期範圍，先建索引

    -- 第 2 步：觀察期間內每張傳票，往前 WindowDays 天內同公司別 + 同供應商 + 同成本中心的合計
    SELECT i.CompanyCode, i.AccountingDoc, i.FiscalYear, i.Vendor,
           SUM(j.Amount) AS WindowAmount,
           COUNT(*)      AS WindowDocCount
    INTO #Window
    FROM #Doc i
    JOIN #Doc j ON j.CompanyCode = i.CompanyCode AND j.Vendor = i.Vendor AND j.CostCenter = i.CostCenter
               AND j.PostingDate BETWEEN DATEADD(DAY, -(@windowDays - 1), i.PostingDate) AND i.PostingDate
    WHERE i.PostingDate BETWEEN @PeriodFrom AND @PeriodTo
    GROUP BY i.CompanyCode, i.AccountingDoc, i.FiscalYear, i.Vendor
    HAVING COUNT(*) >= @minDocCount;

    -- 第 3 步：單張、合計各需要第幾層核決；合計的層級比較高 → 標記；寫進明細
    INSERT kri.K09_Detail (RunId, CompanyCode, AccountingDoc, FiscalYear, Vendor, VendorName, PostingDate,
                           DocumentType, CostCenter, LocalCurrency, Amount, WindowAmount, WindowDocCount,
                           OwnLevel, WindowLevel, IsFlagged)
    SELECT @RunId, d.CompanyCode, d.AccountingDoc, d.FiscalYear, d.Vendor, d.VendorName, d.PostingDate,
           d.DocumentType, d.CostCenter, d.LocalCurrency, d.Amount, w.WindowAmount, w.WindowDocCount,
           ISNULL(own.Lvl, 0), win.Lvl,                -- 單筆低於核決表最低區間 = 第 0 層（不用簽核）
           CASE WHEN win.Lvl > ISNULL(own.Lvl, 0) THEN 1 ELSE 0 END
    FROM #Window w
    JOIN #Doc d ON d.CompanyCode = w.CompanyCode AND d.AccountingDoc = w.AccountingDoc
               AND d.FiscalYear = w.FiscalYear AND d.Vendor = w.Vendor
    OUTER APPLY (SELECT TOP 1 a.ApprovalLevel AS Lvl            -- 單張金額落在哪個核決區間（公司別自己的優先）
                 FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'AP' AND a.CompanyCode IN (d.CompanyCode, '*') AND a.Currency = d.LocalCurrency
                   AND d.Amount >= a.MinAmount AND d.Amount < a.MaxAmount
                   AND d.PostingDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY CASE WHEN a.CompanyCode = '*' THEN 1 ELSE 0 END, a.ApprovalLevel DESC) own
    OUTER APPLY (SELECT TOP 1 a.ApprovalLevel AS Lvl            -- 視窗合計落在哪個核決區間
                 FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'AP' AND a.CompanyCode IN (d.CompanyCode, '*') AND a.Currency = d.LocalCurrency
                   AND w.WindowAmount >= a.MinAmount AND w.WindowAmount < a.MaxAmount
                   AND d.PostingDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY CASE WHEN a.CompanyCode = '*' THEN 1 ELSE 0 END, a.ApprovalLevel DESC) win;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, Vendor,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K09', CONCAT(CompanyCode, '-', AccountingDoc, '-', FiscalYear, '-', Vendor), 'AP', CompanyCode, Vendor,
           AccountingDoc, FiscalYear, PostingDate, WindowAmount, NULL, Amount, LocalCurrency,
           CONCAT(@windowDays, N' 天內同供應商', CASE WHEN CostCenter <> '' THEN N'同成本中心' ELSE N'' END, N' ',
                  WindowDocCount, N' 張沒有 PO 的應付傳票，合計需第 ', WindowLevel, N' 層核決，單張只需第 ', OwnLevel, N' 層')
    FROM kri.K09_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    IF NOT EXISTS (SELECT 1 FROM kri.ApprovalMatrix WHERE DocType = 'AP')
        SET @Note = N'kri.ApprovalMatrix 沒有 AP 的核決權限，這題不會標記任何資料';
    ELSE
    BEGIN
        -- 沒設定只看哪些類型、借貸別又全空白：付款或貸項可能混進來，提醒一下
        DECLARE @mixWarning NVARCHAR(100) =
            CASE WHEN @includeTypeCount = 0
                      AND NOT EXISTS (SELECT 1 FROM fin.AccountsPayable WHERE ISNULL(DebitCreditInd, '') <> '')
                 THEN N'；沒有設定 IncludeDocType、借貸別也是空的，付款或貸項可能混在裡面' ELSE N'' END;

        SELECT @Note = CONCAT(N'候選傳票 ', COUNT(*), N'（期間內沒有 PO 的應付傳票 ',
                              (SELECT COUNT(*) FROM #Doc WHERE PostingDate BETWEEN @PeriodFrom AND @PeriodTo), N'）',
                              @mixWarning)
        FROM kri.K09_Detail WHERE RunId = @RunId;
    END;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K10_先收貨後補PO.sql
-- ######################################################################
-- ======================================================================
-- K10 先入庫才補請採購單
--
-- 【抓什麼】貨已經收了（或下 PO 隔天就收），PO 才補開的採購。
-- 【為什麼有風險】先叫貨、事後補單，等於跳過請購、比價、核准，PO 只是形式；
--                 也可能是和供應商私下約定好再補文件。
--
-- 【怎麼判斷】
--   第 1 步：觀察期間內的 PO 項目，接上第一次收貨的資料（kri.PoReceipt：只看收貨的異動類型、
--            基準日以前已經存在的收貨）。收貨日取「過帳日」和「系統輸入日」較早的那個：
--            過帳日可以手動填，輸入日不行。也記下最早的收貨文件日（通常是送貨單日期）。
--   第 2 步：算 PO 日到第一次收貨的天數（負數 = 收貨早於 PO）、PO 日到送貨單日的天數，
--            以及整張 PO 的本幣金額：直接從 PO 明細加總所有項目（含還沒收貨、被排除名單濾掉的項目；
--            只不算已刪除和數量 0 的）。排除名單只決定哪些項目要看，不能讓整張 PO 的金額變小。
--   第 3 步：判斷金額上限：本幣不在 AmountCurrency 的、或有項目換不出本幣的，標「未判斷」（照樣可以標記）；
--            整張 PO 超過 MaxPoAmount 的標「超過上限」（不標記）。MaxPoAmount = 0 表示不限。
--   第 4 步：（收貨在 PO 後 MaxGapDays 天內，或送貨單日早於 PO）、收貨說明沒有排除關鍵字、
--            金額沒超過上限 → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K10'）
--   MaxGapDays   PO 日到第一次收貨在幾天內（含收貨早於 PO）
--   MaxPoAmount  整張 PO 本幣金額上限；0 = 不限。只在本幣屬於 AmountCurrency 時判斷
--
-- 【名單】（kri.ValueList）
--   GrMovementType      算「收貨」的異動類型
--   ExcludeTextPattern  收貨說明符合這些關鍵字（LIKE 樣式，例如緊急採購）的不標記
--   AmountCurrency      金額上限的幣別；本幣不是這個的公司別不判斷金額
--
-- 【明細表 kri.K10_Detail 怎麼看】（只留有收貨的 PO 項目）
--   FirstGrDate / FirstGrEntryDate  第一次收貨的過帳日 / 系統輸入日
--   GapDays          較早的收貨日 − PO 日；負數 = 收貨早於 PO
--   FirstDocDate     最早的收貨文件日（送貨單日）；DocGapDays = 文件日 − PO 日，負數 = 送貨單早於 PO
--   HasExcludedText  收貨說明有排除關鍵字
--   PoAmountLocal    整張 PO 的本幣金額；AmountCheck = 未超過 / 超過上限 / 未判斷 / 不限
--
-- 【限制】
--   沖銷（102 或貸方）不扣回：沖銷後重收的，第一次收貨日仍是被沖銷的那一筆。
--   排除關鍵字目前比對收貨的項目說明；PO 項目說明（EKPO.TXZ01）進來後再加。
--   和 K19 共用收貨日；K10 看 PO → 收貨，K19 看 PR → 收貨，同一筆可能兩題都標。
-- ======================================================================
IF OBJECT_ID(N'kri.K10_Detail', N'U') IS NULL
CREATE TABLE kri.K10_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoItem           NVARCHAR(5)   NOT NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Plant            NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    VendorName       NVARCHAR(80)  NULL,
    Material         NVARCHAR(18)  NULL,
    FirstGrDate      DATE          NULL,
    FirstGrEntryDate DATE          NULL,
    GapDays          INT           NULL,     -- 較早的收貨日 − PO 日；負數 = 收貨早於 PO
    HasExcludedText  BIT           NOT NULL,
    PoAmountLocal    DECIMAL(19,4) NULL,     -- 整張 PO 的本幣金額（所有未刪除項目合計，含未收貨、被排除的；有項目換不出本幣 = NULL）
    AmountCheck      NVARCHAR(20)  NOT NULL, -- 未超過 / 超過上限 / 未判斷 / 不限
    ItemAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    IsFlagged        BIT           NOT NULL,
    FirstDocDate     DATE          NULL,     -- 最早的收貨文件日（送貨單日）
    DocGapDays       INT           NULL,     -- 文件日 − PO 日；負數 = 送貨單早於 PO（照樣標記）
    CONSTRAINT PK_kri_K10_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO
IF COL_LENGTH('kri.K10_Detail', 'FirstDocDate') IS NULL
    ALTER TABLE kri.K10_Detail ADD FirstDocDate DATE NULL, DocGapDays INT NULL;
GO

CREATE OR ALTER PROCEDURE kri.Run_K10
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @maxGapDays  INT           = kri.Param('K10', 'MaxGapDays'),     -- PO 後幾天內就收貨
            @maxPoAmount DECIMAL(19,4) = kri.Param('K10', 'MaxPoAmount');    -- 整張 PO 金額上限，0 = 不限

    -- 第 1 步：觀察期間內的 PO 項目，接上第一次收貨（只留有收貨的）
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
           b.Material, b.LocalCurrency,
           r.FirstGrDate, r.FirstGrEntryDate,
           r.FirstDate,                            -- 過帳日、輸入日取較早的
           r.FirstDocDate, r.HasExcludedText,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS ItemAmountLocal
    INTO #PoItem
    FROM kri.PoBase('K10', @PeriodFrom, @PeriodTo) b
    JOIN kri.PoReceipt('K10', @AsOfDate) r ON r.PoNumber = b.PoNumber AND r.PoItem = b.PoItem;

    -- 第 2 步：整張 PO 的本幣金額：直接從 PO 明細加總，排除名單濾掉的項目也要算進去
    --   有任何一個項目換不出本幣，整張 PO 金額就不算（留 NULL → 未判斷）
    SELECT d.PoNumber,
           CASE WHEN COUNT(*) = COUNT(a.AmountLocal) THEN SUM(a.AmountLocal) END AS PoAmountLocal
    INTO #PoTotal
    FROM prc.PurchaseOrderDetail d
    LEFT JOIN kri.vCompanyCurrency c ON c.CompanyCode = d.CompanyCode
    CROSS APPLY (SELECT kri.ToLocal(d.NetValue, d.Currency, c.LocalCurrency, d.ExchangeRate) AS AmountLocal) a
    WHERE d.PoNumber IN (SELECT PoNumber FROM #PoItem)
      AND ISNULL(d.DeletionInd, '') = ''
      AND d.OrderQty > 0
    GROUP BY d.PoNumber;

    --   PO 到收貨的天數、PO 到送貨單的天數
    SELECT p.*,
           DATEDIFF(DAY, p.PoDate, p.FirstDate)    AS GapDays,
           DATEDIFF(DAY, p.PoDate, p.FirstDocDate) AS DocGapDays,
           t.PoAmountLocal
    INTO #Gap
    FROM #PoItem p
    LEFT JOIN #PoTotal t ON t.PoNumber = p.PoNumber;

    -- 第 3 步：金額上限的判斷
    SELECT g.*,
           CASE WHEN @maxPoAmount = 0 THEN N'不限'
                WHEN ISNULL(g.LocalCurrency, '') NOT IN (SELECT Value FROM kri.List('K10', 'AmountCurrency')) THEN N'未判斷'
                WHEN g.PoAmountLocal IS NULL THEN N'未判斷'
                WHEN g.PoAmountLocal > @maxPoAmount THEN N'超過上限'
                ELSE N'未超過' END AS AmountCheck
    INTO #Checked
    FROM #Gap g;

    -- 第 4 步：收貨太快（或送貨單早於 PO）、沒有排除關鍵字、金額沒超過 → 標記；寫進明細
    INSERT kri.K10_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, VendorName,
           Material, FirstGrDate, FirstGrEntryDate, GapDays, HasExcludedText, PoAmountLocal, AmountCheck,
           ItemAmountLocal, LocalCurrency, IsFlagged, FirstDocDate, DocGapDays)
    SELECT @RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, VendorName, Material,
           FirstGrDate, FirstGrEntryDate, GapDays, HasExcludedText, PoAmountLocal, AmountCheck,
           ItemAmountLocal, LocalCurrency,
           CASE WHEN (GapDays <= @maxGapDays OR DocGapDays < 0)
                 AND HasExcludedText = 0
                 AND AmountCheck <> N'超過上限' THEN 1 ELSE 0 END,
           FirstDocDate, DocGapDays
    FROM #Checked;

    -- 寫標記
    --   只因為「送貨單早於 PO」被標的（收貨本身不算快）：數值放送貨單的天數、門檻放 0，說明先講送貨單
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT d.RunId, 'K10', CONCAT(d.PoNumber, '-', d.PoItem), 'PO', d.CompanyCode, d.PurchOrg, d.Plant, d.Vendor, d.Material,
           d.PoNumber, d.PoItem, d.PoDate,
           CASE WHEN t.OnlyByDoc = 1 THEN d.DocGapDays ELSE d.GapDays END,
           CASE WHEN t.OnlyByDoc = 1 THEN 0 ELSE @maxGapDays END,
           d.ItemAmountLocal, d.LocalCurrency,
           CONCAT(t.DocTextFirst, t.GrText, t.DocTextAfter, t.AmountText)
    FROM kri.K10_Detail d
    CROSS APPLY (SELECT CASE WHEN d.GapDays > @maxGapDays AND d.DocGapDays < 0 THEN 1 ELSE 0 END AS OnlyByDoc) o
    CROSS APPLY (SELECT
        o.OnlyByDoc,
        -- 只因送貨單被標：說明開頭先講送貨單
        CASE WHEN o.OnlyByDoc = 1 THEN CONCAT(N'送貨單早於 PO ', -d.DocGapDays, N' 天；') ELSE N'' END AS DocTextFirst,
        -- 收貨日相對 PO 日
        CASE WHEN d.GapDays < 0 THEN CONCAT(N'收貨早於 PO ', -d.GapDays, N' 天')
             ELSE CONCAT(N'PO 後 ', d.GapDays, N' 天就收貨') END AS GrText,
        -- 收貨本身就算快、送貨單也早於 PO：附在後面
        CASE WHEN d.GapDays <= @maxGapDays AND d.DocGapDays < 0 THEN CONCAT(N'；送貨單早於 PO ', -d.DocGapDays, N' 天')
             ELSE N'' END AS DocTextAfter,
        CASE WHEN d.AmountCheck = N'未判斷' THEN N'（金額上限未判斷）' ELSE N'' END AS AmountText) t
    WHERE d.RunId = @RunId AND d.IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'有收貨的 PO 項目 ', COUNT(*), N'；收貨早於 PO ', COUNT(CASE WHEN GapDays < 0 THEN 1 END),
                          N'；送貨單早於 PO ', COUNT(CASE WHEN DocGapDays < 0 THEN 1 END),
                          N'；排除關鍵字 ', COUNT(CASE WHEN HasExcludedText = 1 THEN 1 END),
                          N'；超過金額上限 ', COUNT(CASE WHEN AmountCheck = N'超過上限' THEN 1 END),
                          N'；金額未判斷 ', COUNT(CASE WHEN AmountCheck = N'未判斷' THEN 1 END))
    FROM kri.K10_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K11_非緊急之緊急採購.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K12_獨家且漲價.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K13_跨據點單價差異.sql
-- ######################################################################
-- ======================================================================
-- K13 跨據點同料號單價差異
--
-- 【抓什麼】同一個料號，在差不多的時間、差不多的採購量下，某個據點買得比其他據點貴很多。
-- 【為什麼有風險】同一家公司不同據點各自議價，貴的那邊可能沒比價、議價不力，或有利益輸送。
--
-- 【怎麼判斷】
--   第 1 步：觀察期間內的 PO 項目（有料號、有單價，通用料號不看），分好比較群組：
--            料號 + 幣別 + 訂購單位 + 季度 + 數量級距（數量每差 QtyBandRatio 倍算不同級距）。
--            據點 = 公司別（EntityLevel = 1）或工廠（= 2）。
--   第 2 步：每個群組裡，每個據點的最低單價；找出最便宜和第二便宜的據點。至少要有 2 個據點才比。
--   第 3 步：每一行跟「其他據點」的最低單價比：自己就是最便宜的據點，就跟第二便宜的比。
--            單價 ÷ 其他據點最低單價 − 1 > PriceTolerance → 標記。
--            影響金額 =（單價 − 其他據點最低單價）× 數量，換成本幣。
--
-- 【門檻】（kri.Parameter，KriCode = 'K13'）
--   PriceTolerance  比其他據點最低單價高出多少比例才標記
--   QtyBandRatio    數量級距：每差幾倍算不同級距（要大於 1）
--   EntityLevel     據點層級：1 = 公司別、2 = 工廠
--
-- 【名單】（kri.ValueList）
--   GenericMaterial  通用、雜項料號：單價沒有可比性，不看
--
-- 【明細表 kri.K13_Detail 怎麼看】（只留有其他據點可比的 PO 項目）
--   Entity          這一行的據點；PeriodQuarter 季度第一天；QtyBand 數量級距
--   EntityCount     同群組有幾個據點
--   OtherEntity     最便宜的其他據點；OtherMinPrice 是它的最低單價
--   DiffRatio       單價 ÷ OtherMinPrice − 1
--
-- 【限制】
--   只比同幣別、同訂購單位；跨幣別要等匯率表。
-- ======================================================================
IF OBJECT_ID(N'kri.K13_Detail', N'U') IS NULL
CREATE TABLE kri.K13_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoItem           NVARCHAR(5)   NOT NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Plant            NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    Material         NVARCHAR(18)  NULL,
    MaterialDesc     NVARCHAR(40)  NULL,
    Entity           NVARCHAR(4)   NULL,
    PeriodQuarter    DATE          NULL,
    QtyBand          INT           NULL,
    OrderQty         DECIMAL(19,4) NULL,
    OrderUom         NVARCHAR(3)   NULL,
    Currency         NVARCHAR(5)   NULL,
    UnitPrice        DECIMAL(19,6) NULL,
    EntityCount      INT           NULL,     -- 同群組有幾個據點
    OtherEntity      NVARCHAR(4)   NULL,     -- 最便宜的其他據點
    OtherMinPrice    DECIMAL(19,6) NULL,
    DiffRatio        DECIMAL(19,6) NULL,
    IsFlagged        BIT           NOT NULL,
    EffectDoc        DECIMAL(19,4) NULL,
    EffectLocal      DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    CONSTRAINT PK_kri_K13_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K13
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @tolerance    DECIMAL(19,6) = kri.Param('K13', 'PriceTolerance'),   -- 貴多少比例才標記
            @qtyBandRatio FLOAT         = kri.Param('K13', 'QtyBandRatio'),     -- 數量每差幾倍算不同級距
            @entityLevel  INT           = kri.Param('K13', 'EntityLevel');      -- 1 = 公司別、2 = 工廠
    IF @qtyBandRatio <= 1 THROW 50000, N'K13.QtyBandRatio 要大於 1', 1;

    -- 第 1 步：PO 項目和它的比較群組（季度、數量級距）、據點
    SELECT p.PoNumber, p.PoItem, p.PoDate, p.CompanyCode, p.PurchOrg, p.Plant, p.Vendor,
           p.Material, p.MaterialDesc, p.OrderQty, p.OrderUom, p.Currency, p.UnitPrice,
           p.LocalCurrency, p.ExchangeRate,
           CASE WHEN @entityLevel = 2 THEN p.Plant ELSE p.CompanyCode END AS Entity,
           DATEFROMPARTS(YEAR(p.PoDate), (DATEPART(QUARTER, p.PoDate) - 1) * 3 + 1, 1) AS PeriodQuarter,
           -- 數量級距：數量取對數（底數 = QtyBandRatio）後無條件捨去，例如底數 10 時 1～9 = 0、10～99 = 1
           CAST(FLOOR(LOG(CAST(p.OrderQty AS FLOAT)) / LOG(@qtyBandRatio)) AS INT) AS QtyBand
    INTO #Po
    FROM kri.PoBase('K13', @PeriodFrom, @PeriodTo) p
    WHERE ISNULL(p.Material, '') <> '' AND p.UnitPrice > 0 AND p.IsGeneric = 0;

    -- 第 2 步：每個群組裡每個據點的最低單價，排出便宜的順序
    SELECT Material, Currency, OrderUom, PeriodQuarter, QtyBand, Entity, MIN(UnitPrice) AS MinPrice
    INTO #EntityMin
    FROM #Po
    WHERE ISNULL(Entity, '') <> ''
    GROUP BY Material, Currency, OrderUom, PeriodQuarter, QtyBand, Entity;

    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY Material, Currency, OrderUom, PeriodQuarter, QtyBand
                              ORDER BY MinPrice, Entity) AS PriceRank,        -- 1 = 最便宜的據點
           COUNT(*)     OVER (PARTITION BY Material, Currency, OrderUom, PeriodQuarter, QtyBand) AS EntityCount
    INTO #EntityRank
    FROM #EntityMin;

    --   每個群組留下最便宜（E1、P1）和第二便宜（E2、P2）的據點；只有一個據點的群組沒得比
    SELECT Material, Currency, OrderUom, PeriodQuarter, QtyBand,
           MAX(EntityCount) AS EntityCount,
           MAX(CASE WHEN PriceRank = 1 THEN Entity END)   AS E1,
           MAX(CASE WHEN PriceRank = 1 THEN MinPrice END) AS P1,
           MAX(CASE WHEN PriceRank = 2 THEN Entity END)   AS E2,
           MAX(CASE WHEN PriceRank = 2 THEN MinPrice END) AS P2
    INTO #GroupBest
    FROM #EntityRank
    GROUP BY Material, Currency, OrderUom, PeriodQuarter, QtyBand
    HAVING MAX(EntityCount) >= 2;

    -- 第 3 步：每一行跟其他據點的最低單價比（自己就是最便宜的，就跟第二便宜的比）；寫進明細
    INSERT kri.K13_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor,
                           Material, MaterialDesc, Entity, PeriodQuarter, QtyBand, OrderQty, OrderUom,
                           Currency, UnitPrice, EntityCount, OtherEntity, OtherMinPrice, DiffRatio,
                           IsFlagged, EffectDoc, EffectLocal, LocalCurrency)
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor,
           b.Material, b.MaterialDesc, b.Entity, b.PeriodQuarter, b.QtyBand, b.OrderQty, b.OrderUom,
           b.Currency, b.UnitPrice, g.EntityCount, o.OtherEntity, o.OtherMinPrice, d.DiffRatio,
           CASE WHEN d.DiffRatio > @tolerance THEN 1 ELSE 0 END,
           e.EffectDoc,
           kri.ToLocal(e.EffectDoc, b.Currency, b.LocalCurrency, b.ExchangeRate),
           b.LocalCurrency
    FROM #Po b
    JOIN #GroupBest g ON g.Material = b.Material AND g.Currency = b.Currency AND g.OrderUom = b.OrderUom
                     AND g.PeriodQuarter = b.PeriodQuarter AND g.QtyBand = b.QtyBand
    CROSS APPLY (SELECT CASE WHEN b.Entity = g.E1 THEN g.E2 ELSE g.E1 END AS OtherEntity,
                        CASE WHEN b.Entity = g.E1 THEN g.P2 ELSE g.P1 END AS OtherMinPrice) o
    CROSS APPLY (SELECT b.UnitPrice / o.OtherMinPrice - 1 AS DiffRatio) d
    CROSS APPLY (SELECT CASE WHEN d.DiffRatio > @tolerance
                             THEN (b.UnitPrice - o.OtherMinPrice) * b.OrderQty END AS EffectDoc) e;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K13', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tolerance, EffectLocal, LocalCurrency,
           CONCAT(N'單價比據點 ', OtherEntity, N' 高 ', FORMAT(DiffRatio, 'P1'))
    FROM kri.K13_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'可跨據點比較的 PO 項目 ', COUNT(*)) FROM kri.K13_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K14_PO單價高於主檔價.sql
-- ######################################################################
-- ======================================================================
-- K14 PO 單價高於主檔價
--
-- 【抓什麼】PO 上的單價，比下單那天有效的主檔價（採購資訊記錄的價格條件）還貴的 PO 項目。
-- 【為什麼有風險】主檔價是談好的價格，PO 卻用更高的價格下單：可能是採購人員手動改價、
--                 圖利供應商，或主檔沒更新導致多付錢。
--
-- 【怎麼判斷】
--   第 1 步：找出觀察期間內的 PO 項目（kri.PoBase，排除通用料號和沒有料號的），
--            再找下單日有效的主檔價（kri.InfoPriceAt：A017 分工廠的優先，沒有才用 A018）。
--            只用基準日以前已經建立的主檔價，基準日之後才建、生效日倒填的不算。
--   第 2 步：判斷能不能比：缺 PO 單價、找不到主檔價、主檔沒有單價、幣別不同、單位不同，都不比，
--            照樣寫進明細並註明原因。能比的算差異比例 = PO 單價 ÷ 主檔單價 − 1。
--   第 3 步：差異比例超過 PriceTolerance → 標記。影響金額 =（PO 單價 − 主檔單價）× 訂購數量，換成本幣。
--
-- 【門檻】（kri.Parameter，KriCode = 'K14'）
--   PriceTolerance  PO 單價比主檔價高出多少比例才標記（0.05 = 5%）
--   WindowMonths    觀察期間：只看最近幾個月下的 PO（預設 12）
--
-- 【名單】（kri.ValueList，KriCode = 'K14' 或 '*'）
--   AllowedConditionType  拿來比的價格條件類型（例：PB00）
--   AllowedInfoCategory   拿來比的資訊記錄類別（例：0 = 標準）
--   ExcludeVendorPrefix 等 PO 排除名單、GenericMaterial 通用料號
--
-- 【明細表 kri.K14_Detail 怎麼看】
--   PoUnitPrice    PO 單價（淨價 ÷ 價格單位）
--   InfoSource     主檔價來自 A017 或 A018；InfoUnitPrice 主檔單價
--   MatchStatus    已比對 / 無主檔價 / 幣別不同 / 單位不同 / 缺PO單價 / 主檔無單價
--   DiffRatio      PO 單價比主檔價高多少（0.2 = 高 20%）；比不了的是空的
--   EffectDoc      多付的金額（PO 幣別）；EffectLocal 換成本幣
--
-- 【限制】
--   級距價格（KONM）還沒下載，數量越多越便宜的級距價看不到。
--   主檔 PB00 是毛價、PO 是淨價（扣過折扣），有折扣時 PO 會比較便宜，不會誤標。
-- ======================================================================
IF OBJECT_ID(N'kri.K14_Detail', N'U') IS NULL
CREATE TABLE kri.K14_Detail (
    RunId           INT           NOT NULL,
    PoNumber        NVARCHAR(10)  NOT NULL,
    PoItem          NVARCHAR(5)   NOT NULL,
    PoDate          DATE          NULL,
    CompanyCode     NVARCHAR(4)   NULL,
    PurchOrg        NVARCHAR(4)   NULL,
    Plant           NVARCHAR(4)   NULL,
    Vendor          NVARCHAR(10)  NULL,
    VendorName      NVARCHAR(80)  NULL,
    Material        NVARCHAR(18)  NULL,
    MaterialDesc    NVARCHAR(40)  NULL,
    OrderQty        DECIMAL(19,4) NULL,
    OrderUom        NVARCHAR(3)   NULL,
    Currency        NVARCHAR(5)   NULL,
    PoUnitPrice     DECIMAL(19,6) NULL,
    InfoSource      NVARCHAR(4)   NULL,      -- A017 / A018
    ConditionRecord NVARCHAR(10)  NULL,
    ConditionType   NVARCHAR(4)   NULL,
    InfoValidFrom   DATE          NULL,
    InfoUnitPrice   DECIMAL(19,6) NULL,
    InfoCurrency    NVARCHAR(5)   NULL,
    InfoUom         NVARCHAR(3)   NULL,
    MatchStatus     NVARCHAR(20)  NOT NULL,  -- 已比對 / 無主檔價 / 幣別不同 / 單位不同 / 缺PO單價 / 主檔無單價
    DiffRatio       DECIMAL(19,6) NULL,
    IsFlagged       BIT           NOT NULL,
    EffectDoc       DECIMAL(19,4) NULL,
    EffectLocal     DECIMAL(19,4) NULL,
    LocalCurrency   NVARCHAR(5)   NULL,
    CONSTRAINT PK_kri_K14_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K14
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @tolerance DECIMAL(19,6) = kri.Param('K14', 'PriceTolerance');   -- 高出多少比例才標記

    -- 第 1 步：期間內的 PO 項目，配上下單日有效的主檔價
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant,
           b.Vendor, b.VendorName, b.Material, b.MaterialDesc, b.OrderQty, b.OrderUom,
           b.Currency, b.UnitPrice AS PoUnitPrice, b.LocalCurrency, b.ExchangeRate,
           i.Source AS InfoSource, i.ConditionRecord, i.ConditionType, i.ValidFrom AS InfoValidFrom,
           i.UnitPrice AS InfoUnitPrice, i.Currency AS InfoCurrency, i.OrderUom AS InfoUom
    INTO #PoWithInfo
    FROM kri.PoBase('K14', @PeriodFrom, @PeriodTo) b
    -- 只用基準日以前已建立的主檔價（@AsOfDate）
    OUTER APPLY kri.InfoPriceAt('K14', b.Vendor, b.Material, b.PurchOrg, b.Plant, b.PoDate, @AsOfDate) i
    WHERE b.IsGeneric = 0                    -- 通用料號沒有可比的主檔價
      AND ISNULL(b.Material, '') <> '';      -- 沒有料號的不比

    -- 第 2 步：能不能比？能比的算差異比例
    SELECT p.*, s.MatchStatus,
           CASE WHEN s.MatchStatus = N'已比對' THEN p.PoUnitPrice / p.InfoUnitPrice - 1 END AS DiffRatio
    INTO #Compared
    FROM #PoWithInfo p
    CROSS APPLY (SELECT CASE
        WHEN p.PoUnitPrice IS NULL                                  THEN N'缺PO單價'
        WHEN p.InfoSource IS NULL                                   THEN N'無主檔價'
        WHEN p.InfoUnitPrice IS NULL OR p.InfoUnitPrice = 0         THEN N'主檔無單價'
        WHEN p.InfoCurrency <> p.Currency                           THEN N'幣別不同'
        WHEN p.InfoUom IS NOT NULL AND p.InfoUom <> p.OrderUom      THEN N'單位不同'
        ELSE N'已比對' END AS MatchStatus) s;

    -- 第 3 步：貴超過門檻 → 標記，算多付的金額；比不了的也寫進明細（不能悄悄消失）
    INSERT kri.K14_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, VendorName,
                           Material, MaterialDesc, OrderQty, OrderUom, Currency, PoUnitPrice,
                           InfoSource, ConditionRecord, ConditionType, InfoValidFrom, InfoUnitPrice, InfoCurrency, InfoUom,
                           MatchStatus, DiffRatio, IsFlagged, EffectDoc, EffectLocal, LocalCurrency)
    SELECT @RunId, c.PoNumber, c.PoItem, c.PoDate, c.CompanyCode, c.PurchOrg, c.Plant, c.Vendor, c.VendorName,
           c.Material, c.MaterialDesc, c.OrderQty, c.OrderUom, c.Currency, c.PoUnitPrice,
           c.InfoSource, c.ConditionRecord, c.ConditionType, c.InfoValidFrom, c.InfoUnitPrice, c.InfoCurrency, c.InfoUom,
           c.MatchStatus, c.DiffRatio,
           CASE WHEN c.DiffRatio > @tolerance THEN 1 ELSE 0 END,
           e.EffectDoc,
           kri.ToLocal(e.EffectDoc, c.Currency, c.LocalCurrency, c.ExchangeRate),
           c.LocalCurrency
    FROM #Compared c
    CROSS APPLY (SELECT CASE WHEN c.DiffRatio > @tolerance
                             THEN (c.PoUnitPrice - c.InfoUnitPrice) * c.OrderQty END AS EffectDoc) e;   -- 多付的金額（PO 幣別）

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K14', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tolerance, EffectLocal, LocalCurrency,
           CONCAT(N'PO 單價高於', InfoSource, N' 主檔價 ', FORMAT(DiffRatio, 'P1'))
    FROM kri.K14_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'已比對 ', COUNT(CASE WHEN MatchStatus = N'已比對' THEN 1 END), N' / ', COUNT(*),
                          N'；無主檔價 ', COUNT(CASE WHEN MatchStatus = N'無主檔價' THEN 1 END),
                          N'、幣別不同 ', COUNT(CASE WHEN MatchStatus = N'幣別不同' THEN 1 END),
                          N'、單位不同 ', COUNT(CASE WHEN MatchStatus = N'單位不同' THEN 1 END))
    FROM kri.K14_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K15_即將呆滯.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K16_呆滯料仍採購.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K17_重大工程未簽約.sql
-- ######################################################################
-- ======================================================================
-- K17 重大工程未簽合約
--
-- 【抓什麼】金額很大的工程類 PO，卻沒有合約，或合約是在 PO 開出來之後才補簽的。
-- 【為什麼有風險】重大工程沒有合約，責任、驗收標準、罰則都沒有約定，出問題時沒有依據；
--                 先下單後補約，代表事前的審核被跳過。
--
-- 【怎麼判斷】
--   第 1 步：找出觀察期間內的 PO 項目，判斷是不是工程類：PO 類型在 ConstructionPoType、
--            物料群組在 ConstructionMaterialGroup、或總帳科目符合 ConstructionGlPattern，任一個就算。
--   第 2 步：有任一個工程類項目的 PO，整張 PO 加總本幣金額（有項目換不出本幣，整張就不算）。
--   第 3 步：整張金額 >= MajorAmount（只看本幣在 AmountCurrency 名單裡的）的 PO，找合約：
--            PO 上有參照 SAP 合約就算有；否則找 ext.Contract（先找指定這張 PO 的，再找同供應商、
--            有效期間涵蓋下單日的），只看基準日以前簽的。
--   第 4 步：沒有合約、或合約簽約日晚於 PO 日 → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K17'）
--   MajorAmount  整張 PO 本幣金額達多少算重大工程
--
-- 【名單】（kri.ValueList）
--   ConstructionPoType         工程類的 PO 類型
--   ConstructionMaterialGroup  工程類的物料群組
--   ConstructionGlPattern      工程類的總帳科目（LIKE 樣式，例：'1501%'）
--   AmountCurrency             金額門檻適用的本幣（例：TWD）
--
-- 【明細表 kri.K17_Detail 怎麼看】一列 = 一張 PO
--   PoAmountLocal     整張 PO 的本幣金額
--   SapContract       PO 參照的 SAP 合約號碼；ExtContract、ContractSignedOn 外部合約號碼、簽約日
--   Status            有合約 / 合約晚於PO / 無合約
--
-- 【限制】
--   三種工程類條件都沒設定時，這題不會標記任何資料（備註會提示）。
--   合約簽約日空白的視為在下單前就簽了。
-- ======================================================================
IF OBJECT_ID(N'kri.K17_Detail', N'U') IS NULL
CREATE TABLE kri.K17_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    VendorName       NVARCHAR(80)  NULL,
    PoAmountLocal    DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    SapContract      NVARCHAR(10)  NULL,
    ExtContract      NVARCHAR(30)  NULL,
    ContractSignedOn DATE          NULL,
    Status           NVARCHAR(10)  NOT NULL,  -- 有合約 / 合約晚於PO / 無合約
    IsFlagged        BIT           NOT NULL,
    CONSTRAINT PK_kri_K17_Detail PRIMARY KEY (RunId, PoNumber)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K17
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @majorAmount DECIMAL(19,4) = kri.Param('K17', 'MajorAmount');   -- 整張 PO 多少錢算重大工程

    -- 第 1 步：期間內的 PO 項目，判斷是不是工程類
    SELECT b.PoNumber, b.PoDate, b.CompanyCode, b.PurchOrg, b.Vendor, b.VendorName, b.LocalCurrency,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal,
           NULLIF(p.Contract, '') AS Contract,
           CASE WHEN p.PoType IN (SELECT Value FROM kri.List('K17', 'ConstructionPoType'))
                  OR p.MaterialGroup IN (SELECT Value FROM kri.List('K17', 'ConstructionMaterialGroup'))
                  OR EXISTS (SELECT 1 FROM kri.List('K17', 'ConstructionGlPattern') l WHERE p.GlAccount LIKE l.Value)
                THEN 1 ELSE 0 END AS IsConstruction
    INTO #PoItems
    FROM kri.PoBase('K17', @PeriodFrom, @PeriodTo) b
    JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem;

    -- 第 2 步：有任一工程類項目的 PO，整張 PO 的金額
    SELECT PoNumber, MIN(PoDate) AS PoDate, MAX(CompanyCode) AS CompanyCode, MAX(PurchOrg) AS PurchOrg,
           MAX(Vendor) AS Vendor, MAX(VendorName) AS VendorName, MAX(LocalCurrency) AS LocalCurrency,
           CASE WHEN COUNT(*) = COUNT(AmountLocal) THEN SUM(AmountLocal) END AS Amount,   -- 有項目換不出本幣就不算
           MAX(Contract) AS Contract
    INTO #ConstructionPo
    FROM #PoItems
    GROUP BY PoNumber
    HAVING MAX(IsConstruction) = 1;

    -- 第 3 步：重大的工程 PO，找外部合約
    SELECT po.*, x.ContractNo, x.SignedOn
    INTO #WithContract
    FROM #ConstructionPo po
    OUTER APPLY (SELECT TOP 1 k.ContractNo, k.SignedOn
                 FROM ext.Contract k
                 WHERE (   k.PoNumber = po.PoNumber                                   -- 指定這張 PO 的
                        OR (k.PoNumber IS NULL AND k.Vendor = po.Vendor               -- 或同供應商、期間涵蓋下單日的
                            AND po.PoDate BETWEEN ISNULL(k.ValidFrom, '1900-01-01') AND ISNULL(k.ValidTo, '9999-12-31')))
                   AND ISNULL(k.SignedOn, '1900-01-01') <= @AsOfDate                  -- 基準日以前簽的
                 ORDER BY CASE WHEN k.PoNumber IS NULL THEN 1 ELSE 0 END,             -- 指定 PO 的優先
                          CASE WHEN k.SignedOn IS NULL THEN 1 ELSE 0 END,             -- 有簽約日的優先
                          k.SignedOn) x                                               -- 最早簽的
    WHERE po.Amount >= @majorAmount
      AND po.LocalCurrency IN (SELECT Value FROM kri.List('K17', 'AmountCurrency'));

    -- 第 4 步：沒有合約、或合約晚於 PO → 標記；寫進明細
    INSERT kri.K17_Detail (RunId, PoNumber, PoDate, CompanyCode, PurchOrg, Vendor, VendorName, PoAmountLocal,
                           LocalCurrency, SapContract, ExtContract, ContractSignedOn, Status, IsFlagged)
    SELECT @RunId, c.PoNumber, c.PoDate, c.CompanyCode, c.PurchOrg, c.Vendor, c.VendorName, c.Amount,
           c.LocalCurrency, c.Contract, c.ContractNo, c.SignedOn, s.Status,
           CASE WHEN s.Status = N'有合約' THEN 0 ELSE 1 END
    FROM #WithContract c
    CROSS APPLY (SELECT CASE
        WHEN c.Contract IS NOT NULL                                                  THEN N'有合約'   -- PO 參照 SAP 合約
        WHEN c.ContractNo IS NOT NULL AND ISNULL(c.SignedOn, c.PoDate) <= c.PoDate   THEN N'有合約'   -- 下單前就簽了
        WHEN c.ContractNo IS NOT NULL                                                THEN N'合約晚於PO'
        ELSE N'無合約' END AS Status) s;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Vendor, DocNumber, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K17', PoNumber, 'PO', CompanyCode, PurchOrg, Vendor, PoNumber, PoDate,
           PoAmountLocal, @majorAmount, PoAmountLocal, LocalCurrency,
           CASE WHEN Status = N'無合約'
                THEN CONCAT(N'工程 PO ', FORMAT(PoAmountLocal, 'N0'), N' 沒有合約')
                ELSE CONCAT(N'工程 PO ', FORMAT(PoAmountLocal, 'N0'), N'，合約 ', ExtContract, N' 在 ', ContractSignedOn,
                            N' 才簽（PO ', PoDate, N'）') END
    FROM kri.K17_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    IF NOT EXISTS (SELECT 1 FROM kri.ValueList WHERE KriCode IN ('K17', '*')
                     AND ListName IN ('ConstructionPoType', 'ConstructionMaterialGroup', 'ConstructionGlPattern'))
        SET @Note = N'沒有設定工程類 PO 的判斷條件（ConstructionPoType／MaterialGroup／GlPattern），這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'重大工程 PO ', COUNT(*), N'；無合約 ', COUNT(CASE WHEN Status = N'無合約' THEN 1 END),
                              N'、合約晚於 PO ', COUNT(CASE WHEN Status = N'合約晚於PO' THEN 1 END))
        FROM kri.K17_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 檔案：kri_procs/K18_OpenPO收貨進度落後.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K19_收貨太貼近請購日.sql
-- ######################################################################
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

-- ######################################################################
-- 檔案：kri_procs/K20_驗退未及時處理.sql
-- ######################################################################
-- ======================================================================
-- K20 驗退後未及時處理
--
-- 【抓什麼】驗退的貨轉進「待退倉」之後，放了太久（超過 MaxOpenDays 天）才退回供應商或處理掉，
--          或到基準日都還沒處理。
-- 【為什麼有風險】驗退品一直放著，供應商不會補貨、也不會扣款；放久了可能找不到、被誤用，
--                 或錯過退貨期限，損失由公司吸收。
--
-- 【怎麼判斷】
--   第 1 步：把待退倉（ReturnStorLoc）裡、基準日以前的所有異動抓出來。
--   第 2 步：出待退倉（貸方 H）的異動，依同料號 × 工廠 × 倉 × 批號，按日期排好、算「累計出了多少」。
--   第 3 步：進待退倉（借方 S，而且異動類型在 ReturnTransferType）的異動，同樣算「累計進了多少」。
--            先進先出：累計出量第一次追上這筆的累計進量那天，就是這筆處理完的日期。
--            停留天數 = 處理完的日期（還沒處理完用基準日）− 轉入日。
--   第 4 步：觀察期間內轉入、停留天數 > MaxOpenDays → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K20'）
--   MaxOpenDays  轉入待退倉後幾天內要處理完
--
-- 【名單】（kri.ValueList）
--   ReturnStorLoc       待退倉的倉別代碼（只在各環境本地設定）
--   ReturnTransferType  轉入待退倉的異動類型（例：311 倉間轉撥）
--
-- 【明細表 kri.K20_Detail 怎麼看】一列 = 一筆轉入待退倉的異動
--   Quantity、BaseUom  轉入的數量、基本單位
--   ClearedOn          處理完的日期；空的 = 基準日還沒處理完
--   OpenDays           在待退倉停留幾天
--   AmountLocal        這筆異動的本幣金額
--
-- 【限制】
--   資料起始日以前待退倉就有的餘額看不到（當作 0），所以早期的出倉可能被配到後來的轉入。
--   沒有設定 ReturnStorLoc 時，這題不會標記任何資料（備註會提示）。
-- ======================================================================
IF OBJECT_ID(N'kri.K20_Detail', N'U') IS NULL
CREATE TABLE kri.K20_Detail (
    RunId           INT           NOT NULL,
    MaterialDoc     NVARCHAR(10)  NOT NULL,
    MaterialDocYear NVARCHAR(4)   NOT NULL,
    MaterialDocItem NVARCHAR(4)   NOT NULL,
    PostingDate     DATE          NULL,
    Material        NVARCHAR(18)  NULL,
    Plant           NVARCHAR(4)   NULL,
    StorLoc         NVARCHAR(4)   NULL,
    Batch           NVARCHAR(10)  NULL,
    Quantity        DECIMAL(19,4) NULL,
    BaseUom         NVARCHAR(3)   NULL,
    ClearedOn       DATE          NULL,      -- NULL = 基準日還沒處理完
    OpenDays        INT           NULL,
    AmountLocal     DECIMAL(19,4) NULL,
    IsFlagged       BIT           NOT NULL,
    CONSTRAINT PK_kri_K20_Detail PRIMARY KEY (RunId, MaterialDoc, MaterialDocYear, MaterialDocItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K20
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- 門檻
    DECLARE @maxOpenDays INT = kri.Param('K20', 'MaxOpenDays');   -- 幾天內要處理完

    -- 第 1 步：待退倉裡、基準日以前的所有異動
    SELECT m.MaterialDoc, m.MaterialDocYear, m.MaterialDocItem, m.PostingDate, m.Material, m.Plant, m.StorLoc,
           ISNULL(m.Batch, '') AS Batch,          -- 沒有批號的當成同一批
           m.Quantity, m.BaseUom, m.LocalAmount, m.MovementType, m.DebitCreditInd
    INTO #ReturnMoves
    FROM inv.MaterialMovement m
    WHERE m.StorLoc IN (SELECT Value FROM kri.List('K20', 'ReturnStorLoc'))
      AND m.PostingDate <= @AsOfDate
      AND m.Quantity > 0;

    -- 第 2 步：出待退倉（貸方）：同料號 × 工廠 × 倉 × 批號，按日期累計出了多少
    SELECT Material, Plant, StorLoc, Batch, PostingDate,
           SUM(Quantity) OVER (PARTITION BY Material, Plant, StorLoc, Batch
                               ORDER BY PostingDate, MaterialDoc, MaterialDocItem ROWS UNBOUNDED PRECEDING) AS CumOut
    INTO #OutMoves
    FROM #ReturnMoves
    WHERE DebitCreditInd = 'H';
    CREATE CLUSTERED INDEX cx ON #OutMoves (Material, Plant, StorLoc, Batch, CumOut);   -- 第 3 步用累計量找

    -- 第 3 步：進待退倉（借方）：按日期累計進了多少（所有借方都算，配對才正確）
    SELECT r.*,
           SUM(Quantity) OVER (PARTITION BY Material, Plant, StorLoc, Batch
                               ORDER BY PostingDate, MaterialDoc, MaterialDocItem ROWS UNBOUNDED PRECEDING) AS CumIn
    INTO #InMoves
    FROM #ReturnMoves r
    WHERE DebitCreditInd = 'S';

    -- 先進先出：累計出量第一次 >= 這筆的累計進量的那天 = 處理完的日期
    SELECT i.*, c.ClearedOn,
           DATEDIFF(DAY, i.PostingDate, ISNULL(c.ClearedOn, @AsOfDate)) AS OpenDays   -- 沒處理完算到基準日
    INTO #Cleared
    FROM #InMoves i
    OUTER APPLY (SELECT MIN(o.PostingDate) AS ClearedOn
                 FROM #OutMoves o
                 WHERE o.Material = i.Material AND o.Plant = i.Plant AND o.StorLoc = i.StorLoc AND o.Batch = i.Batch
                   AND o.CumOut >= i.CumIn
                   AND o.PostingDate >= i.PostingDate) c
    WHERE i.PostingDate BETWEEN @PeriodFrom AND @PeriodTo                                     -- 期間內轉入的
      AND i.MovementType IN (SELECT Value FROM kri.List('K20', 'ReturnTransferType'));      -- 轉入待退倉的異動

    -- 第 4 步：放太久 → 標記；寫進明細
    INSERT kri.K20_Detail (RunId, MaterialDoc, MaterialDocYear, MaterialDocItem, PostingDate, Material, Plant,
                           StorLoc, Batch, Quantity, BaseUom, ClearedOn, OpenDays, AmountLocal, IsFlagged)
    SELECT @RunId, MaterialDoc, MaterialDocYear, MaterialDocItem, PostingDate, Material, Plant,
           StorLoc, NULLIF(Batch, ''), Quantity, BaseUom, ClearedOn, OpenDays, LocalAmount,
           CASE WHEN OpenDays > @maxOpenDays THEN 1 ELSE 0 END
    FROM #Cleared;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocNumber, DocItem, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, Reason)
    SELECT RunId, 'K20', CONCAT(MaterialDoc, '-', MaterialDocYear, '-', MaterialDocItem), 'MOVEMENT', Plant, Material,
           MaterialDoc, MaterialDocItem, PostingDate, OpenDays, @maxOpenDays, AmountLocal,
           CONCAT(N'轉入待退倉 ', StorLoc, N' 後 ', OpenDays, N' 天',
                  CASE WHEN ClearedOn IS NULL THEN N'仍未處理' ELSE CONCAT(N'才處理完（', ClearedOn, N'）') END)
    FROM kri.K20_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    IF NOT EXISTS (SELECT 1 FROM kri.List('K20', 'ReturnStorLoc'))
        SET @Note = N'沒有設定待退倉（ReturnStorLoc），這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'轉入待退倉 ', COUNT(*), N' 筆；基準日仍未處理 ', COUNT(CASE WHEN ClearedOn IS NULL THEN 1 END))
        FROM kri.K20_Detail WHERE RunId = @RunId;
END;
GO
