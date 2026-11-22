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

-- 讀白名單、排除名單（kri.ValueList）。KriCode = '*' 的設定每一題都適用。
--   用法：WHERE p.PoType IN (SELECT Value FROM kri.List('K11', 'EmergencyPoType'))
CREATE OR ALTER FUNCTION kri.List (@KriCode NVARCHAR(10), @ListName NVARCHAR(50))
RETURNS TABLE
AS RETURN
SELECT ListValue AS Value
FROM kri.ValueList
WHERE KriCode IN (@KriCode, '*') AND ListName = @ListName;
GO

-- 字串裡有幾個數字。例：'(02)2345-6789' → 10。
CREATE OR ALTER FUNCTION kri.DigitCount (@s NVARCHAR(400))
RETURNS INT
AS
BEGIN
    -- 把 0～9 都換成 #，拿掉 # 之後少了幾個字 = 數字個數。
    -- 用 DATALENGTH 不用 LEN：LEN 不算結尾的空白，'12 3' 會被算成 4 個數字。
    RETURN (DATALENGTH(@s) - DATALENGTH(REPLACE(TRANSLATE(@s, N'0123456789', N'##########'), N'#', N''))) / 2;
END;
GO

-- 看起來是不是「填充值」而不是真的資料：空白、整串同一個字（0000000000、XXXXXXXXXX、----）、
-- 只有 NA 重複（NA、NANANA）。比對統編、電話、地址、銀行帳號時，填充值不能拿來配對。
CREATE OR ALTER FUNCTION kri.IsPlaceholder (@s NVARCHAR(400))
RETURNS BIT
AS
BEGIN
    SET @s = LTRIM(RTRIM(@s));
    IF ISNULL(@s, N'') = N''                   RETURN 1;
    IF REPLACE(@s, LEFT(@s, 1), N'') = N''     RETURN 1;   -- 拿掉第一個字之後什麼都不剩 = 整串同一個字
    IF REPLACE(@s, N'NA', N'') = N''           RETURN 1;
    RETURN 0;
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

-- 通用、雜項料號（ValueList GenericMaterial，只在本地設定）：一個料號底下其實是很多種不同的東西，
-- 單價、數量沒有可比性。比價、比量的 KRI（K06、K07、K12、K13、K14）排除；
-- 流程類（拆單、付款條件、先收後補…）照常看。數字料號可以不補零。候選清單用 kri.SuggestGenericMaterial 找。
CREATE OR ALTER FUNCTION kri.IsGeneric (@KriCode NVARCHAR(10), @Material NVARCHAR(40))
RETURNS TABLE
AS RETURN
SELECT 1 AS IsGeneric
WHERE EXISTS (SELECT 1 FROM kri.ValueList x
              WHERE x.KriCode IN (@KriCode, '*') AND x.ListName = 'GenericMaterial'
                AND (@Material = x.ListValue
                     OR (x.ListValue NOT LIKE '%[^0-9]%' AND @Material = RIGHT(REPLICATE('0', 18) + x.ListValue, 18))));
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
       c.LocalCurrency,
       CAST(IIF(g.IsGeneric IS NULL, 0, 1) AS BIT) AS IsGeneric      -- 通用料號：比價類 KRI 用 IsGeneric = 0 排除
FROM prc.PurchaseOrderDetail p
LEFT JOIN kri.vCompanyCurrency c ON c.CompanyCode = p.CompanyCode
OUTER APPLY kri.IsGeneric(@KriCode, p.Material) g
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
               OR (x.ListName = 'ExcludeMaterialGroup' AND p.MaterialGroup = x.ListValue)
               OR (x.ListName = 'ExcludeMaterial'      AND (p.Material = x.ListValue      -- 通用、雜項料號；數字料號可以不補零
                                                           OR (x.ListValue NOT LIKE '%[^0-9]%'
                                                               AND p.Material = RIGHT(REPLICATE('0', 18) + x.ListValue, 18))))));
GO

