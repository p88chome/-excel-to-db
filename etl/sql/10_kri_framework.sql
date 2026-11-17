-- KRI 框架：設定表、執行紀錄、統一標記表、共用函式、kri.RunAll。
-- 設計見 docs/KRI_PRD.md（D2～D8）。
--
-- 可以重複執行：表只在不存在時建立，已經調過的門檻、填好的核決權限表都不會被清掉。
-- 程序與函式用 CREATE OR ALTER，每次都會更新成這份的版本。
--
-- 執行順序：01（業務表）→ 10（這支）→ 11（KRI 程序）→ 12（預設設定）→ EXEC kri.RunAll

IF SCHEMA_ID(N'kri') IS NULL EXEC (N'CREATE SCHEMA kri');
GO

-- ======================================================================
-- 設定
-- ======================================================================
IF OBJECT_ID(N'kri.Definition', N'U') IS NULL
CREATE TABLE kri.Definition (
    KriCode      NVARCHAR(10)  NOT NULL PRIMARY KEY,
    Name         NVARCHAR(100) NOT NULL,
    Description  NVARCHAR(1000) NULL,
    Stage        NVARCHAR(20)  NULL,      -- 供應商管理 / 請購 / 採購 / 驗收 / 應付
    EntityType   NVARCHAR(20)  NOT NULL,  -- PO / PR / VENDOR / MATERIAL / CONDITION
    ProcName     NVARCHAR(128) NOT NULL,
    WindowMonths INT           NOT NULL,
    Enabled      BIT           NOT NULL DEFAULT 1,
    Phase        INT           NOT NULL,
    IsCompliance BIT NOT NULL DEFAULT 0,
    IsFraud      BIT NOT NULL DEFAULT 0,
    IsOperation  BIT NOT NULL DEFAULT 0,
    IsFinancial  BIT NOT NULL DEFAULT 0,
    Notes        NVARCHAR(1000) NULL
);

IF OBJECT_ID(N'kri.Parameter', N'U') IS NULL
CREATE TABLE kri.Parameter (
    KriCode     NVARCHAR(10)   NOT NULL,   -- '*' = 全域
    ParamName   NVARCHAR(50)   NOT NULL,
    ParamValue  DECIMAL(19,6)  NOT NULL,
    Unit        NVARCHAR(20)   NULL,       -- ratio / days / months / amount / count
    Description NVARCHAR(400)  NULL,
    IsTentative BIT            NOT NULL DEFAULT 1,
    UpdatedAt   DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    UpdatedBy   NVARCHAR(128)  NOT NULL DEFAULT SUSER_SNAME(),
    CONSTRAINT PK_kri_Parameter PRIMARY KEY (KriCode, ParamName)
);

IF OBJECT_ID(N'kri.ValueList', N'U') IS NULL
CREATE TABLE kri.ValueList (
    KriCode   NVARCHAR(10)  NOT NULL,      -- '*' = 全部 KRI
    ListName  NVARCHAR(50)  NOT NULL,      -- ExcludeVendorPrefix、AllowedConditionType …
    ListValue NVARCHAR(100) NOT NULL,
    Note      NVARCHAR(400) NULL,
    CONSTRAINT PK_kri_ValueList PRIMARY KEY (KriCode, ListName, ListValue)
);

-- 核決權限（K08 用，由客戶提供）。金額區間是 [MinAmount, MaxAmount)。
IF OBJECT_ID(N'kri.ApprovalMatrix', N'U') IS NULL
CREATE TABLE kri.ApprovalMatrix (
    DocType       NVARCHAR(10)  NOT NULL,   -- PR / PO
    CompanyCode   NVARCHAR(10)  NOT NULL DEFAULT '*',
    Currency      NVARCHAR(5)   NOT NULL,
    MinAmount     DECIMAL(19,4) NOT NULL,
    MaxAmount     DECIMAL(19,4) NOT NULL,
    ApprovalLevel INT           NOT NULL,   -- 數字越大層級越高
    ValidFrom     DATE          NOT NULL DEFAULT '1900-01-01',
    ValidTo       DATE          NOT NULL DEFAULT '9999-12-31',
    Note          NVARCHAR(400) NULL,
    CONSTRAINT PK_kri_ApprovalMatrix PRIMARY KEY (DocType, CompanyCode, Currency, MinAmount, ValidFrom)
);
GO

