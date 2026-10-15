-- 每張目標表一支載入程序：清空後從 stg 表（dbo.EKKO、dbo.EKPO…）重組。
-- 對應規格表 v2.3。串接邏輯照規格的「串接邏輯」欄寫，改過的地方見規格的修訂紀錄分頁。
--
-- 先跑 00_check_staging.sql 確認 stg 表齊了；少欄位的話這支會建不起來。
-- 少整張表倒是建得起來（SQL Server 會延後檢查表名），到執行那支程序時才會報錯。
--
-- stg 表的慣例（excel-to-db 匯入的結果）：
--   * 空白儲存格是 NULL 不是 ''，所以判斷「空白」一律用 ISNULL(x, '') = ''。
--   * 代碼欄位（EBELP、ZEKKN、KOPOS…）是文字，前導零還在，可以直接拿來排序與 JOIN。
--   * 主鍵欄位用 ISNULL(x, '')：SAP 的空白在主鍵裡是合法值（例如不分工廠的資訊記錄），
--     但 PRIMARY KEY 不收 NULL。
--   * 物料說明 MAKT 的語言別：SAP 內部是 'M'，SE16 匯出畫面上是 'ZF'，兩個都收。

-- ======================================================================
-- prc.PurchaseOrderDetail
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_PurchaseOrderDetail AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE prc.PurchaseOrderDetail;

    WITH kn AS (        -- 一個項目多筆科目分攤時取第一筆
        SELECT EBELN, EBELP, SAKTO, KOSTL, AUFNR,
               ROW_NUMBER() OVER (PARTITION BY EBELN, EBELP ORDER BY ZEKKN) AS rn
        FROM dbo.EKKN
    ), et AS (          -- 第一個排程交貨日
        SELECT EBELN, EBELP, MIN(EINDT) AS EINDT
        FROM dbo.EKET
        GROUP BY EBELN, EBELP
    ), be AS (          -- 收貨(E)、發票(Q)彙總；SHKZG='H' 是沖銷/退貨/貸項，取負
        SELECT EBELN, EBELP,
               SUM(CASE WHEN BEWTP = 'E' THEN IIF(SHKZG = 'H', -MENGE, MENGE) END) AS GrQty,
               SUM(CASE WHEN BEWTP = 'E' THEN IIF(SHKZG = 'H', -DMBTR, DMBTR) END) AS GrAmount,
               MAX(CASE WHEN BEWTP = 'E' THEN BUDAT END)                          AS LastGrDate,
               SUM(CASE WHEN BEWTP = 'Q' THEN IIF(SHKZG = 'H', -MENGE, MENGE) END) AS IrQty,
               SUM(CASE WHEN BEWTP = 'Q' THEN IIF(SHKZG = 'H', -DMBTR, DMBTR) END) AS IrAmount,
               MAX(CASE WHEN BEWTP = 'Q' THEN BUDAT END)                          AS LastIrDate
        FROM dbo.EKBE
        WHERE BEWTP IN ('E', 'Q')
        GROUP BY EBELN, EBELP
    )
    INSERT INTO prc.PurchaseOrderDetail (
        PoNumber, PoItem, PoType, CompanyCode, PurchOrg, PurchGroup, PoDate, Vendor,
        PaymentTerm, VendorName, VendorCountry, Material, MaterialDesc, MaterialGroup,
        Plant, StorLoc, GlAccount, CostCenter, IntOrder, OrderQty, OrderUom, NetPrice,
        PriceUnit, NetValue, Currency, ExchangeRate, DelivDate, DelivComplInd, GrInd,
        IrInd, DeletionInd, GrQty, GrAmount, LastGrDate, IrQty, IrAmount, LastIrDate,
        PrNumber, PrItem, Contract, ContractItem)
    SELECT
        k.EBELN, p.EBELP, k.BSART, k.BUKRS, k.EKORG, k.EKGRP, k.BEDAT, k.LIFNR,
        k.ZTERM, v.NAME1, v.LAND1, p.MATNR, t.MAKTX, p.MATKL,
        p.WERKS, p.LGORT, kn.SAKTO, kn.KOSTL, kn.AUFNR, p.MENGE, p.MEINS, p.NETPR,
        p.PEINH, p.NETWR, k.WAERS, k.WKURS, et.EINDT, p.ELIKZ, p.WEPOS,
        p.REPOS, p.LOEKZ, be.GrQty, be.GrAmount, be.LastGrDate, be.IrQty, be.IrAmount, be.LastIrDate,
        p.BANFN, p.BNFPO, p.KONNR, p.KTPNR
    FROM dbo.EKKO k
    JOIN dbo.EKPO p           ON p.EBELN = k.EBELN
    LEFT JOIN dbo.LFA1 v      ON v.LIFNR = k.LIFNR
    LEFT JOIN (SELECT MATNR, MAX(MAKTX) AS MAKTX FROM dbo.MAKT
               WHERE SPRAS IN ('M', 'ZF') GROUP BY MATNR) t
                              ON t.MATNR = p.MATNR
    LEFT JOIN kn              ON kn.EBELN = p.EBELN AND kn.EBELP = p.EBELP AND kn.rn = 1
    LEFT JOIN et              ON et.EBELN = p.EBELN AND et.EBELP = p.EBELP
    LEFT JOIN be              ON be.EBELN = p.EBELN AND be.EBELP = p.EBELP
    WHERE k.BSTYP = 'F';      -- 只留採購單：排除合約(K)、詢價單(A)、排程協議(L)

    COMMIT;
