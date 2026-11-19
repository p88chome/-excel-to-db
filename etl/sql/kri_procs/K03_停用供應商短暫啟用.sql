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