-- 付款條件天數對照（K04 用）。沒有列在這裡的付款條件，從代碼裡的數字推估天數。
-- 拿到 T052 後把正式的天數填進來（IsTentative = 0）。
IF OBJECT_ID(N'kri.PaymentTerm', N'U') IS NULL
CREATE TABLE kri.PaymentTerm (
    Code        NVARCHAR(4)   NOT NULL PRIMARY KEY,
    Days        INT           NOT NULL,
    Note        NVARCHAR(400) NULL,
    IsTentative BIT           NOT NULL DEFAULT 1
);
GO

-- ======================================================================
-- 外部系統資料（ext）：不在 SAP 裡、由各系統匯出後整理成固定格式。
-- KRI 只讀這裡的表，不直接讀各系統的原始匯出表，原始表到這裡的對應由各環境自己維護。
-- ======================================================================
IF SCHEMA_ID(N'ext') IS NULL EXEC (N'CREATE SCHEMA ext');
GO

-- 品質異常單（K01 用）：一張單一列。結案但沒有結案日的單，K01 會略過並在備註列出筆數。
IF OBJECT_ID(N'ext.QualityIssue', N'U') IS NULL
CREATE TABLE ext.QualityIssue (
    IssueNo   NVARCHAR(50)  NOT NULL PRIMARY KEY,
    Vendor    NVARCHAR(20)  NULL,       -- SAP 供應商代碼；純數字的會自動補前導零比對
    Material  NVARCHAR(40)  NULL,       -- 有對應料號才填
    Status    NVARCHAR(50)  NULL,       -- 原系統的狀態（顯示用）
    IsClosed  BIT           NOT NULL,
    OpenedOn  DATE          NOT NULL,
    ClosedOn  DATE          NULL,
    Category  NVARCHAR(100) NULL,
    Note      NVARCHAR(400) NULL
);
GO

-- ======================================================================
-- 執行紀錄與輸出
-- ======================================================================
IF OBJECT_ID(N'kri.Run', N'U') IS NULL
CREATE TABLE kri.Run (
    RunId     INT IDENTITY PRIMARY KEY,
    AsOfDate  DATE         NOT NULL,
    StartedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    EndedAt   DATETIME2(0) NULL,
    Status    NVARCHAR(10) NOT NULL DEFAULT 'RUNNING'   -- RUNNING / OK / PARTIAL / FAILED
);

IF OBJECT_ID(N'kri.RunStep', N'U') IS NULL
CREATE TABLE kri.RunStep (
    RunId        INT            NOT NULL,
    KriCode      NVARCHAR(10)   NOT NULL,
    PeriodFrom   DATE           NULL,
    PeriodTo     DATE           NULL,
    StartedAt    DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    EndedAt      DATETIME2(0)   NULL,
    DetailRows   BIGINT         NULL,
    FlagRows     BIGINT         NULL,
    Status       NVARCHAR(10)   NOT NULL DEFAULT 'RUNNING',  -- RUNNING / OK / FAILED
    Note         NVARCHAR(400)  NULL,
    ErrorMessage NVARCHAR(4000) NULL,
    CONSTRAINT PK_kri_RunStep PRIMARY KEY (RunId, KriCode)
);