END;
GO

-- ======================================================================
-- prc.PurchaseRequisition
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_PurchaseRequisition AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE prc.PurchaseRequisition;

    WITH kn AS (        -- 一個項目多筆科目分攤時取第一筆
        SELECT BANFN, BNFPO, KOSTL, SAKTO,
               ROW_NUMBER() OVER (PARTITION BY BANFN, BNFPO ORDER BY ZEBKN) AS rn
        FROM dbo.EBKN
    ), po AS (          -- 一筆 PR 轉多筆 PO 時取最小的一筆，另外記總數
        SELECT BANFN, BNFPO, EBELN, EBELP,
               ROW_NUMBER() OVER (PARTITION BY BANFN, BNFPO ORDER BY EBELN, EBELP) AS rn,
               COUNT(*)     OVER (PARTITION BY BANFN, BNFPO)                     AS cnt
        FROM dbo.EKPO
        WHERE ISNULL(BANFN, '') <> '' AND ISNULL(LOEKZ, '') = ''
    )
    INSERT INTO prc.PurchaseRequisition (
        PrNumber, PrItem, PrType, PrDate, CreatedBy, Material, MaterialDesc, MaterialGroup,
        Plant, StorLoc, ReqQty, Uom, DelivDate, ValPrice, Currency, PurchGroup, PurchOrg,
        Vendor, VendorName, AcctAssCat, CostCenter, GlAccount, ReleaseInd, ReleaseStrategy,
        PoNumber, PoItem, PoItemCount, DeletionInd)
    SELECT
        r.BANFN, r.BNFPO, r.BSART, r.BADAT, r.ERNAM, r.MATNR, r.TXZ01, r.MATKL,
        r.WERKS, r.LGORT, r.MENGE, r.MEINS, r.LFDAT, r.PREIS, r.WAERS, r.EKGRP, r.EKORG,
        r.FLIEF, v.NAME1, r.KNTTP, kn.KOSTL, kn.SAKTO, r.FRGKZ, r.FRGST,
        po.EBELN, po.EBELP, ISNULL(po.cnt, 0), r.LOEKZ
    FROM dbo.EBAN r
    LEFT JOIN dbo.LFA1 v ON v.LIFNR = r.FLIEF
    LEFT JOIN kn         ON kn.BANFN = r.BANFN AND kn.BNFPO = r.BNFPO AND kn.rn = 1
    LEFT JOIN po         ON po.BANFN = r.BANFN AND po.BNFPO = r.BNFPO AND po.rn = 1;

    COMMIT;
END;
GO

