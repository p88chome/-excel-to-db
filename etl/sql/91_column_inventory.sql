-- 盤點資料庫裡每張表的欄位結構，結果可以直接貼到 Excel。
--
-- 會出兩個結果：
--   1. 表清單：每張表的筆數、欄位數
--   2. 欄位清單：每張表的每個欄位、型別、可否為 NULL
--      @fill = 1 時多兩欄「有值筆數」「有值比例」，對應規格上的「是否有資料」
--
-- @fill = 1 要把每張表整個掃一遍，BSEG 這種千萬筆的表會跑幾分鐘。
-- excel-to-db 匯入時空白儲存格存成 NULL，所以「有值」= 不是 NULL。
--
-- 貼到 Excel：在結果格線按右鍵 →「連同標題一起複製」→ 到 Excel 貼上。

SET NOCOUNT ON;
DECLARE @schemas nvarchar(400) = N'dbo';   -- 要盤點的 schema，逗號分隔；留空 = 全部
DECLARE @fill    bit           = 0;        -- 1 = 一併算每個欄位有幾筆有值

DECLARE @t TABLE (object_id int PRIMARY KEY, sch sysname, tbl sysname);
INSERT @t
SELECT t.object_id, s.name, t.name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (ISNULL(@schemas, N'') = N''
       OR s.name IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@schemas, N',')));

-- 每個欄位有幾筆有值：一張表掃一次，所有欄位一起算
CREATE TABLE #fill (object_id int, col sysname, nonnull bigint);
IF @fill = 1
BEGIN
    DECLARE @id int, @sql nvarchar(max);
    DECLARE tbls CURSOR LOCAL FAST_FORWARD FOR SELECT object_id FROM @t;
    OPEN tbls;
    FETCH NEXT FROM tbls INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- ANSI_WARNINGS OFF：COUNT 遇到 NULL 會在訊息頁籤跳警告，看起來像出錯，關掉
        SELECT @sql = N'SET ANSI_WARNINGS OFF; INSERT #fill SELECT ' + CAST(@id AS nvarchar(20)) + N', v.col, v.n FROM (SELECT '
                    + STRING_AGG(CAST(N'COUNT_BIG(' + QUOTENAME(c.name) + N') AS c' + CAST(c.column_id AS nvarchar(10))
                                      AS nvarchar(max)), N', ')
                    + N' FROM ' + QUOTENAME(OBJECT_SCHEMA_NAME(@id)) + N'.' + QUOTENAME(OBJECT_NAME(@id))
                    + N') x CROSS APPLY (VALUES '
                    + STRING_AGG(CAST(N'(N''' + REPLACE(c.name, N'''', N'''''') + N''', x.c'
                                      + CAST(c.column_id AS nvarchar(10)) + N')' AS nvarchar(max)), N', ')
                    + N') v(col, n);'
        FROM sys.columns c
        WHERE c.object_id = @id;
        EXEC (@sql);
        FETCH NEXT FROM tbls INTO @id;
    END;
    CLOSE tbls;
END;

-- 1. 表清單
SELECT t.sch AS [Schema], t.tbl AS [表],
       (SELECT SUM(p.rows) FROM sys.partitions p
        WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) AS [筆數],
       (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS [欄位數]
FROM @t t
ORDER BY t.sch, t.tbl;

-- 2. 欄位清單
SELECT t.sch AS [Schema], t.tbl AS [表], c.column_id AS [順序], c.name AS [欄位],
       UPPER(ty.name) +
       CASE
           WHEN ty.name IN ('nvarchar', 'nchar')
               THEN '(' + IIF(c.max_length = -1, 'MAX', CAST(c.max_length / 2 AS varchar(10))) + ')'
           WHEN ty.name IN ('varchar', 'char', 'varbinary', 'binary')
               THEN '(' + IIF(c.max_length = -1, 'MAX', CAST(c.max_length AS varchar(10))) + ')'
           WHEN ty.name IN ('decimal', 'numeric')
               THEN '(' + CAST(c.precision AS varchar(5)) + ',' + CAST(c.scale AS varchar(5)) + ')'
           WHEN ty.name IN ('datetime2', 'time', 'datetimeoffset')
               THEN '(' + CAST(c.scale AS varchar(5)) + ')'
           ELSE ''
       END AS [型別],
       IIF(c.is_nullable = 1, 'Y', 'N') AS [可為NULL],
       IIF(@fill = 1, f.nonnull, NULL) AS [有值筆數],
       IIF(@fill = 1,
           CASE WHEN r.rows = 0 THEN N'（空表）'
                WHEN f.nonnull = 0 THEN N'有欄位沒資料'
                ELSE FORMAT(1.0 * f.nonnull / r.rows, 'P1') END,
           NULL) AS [有值比例]
FROM @t t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty  ON ty.user_type_id = c.user_type_id
CROSS APPLY (SELECT SUM(p.rows) AS rows FROM sys.partitions p
             WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) r
LEFT JOIN #fill f  ON f.object_id = t.object_id AND f.col = c.name
ORDER BY t.sch, t.tbl, c.column_id;

DROP TABLE #fill;