IF OBJECT_ID(N'kri.Flag', N'U') IS NULL
CREATE TABLE kri.Flag (
    RunId          INT           NOT NULL,
    KriCode        NVARCHAR(10)  NOT NULL,
    FlagKey        NVARCHAR(100) NOT NULL,   -- 對象鍵，例：4500000001-00010
    EntityType     NVARCHAR(20)  NOT NULL,
    CompanyCode    NVARCHAR(10)  NULL,
    PurchOrg       NVARCHAR(10)  NULL,
    Plant          NVARCHAR(10)  NULL,
    Vendor         NVARCHAR(20)  NULL,
    Material       NVARCHAR(40)  NULL,
    DocNumber      NVARCHAR(20)  NULL,
    DocItem        NVARCHAR(10)  NULL,
    DocDate        DATE          NULL,
    MetricValue    DECIMAL(19,6) NULL,       -- 觸發標記的數值
    ThresholdValue DECIMAL(19,6) NULL,       -- 當次使用的門檻
    EffectLocal    DECIMAL(19,4) NULL,       -- 影響金額（本幣）
    LocalCurrency  NVARCHAR(5)   NULL,
    EffectTWD      DECIMAL(19,4) NULL,       -- 匯率表到位後才有值
    Reason         NVARCHAR(400) NULL,
    CONSTRAINT PK_kri_Flag PRIMARY KEY (RunId, KriCode, FlagKey)
);
GO

-- ======================================================================
-- 共用函式
-- ======================================================================

-- 讀門檻。找不到就讓查詢失敗並指名缺哪一個參數，不靜默用預設值（D3）。
-- 函式裡不能 RAISERROR，用型別轉換錯誤把訊息帶出來。
CREATE OR ALTER FUNCTION kri.Param (@KriCode NVARCHAR(10), @ParamName NVARCHAR(50))
RETURNS DECIMAL(19,6)
AS
BEGIN
    DECLARE @v DECIMAL(19,6) = (SELECT ParamValue FROM kri.Parameter
                                WHERE KriCode = @KriCode AND ParamName = @ParamName);
    IF @v IS NULL
        RETURN CAST(CONCAT(N'kri.Parameter 缺少參數 ', @KriCode, N'.', @ParamName) AS INT);
    RETURN @v;
END;
GO

-- 文件幣別 → 本幣。SAP 的 WKURS 為負代表間接報價（本幣 = 金額 ÷ |匯率|）。
CREATE OR ALTER FUNCTION kri.ToLocal (@Amount DECIMAL(19,4), @DocCurrency NVARCHAR(5),
                                      @LocalCurrency NVARCHAR(5), @Rate DECIMAL(19,5))
RETURNS DECIMAL(19,4)
AS
BEGIN
    IF @Amount IS NULL RETURN NULL;
    IF @DocCurrency = @LocalCurrency RETURN @Amount;
    IF @Rate IS NULL OR @Rate = 0 RETURN NULL;
    RETURN IIF(@Rate > 0, @Amount * @Rate, @Amount / -@Rate);
END;
GO

-- 公司別本幣。KRI 只讀業務表（D1），這是唯一讀 SAP 原表的地方。
CREATE OR ALTER VIEW kri.vCompanyCurrency AS
SELECT BUKRS AS CompanyCode, MAX(WAERS) AS LocalCurrency
FROM dbo.T001
GROUP BY BUKRS;
GO

-- PO 母體：觀察期間內、未刪除、數量 > 0，套用排除名單。比價類 KRI 共用。
CREATE OR ALTER FUNCTION kri.PoBase (@KriCode NVARCHAR(10), @From DATE, @To DATE)
RETURNS TABLE
AS RETURN
SELECT p.PoNumber, p.PoItem, p.PoType, p.PoDate, p.CompanyCode, p.PurchOrg, p.Plant,
       p.Vendor, p.VendorName, p.Material, p.MaterialDesc, p.MaterialGroup,
       p.OrderQty, p.OrderUom, p.NetPrice, p.PriceUnit, p.NetValue, p.Currency,
       p.ExchangeRate, p.DelivDate, p.DelivComplInd, p.GrQty,
       CAST(p.NetPrice / NULLIF(p.PriceUnit, 0) AS DECIMAL(19,6)) AS UnitPrice,
       c.LocalCurrency
