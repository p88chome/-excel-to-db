-- 檢查 stg 表（excel-to-db 匯進來的 SAP 原表）齊不齊。
-- 在 02_load_procedures.sql 之前跑：程序引用了不存在的欄位會建不起來，
-- 錯誤訊息只說 Invalid column name，不會說是哪張表少了什麼。
--
-- 結果是空的就代表都齊了。少的欄位要回 SAP 重新下載時勾選。
--
-- 還沒辦法重新下載、想先組起來的話，把 @fill 改成 1 再跑一次：
-- 「表在、欄位不在」的會補成空欄（ALTER TABLE ADD ... NULL），程序就建得起來，
-- 那幾欄的資料先是 NULL。之後重新匯入時 excel-to-db 會整張重建 stg 表，補的空欄跟著消失。
-- 整張表不存在的不會補，要先匯入。
--
-- excel-to-db 預設匯到 dbo；放在別的 schema 就改下面的 @stg。

SET NOCOUNT ON;
DECLARE @stg sysname = N'dbo';
DECLARE @fill bit = 0;      -- 1 = 把缺的欄位補成空欄

DECLARE @need TABLE (tbl sysname, col sysname, optional bit DEFAULT 0);
INSERT @need (tbl, col) VALUES
-- prc.PurchaseOrderDetail
('EKKO','EBELN'),('EKKO','BSTYP'),('EKKO','BSART'),('EKKO','BUKRS'),('EKKO','EKORG'),
('EKKO','EKGRP'),('EKKO','BEDAT'),('EKKO','LIFNR'),('EKKO','ZTERM'),('EKKO','WAERS'),
('EKKO','WKURS'),
('EKPO','EBELN'),('EKPO','EBELP'),('EKPO','MATNR'),('EKPO','MATKL'),('EKPO','WERKS'),
('EKPO','LGORT'),('EKPO','MENGE'),('EKPO','MEINS'),('EKPO','NETPR'),('EKPO','PEINH'),
('EKPO','NETWR'),('EKPO','ELIKZ'),('EKPO','WEPOS'),('EKPO','REPOS'),('EKPO','LOEKZ'),
('EKPO','BANFN'),('EKPO','BNFPO'),('EKPO','KONNR'),('EKPO','KTPNR'),
('EKKN','EBELN'),('EKKN','EBELP'),('EKKN','ZEKKN'),('EKKN','SAKTO'),('EKKN','KOSTL'),
('EKKN','AUFNR'),
('EKET','EBELN'),('EKET','EBELP'),('EKET','EINDT'),
('EKBE','EBELN'),('EKBE','EBELP'),('EKBE','BEWTP'),('EKBE','SHKZG'),('EKBE','MENGE'),
('EKBE','DMBTR'),('EKBE','BUDAT'),
('MAKT','MATNR'),('MAKT','SPRAS'),('MAKT','MAKTX'),
-- mst.Vendor
('LFA1','LIFNR'),('LFA1','NAME1'),('LFA1','NAME2'),('LFA1','SORTL'),('LFA1','LAND1'),
('LFA1','REGIO'),('LFA1','ORT01'),('LFA1','PSTLZ'),('LFA1','STRAS'),('LFA1','SPRAS'),
('LFA1','TELF1'),('LFA1','TELFX'),('LFA1','STCD1'),('LFA1','KTOKK'),('LFA1','ERDAT'),
('LFA1','ERNAM'),('LFA1','LOEVM'),('LFA1','SPERR'),('LFA1','SPERM'),
('LFB1','LIFNR'),('LFB1','BUKRS'),('LFB1','ZTERM'),('LFB1','ZWELS'),('LFB1','ZAHLS'),
('LFB1','SPERR'),
('LFM1','LIFNR'),('LFM1','EKORG'),('LFM1','SPERM'),('LFM1','INCO1'),('LFM1','WAERS'),
('LFM1','VERKF'),('LFM1','ZTERM'),
('T024E','EKORG'),('T024E','BUKRS'),
-- prc.PurchaseRequisition
('EBAN','BANFN'),('EBAN','BNFPO'),('EBAN','BSART'),('EBAN','BADAT'),('EBAN','ERNAM'),
('EBAN','MATNR'),('EBAN','TXZ01'),('EBAN','MATKL'),('EBAN','WERKS'),('EBAN','LGORT'),
('EBAN','MENGE'),('EBAN','MEINS'),('EBAN','LFDAT'),('EBAN','PREIS'),('EBAN','WAERS'),
('EBAN','EKGRP'),('EBAN','EKORG'),('EBAN','FLIEF'),('EBAN','KNTTP'),('EBAN','FRGKZ'),
('EBAN','FRGST'),('EBAN','LOEKZ'),
('EBKN','BANFN'),('EBKN','BNFPO'),('EBKN','ZEBKN'),('EBKN','KOSTL'),('EBKN','SAKTO'),
-- prc.GoodsReceipt / inv.MaterialMovement
('MKPF','MBLNR'),('MKPF','MJAHR'),('MKPF','BUDAT'),('MKPF','BLDAT'),('MKPF','CPUDT'),
('MKPF','USNAM'),('MKPF','XBLNR'),
('MSEG','MBLNR'),('MSEG','MJAHR'),('MSEG','ZEILE'),('MSEG','BWART'),('MSEG','MATNR'),
('MSEG','WERKS'),('MSEG','LGORT'),('MSEG','CHARG'),('MSEG','BUKRS'),('MSEG','MENGE'),
('MSEG','MEINS'),('MSEG','DMBTR'),('MSEG','EBELN'),('MSEG','EBELP'),('MSEG','SGTXT'),
('MSEG','SHKZG'),('MSEG','KOSTL'),('MSEG','SAKTO'),('MSEG','AUFNR'),('MSEG','KUNNR'),
('T001','BUKRS'),('T001','WAERS'),
-- mst.VendorChangeHistory
('CDHDR','OBJECTCLAS'),('CDHDR','OBJECTID'),('CDHDR','CHANGENR'),('CDHDR','UDATE'),
('CDHDR','UTIME'),('CDHDR','USERNAME'),('CDHDR','TCODE'),
('CDPOS','OBJECTCLAS'),('CDPOS','OBJECTID'),('CDPOS','CHANGENR'),('CDPOS','TABNAME'),
('CDPOS','TABKEY'),('CDPOS','FNAME'),('CDPOS','CHNGIND'),('CDPOS','VALUE_OLD'),
('CDPOS','VALUE_NEW'),
-- mst.Material
('MARA','MATNR'),('MARA','MTART'),('MARA','MATKL'),('MARA','MEINS'),('MARA','MBRSH'),
('MARA','SPART'),('MARA','MSTAE'),('MARA','BRGEW'),('MARA','NTGEW'),('MARA','GEWEI'),
('MARA','VOLUM'),('MARA','VOLEH'),('MARA','GROES'),('MARA','WRKST'),('MARA','MFRPN'),
('MARA','ERSDA'),('MARA','ERNAM'),('MARA','LVORM'),
-- mst.PurchasingInfoRecord
('EINA','INFNR'),('EINA','LIFNR'),('EINA','MATNR'),('EINA','IDNLF'),('EINA','LOEKZ'),
('EINA','ERDAT'),('EINA','ERNAM'),
('EINE','INFNR'),('EINE','EKORG'),('EINE','ESOKZ'),('EINE','WERKS'),('EINE','EKGRP'),
('EINE','APLFZ'),('EINE','NORBM'),('EINE','WAERS'),('EINE','INCO1'),('EINE','BSTAE'),
-- mst.PurchasingCondA017 / A018
('A017','LIFNR'),('A017','MATNR'),('A017','EKORG'),('A017','WERKS'),('A017','ESOKZ'),
('A017','KSCHL'),('A017','DATAB'),('A017','DATBI'),('A017','KNUMH'),
('A018','LIFNR'),('A018','MATNR'),('A018','EKORG'),('A018','ESOKZ'),('A018','KSCHL'),
('A018','DATAB'),('A018','DATBI'),('A018','KNUMH'),
('KONP','KNUMH'),('KONP','KOPOS'),('KONP','KBETR'),('KONP','KONWA'),('KONP','KPEIN'),
('KONP','KMEIN'),('KONP','LOEVM_KO'),
('KONH','KNUMH'),('KONH','ERDAT'),('KONH','ERNAM'),
-- inv.InventoryBalance
('MARD','MATNR'),('MARD','WERKS'),('MARD','LGORT'),('MARD','LABST'),('MARD','INSME'),
('MARD','SPEME'),('MARD','UMLME'),
('MBEW','MATNR'),('MBEW','BWKEY'),('MBEW','BWTAR'),('MBEW','SALK3'),('MBEW','STPRS'),
('MBEW','VERPR'),('MBEW','VPRSV'),('MBEW','PEINH'),
('MARC','MATNR'),('MARC','WERKS'),('MARC','EISBE'),('MARC','MINBE'),('MARC','MABST'),
('MARC','DISMM'),('MARC','DISPO'),('MARC','BESKZ'),('MARC','MAABC'),
-- fin.AccountsPayable
('BKPF','BUKRS'),('BKPF','BELNR'),('BKPF','GJAHR'),('BKPF','BLART'),('BKPF','BUDAT'),
('BKPF','BLDAT'),('BKPF','CPUDT'),('BKPF','USNAM'),('BKPF','XBLNR'),('BKPF','WAERS'),
('BSEG','BUKRS'),('BSEG','BELNR'),('BSEG','GJAHR'),('BSEG','BUZEI'),('BSEG','KOART'),
('BSEG','LIFNR'),('BSEG','ZUONR'),('BSEG','SGTXT'),('BSEG','HKONT'),('BSEG','KOSTL'),
('BSEG','WRBTR'),('BSEG','DMBTR'),('BSEG','SHKZG'),('BSEG','ZTERM'),('BSEG','ZFBDT'),
('BSEG','ZLSCH'),('BSEG','ZLSPR'),('BSEG','AUGBL'),('BSEG','AUGDT'),('BSEG','EBELN'),
('BSEG','EBELP'),
-- KOART、SHKZG 沒有資料時用記帳碼推：21~39 是供應商行，2x 借、3x 貸
('BSEG','BSCHL');