-- ======================================================================
-- prc.GoodsReceipt：只留 PO 收貨（全部異動見 inv.MaterialMovement）
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_GoodsReceipt AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE prc.GoodsReceipt;

    WITH kn AS (
        SELECT EBELN, EBELP, SAKTO, KOSTL,
               ROW_NUMBER() OVER (PARTITION BY EBELN, EBELP ORDER BY ZEKKN) AS rn
        FROM dbo.EKKN
    )
    INSERT INTO prc.GoodsReceipt (
        MaterialDoc, MaterialDocYear, MaterialDocItem, PostingDate, DocumentDate, EntryDate,
        EnteredBy, RefDoc, MovementType, Material, MaterialDesc, MaterialGroup, Plant,
        StorLoc, Batch, CompanyCode, Quantity, DebitCreditInd, BaseUom, LocalAmount,
        Currency, PoNumber, PoItem, PoDate, Vendor, VendorName, PurchGroup, CostCenter,
        GlAccount, ItemText, FiscalYear)
    SELECT
        h.MBLNR, h.MJAHR, s.ZEILE, h.BUDAT, h.BLDAT, h.CPUDT,
        h.USNAM, h.XBLNR, s.BWART, s.MATNR, t.MAKTX, p.MATKL, s.WERKS,
        s.LGORT, s.CHARG, s.BUKRS, s.MENGE, s.SHKZG, s.MEINS, s.DMBTR,
        c.WAERS, s.EBELN, s.EBELP, k.BEDAT, k.LIFNR, v.NAME1, k.EKGRP, kn.KOSTL,
        kn.SAKTO, s.SGTXT, h.MJAHR
    FROM dbo.MKPF h
    JOIN dbo.MSEG s      ON s.MBLNR = h.MBLNR AND s.MJAHR = h.MJAHR
    LEFT JOIN dbo.EKPO p ON p.EBELN = s.EBELN AND p.EBELP = s.EBELP
    LEFT JOIN dbo.EKKO k ON k.EBELN = s.EBELN
    LEFT JOIN dbo.LFA1 v ON v.LIFNR = k.LIFNR
    LEFT JOIN dbo.T001 c ON c.BUKRS = s.BUKRS
    LEFT JOIN (SELECT MATNR, MAX(MAKTX) AS MAKTX FROM dbo.MAKT
               WHERE SPRAS IN ('M', 'ZF') GROUP BY MATNR) t
                         ON t.MATNR = s.MATNR
    LEFT JOIN kn         ON kn.EBELN = s.EBELN AND kn.EBELP = s.EBELP AND kn.rn = 1
    -- 101 收貨、102 收貨沖銷、122 退貨給供應商、123 退貨沖銷
    WHERE s.BWART IN ('101', '102', '122', '123')
      AND ISNULL(s.EBELN, '') <> '';

    COMMIT;
END;
GO

-- ======================================================================
-- mst.VendorChangeHistory：供應商的凍結/解凍異動
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_VendorChangeHistory AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.VendorChangeHistory;

    INSERT INTO mst.VendorChangeHistory (
        Vendor, ChangeNumber, ChangeDate, ChangeTime, ChangedBy, TransactionCode,
        TableName, TableKey, FieldName, OldValue, NewValue, ChangeInd)
    SELECT
        LEFT(RTRIM(h.OBJECTID), 10),        -- OBJECTCLAS='KRED' 時 OBJECTID 就是 LIFNR
        h.CHANGENR, h.UDATE,
        -- 匯出檔可能是 12:34:56，也可能是 123456
        COALESCE(TRY_CONVERT(time(0), h.UTIME),
                 TRY_CONVERT(time(0), STUFF(STUFF(
                     RIGHT('000000' + CONVERT(varchar(20), h.UTIME), 6), 5, 0, ':'), 3, 0, ':'))),
        h.USERNAME, h.TCODE,
        d.TABNAME, ISNULL(d.TABKEY, ''), d.FNAME, d.VALUE_OLD, d.VALUE_NEW, d.CHNGIND
    FROM dbo.CDHDR h
    JOIN dbo.CDPOS d ON d.OBJECTCLAS = h.OBJECTCLAS
                    AND d.OBJECTID   = h.OBJECTID
                    AND d.CHANGENR   = h.CHANGENR
    WHERE h.OBJECTCLAS = 'KRED'
      AND d.TABNAME IN ('LFA1', 'LFB1', 'LFM1')
      AND d.FNAME   IN ('SPERR', 'SPERM', 'ZAHLS');

    COMMIT;
END;
GO