FROM prc.PurchaseOrderDetail p
LEFT JOIN kri.vCompanyCurrency c ON c.CompanyCode = p.CompanyCode
WHERE p.PoDate BETWEEN @From AND @To
  AND ISNULL(p.DeletionInd, '') = ''
  AND p.OrderQty > 0
  AND NOT EXISTS (
        SELECT 1 FROM kri.ValueList x
        WHERE x.KriCode IN (@KriCode, '*')
          AND (   (x.ListName = 'ExcludeVendorPrefix'  AND p.Vendor LIKE x.ListValue + '%')
               OR (x.ListName = 'ExcludePurchOrg'      AND p.PurchOrg = x.ListValue)
               OR (x.ListName = 'ExcludePlant'         AND p.Plant = x.ListValue)
               OR (x.ListName = 'ExcludePoType'        AND p.PoType = x.ListValue)
               OR (x.ListName = 'ExcludeMaterialGroup' AND p.MaterialGroup = x.ListValue)));
GO

-- 下單日有效的主檔價：A017（分工廠）優先，沒有再用 A018。條件類型、資訊記錄類別依白名單。
-- 同一天有多筆有效（不同條件類型或期間重疊）時取生效日最近的一筆。
CREATE OR ALTER FUNCTION kri.InfoPriceAt (@KriCode NVARCHAR(10), @Vendor NVARCHAR(20),
        @Material NVARCHAR(40), @PurchOrg NVARCHAR(10), @Plant NVARCHAR(10), @OnDate DATE)
RETURNS TABLE
AS RETURN
SELECT TOP 1 c.Source, c.ConditionRecord, c.ConditionType, c.ValidFrom, c.ValidTo,
       c.Currency, c.OrderUom,
       CAST(c.ConditionPrice / NULLIF(c.PriceUnit, 0) AS DECIMAL(19,6)) AS UnitPrice
FROM (
    SELECT 1 AS Pref, 'A017' AS Source, ConditionRecord, ConditionType, ValidFrom, ValidTo,
           Currency, OrderUom, ConditionPrice, PriceUnit, InfoCategory, DeletionInd
    FROM mst.PurchasingCondA017
    WHERE Vendor = @Vendor AND Material = @Material AND PurchOrg = @PurchOrg AND Plant = @Plant
      AND @OnDate BETWEEN ValidFrom AND ValidTo
    UNION ALL
    SELECT 2, 'A018', ConditionRecord, ConditionType, ValidFrom, ValidTo,
           Currency, OrderUom, ConditionPrice, PriceUnit, InfoCategory, DeletionInd
    FROM mst.PurchasingCondA018
    WHERE Vendor = @Vendor AND Material = @Material AND PurchOrg = @PurchOrg
      AND @OnDate BETWEEN ValidFrom AND ValidTo
) c
WHERE ISNULL(c.DeletionInd, '') = ''
  AND c.ConditionType IN (SELECT ListValue FROM kri.ValueList
                          WHERE KriCode IN (@KriCode, '*') AND ListName = 'AllowedConditionType')
  AND c.InfoCategory  IN (SELECT ListValue FROM kri.ValueList
                          WHERE KriCode IN (@KriCode, '*') AND ListName = 'AllowedInfoCategory')
ORDER BY c.Pref, c.ValidFrom DESC, c.ConditionType;
GO

