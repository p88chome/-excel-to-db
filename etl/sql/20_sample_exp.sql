-- 抽樣：把 ETL 用到的 SAP 原表、業務表（prc / mst / inv / fin）抽一小份到 exp schema，
-- 表名不變：dbo.EKKO → exp.EKKO、prc.PurchaseOrderDetail → exp.PurchaseOrderDetail。
--
--   EXEC exp.SampleAll;                         -- 每類單據隨機抽 1000 張，每次都不一樣
--   EXEC exp.SampleAll @Rows = 500, @Seed = 42;  -- 同一個 seed、同一份資料 → 抽出同一批
--
-- 不是每張表各自亂抽 1000 筆（那樣 EKKO 和 EKPO 會對不起來），而是「以單據為主」：
--   1. 隨機抽 @Rows 張單據表頭：PO（EKKO）、PR（EBAN）、物料憑證（MKPF）、有供應商行的會計傳票（BKPF）
--   2. 補上相關的單據：PR、物料憑證、傳票引用到的 PO 併進來；再由全部的 PO 補來源 PR、
--      收貨憑證、發票傳票。所以 exp 裡任何單據引用的 PO 都在 exp.EKKO 裡
--   3. 明細照表頭帶：EKPO / EKKN / EKET / EKBE、EBKN、MSEG、BSEG，一張單據的明細全部帶出
--   4. 主檔只帶有用到的：這些單據的供應商（LFA1 / LFB1 / LFM1 / CDHDR / CDPOS）、
--      物料（MARA / MAKT / MARC / MARD / MBEW）、供應商 × 物料的資訊記錄與價格條件
--   5. 設定表（T001、T001K、T001W、T024D、T024E）整張複製
--   6. 業務表用同一批鍵篩，跟 exp 裡的原表是同一批單據
--   7. 其他表：LFBK 帶用到的供應商、MBEWH 帶用到的物料（沒有 LIFNR / MATNR 欄位就改成隨機）；
--      ANLA 帶抽到的 PO（EKKN.ANLN1）、會計傳票（BSEG.ANLN1）用到的資產（沒有 ANLN1 欄位就改成隨機）；
--      ZTM105、ZTM80、ADT_CONTRACT、ADT_ECAR、ADT_OSWEB、ADT_POAS 沒有固定關聯，
--      SELECT * 隨機抽 @Rows 筆（依 seed + 整列內容的雜湊排序，同一個 seed 一樣抽同一批）
-- 所以 @Rows 是「每類單據的張數」，不是每張表的筆數：明細表會比較多，主檔看用到幾個。
--
-- 隨機的方式：依「seed + 單據號碼」的雜湊排序取前 @Rows 張。
-- 不給 @Seed 就隨機產生一個，結果最後一欄會列出這次用的 seed，要重抽同一批就把它帶回來。
-- 重新匯入 SAP 資料後用同一個 seed，原本就有的單據還是會抽到同一批。
--
-- 每次執行會 DROP 掉 exp 裡同名的表重建。來源表不存在的（例如沒有 T024E）會跳過並在結果註明。
-- 注意：exp 裡仍然是客戶的真實資料，不要放進版控或帶出客戶環境。

IF SCHEMA_ID(N'exp') IS NULL EXEC (N'CREATE SCHEMA exp');
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
CREATE OR ALTER PROCEDURE exp.CopyRandom @Src NVARCHAR(256), @Top INT, @Seed INT
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
             + N' ORDER BY HASHBYTES(''MD5'', CONCAT(@seed, N''|'', BINARY_CHECKSUM(*)));'
             + N'SET @r = @@ROWCOUNT;';
    EXEC sp_executesql @sql, N'@n INT, @seed INT, @r BIGINT OUTPUT', @n = @Top, @seed = @Seed, @r = @rows OUTPUT;
    INSERT #explog (Src, Rows, Note) VALUES (@Src, @rows, N'隨機');
END;
GO

