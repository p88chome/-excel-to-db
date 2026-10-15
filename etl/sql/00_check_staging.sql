-- 檢查 stg 表（excel-to-db 匯進來的 SAP 原表）齊不齊。
-- 在 02_load_procedures.sql 之前跑：程序引用了不存在的欄位會建不起來，
-- 錯誤訊息只說 Invalid column name，不會說是哪張表少了什麼。
--
-- 結果是空的就代表都齊了。少的欄位要回 SAP 重新下載時勾選。
-- excel-to-db 預設匯到 dbo；放在別的 schema 就改下面的 @stg。

SET NOCOUNT ON;
DECLARE @stg sysname = N'dbo';

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
-- mst.Vendor / VendorCompany / VendorPurchOrg
('LFA1','LIFNR'),('LFA1','NAME1'),('LFA1','NAME2'),('LFA1','SORTL'),('LFA1','LAND1'),
('LFA1','REGIO'),('LFA1','ORT01'),('LFA1','PSTLZ'),('LFA1','STRAS'),('LFA1','SPRAS'),
('LFA1','TELF1'),('LFA1','TELFX'),('LFA1','STCD1'),('LFA1','KTOKK'),('LFA1','ERDAT'),
('LFA1','ERNAM'),('LFA1','LOEVM'),('LFA1','SPERR'),('LFA1','SPERM'),
('LFB1','LIFNR'),('LFB1','BUKRS'),('LFB1','ZTERM'),('LFB1','ZWELS'),('LFB1','ZAHLS'),
('LFB1','SPERR'),('LFB1','LOEVM'),('LFB1','ERDAT'),('LFB1','ERNAM'),
('LFM1','LIFNR'),('LFM1','EKORG'),('LFM1','SPERM'),('LFM1','INCO1'),('LFM1','WAERS'),
('LFM1','VERKF'),('LFM1','ZTERM'),('LFM1','LOEVM'),('LFM1','ERDAT'),('LFM1','ERNAM'),
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
('BSEG','EBELP');

-- 沒有也能跑，只是對應的欄位會是 NULL
INSERT @need (tbl, col, optional) VALUES
('T024D','WERKS',1),('T024D','DISPO',1),('T024D','DSNAM',1);

SELECT n.tbl AS [stg 表], n.col AS [欄位],
       CASE WHEN t.object_id IS NULL THEN N'整張表不存在' ELSE N'缺欄位' END AS [狀況],
       CASE WHEN n.optional = 1 THEN N'選用（沒有就留 NULL）' ELSE N'必要' END AS [影響]
FROM @need n
LEFT JOIN sys.tables t
       ON t.name = n.tbl AND t.schema_id = SCHEMA_ID(@stg)
LEFT JOIN sys.columns c
       ON c.object_id = t.object_id AND c.name = n.col
WHERE c.column_id IS NULL
ORDER BY n.optional, n.tbl, n.col;