-- PO 項目的收貨日期（K10、K19 共用）：只算收貨異動類型（白名單 GrMovementType）的借方（S）。
-- 只看基準日當時已經存在的收貨（過帳日、系統輸入日都 <= @AsOfDate），回補歷史基準日時不會看到之後才補的收貨。
-- FirstDate = 每筆收貨的過帳日、系統輸入日取較早（過帳日可以手動填，輸入日不行），再取最早一筆。
-- FirstDocDate = 最早的收貨文件日（BLDAT，通常是送貨單日期），送貨單早於 PO 是貨先到的直接證據。
-- HasExcludedText = 任何一筆收貨的項目說明符合排除關鍵字（ExcludeTextPattern，LIKE 樣式）。
-- 限制：沖銷（102 或 H）不扣回；沖銷後重收的，第一次收貨日仍是被沖銷那筆。
CREATE OR ALTER FUNCTION kri.PoReceipt (@KriCode NVARCHAR(10), @AsOfDate DATE)
RETURNS TABLE
AS RETURN
WITH g AS (
    SELECT g.PoNumber, g.PoItem, g.PostingDate, g.EntryDate, g.DocumentDate,
           (SELECT MIN(v) FROM (VALUES (g.PostingDate), (g.EntryDate)) x(v)) AS EarlierDate,
           IIF(EXISTS (SELECT 1 FROM kri.ValueList x
                       WHERE x.KriCode IN (@KriCode, '*') AND x.ListName = 'ExcludeTextPattern'
                         AND g.ItemText LIKE x.ListValue), 1, 0) AS Excluded
    FROM prc.GoodsReceipt g
    WHERE ISNULL(g.PoNumber, '') <> ''
      AND g.DebitCreditInd = 'S'
      AND g.MovementType IN (SELECT ListValue FROM kri.ValueList
                             WHERE KriCode IN (@KriCode, '*') AND ListName = 'GrMovementType')
      AND ISNULL(g.PostingDate, g.EntryDate) <= @AsOfDate
      AND ISNULL(g.EntryDate, g.PostingDate) <= @AsOfDate
)
SELECT PoNumber, PoItem, MIN(PostingDate) AS FirstGrDate, MIN(EntryDate) AS FirstGrEntryDate,
       MIN(EarlierDate) AS FirstDate, MIN(DocumentDate) AS FirstDocDate, COUNT(*) AS GrCount, CAST(MAX(Excluded) AS BIT) AS HasExcludedText
FROM g
GROUP BY PoNumber, PoItem;
GO

-- 付款條件天數：先查 kri.PaymentTerm，沒有就取代碼裡的第一串數字（例：XX30 → 30）。都沒有回 NULL。
CREATE OR ALTER FUNCTION kri.TermDays (@Code NVARCHAR(4))
RETURNS INT
AS
BEGIN
    IF ISNULL(@Code, '') = '' RETURN NULL;
    DECLARE @d INT = (SELECT Days FROM kri.PaymentTerm WHERE Code = @Code);
    IF @d IS NOT NULL RETURN @d;
    DECLARE @p INT = PATINDEX('%[0-9]%', @Code);
    IF @p = 0 RETURN NULL;
    DECLARE @s NVARCHAR(4) = SUBSTRING(@Code, @p, 4);
    DECLARE @q INT = PATINDEX('%[^0-9]%', @s);
    IF @q > 0 SET @s = LEFT(@s, @q - 1);
    RETURN TRY_CONVERT(INT, @s);
END;
GO

-- KRI 查詢用的索引。01_create_tables.sql 會整張重建資料表，重跑 01 之後要再跑這支。
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_AP_Po' AND object_id = OBJECT_ID('fin.AccountsPayable'))
    CREATE INDEX IX_kri_AP_Po ON fin.AccountsPayable (PoNumber, PoItem)
    INCLUDE (PaymentTerms, PostingDate, EntryDate, DebitCreditInd);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_AP_Vendor' AND object_id = OBJECT_ID('fin.AccountsPayable'))
    CREATE INDEX IX_kri_AP_Vendor ON fin.AccountsPayable (Vendor, PostingDate) INCLUDE (CompanyCode, EntryDate, AccountingDoc, FiscalYear);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_PO_Date' AND object_id = OBJECT_ID('prc.PurchaseOrderDetail'))
    CREATE INDEX IX_kri_PO_Date ON prc.PurchaseOrderDetail (PoDate)
    INCLUDE (Vendor, PurchOrg, CompanyCode, Plant, Material, MaterialGroup, PoType, NetValue, Currency,
             ExchangeRate, OrderQty, DeletionInd);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_PO_Vendor' AND object_id = OBJECT_ID('prc.PurchaseOrderDetail'))
    CREATE INDEX IX_kri_PO_Vendor ON prc.PurchaseOrderDetail (Vendor, PoDate)
    INCLUDE (PurchOrg, CompanyCode, Plant, Material, MaterialGroup, PoType, NetValue, Currency,
             ExchangeRate, OrderQty, DeletionInd);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_GR_Po' AND object_id = OBJECT_ID('prc.GoodsReceipt'))
    CREATE INDEX IX_kri_GR_Po ON prc.GoodsReceipt (PoNumber, PoItem)
    INCLUDE (PostingDate, EntryDate, DocumentDate, MovementType, DebitCreditInd, ItemText);
