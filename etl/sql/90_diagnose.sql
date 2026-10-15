-- 診斷 LoadAll 的筆數與 stg 的常見問題，輸出壓成三行「代號=數字」，
-- 方便在沒辦法複製貼上的環境用手打回報。只有筆數，不含任何資料內容。
-- 某一項查不了（表不存在等）顯示 -1。
--
-- T 目標表筆數：T1 PurchaseOrderDetail  T2 PurchaseRequisition  T3 GoodsReceipt
--   T4 VendorChangeHistory  T5 Vendor  T6 Material  T7 PurchasingInfoRecord
--   T8 PurchasingCondA017  T9 PurchasingCondA018  T10 AccountsPayable
--   T11 MaterialMovement  T12 InventoryBalance
-- M MARA：M1 總筆數  M2 MATNR 空白
-- D MARD：D1 總筆數  D2 MATNR 空白  D3 LGORT 空白  D4 WERKS 空白
-- B BSEG：B1 總筆數  B2 重複的鍵數  B3 重複涉及筆數  B4 單一鍵最多出現幾次
--         B5 判定為供應商行的筆數  B6 BUZEI 空白
-- K BKPF：K1 總筆數  K2 重複的鍵數
-- S MSEG/MKPF：S1 MSEG 總筆數  S2 MSEG.MBLNR 空白  S3 MKPF 總筆數

SET NOCOUNT ON;
DECLARE @q TABLE (seq int IDENTITY, grp char(1), code varchar(4), sql nvarchar(max));
INSERT @q (grp, code, sql) VALUES
('T','T1', N'SELECT COUNT_BIG(*) FROM prc.PurchaseOrderDetail'),
('T','T2', N'SELECT COUNT_BIG(*) FROM prc.PurchaseRequisition'),
('T','T3', N'SELECT COUNT_BIG(*) FROM prc.GoodsReceipt'),
('T','T4', N'SELECT COUNT_BIG(*) FROM mst.VendorChangeHistory'),
('T','T5', N'SELECT COUNT_BIG(*) FROM mst.Vendor'),
('T','T6', N'SELECT COUNT_BIG(*) FROM mst.Material'),
('T','T7', N'SELECT COUNT_BIG(*) FROM mst.PurchasingInfoRecord'),
('T','T8', N'SELECT COUNT_BIG(*) FROM mst.PurchasingCondA017'),
('T','T9', N'SELECT COUNT_BIG(*) FROM mst.PurchasingCondA018'),
('T','T10',N'SELECT COUNT_BIG(*) FROM fin.AccountsPayable'),
('T','T11',N'SELECT COUNT_BIG(*) FROM inv.MaterialMovement'),
('T','T12',N'SELECT COUNT_BIG(*) FROM inv.InventoryBalance'),
('M','M1', N'SELECT COUNT_BIG(*) FROM dbo.MARA'),
('M','M2', N'SELECT COUNT_BIG(*) FROM dbo.MARA WHERE ISNULL(MATNR, '''') = '''''),
('D','D1', N'SELECT COUNT_BIG(*) FROM dbo.MARD'),
('D','D2', N'SELECT COUNT_BIG(*) FROM dbo.MARD WHERE ISNULL(MATNR, '''') = '''''),
('D','D3', N'SELECT COUNT_BIG(*) FROM dbo.MARD WHERE ISNULL(LGORT, '''') = '''''),
('D','D4', N'SELECT COUNT_BIG(*) FROM dbo.MARD WHERE ISNULL(WERKS, '''') = '''''),
('B','B1', N'SELECT COUNT_BIG(*) FROM dbo.BSEG'),
('B','B2', N'SELECT COUNT_BIG(*) FROM (SELECT 1 x FROM dbo.BSEG GROUP BY BUKRS, BELNR, GJAHR, BUZEI HAVING COUNT(*) > 1) d'),
('B','B3', N'SELECT ISNULL(SUM(n), 0) FROM (SELECT COUNT_BIG(*) n FROM dbo.BSEG GROUP BY BUKRS, BELNR, GJAHR, BUZEI HAVING COUNT(*) > 1) d'),
('B','B4', N'SELECT ISNULL(MAX(n), 0) FROM (SELECT COUNT_BIG(*) n FROM dbo.BSEG GROUP BY BUKRS, BELNR, GJAHR, BUZEI) d'),
('B','B5', N'SELECT COUNT_BIG(*) FROM dbo.BSEG s WHERE COALESCE(NULLIF(s.KOART, ''''),
                 CASE WHEN s.BSCHL BETWEEN ''21'' AND ''39'' THEN ''K'' WHEN ISNULL(s.BSCHL, '''') <> '''' THEN ''-'' END,
                 IIF(ISNULL(s.LIFNR, '''') <> '''', ''K'', ''-'')) = ''K'''),
('B','B6', N'SELECT COUNT_BIG(*) FROM dbo.BSEG WHERE ISNULL(BUZEI, '''') = '''''),
('K','K1', N'SELECT COUNT_BIG(*) FROM dbo.BKPF'),
('K','K2', N'SELECT COUNT_BIG(*) FROM (SELECT 1 x FROM dbo.BKPF GROUP BY BUKRS, BELNR, GJAHR HAVING COUNT(*) > 1) d'),
('S','S1', N'SELECT COUNT_BIG(*) FROM dbo.MSEG'),
('S','S2', N'SELECT COUNT_BIG(*) FROM dbo.MSEG WHERE ISNULL(MBLNR, '''') = '''''),
('S','S3', N'SELECT COUNT_BIG(*) FROM dbo.MKPF');

DECLARE @r TABLE (seq int, grp char(1), code varchar(4), val bigint);
DECLARE @one TABLE (v bigint);
DECLARE @i int = 1, @n int = (SELECT COUNT(*) FROM @q), @sql nvarchar(max);
WHILE @i <= @n
BEGIN
    SELECT @sql = sql FROM @q WHERE seq = @i;
    DELETE @one;
    BEGIN TRY
        INSERT @one EXEC (@sql);
    END TRY
    BEGIN CATCH
        INSERT @one VALUES (-1);
    END CATCH;
    INSERT @r SELECT q.seq, q.grp, q.code, (SELECT TOP 1 v FROM @one) FROM @q q WHERE q.seq = @i;
    SET @i += 1;
END;

SELECT STRING_AGG(CONCAT(code, '=', val), ' ') WITHIN GROUP (ORDER BY seq) AS [回報這三行]
FROM @r
GROUP BY CASE WHEN grp = 'T' THEN 1 WHEN grp IN ('M', 'D') THEN 2 ELSE 3 END
ORDER BY MIN(seq);
