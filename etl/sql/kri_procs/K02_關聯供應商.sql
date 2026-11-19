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

    SELECT x.Vendor AS VendorA, y.Vendor AS VendorB, x.MatchType, x.MatchValue
    INTO #Pair
    FROM #AttrShared x
    JOIN #AttrShared y ON y.MatchType = x.MatchType AND y.MatchValue = x.MatchValue AND x.Vendor < y.Vendor
    WHERE x.SharedBy <= @maxGroupSize;

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
