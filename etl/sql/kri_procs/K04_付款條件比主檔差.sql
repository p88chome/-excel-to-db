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