-- 找通用料號的候選：期間內同一個料號（同幣別、同單位）有很多家供應商、單價差距很大。
-- 只是建議，確認後自己加進 ValueList：INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('*', 'GenericMaterial', 'M001');
--   EXEC kri.SuggestGenericMaterial @From = '2024-01-01', @To = '2024-12-31';
CREATE OR ALTER PROCEDURE kri.SuggestGenericMaterial
    @From DATE, @To DATE, @MinVendors INT = 5, @MinSpread DECIMAL(19,4) = 20
AS
BEGIN
    SET NOCOUNT ON;
    WITH g AS (
        SELECT Material, Currency, OrderUom, COUNT(*) AS Items, COUNT(DISTINCT Vendor) AS Vendors,
               COUNT(DISTINCT Plant) AS Plants, MIN(UnitPrice) AS MinPrice, MAX(UnitPrice) AS MaxPrice
        FROM kri.PoBase('*', @From, @To)
        WHERE ISNULL(Material, '') <> '' AND UnitPrice > 0
        GROUP BY Material, Currency, OrderUom
    )
    SELECT g.Material, g.Currency, g.OrderUom, g.Items AS PoItems, g.Vendors, g.Plants, g.MinPrice, g.MaxPrice,
           CAST(g.MaxPrice / g.MinPrice AS DECIMAL(19,1)) AS Spread,
           IIF(EXISTS (SELECT 1 FROM kri.IsGeneric('*', g.Material)), N'已列入', N'') AS Listed
    FROM g
    WHERE g.Vendors >= @MinVendors AND g.MaxPrice / g.MinPrice >= @MinSpread
    ORDER BY g.Items DESC;
END;
GO

-- 某一天有效的主檔價：A017（分工廠）優先，沒有再用 A018。條件類型、資訊記錄類別依白名單。
-- 同一天有多筆有效（不同條件類型或期間重疊）時取生效日最近的一筆。
-- @KnownBy：只看這天以前已經建立的條件（通常給基準日）。回補過去的基準日時，
--            不能用到基準日之後才建、再把生效日倒填回去的主檔價。建立日空白的視為生效日就建了。
--            SAP 建新條件時會把重疊的舊條件的有效迄日縮短；舊條件的迄日如果是被 @KnownBy 之後才建的
--            條件縮短的（新條件的生效日 = 舊條件迄日 + 1），那天的舊條件當作還有效。
CREATE OR ALTER FUNCTION kri.InfoPriceAt (@KriCode NVARCHAR(10), @Vendor NVARCHAR(20),
        @Material NVARCHAR(40), @PurchOrg NVARCHAR(10), @Plant NVARCHAR(10), @OnDate DATE, @KnownBy DATE)
RETURNS TABLE
AS RETURN
SELECT TOP 1 c.Source, c.ConditionRecord, c.ConditionType, c.ValidFrom, c.ValidTo,
       c.Currency, c.OrderUom,
       CAST(c.ConditionPrice / NULLIF(c.PriceUnit, 0) AS DECIMAL(19,6)) AS UnitPrice