CREATE OR ALTER PROCEDURE exp.SampleAll @Rows INT = 1000, @Seed INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Seed = ISNULL(@Seed, ABS(CHECKSUM(NEWID())) % 1000000);
    DECLARE @s NVARCHAR(20) = CAST(@Seed AS NVARCHAR(20)) + N'|';

    CREATE TABLE #explog (seq INT IDENTITY, Src NVARCHAR(256), Rows BIGINT, Note NVARCHAR(200));

    -- ------------------------------------------------------------------
    -- 1～2. 單據鍵
    -- ------------------------------------------------------------------
    -- 先四類各自隨機抽 @Rows 張
    SELECT TOP (@Rows) EBELN INTO #po
    FROM dbo.EKKO
    WHERE ISNULL(EBELN, '') <> ''
    ORDER BY HASHBYTES('MD5', @s + EBELN);

    SELECT TOP (@Rows) BANFN INTO #pr
    FROM (SELECT DISTINCT BANFN FROM dbo.EBAN WHERE ISNULL(BANFN, '') <> '') x
    ORDER BY HASHBYTES('MD5', @s + BANFN);

    SELECT TOP (@Rows) MBLNR, MJAHR INTO #md
    FROM dbo.MKPF
    WHERE ISNULL(MBLNR, '') <> ''
    ORDER BY HASHBYTES('MD5', @s + MBLNR + N'|' + CAST(MJAHR AS NVARCHAR(10)));

    -- 會計傳票只從有供應商行的抽（不然 fin.AccountsPayable 抽出來幾乎是空的）
    SELECT TOP (@Rows) h.BUKRS, h.BELNR, h.GJAHR INTO #ad
    FROM dbo.BKPF h
    WHERE EXISTS (SELECT 1 FROM dbo.BSEG s
                  WHERE s.BUKRS = h.BUKRS AND s.BELNR = h.BELNR AND s.GJAHR = h.GJAHR
                    AND ISNULL(s.LIFNR, '') <> '')
    ORDER BY HASHBYTES('MD5', @s + h.BUKRS + N'|' + h.BELNR + N'|' + CAST(h.GJAHR AS NVARCHAR(10)));

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
            @vm NVARCHAR(200) = N't.LIFNR IN (SELECT LIFNR FROM #vendor) AND t.MATNR IN (SELECT MATNR FROM #mat)';

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
    EXEC exp.CopyTable N'dbo.A017', @vm;
    EXEC exp.CopyTable N'dbo.A018', @vm;
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
            @bm  NVARCHAR(200) = N't.Material IN (SELECT MATNR FROM #mat)',
            @bvm NVARCHAR(200) = N't.Vendor IN (SELECT LIFNR FROM #vendor) AND t.Material IN (SELECT MATNR FROM #mat)';

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
    EXEC exp.CopyTable N'mst.PurchasingInfoRecord', @bvm;
    EXEC exp.CopyTable N'mst.PurchasingCondA017',   @bvm;
    EXEC exp.CopyTable N'mst.PurchasingCondA018',   @bvm;

    -- ------------------------------------------------------------------
    -- 7. 其他表
    -- ------------------------------------------------------------------
    IF COL_LENGTH(N'dbo.LFBK', N'LIFNR') IS NOT NULL EXEC exp.CopyTable N'dbo.LFBK', @v;
    ELSE EXEC exp.CopyRandom N'dbo.LFBK', @Rows, @Seed;
    IF COL_LENGTH(N'dbo.MBEWH', N'MATNR') IS NOT NULL EXEC exp.CopyTable N'dbo.MBEWH', @m;
    ELSE EXEC exp.CopyRandom N'dbo.MBEWH', @Rows, @Seed;

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
    IF @anla IS NOT NULL EXEC exp.CopyTable N'dbo.ANLA', @anla;
    ELSE EXEC exp.CopyRandom N'dbo.ANLA', @Rows, @Seed;
    EXEC exp.CopyRandom N'dbo.ZTM105',       @Rows, @Seed;
    EXEC exp.CopyRandom N'dbo.ZTM80',        @Rows, @Seed;
    EXEC exp.CopyRandom N'dbo.ADT_CONTRACT', @Rows, @Seed;
    EXEC exp.CopyRandom N'dbo.ADT_ECAR',     @Rows, @Seed;
    EXEC exp.CopyRandom N'dbo.ADT_OSWEB',    @Rows, @Seed;
    EXEC exp.CopyRandom N'dbo.ADT_POAS',     @Rows, @Seed;

    SELECT Src AS [來源], N'exp.' + PARSENAME(Src, 1) AS [抽樣表], Rows AS [筆數], Note AS [說明],
           @Seed AS [Seed]
    FROM #explog
    ORDER BY seq;
END;
GO