GO

-- ======================================================================
-- 儀表板讀這個：每個 KRI 最新一次成功執行的標記
-- ======================================================================
CREATE OR ALTER VIEW kri.vFlagLatest AS
SELECT f.*, d.Name AS KriName, s.PeriodFrom, s.PeriodTo, r.AsOfDate
FROM kri.Flag f
JOIN (SELECT KriCode, MAX(RunId) AS RunId FROM kri.RunStep WHERE Status = 'OK' GROUP BY KriCode) l
  ON l.KriCode = f.KriCode AND l.RunId = f.RunId
JOIN kri.RunStep s   ON s.RunId = f.RunId AND s.KriCode = f.KriCode
JOIN kri.Run r       ON r.RunId = f.RunId
JOIN kri.Definition d ON d.KriCode = f.KriCode;
GO

-- ======================================================================
-- kri.RunAll：依 kri.Definition 跑所有啟用的 KRI（D7）
--   EXEC kri.RunAll;                          -- 基準日 = 今天
--   EXEC kri.RunAll @AsOfDate = '2025-12-31'; -- 回補某個基準日
--   EXEC kri.RunAll @Only = N'K14,K13';        -- 只跑這幾題
-- 每題各自一個交易：失敗的那題回滾、記錄錯誤，其他照跑。
-- 每題的程序簽名：@RunId, @AsOfDate, @PeriodFrom, @PeriodTo, @Note OUTPUT，
-- 明細寫到 kri.<KriCode>_Detail、標記寫到 kri.Flag，都帶 RunId。
-- ======================================================================
CREATE OR ALTER PROCEDURE kri.RunAll @AsOfDate DATE = NULL, @Only NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @AsOfDate = ISNULL(@AsOfDate, CAST(GETDATE() AS DATE));

    INSERT kri.Run (AsOfDate) VALUES (@AsOfDate);
    DECLARE @RunId INT = SCOPE_IDENTITY();

    DECLARE @steps TABLE (seq INT IDENTITY, KriCode NVARCHAR(10), ProcName NVARCHAR(128), WindowMonths INT);
    INSERT @steps (KriCode, ProcName, WindowMonths)
    SELECT d.KriCode, d.ProcName,
           ISNULL(CAST(p.ParamValue AS INT), d.WindowMonths)   -- 參數可以覆寫預設期間
    FROM kri.Definition d
    LEFT JOIN kri.Parameter p ON p.KriCode = d.KriCode AND p.ParamName = 'WindowMonths'
    WHERE d.Enabled = 1
      AND (@Only IS NULL OR d.KriCode IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Only, ',')))
    ORDER BY d.KriCode;

    DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @steps),
            @code NVARCHAR(10), @proc NVARCHAR(128), @months INT,
            @from DATE, @note NVARCHAR(400), @rows BIGINT, @sql NVARCHAR(400);

    WHILE @i <= @n
    BEGIN
        SELECT @code = KriCode, @proc = ProcName, @months = WindowMonths FROM @steps WHERE seq = @i;
        SET @from = DATEADD(DAY, 1, DATEADD(MONTH, -@months, @AsOfDate));
        SET @note = NULL;
        INSERT kri.RunStep (RunId, KriCode, PeriodFrom, PeriodTo) VALUES (@RunId, @code, @from, @AsOfDate);
        BEGIN TRY
            BEGIN TRAN;
            EXEC @proc @RunId = @RunId, @AsOfDate = @AsOfDate, @PeriodFrom = @from,
                       @PeriodTo = @AsOfDate, @Note = @note OUTPUT;
            COMMIT;
            SET @sql = N'SELECT @r = COUNT_BIG(*) FROM kri.' + QUOTENAME(@code + N'_Detail') + N' WHERE RunId = @id';
            EXEC sp_executesql @sql, N'@r BIGINT OUTPUT, @id INT', @r = @rows OUTPUT, @id = @RunId;
            UPDATE kri.RunStep
            SET EndedAt = SYSDATETIME(), Status = 'OK', Note = @note, DetailRows = @rows,
                FlagRows = (SELECT COUNT_BIG(*) FROM kri.Flag WHERE RunId = @RunId AND KriCode = @code)
            WHERE RunId = @RunId AND KriCode = @code;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            UPDATE kri.RunStep
            SET EndedAt = SYSDATETIME(), Status = 'FAILED',
                ErrorMessage = CONCAT(N'[', ERROR_NUMBER(), N'] ', ERROR_MESSAGE())
            WHERE RunId = @RunId AND KriCode = @code;
        END CATCH;
        SET @i += 1;
    END;

    UPDATE kri.Run
    SET EndedAt = SYSDATETIME(),
        Status = CASE WHEN NOT EXISTS (SELECT 1 FROM kri.RunStep WHERE RunId = @RunId AND Status <> 'OK') THEN 'OK'
                      WHEN EXISTS (SELECT 1 FROM kri.RunStep WHERE RunId = @RunId AND Status = 'OK') THEN 'PARTIAL'
                      ELSE 'FAILED' END
    WHERE RunId = @RunId;

    -- 只保留最近 KeepRuns 次（D4）。沒設參數就全部保留。
    DECLARE @keep INT = (SELECT CAST(ParamValue AS INT) FROM kri.Parameter
                         WHERE KriCode = '*' AND ParamName = 'KeepRuns');
    IF @keep > 0
    BEGIN
        DECLARE @cut INT = (SELECT MIN(RunId) FROM (SELECT TOP (@keep) RunId FROM kri.Run ORDER BY RunId DESC) k);
        DECLARE @t NVARCHAR(128);
        DECLARE tbls CURSOR LOCAL FAST_FORWARD FOR
            SELECT t.name FROM sys.tables t
            WHERE t.schema_id = SCHEMA_ID('kri') AND t.name LIKE N'K%[_]Detail';
        OPEN tbls;
        FETCH NEXT FROM tbls INTO @t;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'DELETE kri.' + QUOTENAME(@t) + N' WHERE RunId < @cut';
            EXEC sp_executesql @sql, N'@cut INT', @cut = @cut;
            FETCH NEXT FROM tbls INTO @t;
        END;
        CLOSE tbls;
        DELETE kri.Flag    WHERE RunId < @cut;
        DELETE kri.RunStep WHERE RunId < @cut;
        DELETE kri.Run     WHERE RunId < @cut;
    END;

    SELECT s.KriCode AS [KRI], d.Name AS [名稱], s.PeriodFrom AS [期間起], s.PeriodTo AS [期間迄],
           s.DetailRows AS [明細筆數], s.FlagRows AS [標記筆數], s.Status AS [結果],
           COALESCE(s.ErrorMessage, s.Note) AS [說明]
    FROM kri.RunStep s
    JOIN kri.Definition d ON d.KriCode = s.KriCode
    WHERE s.RunId = @RunId
    ORDER BY s.KriCode;
END;
GO