FROM (
    SELECT 1 AS Pref, 'A017' AS Source, a.ConditionRecord, a.ConditionType, a.ValidFrom, a.ValidTo,
           a.Currency, a.OrderUom, a.ConditionPrice, a.PriceUnit, a.InfoCategory, a.DeletionInd, a.CreatedOn
    FROM mst.PurchasingCondA017 a
    WHERE a.Vendor = @Vendor AND a.Material = @Material AND a.PurchOrg = @PurchOrg AND a.Plant = @Plant
      AND a.ValidFrom <= @OnDate
      AND (   @OnDate <= a.ValidTo
           OR EXISTS (SELECT 1 FROM mst.PurchasingCondA017 n          -- 迄日是之後才建的條件縮短的
                      WHERE n.Vendor = a.Vendor AND n.Material = a.Material AND n.PurchOrg = a.PurchOrg
                        AND n.Plant = a.Plant AND n.InfoCategory = a.InfoCategory AND n.ConditionType = a.ConditionType
                        AND n.ValidFrom = DATEADD(DAY, 1, a.ValidTo)
                        AND ISNULL(n.CreatedOn, n.ValidFrom) > @KnownBy))
    UNION ALL
    SELECT 2, 'A018', a.ConditionRecord, a.ConditionType, a.ValidFrom, a.ValidTo,
           a.Currency, a.OrderUom, a.ConditionPrice, a.PriceUnit, a.InfoCategory, a.DeletionInd, a.CreatedOn
    FROM mst.PurchasingCondA018 a
    WHERE a.Vendor = @Vendor AND a.Material = @Material AND a.PurchOrg = @PurchOrg
      AND a.ValidFrom <= @OnDate
      AND (   @OnDate <= a.ValidTo
           OR EXISTS (SELECT 1 FROM mst.PurchasingCondA018 n
                      WHERE n.Vendor = a.Vendor AND n.Material = a.Material AND n.PurchOrg = a.PurchOrg
                        AND n.InfoCategory = a.InfoCategory AND n.ConditionType = a.ConditionType
                        AND n.ValidFrom = DATEADD(DAY, 1, a.ValidTo)
                        AND ISNULL(n.CreatedOn, n.ValidFrom) > @KnownBy))
) c
WHERE ISNULL(c.DeletionInd, '') = ''
  AND ISNULL(c.CreatedOn, c.ValidFrom) <= @KnownBy
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
-- kri.PoReceivedAt 要讀 Quantity：舊版索引沒有包含的話先拿掉重建
IF EXISTS (SELECT 1 FROM sys.indexes i WHERE i.name = 'IX_kri_GR_Po' AND i.object_id = OBJECT_ID('prc.GoodsReceipt'))
   AND NOT EXISTS (SELECT 1 FROM sys.indexes i
                   JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                   WHERE i.name = 'IX_kri_GR_Po' AND i.object_id = OBJECT_ID('prc.GoodsReceipt')
                     AND COL_NAME(ic.object_id, ic.column_id) = 'Quantity')
    DROP INDEX IX_kri_GR_Po ON prc.GoodsReceipt;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_GR_Po' AND object_id = OBJECT_ID('prc.GoodsReceipt'))
    CREATE INDEX IX_kri_GR_Po ON prc.GoodsReceipt (PoNumber, PoItem)
    INCLUDE (PostingDate, EntryDate, DocumentDate, MovementType, DebitCreditInd, ItemText, Quantity);
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

-- ======================================================================
-- 外部資料（第四批 KRI）：各環境把原系統匯出整理進來；原始表到 ext 的對應不放在 repo。
-- ======================================================================
IF OBJECT_ID(N'ext.VendorRelation', N'U') IS NULL
CREATE TABLE ext.VendorRelation (          -- 商工登記：關聯企業（同代表人、董監事、地址…），K02
    VendorA      NVARCHAR(10)  NOT NULL,
    VendorB      NVARCHAR(10)  NOT NULL,
    RelationType NVARCHAR(30)  NOT NULL,
    Note         NVARCHAR(200) NULL,
    CONSTRAINT PK_ext_VendorRelation PRIMARY KEY (VendorA, VendorB, RelationType)
);
IF OBJECT_ID(N'ext.VendorCapital', N'U') IS NULL
CREATE TABLE ext.VendorCapital (           -- 商工登記：實收資本額，K05。Vendor 或 TaxNumber 擇一對應
    Id         INT IDENTITY  NOT NULL CONSTRAINT PK_ext_VendorCapital PRIMARY KEY,
    Vendor     NVARCHAR(10)  NULL,
    TaxNumber  NVARCHAR(20)  NULL,
    Capital    DECIMAL(19,2) NOT NULL,
    Currency   NVARCHAR(5)   NOT NULL,
    DataDate   DATE          NULL          -- 查詢日；同一家有多筆取基準日前最新的
);
IF OBJECT_ID(N'ext.PartUsage', N'U') IS NULL
CREATE TABLE ext.PartUsage (               -- 零件系統：MOU、waiting for use，K11
    Material      NVARCHAR(18)  NOT NULL,
    Plant         NVARCHAR(4)   NOT NULL,
    SnapshotDate  DATE          NOT NULL,
    Mou           DECIMAL(19,4) NULL,
    WaitingForUse DECIMAL(19,4) NULL,
    CONSTRAINT PK_ext_PartUsage PRIMARY KEY (Material, Plant, SnapshotDate)
);
IF OBJECT_ID(N'ext.SlowMoving', N'U') IS NULL
CREATE TABLE ext.SlowMoving (              -- 呆滯報表每月快照，K15、K16
    SnapshotDate DATE          NOT NULL,
    Material     NVARCHAR(18)  NOT NULL,
    Plant        NVARCHAR(4)   NOT NULL,
    Status       NVARCHAR(20)  NULL,
    AgeDays      INT           NULL,
    SlowOn       DATE          NULL,       -- 認列呆滯的日期（已呆滯 = 過去、還沒 = 未來）
    StockQty     DECIMAL(19,4) NULL,
    StockValue   DECIMAL(19,4) NULL,
    Currency     NVARCHAR(5)   NULL,
    CONSTRAINT PK_ext_SlowMoving PRIMARY KEY (SnapshotDate, Material, Plant)
);
IF OBJECT_ID(N'ext.Contract', N'U') IS NULL
CREATE TABLE ext.Contract (                -- 合約系統，K17
    ContractNo NVARCHAR(30)  NOT NULL CONSTRAINT PK_ext_Contract PRIMARY KEY,
    Vendor     NVARCHAR(10)  NULL,
    PoNumber   NVARCHAR(10)  NULL,         -- 有填就直接對 PO，沒填用供應商 + 有效期間對
    SignedOn   DATE          NULL,
    ValidFrom  DATE          NULL,
    ValidTo    DATE          NULL,
    Amount     DECIMAL(19,2) NULL,
    Currency   NVARCHAR(5)   NULL
);
IF OBJECT_ID(N'ext.ExpectedDemand', N'U') IS NULL
CREATE TABLE ext.ExpectedDemand (          -- 預期請購量（月），K07
    Material NVARCHAR(18)  NOT NULL,
    Plant    NVARCHAR(4)   NOT NULL,
    Month    DATE          NOT NULL,       -- 當月 1 日
    Qty      DECIMAL(19,4) NOT NULL,
    CONSTRAINT PK_ext_ExpectedDemand PRIMARY KEY (Material, Plant, Month)
);
GO

