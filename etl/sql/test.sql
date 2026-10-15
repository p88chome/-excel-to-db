-- 1. MARA、MARD 有沒有這些欄位（沒有的話就是 @fill 補的）
SELECT OBJECT_NAME(object_id) AS 表, name AS 欄位
FROM sys.columns
WHERE object_id IN (OBJECT_ID(N'dbo.MARA'), OBJECT_ID(N'dbo.MARD'))
  AND name IN ('MATNR', 'WERKS', 'LGORT');

-- 2. 主鍵空白的有幾筆
SELECT 'MARA' AS 表, COUNT(*) AS 總筆數,
       SUM(IIF(ISNULL(MATNR, '') = '', 1, 0)) AS 料號空白
FROM dbo.MARA;
SELECT 'MARD' AS 表, COUNT(*) AS 總筆數,
       SUM(IIF(ISNULL(MATNR, '') = '', 1, 0)) AS 料號空白,
       SUM(IIF(ISNULL(LGORT, '') = '', 1, 0)) AS 儲位空白
FROM dbo.MARD;

-- 3. 空白的那幾列長什麼樣（看是不是合計列、垃圾列）
SELECT TOP 5 * FROM dbo.MARA WHERE ISNULL(MATNR, '') = '';
SELECT TOP 5 * FROM dbo.MARD WHERE ISNULL(LGORT, '') = '';

-- 4. BSEG、BKPF 重複的情況
SELECT 'BSEG' AS 表, COUNT(*) AS 重複的鍵數, SUM(n) AS 涉及筆數 FROM (
    SELECT COUNT(*) AS n FROM dbo.BSEG
    GROUP BY BUKRS, BELNR, GJAHR, BUZEI HAVING COUNT(*) > 1) x;
SELECT 'BKPF' AS 表, COUNT(*) AS 重複的鍵數, SUM(n) AS 涉及筆數 FROM (
    SELECT COUNT(*) AS n FROM dbo.BKPF
    GROUP BY BUKRS, BELNR, GJAHR HAVING COUNT(*) > 1) x;

-- 5. 重複的範例
SELECT TOP 5 BUKRS, BELNR, GJAHR, BUZEI, COUNT(*) AS 次數
FROM dbo.BSEG GROUP BY BUKRS, BELNR, GJAHR, BUZEI
HAVING COUNT(*) > 1 ORDER BY 次數 DESC;