-- ======================================================================
-- mst.Vendor / mst.VendorCompany / mst.VendorPurchOrg
-- 原本一張表 LFA1 × LFB1 × LFM1 會變笛卡兒積，拆成三張各自的粒度。
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_Vendor AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.Vendor;

    INSERT INTO mst.Vendor (
        Vendor, VendorName, VendorName2, SearchTerm, Country, Region, City, PostalCode,
        Address, Language, Phone, Fax, TaxNumber, VendorAccountGroup, CreatedOn, CreatedBy,
        DeletionInd, CentralPostingBlock, CentralPurchBlock)
    SELECT
        LIFNR, NAME1, NAME2, SORTL, LAND1, REGIO, ORT01, PSTLZ,
        STRAS, SPRAS, TELF1, TELFX, STCD1, KTOKK, ERDAT, ERNAM,
        LOEVM, SPERR, SPERM
    FROM dbo.LFA1;

    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE etl.Load_VendorCompany AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.VendorCompany;

    INSERT INTO mst.VendorCompany (
        Vendor, CompanyCode, VendorName, PaymentTerms, PaymentMethod, PaymentBlock,
        PostingBlock, DeletionInd, CreatedOn, CreatedBy)
    SELECT
        b.LIFNR, b.BUKRS, v.NAME1, b.ZTERM, b.ZWELS, b.ZAHLS,
        b.SPERR, b.LOEVM, b.ERDAT, b.ERNAM
    FROM dbo.LFB1 b
    LEFT JOIN dbo.LFA1 v ON v.LIFNR = b.LIFNR;

    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE etl.Load_VendorPurchOrg AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.VendorPurchOrg;

    INSERT INTO mst.VendorPurchOrg (
        Vendor, PurchOrg, VendorName, PurchasingBlock, Incoterms, OrderCurrency,
        SalesPerson, PaymentTerms, DeletionInd, CreatedOn, CreatedBy)
    SELECT
        m.LIFNR, m.EKORG, v.NAME1, m.SPERM, m.INCO1, m.WAERS,
        m.VERKF, m.ZTERM, m.LOEVM, m.ERDAT, m.ERNAM
    FROM dbo.LFM1 m
    LEFT JOIN dbo.LFA1 v ON v.LIFNR = m.LIFNR;

    COMMIT;
END;
GO

-- ======================================================================
-- mst.Material
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_Material AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.Material;

    INSERT INTO mst.Material (
        Material, MaterialDesc, MaterialType, MaterialGroup, BaseUom, IndustrySector,
        Division, MaterialStatus, GrossWeight, NetWeight, WeightUnit, Volume, VolumeUnit,
        SizeDimension, BasicMaterial, ManufacturerPartNo, CreatedOn, CreatedBy, DeletionFlag)
    SELECT
        m.MATNR, t.MAKTX, m.MTART, m.MATKL, m.MEINS, m.MBRSH,
        m.SPART, m.MSTAE, m.BRGEW, m.NTGEW, m.GEWEI, m.VOLUM, m.VOLEH,
        m.GROES, m.WRKST, m.MFRPN, m.ERSDA, m.ERNAM, m.LVORM
    FROM dbo.MARA m
    LEFT JOIN (SELECT MATNR, MAX(MAKTX) AS MAKTX FROM dbo.MAKT
               WHERE SPRAS IN ('M', 'ZF') GROUP BY MATNR) t
           ON t.MATNR = m.MATNR;

    COMMIT;
END;
GO

-- ======================================================================
-- mst.PurchasingInfoRecord
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_PurchasingInfoRecord AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.PurchasingInfoRecord;

    INSERT INTO mst.PurchasingInfoRecord (
        Vendor, Material, PurchOrg, InfoCategory, InfoRecord, VendorMaterial, MaterialDesc,
        VendorName, PurchGroup, Plant, PlannedDelivTime, StandardQty, OrderCurrency,
        Incoterms, ConfirmationCtrl, DeletionInd, CreatedOn, CreatedBy)
    SELECT
        ISNULL(a.LIFNR, ''), ISNULL(a.MATNR, ''), ISNULL(e.EKORG, ''), ISNULL(e.ESOKZ, ''),
        a.INFNR, a.IDNLF, t.MAKTX,
        v.NAME1, e.EKGRP, ISNULL(e.WERKS, ''), e.APLFZ, e.NORBM, e.WAERS,
        e.INCO1, e.BSTAE, a.LOEKZ, a.ERDAT, a.ERNAM
    FROM dbo.EINA a
    JOIN dbo.EINE e      ON e.INFNR = a.INFNR
    LEFT JOIN dbo.LFA1 v ON v.LIFNR = a.LIFNR
    LEFT JOIN (SELECT MATNR, MAX(MAKTX) AS MAKTX FROM dbo.MAKT
               WHERE SPRAS IN ('M', 'ZF') GROUP BY MATNR) t
                         ON t.MATNR = a.MATNR;

    COMMIT;
