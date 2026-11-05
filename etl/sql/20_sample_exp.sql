-- 抽樣：把 ETL 用到的 SAP 原表、業務表（prc / mst / inv / fin）抽一小份到 exp schema，
-- 表名不變：dbo.EKKO → exp.EKKO、prc.PurchaseOrderDetail → exp.PurchaseOrderDetail。
--
--   EXEC exp.SampleAll;                         -- 每類單據隨機抽 1000 張，每次都不一樣
--   EXEC exp.SampleAll @Rows = 500, @Seed = 42;  -- 同一個 seed、同一份資料 → 抽出同一批
--   EXEC exp.SampleAll @PreferFilled = 0;        -- 不挑空欄位少的，純隨機
--
-- 不是每張表各自亂抽 1000 筆（那樣 EKKO 和 EKPO 會對不起來），而是「以單據為主」：
--   1. 隨機抽 @Rows 張單據表頭：PO（EKKO）、PR（EBAN）、物料憑證（MKPF）、有供應商行的會計傳票（BKPF）
--   2. 補上相關的單據：PR、物料憑證、傳票引用到的 PO 併進來；再由全部的 PO 補來源 PR、
--      收貨憑證、發票傳票。所以 exp 裡任何單據引用的 PO 都在 exp.EKKO 裡
--   3. 明細照表頭帶：EKPO / EKKN / EKET / EKBE、EBKN、MSEG、BSEG，一張單據的明細全部帶出
--   4. 主檔只帶有用到的：這些單據的供應商（LFA1 / LFB1 / LFM1 / CDHDR / CDPOS）、
--      物料（MARA / MAKT / MARC / MARD / MBEW）；資訊記錄與價格條件只帶同一張 PO / PR 上
--      一起出現的「供應商 + 物料」，A017 / A018 再調到 @Rows 筆（不足隨機補、超過隨機留）
--   5. 設定表（T001、T001K、T001W、T024D、T024E）整張複製
--   6. 業務表先用同一批鍵篩，再調到剛好 @Rows 筆：超過就隨機留 @Rows 筆（一張單據可能只留部分項目），
--      不足就從整張業務表隨機補（補進來的不在 exp 的原表裡）
--   7. 其他表：LFBK 帶用到的供應商、MBEWH 帶用到的物料（沒有 LIFNR / MATNR 欄位就改成隨機）；
--      ANLA 先帶抽到的 PO（EKKN.ANLN1）、會計傳票（BSEG.ANLN1）用到的資產，再調到 @Rows 筆
--      （不足隨機補、超過隨機留；沒有 ANLN1 欄位就整張隨機）；
--      ZTM105、ZTM80、ADT_CONTRACT、ADT_ECAR、ADT_OSWEB、ADT_POAS 沒有固定關聯，
--      SELECT * 隨機抽 @Rows 筆（依 seed + 整列內容的雜湊排序，同一個 seed 一樣抽同一批）
-- 所以 SAP 原表的 @Rows 是「每類單據的張數」，不是每張表的筆數：明細表會比較多，主檔看用到幾個。
-- 剛好 @Rows 筆的是：業務表、A017 / A018 / ANLA、整張隨機的表（來源本身不足 @Rows 筆的除外）。
--
-- 隨機的方式：依「seed + 單據號碼」的雜湊排序取前 @Rows 張。
-- @PreferFilled = 1（預設）時，凡是「隨機挑」的地方都先挑空欄位（NULL）少的，同樣少的再隨機。
-- 先比「重要欄位」（exp.ImportantColumn，預設是 ETL 用到的欄位）的空值數，再比全部欄位：
-- 四類單據表頭、整張隨機的表、A017 / A018 / ANLA 的補與縮。跟著單據帶的明細與主檔沒得挑。
-- 這樣抽出來的會偏向資料比較完整的單據；要照原本的比例抽就給 @PreferFilled = 0。
-- 不給 @Seed 就隨機產生一個，結果最後一欄會列出這次用的 seed，要重抽同一批就把它帶回來。
-- 重新匯入 SAP 資料後用同一個 seed，原本就有的單據還是會抽到同一批。
--
-- 每次執行會 DROP 掉 exp 裡同名的表重建。來源表不存在的（例如沒有 T024E）會跳過並在結果註明。
-- 注意：exp 裡仍然是客戶的真實資料，不要放進版控或帶出客戶環境。

IF SCHEMA_ID(N'exp') IS NULL EXEC (N'CREATE SCHEMA exp');
GO

-- 重要欄位：挑資料時這些欄位有值的優先。依表名（不分 schema）對應。
-- 預設 = ETL 會用到的欄位（00_check_staging.sql 的清單）；業務表沒列 = 全部欄位都算重要。
-- 可以自己增刪，重跑這支只補沒有的、不會蓋掉：
--   INSERT exp.ImportantColumn VALUES ('ZTM80', 'EBELN');
--   DELETE exp.ImportantColumn WHERE TableName = 'LFA1' AND ColumnName = 'TELFX';
IF OBJECT_ID(N'exp.ImportantColumn', N'U') IS NULL
CREATE TABLE exp.ImportantColumn (
    TableName  SYSNAME NOT NULL,
    ColumnName SYSNAME NOT NULL,
    CONSTRAINT PK_exp_ImportantColumn PRIMARY KEY (TableName, ColumnName)
);
GO