-- 某天的工廠庫存（K06、K11、K16）：庫存快照 − 快照日之前、指定日之後的異動（貸方減、借方加）。
-- 快照只有一份，回推的準度取決於異動資料是否完整（期間外、非 PO 的異動有沒有下載）。
CREATE OR ALTER FUNCTION kri.StockAt (@Material NVARCHAR(18), @Plant NVARCHAR(4), @OnDate DATE)
RETURNS TABLE
AS RETURN
SELECT s.Qty - ISNULL(m.Net, 0) AS StockQty, s.SnapshotDate
FROM (SELECT SUM(ISNULL(StockQty, 0) + ISNULL(QualityStock, 0) + ISNULL(BlockedStock, 0)) AS Qty,
             MAX(SnapshotDate) AS SnapshotDate
      FROM inv.InventoryBalance WHERE Material = @Material AND Plant = @Plant) s
OUTER APPLY (SELECT SUM(IIF(DebitCreditInd = 'H', -Quantity, Quantity)) AS Net
             FROM inv.MaterialMovement
             WHERE Material = @Material AND Plant = @Plant
               AND PostingDate > @OnDate AND PostingDate <= s.SnapshotDate) m
WHERE s.Qty IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_MM_Mat' AND object_id = OBJECT_ID('inv.MaterialMovement'))
    CREATE INDEX IX_kri_MM_Mat ON inv.MaterialMovement (Material, Plant, PostingDate)
    INCLUDE (Quantity, DebitCreditInd, MovementType, StorLoc, Batch);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_PR_Mat' AND object_id = OBJECT_ID('prc.PurchaseRequisition'))
    CREATE INDEX IX_kri_PR_Mat ON prc.PurchaseRequisition (Material, Plant, PrDate) INCLUDE (ReqQty, DeletionInd);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_kri_PO_Mat' AND object_id = OBJECT_ID('prc.PurchaseOrderDetail'))
    CREATE INDEX IX_kri_PO_Mat ON prc.PurchaseOrderDetail (Material, Plant, PoDate) INCLUDE (OrderQty, DeletionInd);
GO