END;
GO

-- ======================================================================
-- mst.PurchasingCondA017（分工廠）/ mst.PurchasingCondA018（不分工廠）
-- KONP 的鍵是 KNUMH+KOPOS，同一個條件記錄有多個項目時取第一個。
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_PurchasingCondA017 AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.PurchasingCondA017;

    WITH kp AS (
        SELECT KNUMH, KBETR, KONWA, KPEIN, KMEIN, LOEVM_KO,
               ROW_NUMBER() OVER (PARTITION BY KNUMH ORDER BY KOPOS) AS rn
        FROM dbo.KONP
    )
    INSERT INTO mst.PurchasingCondA017 (
        Vendor, Material, PurchOrg, Plant, InfoCategory, ConditionType, ValidFrom, ValidTo,
        ConditionRecord, ConditionPrice, Currency, PriceUnit, OrderUom, CreatedOn, CreatedBy,
        DeletionInd)
    SELECT
        ISNULL(a.LIFNR, ''), ISNULL(a.MATNR, ''), ISNULL(a.EKORG, ''), ISNULL(a.WERKS, ''),
        ISNULL(a.ESOKZ, ''), ISNULL(a.KSCHL, ''), a.DATAB, a.DATBI,
        a.KNUMH, kp.KBETR, kp.KONWA, kp.KPEIN, kp.KMEIN, h.ERDAT, h.ERNAM,
        kp.LOEVM_KO
    FROM dbo.A017 a
    LEFT JOIN kp         ON kp.KNUMH = a.KNUMH AND kp.rn = 1
    LEFT JOIN dbo.KONH h ON h.KNUMH = a.KNUMH;

    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE etl.Load_PurchasingCondA018 AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE mst.PurchasingCondA018;

    WITH kp AS (
        SELECT KNUMH, KBETR, KONWA, KPEIN, KMEIN, LOEVM_KO,
               ROW_NUMBER() OVER (PARTITION BY KNUMH ORDER BY KOPOS) AS rn
        FROM dbo.KONP
    )
    INSERT INTO mst.PurchasingCondA018 (
        Vendor, Material, PurchOrg, InfoCategory, ConditionType, ValidFrom, ValidTo,
        ConditionRecord, ConditionPrice, Currency, PriceUnit, OrderUom, CreatedOn, CreatedBy,
        DeletionInd)
    SELECT
        ISNULL(a.LIFNR, ''), ISNULL(a.MATNR, ''), ISNULL(a.EKORG, ''),
        ISNULL(a.ESOKZ, ''), ISNULL(a.KSCHL, ''), a.DATAB, a.DATBI,
        a.KNUMH, kp.KBETR, kp.KONWA, kp.KPEIN, kp.KMEIN, h.ERDAT, h.ERNAM,
        kp.LOEVM_KO
    FROM dbo.A018 a
    LEFT JOIN kp         ON kp.KNUMH = a.KNUMH AND kp.rn = 1
    LEFT JOIN dbo.KONH h ON h.KNUMH = a.KNUMH;

    COMMIT;
END;
GO

-- ======================================================================
-- inv.MaterialMovement：全部異動類型
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_MaterialMovement AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE inv.MaterialMovement;

    INSERT INTO inv.MaterialMovement (
        MaterialDoc, MaterialDocYear, MaterialDocItem, PostingDate, DocumentDate, EnteredBy,
        RefDoc, MovementType, Material, MaterialDesc, MaterialGroup, Plant, StorLoc, Batch,
        CompanyCode, Quantity, DebitCreditInd, BaseUom, LocalAmount, Vendor, VendorName,
        PoNumber, PoItem, CostCenter, GlAccount, ProductionOrder, Customer, FiscalYear)
    SELECT
        h.MBLNR, h.MJAHR, s.ZEILE, h.BUDAT, h.BLDAT, h.USNAM,
        h.XBLNR, s.BWART, s.MATNR, t.MAKTX, m.MATKL, s.WERKS, s.LGORT, s.CHARG,
        s.BUKRS, s.MENGE, s.SHKZG, s.MEINS, s.DMBTR, k.LIFNR, v.NAME1,
        s.EBELN, s.EBELP, s.KOSTL, s.SAKTO, s.AUFNR, s.KUNNR, h.MJAHR
    FROM dbo.MKPF h
    JOIN dbo.MSEG s      ON s.MBLNR = h.MBLNR AND s.MJAHR = h.MJAHR
    LEFT JOIN dbo.MARA m ON m.MATNR = s.MATNR
    LEFT JOIN dbo.EKKO k ON k.EBELN = s.EBELN
    LEFT JOIN dbo.LFA1 v ON v.LIFNR = k.LIFNR
    LEFT JOIN (SELECT MATNR, MAX(MAKTX) AS MAKTX FROM dbo.MAKT
               WHERE SPRAS IN ('M', 'ZF') GROUP BY MATNR) t
                         ON t.MATNR = s.MATNR;

    COMMIT;