INSERT exp.ImportantColumn (TableName, ColumnName)
SELECT s.t, s.c FROM (VALUES
('EKKO','EBELN'),('EKKO','BSTYP'),('EKKO','BSART'),('EKKO','BUKRS'),('EKKO','EKORG'),
('EKKO','EKGRP'),('EKKO','BEDAT'),('EKKO','LIFNR'),('EKKO','ZTERM'),('EKKO','WAERS'),
('EKKO','WKURS'),('EKPO','EBELN'),('EKPO','EBELP'),('EKPO','MATNR'),('EKPO','MATKL'),
('EKPO','WERKS'),('EKPO','LGORT'),('EKPO','MENGE'),('EKPO','MEINS'),('EKPO','NETPR'),
('EKPO','PEINH'),('EKPO','NETWR'),('EKPO','ELIKZ'),('EKPO','WEPOS'),('EKPO','REPOS'),
('EKPO','LOEKZ'),('EKPO','BANFN'),('EKPO','BNFPO'),('EKPO','KONNR'),('EKPO','KTPNR'),
('EKKN','EBELN'),('EKKN','EBELP'),('EKKN','ZEKKN'),('EKKN','SAKTO'),('EKKN','KOSTL'),
('EKKN','AUFNR'),('EKET','EBELN'),('EKET','EBELP'),('EKET','EINDT'),('EKBE','EBELN'),
('EKBE','EBELP'),('EKBE','BEWTP'),('EKBE','SHKZG'),('EKBE','MENGE'),('EKBE','DMBTR'),
('EKBE','BUDAT'),('MAKT','MATNR'),('MAKT','SPRAS'),('MAKT','MAKTX'),('LFA1','LIFNR'),
('LFA1','NAME1'),('LFA1','NAME2'),('LFA1','SORTL'),('LFA1','LAND1'),('LFA1','REGIO'),
('LFA1','ORT01'),('LFA1','PSTLZ'),('LFA1','STRAS'),('LFA1','SPRAS'),('LFA1','TELF1'),
('LFA1','TELFX'),('LFA1','STCD1'),('LFA1','KTOKK'),('LFA1','ERDAT'),('LFA1','ERNAM'),
('LFA1','LOEVM'),('LFA1','SPERR'),('LFA1','SPERM'),('LFB1','LIFNR'),('LFB1','BUKRS'),
('LFB1','ZTERM'),('LFB1','ZWELS'),('LFB1','ZAHLS'),('LFB1','SPERR'),('LFM1','LIFNR'),
('LFM1','EKORG'),('LFM1','SPERM'),('LFM1','INCO1'),('LFM1','WAERS'),('LFM1','VERKF'),
('LFM1','ZTERM'),('EBAN','BANFN'),('EBAN','BNFPO'),('EBAN','BSART'),('EBAN','BADAT'),
('EBAN','ERNAM'),('EBAN','MATNR'),('EBAN','TXZ01'),('EBAN','MATKL'),('EBAN','WERKS'),
('EBAN','LGORT'),('EBAN','MENGE'),('EBAN','MEINS'),('EBAN','LFDAT'),('EBAN','PREIS'),
('EBAN','WAERS'),('EBAN','EKGRP'),('EBAN','EKORG'),('EBAN','FLIEF'),('EBAN','KNTTP'),
('EBAN','FRGKZ'),('EBAN','FRGST'),('EBAN','LOEKZ'),('EBKN','BANFN'),('EBKN','BNFPO'),
('EBKN','ZEBKN'),('EBKN','KOSTL'),('EBKN','SAKTO'),('MKPF','MBLNR'),('MKPF','MJAHR'),
('MKPF','BUDAT'),('MKPF','BLDAT'),('MKPF','CPUDT'),('MKPF','USNAM'),('MKPF','XBLNR'),
('MSEG','MBLNR'),('MSEG','MJAHR'),('MSEG','ZEILE'),('MSEG','BWART'),('MSEG','MATNR'),
('MSEG','WERKS'),('MSEG','LGORT'),('MSEG','CHARG'),('MSEG','BUKRS'),('MSEG','MENGE'),
('MSEG','MEINS'),('MSEG','DMBTR'),('MSEG','EBELN'),('MSEG','EBELP'),('MSEG','SGTXT'),
('MSEG','SHKZG'),('MSEG','KOSTL'),('MSEG','SAKTO'),('MSEG','AUFNR'),('MSEG','KUNNR'),
('T001','BUKRS'),('T001','WAERS'),('CDHDR','OBJECTCLAS'),('CDHDR','OBJECTID'),
('CDHDR','CHANGENR'),('CDHDR','UDATE'),('CDHDR','UTIME'),('CDHDR','USERNAME'),('CDHDR','TCODE'),
('CDPOS','OBJECTCLAS'),('CDPOS','OBJECTID'),('CDPOS','CHANGENR'),('CDPOS','TABNAME'),
('CDPOS','TABKEY'),('CDPOS','FNAME'),('CDPOS','CHNGIND'),('CDPOS','VALUE_OLD'),
('CDPOS','VALUE_NEW'),('MARA','MATNR'),('MARA','MTART'),('MARA','MATKL'),('MARA','MEINS'),
('MARA','MBRSH'),('MARA','SPART'),('MARA','MSTAE'),('MARA','BRGEW'),('MARA','NTGEW'),
('MARA','GEWEI'),('MARA','VOLUM'),('MARA','VOLEH'),('MARA','GROES'),('MARA','WRKST'),
('MARA','MFRPN'),('MARA','ERSDA'),('MARA','ERNAM'),('MARA','LVORM'),('EINA','INFNR'),
('EINA','LIFNR'),('EINA','MATNR'),('EINA','IDNLF'),('EINA','LOEKZ'),('EINA','ERDAT'),
('EINA','ERNAM'),('EINE','INFNR'),('EINE','EKORG'),('EINE','ESOKZ'),('EINE','WERKS'),
('EINE','EKGRP'),('EINE','APLFZ'),('EINE','NORBM'),('EINE','WAERS'),('EINE','INCO1'),
('EINE','BSTAE'),('A017','LIFNR'),('A017','MATNR'),('A017','EKORG'),('A017','WERKS'),
('A017','ESOKZ'),('A017','KSCHL'),('A017','DATAB'),('A017','DATBI'),('A017','KNUMH'),
('A018','LIFNR'),('A018','MATNR'),('A018','EKORG'),('A018','ESOKZ'),('A018','KSCHL'),
('A018','DATAB'),('A018','DATBI'),('A018','KNUMH'),('KONP','KNUMH'),('KONP','KOPOS'),
('KONP','KBETR'),('KONP','KONWA'),('KONP','KPEIN'),('KONP','KMEIN'),('KONP','LOEVM_KO'),
('KONH','KNUMH'),('KONH','ERDAT'),('KONH','ERNAM'),('MARD','MATNR'),('MARD','WERKS'),
('MARD','LGORT'),('MARD','LABST'),('MARD','INSME'),('MARD','SPEME'),('MARD','UMLME'),
('MBEW','MATNR'),('MBEW','BWKEY'),('MBEW','BWTAR'),('MBEW','SALK3'),('MBEW','STPRS'),
('MBEW','VERPR'),('MBEW','VPRSV'),('MBEW','PEINH'),('MBEW','LBKUM'),('MARC','MATNR'),
('MARC','WERKS'),('MARC','EISBE'),('MARC','MINBE'),('MARC','MABST'),('MARC','DISMM'),
('MARC','DISPO'),('MARC','BESKZ'),('MARC','MAABC'),('BKPF','BUKRS'),('BKPF','BELNR'),
('BKPF','GJAHR'),('BKPF','BLART'),('BKPF','BUDAT'),('BKPF','BLDAT'),('BKPF','CPUDT'),
('BKPF','USNAM'),('BKPF','XBLNR'),('BKPF','WAERS'),('BSEG','BUKRS'),('BSEG','BELNR'),
('BSEG','GJAHR'),('BSEG','BUZEI'),('BSEG','KOART'),('BSEG','LIFNR'),('BSEG','ZUONR'),
('BSEG','SGTXT'),('BSEG','HKONT'),('BSEG','KOSTL'),('BSEG','WRBTR'),('BSEG','DMBTR'),
('BSEG','SHKZG'),('BSEG','ZTERM'),('BSEG','ZFBDT'),('BSEG','ZLSCH'),('BSEG','ZLSPR'),
('BSEG','AUGBL'),('BSEG','AUGDT'),('BSEG','EBELN'),('BSEG','EBELP'),('BSEG','BSCHL'),
('T024D','WERKS'),('T024D','DISPO'),('T024D','DSNAM'),('T024E','EKORG'),('T024E','BUKRS')
) AS s (t, c)
WHERE NOT EXISTS (SELECT 1 FROM exp.ImportantColumn x WHERE x.TableName = s.t AND x.ColumnName = s.c);
GO

