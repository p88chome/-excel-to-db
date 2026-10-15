1. 確認是不是完全相同

WITH d AS (
    SELECT BUKRS, BELNR, GJAHR, BUZEI
    FROM dbo.BSEG
    GROUP BY BUKRS, BELNR, GJAHR, BUZEI
    HAVING COUNT(*) > 1
)
SELECT COUNT(*) AS 不同的列數
FROM (SELECT DISTINCT s.*
      FROM dbo.BSEG s
      JOIN d ON d.BUKRS = s.BUKRS AND d.BELNR = s.BELNR
            AND d.GJAHR = s.GJAHR AND d.BUZEI = s.BUZEI) x;

- 結果是 247376： 每組的兩筆完全相同，可以刪。
- 結果比 247376 大： 有些內容不一樣。先不要刪，把數字告訴我。

順便看看重複集中在哪一段，比較容易找出是哪個檔案匯了兩次：

SELECT GJAHR, BUKRS, COUNT(*) AS 重複的鍵數
FROM (SELECT BUKRS, BELNR, GJAHR, BUZEI FROM dbo.BSEG
      GROUP BY BUKRS, BELNR, GJAHR, BUZEI HAVING COUNT(*) > 1) d
GROUP BY GJAHR, BUKRS
ORDER BY GJAHR, BUKRS;

2. 確認完全相同之後，備份再刪

▎ 注意：DELETE 不能復原，所以先把要刪的那一份另存起來。

-- 備份「多出來的那一份」（247,376 筆）
WITH r AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY BUKRS, BELNR, GJAHR, BUZEI
                                 ORDER BY (SELECT NULL)) AS rn
    FROM dbo.BSEG
)
SELECT * INTO dbo.BSEG_deleted_dup FROM r WHERE rn > 1;

-- 在交易裡刪，每組留一筆
BEGIN TRAN;
WITH r AS (
    SELECT ROW_NUMBER() OVER (PARTITION BY BUKRS, BELNR, GJAHR, BUZEI
                              ORDER BY (SELECT NULL)) AS rn
    FROM dbo.BSEG
)
DELETE FROM r WHERE rn > 1;
SELECT @@ROWCOUNT AS 刪除筆數;   -- 應該是 247376
-- 是 247376 就執行：COMMIT;   不是就執行：ROLLBACK;
