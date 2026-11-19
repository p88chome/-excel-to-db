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
--            以及整張 PO 的本幣金額（所有項目合計，含還沒收貨的項目）。
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
    PoAmountLocal    DECIMAL(19,4) NULL,     -- 整張 PO 的本幣金額（母體內所有項目合計，含未收貨；有項目換不出本幣 = NULL）
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

    -- 第 1 步：觀察期間內的 PO 項目，接上第一次收貨（還沒收貨的也留著，整張 PO 金額要算全部項目）
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
           b.Material, b.LocalCurrency,
           r.PoNumber AS GrPoNumber,               -- NULL = 這個項目還沒收貨
           r.FirstGrDate, r.FirstGrEntryDate,
           r.FirstDate,                            -- 過帳日、輸入日取較早的
           r.FirstDocDate, r.HasExcludedText,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS ItemAmountLocal
    INTO #PoItem
    FROM kri.PoBase('K10', @PeriodFrom, @PeriodTo) b
    LEFT JOIN kri.PoReceipt('K10', @AsOfDate) r ON r.PoNumber = b.PoNumber AND r.PoItem = b.PoItem;

    -- 第 2 步：PO 到收貨的天數、PO 到送貨單的天數、整張 PO 的本幣金額
    SELECT p.*,
           DATEDIFF(DAY, p.PoDate, p.FirstDate)    AS GapDays,
           DATEDIFF(DAY, p.PoDate, p.FirstDocDate) AS DocGapDays,
           -- 有任何一個項目換不出本幣，整張 PO 金額就不算（留 NULL → 未判斷）
           CASE WHEN COUNT(*) OVER (PARTITION BY p.PoNumber) = COUNT(p.ItemAmountLocal) OVER (PARTITION BY p.PoNumber)
                THEN SUM(p.ItemAmountLocal) OVER (PARTITION BY p.PoNumber) END AS PoAmountLocal
    INTO #Gap
    FROM #PoItem p;

    DELETE #Gap WHERE GrPoNumber IS NULL;          -- 明細只留有收貨的項目（整張金額已經算好了）

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