-- ======================================================================
-- 呆滯判斷（K15、K16 共用）：優先用呆滯報表快照（ext.SlowMoving，取指定日以前最新一份）；
-- 沒有快照而且 UseSapFallback = 1 時，用「最後一次領用日」+ SlowDays 推估認列呆滯的日期。
--   領用 = 這一題 ConsumptionMovementType 名單裡、從庫存扣出（貸方 H）的異動。收貨、移倉、沖回都不算：
--   不然每收一次貨呆滯就重新計算，一直在買、卻沒人用的料反而永遠不會呆滯。
--   從來沒有領用過的料，用第一次出現異動的日子起算。
-- ======================================================================
CREATE OR ALTER FUNCTION kri.SlowStatusAt (@KriCode NVARCHAR(10), @Material NVARCHAR(18), @Plant NVARCHAR(4), @OnDate DATE,
                                            @SlowDays INT, @UseSapFallback INT)
RETURNS TABLE
AS RETURN
SELECT TOP 1 *
FROM (
    SELECT 1 AS Pref, N'呆滯報表' AS Source, s.SnapshotDate, s.Status, s.SlowOn, CAST(NULL AS DATE) AS LastMoveDate,
           s.StockQty, s.StockValue, s.Currency
    FROM ext.SlowMoving s
    WHERE s.Material = @Material AND s.Plant = @Plant AND s.SnapshotDate <= @OnDate
      AND s.SnapshotDate = (SELECT MAX(SnapshotDate) FROM ext.SlowMoving WHERE SnapshotDate <= @OnDate)
    UNION ALL
    SELECT 2, N'SAP推估', NULL, NULL, DATEADD(DAY, @SlowDays, m.LastMove), m.LastMove, NULL, NULL, NULL
    FROM (SELECT COALESCE(MAX(CASE WHEN mv.DebitCreditInd = 'H' AND c.Value IS NOT NULL
                                    THEN mv.PostingDate END),   -- 最後一次領用
                          MIN(mv.PostingDate)) AS LastMove       -- 沒領用過：第一次出現的日子
          FROM inv.MaterialMovement mv
          LEFT JOIN kri.List(@KriCode, 'ConsumptionMovementType') c ON c.Value = mv.MovementType
          WHERE mv.Material = @Material AND mv.Plant = @Plant AND mv.PostingDate <= @OnDate) m
    WHERE @UseSapFallback = 1 AND m.LastMove IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM ext.SlowMoving WHERE SnapshotDate <= @OnDate)
) x
ORDER BY Pref;
GO

-- ======================================================================
-- 「基準日當時」的狀態：回補過去的基準日時，不能用到基準日之後才發生的事
-- ======================================================================

-- PO 項目在某一天已經收了多少（PO 訂購單位），以及當時算不算已結案。
--   PO 上的已收數量（GrQty）和交貨完成碼是「現在」的值；收貨資料是基本單位，跟 PO 單位不一定一樣。
--   所以用「那天以前的收貨 ÷ 全部收貨」的比例，乘上 PO 現在的已收數量，換回那天的已收數量。
--   ReceivedQty = 那天已收（PO 單位）。沒有收貨資料時就用 PO 上的已收數量。
--   BasePerUnit = 每個 PO 單位等於幾個基本單位（收貨量 ÷ PO 已收數量），沒收過貨當 1。
--   IsClosed    = 交貨完成碼有勾，而且所有收貨在那天以前都已經存在（過帳日、輸入日都 <= 那天）。
--                 那天之後才過帳或才輸入的收貨，代表那天還沒收完、還沒結案。
-- 限制：交貨完成碼是那天之後才手動勾、之後又沒有收貨的，分辨不出來，會當作那天已結案。
--       收貨資料的下載期間如果比 PO 短（前面的收貨沒下載到），比例只用下載到的收貨算。
CREATE OR ALTER FUNCTION kri.PoReceivedAt (@PoNumber NVARCHAR(10), @PoItem NVARCHAR(5), @GrQty DECIMAL(19,4),
                                           @DelivComplInd NVARCHAR(1), @PoDate DATE, @OnDate DATE)