-- 沒有也能跑，只是對應的欄位會是 NULL
INSERT @need (tbl, col, optional) VALUES
('T024D','WERKS',1),('T024D','DISPO',1),('T024D','DSNAM',1);

SELECT n.tbl, n.col, n.optional, t.object_id
INTO #missing
FROM @need n
LEFT JOIN sys.tables t
       ON t.name = n.tbl AND t.schema_id = SCHEMA_ID(@stg)
LEFT JOIN sys.columns c
       ON c.object_id = t.object_id AND c.name = n.col
WHERE c.column_id IS NULL;

IF @fill = 1
BEGIN
    -- 型別照 excel-to-db 匯入的結果：日期 DATE、金額數量 DECIMAL、其餘文字
    DECLARE @dates nvarchar(max) = N'BEDAT EINDT BUDAT BADAT LFDAT ERDAT CPUDT BLDAT UDATE ERSDA DATAB DATBI ZFBDT AUGDT',
            @nums  nvarchar(max) = N'WKURS MENGE NETPR PEINH NETWR DMBTR PREIS BRGEW NTGEW VOLUM APLFZ NORBM KBETR KPEIN LABST INSME SPEME UMLME SALK3 STPRS VERPR EISBE MINBE MABST WRBTR',
            @tbl sysname, @col sysname, @sql nvarchar(400);
    DECLARE cols CURSOR LOCAL FAST_FORWARD FOR
        SELECT tbl, col FROM #missing WHERE object_id IS NOT NULL;
    OPEN cols;
    FETCH NEXT FROM cols INTO @tbl, @col;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE ' + QUOTENAME(@stg) + N'.' + QUOTENAME(@tbl) + N' ADD ' + QUOTENAME(@col) + N' '
                 + CASE WHEN @col IN (SELECT value FROM STRING_SPLIT(@dates, N' ')) THEN N'DATE'
                        WHEN @col IN (SELECT value FROM STRING_SPLIT(@nums, N' ')) THEN N'DECIMAL(18,3)'
                        ELSE N'NVARCHAR(100)' END
                 + N' NULL';
        EXEC (@sql);
        FETCH NEXT FROM cols INTO @tbl, @col;
    END;
    CLOSE cols;
END;

SELECT tbl AS [stg 表], col AS [欄位],
       CASE WHEN object_id IS NULL THEN N'整張表不存在'
            WHEN @fill = 1         THEN N'缺欄位 → 已補成空欄'
            ELSE N'缺欄位' END AS [狀況],
       CASE WHEN optional = 1 THEN N'選用（沒有就留 NULL）' ELSE N'必要' END AS [影響]
FROM #missing
ORDER BY optional, tbl, col;

DROP TABLE #missing;