-- 一列有幾個 NULL 欄位的運算式，給「挑空欄位少的」排序用。@Alias 空字串 = 不加前綴。
-- @Important = 1 只算重要欄位：exp.ImportantColumn 有列這張表就用列的；業務表沒列就算全部欄位；
-- 其他沒列的表（ZTM、ADT、ANLA…）回 NULL，等於只看全部欄位。
CREATE OR ALTER FUNCTION exp.NullCountExpr (@Obj NVARCHAR(256), @Alias SYSNAME, @Important BIT = 0)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @p NVARCHAR(200) = IIF(ISNULL(@Alias, N'') = N'', N'', QUOTENAME(@Alias) + N'.'),
            @tbl SYSNAME = PARSENAME(@Obj, 1), @sch SYSNAME = PARSENAME(@Obj, 2),
            @listed BIT, @biz BIT, @r NVARCHAR(MAX);
    SET @listed = IIF(EXISTS (SELECT 1 FROM exp.ImportantColumn WHERE TableName = @tbl), 1, 0);
    -- 業務表（含 exp 裡的業務表抽樣）
    SET @biz = IIF(EXISTS (SELECT 1 FROM sys.tables t
                           WHERE t.name = @tbl AND SCHEMA_NAME(t.schema_id) IN (N'prc', N'mst', N'inv', N'fin')), 1, 0);
    IF @Important = 1 AND @listed = 0 AND @biz = 0
        RETURN NULL;
    SELECT @r = N'(' + STRING_AGG(CAST(N'IIF(' + @p + QUOTENAME(c.name) + N' IS NULL, 1, 0)' AS NVARCHAR(MAX)), N' + ') + N')'
    FROM sys.columns c
    WHERE c.object_id = OBJECT_ID(@Obj)
      AND (@Important = 0 OR @listed = 0
           OR c.name IN (SELECT ColumnName FROM exp.ImportantColumn WHERE TableName = @tbl));
    RETURN @r;
END;
GO