END;
GO

-- ======================================================================
-- inv.InventoryBalance：每次執行就是一次快照
-- MBEW 是工廠層級（評價範圍 BWKEY = 工廠），StockValue 同工廠的每個儲位都一樣，
-- 不能直接加總。BWTAR 不空的是分割評價的子列，排除。
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_InventoryBalance AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE inv.InventoryBalance;

    INSERT INTO inv.InventoryBalance (
        Material, Plant, StorLoc, MaterialDesc, MaterialGroup, BaseUom, StockQty,
        QualityStock, BlockedStock, TransferStock, StockValue, StandardPrice, MovingAvgPrice,
        PriceUnit, PriceControl, SafetyStock, ReorderPoint, MaxStockLevel, MrpType,
        MrpController, ProcurementType, Planner, AbcIndicator, SnapshotDate)
    SELECT
        d.MATNR, d.WERKS, d.LGORT, t.MAKTX, m.MATKL, m.MEINS, d.LABST,
        d.INSME, d.SPEME, d.UMLME, b.SALK3, b.STPRS, b.VERPR,
        b.PEINH, b.VPRSV, c.EISBE, c.MINBE, c.MABST, c.DISMM,
        c.DISPO, c.BESKZ, NULL, c.MAABC, CAST(GETDATE() AS date)
    FROM dbo.MARD d
    LEFT JOIN dbo.MARC c ON c.MATNR = d.MATNR AND c.WERKS = d.WERKS
    LEFT JOIN dbo.MARA m ON m.MATNR = d.MATNR
    LEFT JOIN dbo.MBEW b ON b.MATNR = d.MATNR AND b.BWKEY = d.WERKS AND ISNULL(b.BWTAR, '') = ''
    LEFT JOIN (SELECT MATNR, MAX(MAKTX) AS MAKTX FROM dbo.MAKT
               WHERE SPRAS IN ('M', 'ZF') GROUP BY MATNR) t
                         ON t.MATNR = d.MATNR;

    -- Planner 要另外下載 T024D（MRP 控制員主檔）。還沒下載就先留 NULL，
    -- 不讓整張表因為一個選用欄位失敗。用動態 SQL 是因為表不存在時靜態寫法會在執行期報錯。
    IF OBJECT_ID(N'dbo.T024D', N'U') IS NOT NULL
        EXEC (N'UPDATE b SET Planner = m.DSNAM
                FROM inv.InventoryBalance b
                JOIN dbo.T024D m ON m.WERKS = b.Plant AND m.DISPO = b.MrpController;');

    COMMIT;
END;
GO

-- ======================================================================
-- fin.AccountsPayable：只留供應商行
-- 供應商行本身不帶 PO 號，PO 號在同一張傳票的 GR/IR 行上，從那裡帶過來。
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.Load_AccountsPayable AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    TRUNCATE TABLE fin.AccountsPayable;

    WITH po AS (
        SELECT BUKRS, BELNR, GJAHR, EBELN, EBELP,
               ROW_NUMBER() OVER (PARTITION BY BUKRS, BELNR, GJAHR ORDER BY BUZEI) AS rn
        FROM dbo.BSEG
        WHERE ISNULL(EBELN, '') <> ''
    )
    INSERT INTO fin.AccountsPayable (
        CompanyCode, AccountingDoc, FiscalYear, LineItem, DocumentType, PostingDate,
        DocumentDate, EntryDate, CreatedBy, Vendor, VendorName, ReferenceDoc, Assignment,
        ItemText, GlAccount, CostCenter, Currency, DocAmount, LocalAmount, DebitCreditInd,
        PaymentTerms, BaselineDate, PaymentMethod, PaymentBlock, ClearingDoc, ClearingDate,
        PoNumber, PoItem)
    SELECT
        h.BUKRS, h.BELNR, h.GJAHR, s.BUZEI, h.BLART, h.BUDAT,
        h.BLDAT, h.CPUDT, h.USNAM, s.LIFNR, v.NAME1, h.XBLNR, s.ZUONR,
        s.SGTXT, s.HKONT, s.KOSTL, h.WAERS, s.WRBTR, s.DMBTR, s.SHKZG,
        s.ZTERM, s.ZFBDT, s.ZLSCH, s.ZLSPR, s.AUGBL, s.AUGDT,
        COALESCE(NULLIF(s.EBELN, ''), po.EBELN),
        IIF(ISNULL(s.EBELN, '') <> '', s.EBELP, po.EBELP)
    FROM dbo.BKPF h
    JOIN dbo.BSEG s      ON s.BUKRS = h.BUKRS AND s.BELNR = h.BELNR AND s.GJAHR = h.GJAHR
    LEFT JOIN dbo.LFA1 v ON v.LIFNR = s.LIFNR
    LEFT JOIN po         ON po.BUKRS = s.BUKRS AND po.BELNR = s.BELNR AND po.GJAHR = s.GJAHR
                        AND po.rn = 1
    WHERE s.KOART = 'K';

    COMMIT;
END;
GO

-- ======================================================================
-- etl.LoadAll：照優先順序全部跑一次。一張失敗不影響其他張，最後列出結果。
-- ======================================================================
CREATE OR ALTER PROCEDURE etl.LoadAll AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @steps TABLE (seq int IDENTITY, proc_name sysname, target sysname);
    INSERT @steps (proc_name, target) VALUES
        ('etl.Load_Vendor',               'mst.Vendor'),
        ('etl.Load_VendorCompany',        'mst.VendorCompany'),
        ('etl.Load_VendorPurchOrg',       'mst.VendorPurchOrg'),
        ('etl.Load_Material',             'mst.Material'),
        ('etl.Load_PurchaseOrderDetail',  'prc.PurchaseOrderDetail'),
        ('etl.Load_PurchaseRequisition',  'prc.PurchaseRequisition'),
        ('etl.Load_GoodsReceipt',         'prc.GoodsReceipt'),
        ('etl.Load_VendorChangeHistory',  'mst.VendorChangeHistory'),
        ('etl.Load_PurchasingInfoRecord', 'mst.PurchasingInfoRecord'),
        ('etl.Load_PurchasingCondA017',   'mst.PurchasingCondA017'),
        ('etl.Load_PurchasingCondA018',   'mst.PurchasingCondA018'),
        ('etl.Load_AccountsPayable',      'fin.AccountsPayable'),
        ('etl.Load_MaterialMovement',     'inv.MaterialMovement'),
        ('etl.Load_InventoryBalance',     'inv.InventoryBalance');

    DECLARE @result TABLE (seq int, target sysname, rows_loaded bigint NULL,
                           seconds int, error nvarchar(4000) NULL);
    DECLARE @i int = 1, @n int = (SELECT COUNT(*) FROM @steps),
            @proc sysname, @target sysname, @t0 datetime2, @rows bigint, @sql nvarchar(400);

    WHILE @i <= @n
    BEGIN
        SELECT @proc = proc_name, @target = target FROM @steps WHERE seq = @i;
        SET @t0 = SYSDATETIME();
        BEGIN TRY
            EXEC @proc;
            SET @sql = N'SELECT @r = COUNT_BIG(*) FROM ' + @target;
            EXEC sp_executesql @sql, N'@r bigint OUTPUT', @r = @rows OUTPUT;
            INSERT @result VALUES (@i, @target, @rows, DATEDIFF(second, @t0, SYSDATETIME()), NULL);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            INSERT @result VALUES (@i, @target, NULL, DATEDIFF(second, @t0, SYSDATETIME()),
                                   CONCAT(N'[', ERROR_NUMBER(), N'] ', ERROR_MESSAGE()));
        END CATCH;
        SET @i += 1;
    END;

    SELECT target AS [目標表], rows_loaded AS [筆數], seconds AS [秒],
           ISNULL(error, N'OK') AS [結果]
    FROM @result ORDER BY seq;
END;
GO
