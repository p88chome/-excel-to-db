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