-- 挑空欄位少的排序鍵：先比重要欄位的 NULL 數、再比全部欄位的 NULL 數。@Agg 給 PR 這種分組的用（AVG）。
CREATE OR ALTER FUNCTION exp.FilledOrder (@Obj NVARCHAR(256), @Alias SYSNAME, @Agg NVARCHAR(10) = NULL)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @i NVARCHAR(MAX) = exp.NullCountExpr(@Obj, @Alias, 1),
            @a NVARCHAR(MAX) = exp.NullCountExpr(@Obj, @Alias, 0);
    IF @Agg IS NOT NULL
        SELECT @i = @Agg + N'(CAST(' + @i + N' AS FLOAT))', @a = @Agg + N'(CAST(' + @a + N' AS FLOAT))';
    -- ORDER BY 不能有重複的運算式：重要欄位 = 全部欄位（業務表）或沒有重要欄位時只放一次
    IF @i IS NULL OR @i = @a RETURN ISNULL(@a + N', ', N'');
    RETURN @i + N', ' + @a + N', ';
END;
GO

-- 隨機排序：@Prefer = 1 時空欄位少的排前面（重要欄位優先），同樣少的再依 seed + 整列內容的雜湊
CREATE OR ALTER FUNCTION exp.RandomOrder (@Obj NVARCHAR(256), @Alias SYSNAME, @Prefer BIT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN IIF(@Prefer = 1, exp.FilledOrder(@Obj, @Alias, NULL), N'')
         + N'HASHBYTES(''MD5'', CONCAT(@seed, N''|'', BINARY_CHECKSUM(*)))';
END;
GO

-- 複製一張表：exp.<表名> = SELECT * FROM @Src t WHERE @Where（@Where 用 t 當別名）
CREATE OR ALTER PROCEDURE exp.CopyTable @Src NVARCHAR(256), @Where NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @schema SYSNAME = PARSENAME(@Src, 2), @name SYSNAME = PARSENAME(@Src, 1),
            @sql NVARCHAR(MAX), @rows BIGINT;

    IF OBJECT_ID(QUOTENAME(@schema) + N'.' + QUOTENAME(@name), N'U') IS NULL
    BEGIN
        INSERT #explog (Src, Rows, Note) VALUES (@Src, NULL, N'來源表不存在，跳過');
        RETURN;
    END;

    SET @sql = N'DROP TABLE IF EXISTS exp.' + QUOTENAME(@name) + N';'
             + N'SELECT t.* INTO exp.' + QUOTENAME(@name)
             + N' FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@name) + N' t'
             + ISNULL(N' WHERE ' + @Where, N'') + N';'
             + N'SET @r = @@ROWCOUNT;';
    EXEC sp_executesql @sql, N'@r BIGINT OUTPUT', @r = @rows OUTPUT;
    INSERT #explog (Src, Rows, Note) VALUES (@Src, @rows, NULL);
END;
GO

-- 隨機抽 @Rows 筆：exp.<表名> = SELECT TOP (@Rows) * FROM @Src，依 seed + 整列的 BINARY_CHECKSUM 排序
CREATE OR ALTER PROCEDURE exp.CopyRandom @Src NVARCHAR(256), @Top INT, @Seed INT, @Prefer BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @schema SYSNAME = PARSENAME(@Src, 2), @name SYSNAME = PARSENAME(@Src, 1),
            @sql NVARCHAR(MAX), @rows BIGINT;

    IF OBJECT_ID(QUOTENAME(@schema) + N'.' + QUOTENAME(@name), N'U') IS NULL
    BEGIN
        INSERT #explog (Src, Rows, Note) VALUES (@Src, NULL, N'來源表不存在，跳過');
        RETURN;
    END;

    SET @sql = N'DROP TABLE IF EXISTS exp.' + QUOTENAME(@name) + N';'
             + N'SELECT TOP (@n) t.* INTO exp.' + QUOTENAME(@name)
             + N' FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@name) + N' t'
             + N' ORDER BY ' + exp.RandomOrder(@Src, N't', @Prefer) + N';'
             + N'SET @r = @@ROWCOUNT;';
    EXEC sp_executesql @sql, N'@n INT, @seed INT, @r BIGINT OUTPUT', @n = @Top, @seed = @Seed, @r = @rows OUTPUT;
    INSERT #explog (Src, Rows, Note) VALUES (@Src, @rows, IIF(@Prefer = 1, N'隨機（空欄位少的優先）', N'隨機'));
END;
GO

-- 調到剛好 @Top 筆：exp.<表名> 不足就從 @Src 裡還沒抽到的（依 @Keys 判斷）隨機補，
-- 超過就依 seed 隨機留 @Top 筆。都是依 seed + 整列內容的雜湊排序，同一個 seed 結果一樣。
CREATE OR ALTER PROCEDURE exp.FitRows @Src NVARCHAR(256), @Top INT, @Seed INT, @Keys NVARCHAR(400),
                                     @Prefer BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @schema SYSNAME = PARSENAME(@Src, 2), @name SYSNAME = PARSENAME(@Src, 1),
            @have BIGINT, @sql NVARCHAR(MAX), @n BIGINT, @match NVARCHAR(MAX);
    IF OBJECT_ID(N'exp.' + QUOTENAME(@name), N'U') IS NULL RETURN;

    SET @sql = N'SELECT @c = COUNT_BIG(*) FROM exp.' + QUOTENAME(@name);
    EXEC sp_executesql @sql, N'@c BIGINT OUTPUT', @c = @have OUTPUT;
    IF @have = @Top RETURN;

    IF @have > @Top
    BEGIN
        SET @sql = N'WITH x AS (SELECT ROW_NUMBER() OVER (ORDER BY '
                 + exp.RandomOrder(N'exp.' + QUOTENAME(@name), N'', @Prefer) + N') AS rn'
                 + N' FROM exp.' + QUOTENAME(@name) + N') DELETE x WHERE rn > @top;'
                 + N'SET @r = @@ROWCOUNT;';
        EXEC sp_executesql @sql, N'@top INT, @seed INT, @r BIGINT OUTPUT', @top = @Top, @seed = @Seed, @r = @n OUTPUT;
        UPDATE #explog SET Rows = Rows - @n,
                           Note = CONCAT(N'用到的 ', @have, N' 筆，隨機留 ', @Top, N' 筆')
        WHERE Src = @Src;
        RETURN;
    END;

    SELECT @match = STRING_AGG(N'ISNULL(e.' + QUOTENAME(TRIM(value)) + N', '''') = ISNULL(t.'
                               + QUOTENAME(TRIM(value)) + N', '''')', N' AND ')
    FROM STRING_SPLIT(@Keys, N',');

    SET @sql = N'INSERT exp.' + QUOTENAME(@name) + N' SELECT TOP (@n) t.* FROM '
             + QUOTENAME(@schema) + N'.' + QUOTENAME(@name) + N' t'
             + N' WHERE NOT EXISTS (SELECT 1 FROM exp.' + QUOTENAME(@name) + N' e WHERE ' + @match + N')'
             + N' ORDER BY ' + exp.RandomOrder(@Src, N't', @Prefer) + N';'
             + N'SET @r = @@ROWCOUNT;';
    DECLARE @need BIGINT = @Top - @have;
    EXEC sp_executesql @sql, N'@n BIGINT, @seed INT, @r BIGINT OUTPUT', @n = @need, @seed = @Seed, @r = @n OUTPUT;
    UPDATE #explog SET Rows = Rows + @n,
                       Note = CONCAT(N'用到的 ', @have, N' 筆 + 隨機補 ', @n, N' 筆')
    WHERE Src = @Src;
END;
GO

DROP PROCEDURE IF EXISTS exp.TopUp;
GO

CREATE OR ALTER PROCEDURE exp.SampleAll @Rows INT = 1000, @Seed INT = NULL, @PreferFilled BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET @Seed = ISNULL(@Seed, ABS(CHECKSUM(NEWID())) % 1000000);
    DECLARE @s NVARCHAR(20) = CAST(@Seed AS NVARCHAR(20)) + N'|', @q NVARCHAR(MAX),
            @nul NVARCHAR(MAX);

    CREATE TABLE #explog (seq INT IDENTITY, Src NVARCHAR(256), Rows BIGINT, Note NVARCHAR(200));

    -- ------------------------------------------------------------------
    -- 1～2. 單據鍵
    -- ------------------------------------------------------------------
    -- 先四類各自隨機抽 @Rows 張。@PreferFilled = 1 時表頭空欄位少的優先（PR 看項目的平均）
    SELECT TOP 0 EBELN INTO #po FROM dbo.EKKO;
    SET @nul = IIF(@PreferFilled = 1, exp.FilledOrder(N'dbo.EKKO', N't', NULL), N'');
    SET @q = N'INSERT #po SELECT TOP (@n) t.EBELN FROM dbo.EKKO t WHERE ISNULL(t.EBELN, '''') <> '''''
           + N' ORDER BY ' + @nul + N'HASHBYTES(''MD5'', @s + t.EBELN)';
    EXEC sp_executesql @q, N'@n INT, @s NVARCHAR(20)', @n = @Rows, @s = @s;

    SELECT TOP 0 BANFN INTO #pr FROM dbo.EBAN;
    SET @nul = IIF(@PreferFilled = 1, exp.FilledOrder(N'dbo.EBAN', N't', N'AVG'), N'');
    SET @q = N'INSERT #pr SELECT TOP (@n) t.BANFN FROM dbo.EBAN t WHERE ISNULL(t.BANFN, '''') <> '''''
           + N' GROUP BY t.BANFN ORDER BY ' + @nul + N'HASHBYTES(''MD5'', @s + t.BANFN)';
    EXEC sp_executesql @q, N'@n INT, @s NVARCHAR(20)', @n = @Rows, @s = @s;

    SELECT TOP 0 MBLNR, MJAHR INTO #md FROM dbo.MKPF;
    SET @nul = IIF(@PreferFilled = 1, exp.FilledOrder(N'dbo.MKPF', N't', NULL), N'');
    SET @q = N'INSERT #md SELECT TOP (@n) t.MBLNR, t.MJAHR FROM dbo.MKPF t WHERE ISNULL(t.MBLNR, '''') <> '''''
           + N' ORDER BY ' + @nul + N'HASHBYTES(''MD5'', @s + t.MBLNR + N''|'' + CAST(t.MJAHR AS NVARCHAR(10)))';
    EXEC sp_executesql @q, N'@n INT, @s NVARCHAR(20)', @n = @Rows, @s = @s;

    -- 會計傳票只從有供應商行的抽（不然 fin.AccountsPayable 抽出來幾乎是空的）
    SELECT TOP 0 BUKRS, BELNR, GJAHR INTO #ad FROM dbo.BKPF;
    SET @nul = IIF(@PreferFilled = 1, exp.FilledOrder(N'dbo.BKPF', N't', NULL), N'');
    SET @q = N'INSERT #ad SELECT TOP (@n) t.BUKRS, t.BELNR, t.GJAHR FROM dbo.BKPF t'
           + N' WHERE EXISTS (SELECT 1 FROM dbo.BSEG s WHERE s.BUKRS = t.BUKRS AND s.BELNR = t.BELNR'
           + N' AND s.GJAHR = t.GJAHR AND ISNULL(s.LIFNR, '''') <> '''')'
           + N' ORDER BY ' + @nul + N'HASHBYTES(''MD5'', @s + t.BUKRS + N''|'' + t.BELNR + N''|'' + CAST(t.GJAHR AS NVARCHAR(10)))';
    EXEC sp_executesql @q, N'@n INT, @s NVARCHAR(20)', @n = @Rows, @s = @s;

    -- 抽到的 PR、物料憑證、傳票引用到的 PO 併進來
    INSERT #po (EBELN)
    SELECT EBELN FROM dbo.EKPO WHERE BANFN IN (SELECT BANFN FROM #pr)
    UNION SELECT s.EBELN FROM dbo.MSEG s
          WHERE EXISTS (SELECT 1 FROM #md k WHERE k.MBLNR = s.MBLNR AND k.MJAHR = s.MJAHR)
    UNION SELECT s.EBELN FROM dbo.BSEG s
          WHERE EXISTS (SELECT 1 FROM #ad k WHERE k.BUKRS = s.BUKRS AND k.BELNR = s.BELNR AND k.GJAHR = s.GJAHR)
    EXCEPT SELECT EBELN FROM #po;
    DELETE #po WHERE ISNULL(EBELN, '') = '';

    -- 再由全部的 PO 補：來源 PR（K08 要用 PO 的供應商）、收貨憑證、發票傳票
    INSERT #pr (BANFN)
    SELECT BANFN FROM dbo.EKPO WHERE EBELN IN (SELECT EBELN FROM #po) AND ISNULL(BANFN, '') <> ''
    EXCEPT SELECT BANFN FROM #pr;

    INSERT #md (MBLNR, MJAHR)
    SELECT MBLNR, MJAHR FROM dbo.MSEG WHERE EBELN IN (SELECT EBELN FROM #po)
    EXCEPT SELECT MBLNR, MJAHR FROM #md;

    INSERT #ad (BUKRS, BELNR, GJAHR)
    SELECT BUKRS, BELNR, GJAHR FROM dbo.BSEG WHERE EBELN IN (SELECT EBELN FROM #po)
    EXCEPT SELECT BUKRS, BELNR, GJAHR FROM #ad;

    -- ------------------------------------------------------------------
    -- 3. 單據表頭與明細
    -- ------------------------------------------------------------------
    DECLARE @po NVARCHAR(200) = N't.EBELN IN (SELECT EBELN FROM #po)',
            @pr NVARCHAR(200) = N't.BANFN IN (SELECT BANFN FROM #pr)',
            @md NVARCHAR(200) = N'EXISTS (SELECT 1 FROM #md k WHERE k.MBLNR = t.MBLNR AND k.MJAHR = t.MJAHR)',
            @ad NVARCHAR(200) = N'EXISTS (SELECT 1 FROM #ad k WHERE k.BUKRS = t.BUKRS AND k.BELNR = t.BELNR AND k.GJAHR = t.GJAHR)';

    EXEC exp.CopyTable N'dbo.EKKO', @po;
    EXEC exp.CopyTable N'dbo.EKPO', @po;
    EXEC exp.CopyTable N'dbo.EKKN', @po;
    EXEC exp.CopyTable N'dbo.EKET', @po;
    EXEC exp.CopyTable N'dbo.EKBE', @po;
    EXEC exp.CopyTable N'dbo.EBAN', @pr;
    EXEC exp.CopyTable N'dbo.EBKN', @pr;
    EXEC exp.CopyTable N'dbo.MKPF', @md;
    EXEC exp.CopyTable N'dbo.MSEG', @md;
    EXEC exp.CopyTable N'dbo.BKPF', @ad;
    EXEC exp.CopyTable N'dbo.BSEG', @ad;

    -- ------------------------------------------------------------------
    -- 4. 主檔：只帶這些單據用到的供應商、物料
    -- ------------------------------------------------------------------
    SELECT LIFNR INTO #vendor FROM exp.EKKO WHERE ISNULL(LIFNR, '') <> ''
    UNION SELECT FLIEF FROM exp.EBAN WHERE ISNULL(FLIEF, '') <> ''
    UNION SELECT LIFNR FROM exp.BSEG WHERE ISNULL(LIFNR, '') <> '';

    SELECT MATNR INTO #mat FROM exp.EKPO WHERE ISNULL(MATNR, '') <> ''
    UNION SELECT MATNR FROM exp.EBAN WHERE ISNULL(MATNR, '') <> ''
    UNION SELECT MATNR FROM exp.MSEG WHERE ISNULL(MATNR, '') <> '';

    DECLARE @v  NVARCHAR(200) = N't.LIFNR IN (SELECT LIFNR FROM #vendor)',
            @m  NVARCHAR(200) = N't.MATNR IN (SELECT MATNR FROM #mat)',
            @vm NVARCHAR(200) = N'EXISTS (SELECT 1 FROM #vm k WHERE k.LIFNR = t.LIFNR AND k.MATNR = t.MATNR)';

    -- 同一張 PO / PR 上真的一起出現的「供應商 + 物料」，不是所有供應商 × 所有物料
    SELECT k.LIFNR, p.MATNR INTO #vm
    FROM exp.EKKO k JOIN exp.EKPO p ON p.EBELN = k.EBELN
    WHERE ISNULL(k.LIFNR, '') <> '' AND ISNULL(p.MATNR, '') <> ''
    UNION SELECT FLIEF, MATNR FROM exp.EBAN WHERE ISNULL(FLIEF, '') <> '' AND ISNULL(MATNR, '') <> '';

    EXEC exp.CopyTable N'dbo.LFA1', @v;
    EXEC exp.CopyTable N'dbo.LFB1', @v;
    EXEC exp.CopyTable N'dbo.LFM1', @v;
    EXEC exp.CopyTable N'dbo.CDHDR', N't.OBJECTCLAS = ''KRED'' AND LEFT(RTRIM(t.OBJECTID), 10) IN (SELECT LIFNR FROM #vendor)';
    EXEC exp.CopyTable N'dbo.CDPOS', N'EXISTS (SELECT 1 FROM exp.CDHDR k WHERE k.OBJECTCLAS = t.OBJECTCLAS AND k.OBJECTID = t.OBJECTID AND k.CHANGENR = t.CHANGENR)';

    EXEC exp.CopyTable N'dbo.MARA', @m;
    EXEC exp.CopyTable N'dbo.MAKT', @m;
    EXEC exp.CopyTable N'dbo.MARC', @m;
    EXEC exp.CopyTable N'dbo.MARD', @m;
    EXEC exp.CopyTable N'dbo.MBEW', @m;

    EXEC exp.CopyTable N'dbo.EINA', @vm;
    EXEC exp.CopyTable N'dbo.EINE', N't.INFNR IN (SELECT INFNR FROM exp.EINA)';
    -- 價格條件：先帶用到的組合，調到 @Rows 筆（不足隨機補、超過隨機留），KONP / KONH 跟著同一批
    EXEC exp.CopyTable N'dbo.A017', @vm;
    EXEC exp.FitRows    N'dbo.A017', @Rows, @Seed, N'KNUMH', @PreferFilled;
    EXEC exp.CopyTable N'dbo.A018', @vm;
    EXEC exp.FitRows    N'dbo.A018', @Rows, @Seed, N'KNUMH', @PreferFilled;
    EXEC exp.CopyTable N'dbo.KONP', N't.KNUMH IN (SELECT KNUMH FROM exp.A017 UNION SELECT KNUMH FROM exp.A018)';
    EXEC exp.CopyTable N'dbo.KONH', N't.KNUMH IN (SELECT KNUMH FROM exp.A017 UNION SELECT KNUMH FROM exp.A018)';

    -- ------------------------------------------------------------------
    -- 5. 設定表：整張
    -- ------------------------------------------------------------------
    EXEC exp.CopyTable N'dbo.T001';
    EXEC exp.CopyTable N'dbo.T024D';
    EXEC exp.CopyTable N'dbo.T024E';
    EXEC exp.CopyTable N'dbo.T001K';
    EXEC exp.CopyTable N'dbo.T001W';

    -- ------------------------------------------------------------------
    -- 6. 業務表：同一批鍵
    -- ------------------------------------------------------------------
    DECLARE @bmd NVARCHAR(200) = N'EXISTS (SELECT 1 FROM #md k WHERE k.MBLNR = t.MaterialDoc AND k.MJAHR = t.MaterialDocYear)',
            @bv  NVARCHAR(200) = N't.Vendor IN (SELECT LIFNR FROM #vendor)',
            @bm  NVARCHAR(200) = N't.Material IN (SELECT MATNR FROM #mat)';

    EXEC exp.CopyTable N'prc.PurchaseOrderDetail', N't.PoNumber IN (SELECT EBELN FROM #po)';
    EXEC exp.CopyTable N'prc.PurchaseRequisition', N't.PrNumber IN (SELECT BANFN FROM #pr)';
    EXEC exp.CopyTable N'prc.GoodsReceipt',        @bmd;
    EXEC exp.CopyTable N'inv.MaterialMovement',    @bmd;
    EXEC exp.CopyTable N'fin.AccountsPayable',
         N'EXISTS (SELECT 1 FROM #ad k WHERE k.BUKRS = t.CompanyCode AND k.BELNR = t.AccountingDoc AND k.GJAHR = t.FiscalYear)';
    EXEC exp.CopyTable N'mst.Vendor',               @bv;
    EXEC exp.CopyTable N'mst.VendorChangeHistory',  @bv;
    EXEC exp.CopyTable N'mst.Material',             @bm;
    EXEC exp.CopyTable N'inv.InventoryBalance',     @bm;
    EXEC exp.CopyTable N'mst.PurchasingInfoRecord', N't.InfoRecord IN (SELECT INFNR FROM exp.EINA)';
    EXEC exp.CopyTable N'mst.PurchasingCondA017',   N't.ConditionRecord IN (SELECT KNUMH FROM exp.A017)';
    EXEC exp.CopyTable N'mst.PurchasingCondA018',   N't.ConditionRecord IN (SELECT KNUMH FROM exp.A018)';

    -- 業務表以 @Rows 筆為主：上面同一批鍵篩出來的超過就隨機留 @Rows 筆、不足就從整張業務表隨機補
    EXEC exp.FitRows N'prc.PurchaseOrderDetail', @Rows, @Seed, N'PoNumber,PoItem', @PreferFilled;
    EXEC exp.FitRows N'prc.PurchaseRequisition', @Rows, @Seed, N'PrNumber,PrItem', @PreferFilled;
    EXEC exp.FitRows N'prc.GoodsReceipt',        @Rows, @Seed, N'MaterialDoc,MaterialDocYear,MaterialDocItem', @PreferFilled;
    EXEC exp.FitRows N'inv.MaterialMovement',    @Rows, @Seed, N'MaterialDoc,MaterialDocYear,MaterialDocItem', @PreferFilled;
    EXEC exp.FitRows N'fin.AccountsPayable',     @Rows, @Seed, N'CompanyCode,AccountingDoc,FiscalYear,LineItem', @PreferFilled;
    EXEC exp.FitRows N'mst.Vendor',              @Rows, @Seed, N'Vendor,CompanyCode,PurchOrg', @PreferFilled;
    EXEC exp.FitRows N'mst.VendorChangeHistory', @Rows, @Seed, N'Vendor,ChangeNumber,TableName,TableKey,FieldName', @PreferFilled;
    EXEC exp.FitRows N'mst.Material',            @Rows, @Seed, N'Material', @PreferFilled;
    EXEC exp.FitRows N'inv.InventoryBalance',    @Rows, @Seed, N'Material,Plant,StorLoc', @PreferFilled;
    EXEC exp.FitRows N'mst.PurchasingInfoRecord', @Rows, @Seed, N'Vendor,Material,PurchOrg,InfoCategory,Plant', @PreferFilled;
    EXEC exp.FitRows N'mst.PurchasingCondA017',  @Rows, @Seed, N'Vendor,Material,PurchOrg,Plant,InfoCategory,ConditionType,ValidFrom', @PreferFilled;
    EXEC exp.FitRows N'mst.PurchasingCondA018',  @Rows, @Seed, N'Vendor,Material,PurchOrg,InfoCategory,ConditionType,ValidFrom', @PreferFilled;

    -- ------------------------------------------------------------------
    -- 7. 其他表
    -- ------------------------------------------------------------------
    IF COL_LENGTH(N'dbo.LFBK', N'LIFNR') IS NOT NULL EXEC exp.CopyTable N'dbo.LFBK', @v;
    ELSE EXEC exp.CopyRandom N'dbo.LFBK', @Rows, @Seed, @PreferFilled;
    IF COL_LENGTH(N'dbo.MBEWH', N'MATNR') IS NOT NULL EXEC exp.CopyTable N'dbo.MBEWH', @m;
    ELSE EXEC exp.CopyRandom N'dbo.MBEWH', @Rows, @Seed, @PreferFilled;

    -- ANLA：EKKN / BSEG 有 ANLN1 才串得起來；兩邊都有 ANLN2（資產子編號）時一起比
    DECLARE @anla NVARCHAR(MAX) = NULL;
    IF COL_LENGTH(N'dbo.ANLA', N'ANLN1') IS NOT NULL AND COL_LENGTH(N'dbo.ANLA', N'BUKRS') IS NOT NULL
    BEGIN
        IF COL_LENGTH(N'exp.EKKN', N'ANLN1') IS NOT NULL
            SET @anla = N'EXISTS (SELECT 1 FROM exp.EKKN k JOIN exp.EKKO h ON h.EBELN = k.EBELN'
                      + N' WHERE h.BUKRS = t.BUKRS AND k.ANLN1 = t.ANLN1'
                      + IIF(COL_LENGTH(N'exp.EKKN', N'ANLN2') IS NOT NULL AND COL_LENGTH(N'dbo.ANLA', N'ANLN2') IS NOT NULL,
                            N' AND k.ANLN2 = t.ANLN2', N'') + N')';
        IF COL_LENGTH(N'exp.BSEG', N'ANLN1') IS NOT NULL
            SET @anla = CONCAT(@anla + N' OR ', N'EXISTS (SELECT 1 FROM exp.BSEG k'
                      + N' WHERE k.BUKRS = t.BUKRS AND k.ANLN1 = t.ANLN1'
                      + IIF(COL_LENGTH(N'exp.BSEG', N'ANLN2') IS NOT NULL AND COL_LENGTH(N'dbo.ANLA', N'ANLN2') IS NOT NULL,
                            N' AND k.ANLN2 = t.ANLN2', N'') + N')');
    END;
    IF @anla IS NOT NULL
    BEGIN
        -- 先帶用到的資產，調到 @Rows 筆（不足隨機補、超過隨機留）
        EXEC exp.CopyTable N'dbo.ANLA', @anla;
        DECLARE @anlaKeys NVARCHAR(100) = IIF(COL_LENGTH(N'dbo.ANLA', N'ANLN2') IS NOT NULL,
                                              N'BUKRS,ANLN1,ANLN2', N'BUKRS,ANLN1');
        EXEC exp.FitRows N'dbo.ANLA', @Rows, @Seed, @anlaKeys, @PreferFilled;
    END;
    ELSE EXEC exp.CopyRandom N'dbo.ANLA', @Rows, @Seed, @PreferFilled;
    EXEC exp.CopyRandom N'dbo.ZTM105',       @Rows, @Seed, @PreferFilled;
    EXEC exp.CopyRandom N'dbo.ZTM80',        @Rows, @Seed, @PreferFilled;
    EXEC exp.CopyRandom N'dbo.ADT_CONTRACT', @Rows, @Seed, @PreferFilled;
    EXEC exp.CopyRandom N'dbo.ADT_ECAR',     @Rows, @Seed, @PreferFilled;
    EXEC exp.CopyRandom N'dbo.ADT_OSWEB',    @Rows, @Seed, @PreferFilled;
    EXEC exp.CopyRandom N'dbo.ADT_POAS',     @Rows, @Seed, @PreferFilled;

    SELECT Src AS [來源], N'exp.' + PARSENAME(Src, 1) AS [抽樣表], Rows AS [筆數], Note AS [說明],
           @Seed AS [Seed]
    FROM #explog
    ORDER BY seq;
END;
GO