RETURNS TABLE
AS RETURN
SELECT CAST(CASE WHEN g.TotalQty > 0 THEN ISNULL(@GrQty, 0) * g.QtyByDate / g.TotalQty
                 ELSE ISNULL(@GrQty, 0) END AS DECIMAL(19,4))                       AS ReceivedQty,
       CAST(CASE WHEN g.TotalQty > 0 AND @GrQty > 0 THEN g.TotalQty / @GrQty
                 ELSE 1 END AS DECIMAL(19,6))                                       AS BasePerUnit,
       CAST(CASE WHEN ISNULL(@DelivComplInd, '') <> ''
                  AND ISNULL(g.LaterCount, 0) = 0
                  AND @PoDate <= @OnDate THEN 1
                 ELSE 0 END AS BIT)                                                 AS IsClosed
FROM (
    SELECT SUM(r.SignedQty)                                 AS TotalQty,    -- 全部收貨（扣掉退貨、沖銷）
           SUM(IIF(r.KnownByDate = 1, r.SignedQty, 0))     AS QtyByDate,   -- 那天以前的收貨
           SUM(1 - r.KnownByDate)                           AS LaterCount   -- 那天之後才過帳或才輸入的收貨筆數
    FROM (
        SELECT g.PostingDate,
               IIF(g.DebitCreditInd = 'H', -g.Quantity, g.Quantity) AS SignedQty,     -- 貸方（H）= 退貨或沖銷，算負的
               IIF(g.PostingDate <= @OnDate AND ISNULL(g.EntryDate, g.PostingDate) <= @OnDate, 1, 0) AS KnownByDate
        FROM prc.GoodsReceipt g
        WHERE g.PoNumber = @PoNumber AND g.PoItem = @PoItem
    ) r
) g;
GO

-- 供應商主檔某個欄位在某一天的值。主檔表是「現在」的值，那天之後改過的話，
-- 那天的值 = 那天之後第一筆異動的「舊值」。沒改過就回傳空的結果，呼叫的地方用現在的值。
--   @TableName：LFA1（全部）、LFM1（某採購組織）、LFB1（某公司別）；@Scope 給採購組織或公司別，LFA1 給 ''
--   用法：OUTER APPLY kri.VendorValueAt(v.Vendor, 'LFM1', 'ZTERM', v.PurchOrg, @day) h
--         ... COALESCE(h.ValueThen, v.PurchOrgPaymentTerms)
CREATE OR ALTER FUNCTION kri.VendorValueAt (@Vendor NVARCHAR(10), @TableName NVARCHAR(30), @FieldName NVARCHAR(30),
                                            @Scope NVARCHAR(4), @OnDate DATE)
RETURNS TABLE
AS RETURN
SELECT TOP 1 ISNULL(h.OldValue, '') AS ValueThen
FROM mst.VendorChangeHistory h
WHERE h.Vendor = @Vendor AND h.TableName = @TableName AND h.FieldName = @FieldName
  AND (@Scope = '' OR SUBSTRING(h.TableKey, 14, 4) = @Scope)    -- TableKey = 用戶端(3) + 供應商(10) + 採購組織或公司別(4)
  AND h.ChangeDate > @OnDate
ORDER BY h.ChangeDate, h.ChangeTime, h.ChangeNumber;
GO

-- ======================================================================
-- 規格表沒有、直接讀 SAP 原表的欄位（跟 kri.vCompanyCurrency 一樣是例外）。
-- 原表不存在的環境建成空的 view，用到的 KRI 照跑、備註說明。
-- ======================================================================

-- 供應商銀行帳號（LFBK），K02 用。一家供應商可以有好幾個帳號。
IF OBJECT_ID(N'dbo.LFBK', N'U') IS NOT NULL
    EXEC (N'CREATE OR ALTER VIEW kri.vVendorBank AS
            SELECT DISTINCT LIFNR AS Vendor, BANKS AS BankCountry, BANKL AS BankKey, BANKN AS BankAccount
            FROM dbo.LFBK WHERE ISNULL(BANKN, '''') <> ''''');
ELSE
    EXEC (N'CREATE OR ALTER VIEW kri.vVendorBank AS
            SELECT CAST(NULL AS NVARCHAR(10)) AS Vendor, CAST(NULL AS NVARCHAR(3)) AS BankCountry,
                   CAST(NULL AS NVARCHAR(15)) AS BankKey, CAST(NULL AS NVARCHAR(18)) AS BankAccount WHERE 1 = 0');
GO
