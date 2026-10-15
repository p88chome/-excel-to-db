-- 由 etl/gen_ddl.py 從規格表產生，不要手改。
-- 來源：UMC採購風險儀表板_資料移轉需求規格及欄位屬性_20261015_v2.3.xlsx

-- 注意：會 DROP 掉同名的表重建，表裡的資料會不見。

IF SCHEMA_ID(N'fin') IS NULL EXEC(N'CREATE SCHEMA fin');
GO

IF SCHEMA_ID(N'inv') IS NULL EXEC(N'CREATE SCHEMA inv');
GO

IF SCHEMA_ID(N'mst') IS NULL EXEC(N'CREATE SCHEMA mst');
GO

IF SCHEMA_ID(N'prc') IS NULL EXEC(N'CREATE SCHEMA prc');
GO

IF SCHEMA_ID(N'etl') IS NULL EXEC(N'CREATE SCHEMA etl');
GO

IF OBJECT_ID(N'prc.PurchaseOrderDetail', N'U') IS NOT NULL DROP TABLE prc.PurchaseOrderDetail;
CREATE TABLE prc.PurchaseOrderDetail (
    [PoNumber]      VARCHAR(10) NOT NULL,
    [PoItem]        VARCHAR(5) NOT NULL,
    [PoType]        VARCHAR(4) NULL,
    [CompanyCode]   VARCHAR(4) NULL,
    [PurchOrg]      VARCHAR(4) NULL,
    [PurchGroup]    VARCHAR(3) NULL,
    [PoDate]        DATE NULL,
    [Vendor]        VARCHAR(10) NULL,
    [PaymentTerm]   VARCHAR(4) NULL,
    [VendorName]    NVARCHAR(80) NULL,
    [VendorCountry] VARCHAR(3) NULL,
    [Material]      VARCHAR(18) NULL,
    [MaterialDesc]  NVARCHAR(40) NULL,
    [MaterialGroup] VARCHAR(9) NULL,
    [Plant]         VARCHAR(4) NULL,
    [StorLoc]       VARCHAR(4) NULL,
    [GlAccount]     VARCHAR(10) NULL,
    [CostCenter]    VARCHAR(10) NULL,
    [IntOrder]      VARCHAR(12) NULL,
    [OrderQty]      DECIMAL(19,4) NULL,
    [OrderUom]      VARCHAR(3) NULL,
    [NetPrice]      DECIMAL(19,4) NULL,
    [PriceUnit]     DECIMAL(19,4) NULL,
    [NetValue]      DECIMAL(19,4) NULL,
    [Currency]      VARCHAR(5) NULL,
    [ExchangeRate]  DECIMAL(19,4) NULL,
    [DelivDate]     DATE NULL,
    [DelivComplInd] VARCHAR(1) NULL,
    [GrInd]         VARCHAR(1) NULL,
    [IrInd]         VARCHAR(1) NULL,
    [DeletionInd]   VARCHAR(1) NULL,
    [GrQty]         DECIMAL(19,4) NULL,
    [GrAmount]      DECIMAL(19,4) NULL,
    [LastGrDate]    DATE NULL,
    [IrQty]         DECIMAL(19,4) NULL,
    [IrAmount]      DECIMAL(19,4) NULL,
    [LastIrDate]    DATE NULL,
    [PrNumber]      VARCHAR(10) NULL,
    [PrItem]        VARCHAR(5) NULL,
    [Contract]      VARCHAR(10) NULL,
    [ContractItem]  VARCHAR(5) NULL,
    CONSTRAINT PK_prc_PurchaseOrderDetail PRIMARY KEY ([PoNumber], [PoItem])
);
GO

IF OBJECT_ID(N'prc.PurchaseRequisition', N'U') IS NOT NULL DROP TABLE prc.PurchaseRequisition;
CREATE TABLE prc.PurchaseRequisition (
    [PrNumber]        VARCHAR(10) NOT NULL,
    [PrItem]          VARCHAR(5) NOT NULL,
    [PrType]          VARCHAR(4) NULL,
    [PrDate]          DATE NULL,
    [CreatedBy]       VARCHAR(12) NULL,
    [Material]        VARCHAR(18) NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   VARCHAR(9) NULL,
    [Plant]           VARCHAR(4) NULL,
    [StorLoc]         VARCHAR(4) NULL,
    [ReqQty]          DECIMAL(19,4) NULL,
    [Uom]             VARCHAR(3) NULL,
    [DelivDate]       DATE NULL,
    [ValPrice]        DECIMAL(19,4) NULL,
    [Currency]        VARCHAR(5) NULL,
    [PurchGroup]      VARCHAR(3) NULL,
    [PurchOrg]        VARCHAR(4) NULL,
    [Vendor]          VARCHAR(10) NULL,
    [VendorName]      NVARCHAR(80) NULL,
    [AcctAssCat]      VARCHAR(1) NULL,
    [CostCenter]      VARCHAR(10) NULL,
    [GlAccount]       VARCHAR(10) NULL,
    [ReleaseInd]      VARCHAR(1) NULL,
    [ReleaseStrategy] VARCHAR(2) NULL,
    [PoNumber]        VARCHAR(10) NULL,
    [PoItem]          VARCHAR(5) NULL,
    [PoItemCount]     INT NULL,
    [DeletionInd]     VARCHAR(1) NULL,
    CONSTRAINT PK_prc_PurchaseRequisition PRIMARY KEY ([PrNumber], [PrItem])
);
GO

IF OBJECT_ID(N'prc.GoodsReceipt', N'U') IS NOT NULL DROP TABLE prc.GoodsReceipt;
CREATE TABLE prc.GoodsReceipt (
    [MaterialDoc]     VARCHAR(10) NOT NULL,
    [MaterialDocYear] VARCHAR(4) NOT NULL,
    [MaterialDocItem] VARCHAR(4) NOT NULL,
    [PostingDate]     DATE NULL,
    [DocumentDate]    DATE NULL,
    [EntryDate]       DATE NULL,
    [EnteredBy]       VARCHAR(12) NULL,
    [RefDoc]          VARCHAR(16) NULL,
    [MovementType]    VARCHAR(3) NULL,
    [Material]        VARCHAR(18) NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   VARCHAR(9) NULL,
    [Plant]           VARCHAR(4) NULL,
    [StorLoc]         VARCHAR(4) NULL,
    [Batch]           VARCHAR(10) NULL,
    [CompanyCode]     VARCHAR(4) NULL,
    [Quantity]        DECIMAL(19,4) NULL,
    [DebitCreditInd]  VARCHAR(1) NULL,
    [BaseUom]         VARCHAR(3) NULL,
    [LocalAmount]     DECIMAL(19,4) NULL,
    [Currency]        VARCHAR(5) NULL,
    [PoNumber]        VARCHAR(10) NULL,
    [PoItem]          VARCHAR(5) NULL,
    [PoDate]          DATE NULL,
    [Vendor]          VARCHAR(10) NULL,
    [VendorName]      NVARCHAR(80) NULL,
    [PurchGroup]      VARCHAR(3) NULL,
    [CostCenter]      VARCHAR(10) NULL,
    [GlAccount]       VARCHAR(10) NULL,
    [ItemText]        NVARCHAR(50) NULL,
    [FiscalYear]      VARCHAR(4) NULL,
    CONSTRAINT PK_prc_GoodsReceipt PRIMARY KEY ([MaterialDoc], [MaterialDocYear], [MaterialDocItem])
);
GO

IF OBJECT_ID(N'mst.VendorChangeHistory', N'U') IS NOT NULL DROP TABLE mst.VendorChangeHistory;
CREATE TABLE mst.VendorChangeHistory (
    [Vendor]          VARCHAR(10) NOT NULL,
    [ChangeNumber]    VARCHAR(10) NOT NULL,
    [ChangeDate]      DATE NULL,
    [ChangeTime]      TIME NULL,
    [ChangedBy]       VARCHAR(12) NULL,
    [TransactionCode] VARCHAR(20) NULL,
    [TableName]       VARCHAR(30) NOT NULL,
    [TableKey]        VARCHAR(70) NOT NULL,
    [FieldName]       VARCHAR(30) NOT NULL,
    [OldValue]        NVARCHAR(255) NULL,
    [NewValue]        NVARCHAR(255) NULL,
    [ChangeInd]       VARCHAR(1) NULL,
    CONSTRAINT PK_mst_VendorChangeHistory PRIMARY KEY ([Vendor], [ChangeNumber], [TableName], [TableKey], [FieldName])
);
GO

IF OBJECT_ID(N'mst.Vendor', N'U') IS NOT NULL DROP TABLE mst.Vendor;
CREATE TABLE mst.Vendor (
    [Vendor]              VARCHAR(10) NOT NULL,
    [VendorName]          NVARCHAR(80) NULL,
    [VendorName2]         NVARCHAR(80) NULL,
    [SearchTerm]          NVARCHAR(20) NULL,
    [Country]             VARCHAR(3) NULL,
    [Region]              VARCHAR(3) NULL,
    [City]                NVARCHAR(35) NULL,
    [PostalCode]          VARCHAR(10) NULL,
    [Address]             NVARCHAR(60) NULL,
    [Language]            VARCHAR(2) NULL,
    [Phone]               VARCHAR(30) NULL,
    [Fax]                 VARCHAR(30) NULL,
    [TaxNumber]           VARCHAR(20) NULL,
    [VendorAccountGroup]  VARCHAR(4) NULL,
    [CreatedOn]           DATE NULL,
    [CreatedBy]           VARCHAR(12) NULL,
    [DeletionInd]         VARCHAR(1) NULL,
    [CentralPostingBlock] VARCHAR(1) NULL,
    [CentralPurchBlock]   VARCHAR(1) NULL,
    CONSTRAINT PK_mst_Vendor PRIMARY KEY ([Vendor])
);
GO

IF OBJECT_ID(N'mst.VendorCompany', N'U') IS NOT NULL DROP TABLE mst.VendorCompany;
CREATE TABLE mst.VendorCompany (
    [Vendor]        VARCHAR(10) NOT NULL,
    [CompanyCode]   VARCHAR(4) NOT NULL,
    [VendorName]    NVARCHAR(80) NULL,
    [PaymentTerms]  VARCHAR(4) NULL,
    [PaymentMethod] VARCHAR(10) NULL,
    [PaymentBlock]  VARCHAR(1) NULL,
    [PostingBlock]  VARCHAR(1) NULL,
    [DeletionInd]   VARCHAR(1) NULL,
    [CreatedOn]     DATE NULL,
    [CreatedBy]     VARCHAR(12) NULL,
    CONSTRAINT PK_mst_VendorCompany PRIMARY KEY ([Vendor], [CompanyCode])
);
GO

IF OBJECT_ID(N'mst.VendorPurchOrg', N'U') IS NOT NULL DROP TABLE mst.VendorPurchOrg;
CREATE TABLE mst.VendorPurchOrg (
    [Vendor]          VARCHAR(10) NOT NULL,
    [PurchOrg]        VARCHAR(4) NOT NULL,
    [VendorName]      NVARCHAR(80) NULL,
    [PurchasingBlock] VARCHAR(1) NULL,
    [Incoterms]       VARCHAR(3) NULL,
    [OrderCurrency]   VARCHAR(5) NULL,
    [SalesPerson]     NVARCHAR(30) NULL,
    [PaymentTerms]    VARCHAR(4) NULL,
    [DeletionInd]     VARCHAR(1) NULL,
    [CreatedOn]       DATE NULL,
    [CreatedBy]       VARCHAR(12) NULL,
    CONSTRAINT PK_mst_VendorPurchOrg PRIMARY KEY ([Vendor], [PurchOrg])
);
GO

IF OBJECT_ID(N'mst.Material', N'U') IS NOT NULL DROP TABLE mst.Material;
CREATE TABLE mst.Material (
    [Material]           VARCHAR(18) NOT NULL,
    [MaterialDesc]       NVARCHAR(40) NULL,
    [MaterialType]       VARCHAR(4) NULL,
    [MaterialGroup]      VARCHAR(9) NULL,
    [BaseUom]            VARCHAR(3) NULL,
    [IndustrySector]     VARCHAR(1) NULL,
    [Division]           VARCHAR(2) NULL,
    [MaterialStatus]     VARCHAR(2) NULL,
    [GrossWeight]        DECIMAL(19,4) NULL,
    [NetWeight]          DECIMAL(19,4) NULL,
    [WeightUnit]         VARCHAR(3) NULL,
    [Volume]             DECIMAL(19,4) NULL,
    [VolumeUnit]         VARCHAR(3) NULL,
    [SizeDimension]      VARCHAR(32) NULL,
    [BasicMaterial]      VARCHAR(18) NULL,
    [ManufacturerPartNo] VARCHAR(40) NULL,
    [CreatedOn]          DATE NULL,
    [CreatedBy]          VARCHAR(12) NULL,
    [DeletionFlag]       VARCHAR(1) NULL,
    CONSTRAINT PK_mst_Material PRIMARY KEY ([Material])
);
GO

IF OBJECT_ID(N'mst.PurchasingInfoRecord', N'U') IS NOT NULL DROP TABLE mst.PurchasingInfoRecord;
CREATE TABLE mst.PurchasingInfoRecord (
    [Vendor]           VARCHAR(10) NOT NULL,
    [Material]         VARCHAR(18) NOT NULL,
    [PurchOrg]         VARCHAR(4) NOT NULL,
    [InfoCategory]     VARCHAR(1) NOT NULL,
    [InfoRecord]       VARCHAR(10) NULL,
    [VendorMaterial]   NVARCHAR(35) NULL,
    [MaterialDesc]     NVARCHAR(40) NULL,
    [VendorName]       NVARCHAR(80) NULL,
    [PurchGroup]       VARCHAR(3) NULL,
    [Plant]            VARCHAR(4) NOT NULL,
    [PlannedDelivTime] INT NULL,
    [StandardQty]      DECIMAL(19,4) NULL,
    [OrderCurrency]    VARCHAR(5) NULL,
    [Incoterms]        VARCHAR(3) NULL,
    [ConfirmationCtrl] VARCHAR(4) NULL,
    [DeletionInd]      VARCHAR(1) NULL,
    [CreatedOn]        DATE NULL,
    [CreatedBy]        VARCHAR(12) NULL,
    CONSTRAINT PK_mst_PurchasingInfoRecord PRIMARY KEY ([Vendor], [Material], [PurchOrg], [InfoCategory], [Plant])
);
GO

IF OBJECT_ID(N'mst.PurchasingCondA017', N'U') IS NOT NULL DROP TABLE mst.PurchasingCondA017;
CREATE TABLE mst.PurchasingCondA017 (
    [Vendor]          VARCHAR(10) NOT NULL,
    [Material]        VARCHAR(18) NOT NULL,
    [PurchOrg]        VARCHAR(4) NOT NULL,
    [Plant]           VARCHAR(4) NOT NULL,
    [InfoCategory]    VARCHAR(1) NOT NULL,
    [ConditionType]   VARCHAR(4) NOT NULL,
    [ValidFrom]       DATE NOT NULL,
    [ValidTo]         DATE NULL,
    [ConditionRecord] VARCHAR(10) NULL,
    [ConditionPrice]  DECIMAL(19,4) NULL,
    [Currency]        VARCHAR(5) NULL,
    [PriceUnit]       DECIMAL(19,4) NULL,
    [OrderUom]        VARCHAR(3) NULL,
    [CreatedOn]       DATE NULL,
    [CreatedBy]       VARCHAR(12) NULL,
    [DeletionInd]     VARCHAR(1) NULL,
    CONSTRAINT PK_mst_PurchasingCondA017 PRIMARY KEY ([Vendor], [Material], [PurchOrg], [Plant], [InfoCategory], [ConditionType], [ValidFrom])
);
GO

IF OBJECT_ID(N'mst.PurchasingCondA018', N'U') IS NOT NULL DROP TABLE mst.PurchasingCondA018;
CREATE TABLE mst.PurchasingCondA018 (
    [Vendor]          VARCHAR(10) NOT NULL,
    [Material]        VARCHAR(18) NOT NULL,
    [PurchOrg]        VARCHAR(4) NOT NULL,
    [InfoCategory]    VARCHAR(1) NOT NULL,
    [ConditionType]   VARCHAR(4) NOT NULL,
    [ValidFrom]       DATE NOT NULL,
    [ValidTo]         DATE NULL,
    [ConditionRecord] VARCHAR(10) NULL,
    [ConditionPrice]  DECIMAL(19,4) NULL,
    [Currency]        VARCHAR(5) NULL,
    [PriceUnit]       DECIMAL(19,4) NULL,
    [OrderUom]        VARCHAR(3) NULL,
    [CreatedOn]       DATE NULL,
    [CreatedBy]       VARCHAR(12) NULL,
    [DeletionInd]     VARCHAR(1) NULL,
    CONSTRAINT PK_mst_PurchasingCondA018 PRIMARY KEY ([Vendor], [Material], [PurchOrg], [InfoCategory], [ConditionType], [ValidFrom])
);
GO

IF OBJECT_ID(N'inv.MaterialMovement', N'U') IS NOT NULL DROP TABLE inv.MaterialMovement;
CREATE TABLE inv.MaterialMovement (
    [MaterialDoc]     VARCHAR(10) NOT NULL,
    [MaterialDocYear] VARCHAR(4) NOT NULL,
    [MaterialDocItem] VARCHAR(4) NOT NULL,
    [PostingDate]     DATE NULL,
    [DocumentDate]    DATE NULL,
    [EnteredBy]       VARCHAR(12) NULL,
    [RefDoc]          VARCHAR(16) NULL,
    [MovementType]    VARCHAR(3) NULL,
    [Material]        VARCHAR(18) NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   VARCHAR(9) NULL,
    [Plant]           VARCHAR(4) NULL,
    [StorLoc]         VARCHAR(4) NULL,
    [Batch]           VARCHAR(10) NULL,
    [CompanyCode]     VARCHAR(4) NULL,
    [Quantity]        DECIMAL(19,4) NULL,
    [DebitCreditInd]  VARCHAR(1) NULL,
    [BaseUom]         VARCHAR(3) NULL,
    [LocalAmount]     DECIMAL(19,4) NULL,
    [Vendor]          VARCHAR(10) NULL,
    [VendorName]      NVARCHAR(80) NULL,
    [PoNumber]        VARCHAR(10) NULL,
    [PoItem]          VARCHAR(5) NULL,
    [CostCenter]      VARCHAR(10) NULL,
    [GlAccount]       VARCHAR(10) NULL,
    [ProductionOrder] VARCHAR(12) NULL,
    [Customer]        VARCHAR(10) NULL,
    [FiscalYear]      VARCHAR(4) NULL,
    CONSTRAINT PK_inv_MaterialMovement PRIMARY KEY ([MaterialDoc], [MaterialDocYear], [MaterialDocItem])
);
GO

IF OBJECT_ID(N'inv.InventoryBalance', N'U') IS NOT NULL DROP TABLE inv.InventoryBalance;
CREATE TABLE inv.InventoryBalance (
    [Material]        VARCHAR(18) NOT NULL,
    [Plant]           VARCHAR(4) NOT NULL,
    [StorLoc]         VARCHAR(4) NOT NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   VARCHAR(9) NULL,
    [BaseUom]         VARCHAR(3) NULL,
    [StockQty]        DECIMAL(19,4) NULL,
    [QualityStock]    DECIMAL(19,4) NULL,
    [BlockedStock]    DECIMAL(19,4) NULL,
    [TransferStock]   DECIMAL(19,4) NULL,
    [StockValue]      DECIMAL(19,4) NULL,
    [StandardPrice]   DECIMAL(19,4) NULL,
    [MovingAvgPrice]  DECIMAL(19,4) NULL,
    [PriceUnit]       DECIMAL(19,4) NULL,
    [PriceControl]    VARCHAR(1) NULL,
    [SafetyStock]     DECIMAL(19,4) NULL,
    [ReorderPoint]    DECIMAL(19,4) NULL,
    [MaxStockLevel]   DECIMAL(19,4) NULL,
    [MrpType]         VARCHAR(4) NULL,
    [MrpController]   VARCHAR(3) NULL,
    [ProcurementType] VARCHAR(1) NULL,
    [Planner]         NVARCHAR(20) NULL,
    [AbcIndicator]    VARCHAR(1) NULL,
    [SnapshotDate]    DATE NULL,
    CONSTRAINT PK_inv_InventoryBalance PRIMARY KEY ([Material], [Plant], [StorLoc])
);
GO

IF OBJECT_ID(N'fin.AccountsPayable', N'U') IS NOT NULL DROP TABLE fin.AccountsPayable;
CREATE TABLE fin.AccountsPayable (
    [CompanyCode]    VARCHAR(4) NOT NULL,
    [AccountingDoc]  VARCHAR(10) NOT NULL,
    [FiscalYear]     VARCHAR(4) NOT NULL,
    [LineItem]       VARCHAR(3) NOT NULL,
    [DocumentType]   VARCHAR(2) NULL,
    [PostingDate]    DATE NULL,
    [DocumentDate]   DATE NULL,
    [EntryDate]      DATE NULL,
    [CreatedBy]      VARCHAR(12) NULL,
    [Vendor]         VARCHAR(10) NULL,
    [VendorName]     NVARCHAR(80) NULL,
    [ReferenceDoc]   VARCHAR(16) NULL,
    [Assignment]     VARCHAR(18) NULL,
    [ItemText]       NVARCHAR(50) NULL,
    [GlAccount]      VARCHAR(10) NULL,
    [CostCenter]     VARCHAR(10) NULL,
    [Currency]       VARCHAR(5) NULL,
    [DocAmount]      DECIMAL(19,4) NULL,
    [LocalAmount]    DECIMAL(19,4) NULL,
    [DebitCreditInd] VARCHAR(1) NULL,
    [PaymentTerms]   VARCHAR(4) NULL,
    [BaselineDate]   DATE NULL,
    [PaymentMethod]  VARCHAR(10) NULL,
    [PaymentBlock]   VARCHAR(1) NULL,
    [ClearingDoc]    VARCHAR(10) NULL,
    [ClearingDate]   DATE NULL,
    [PoNumber]       VARCHAR(10) NULL,
    [PoItem]         VARCHAR(5) NULL,
    CONSTRAINT PK_fin_AccountsPayable PRIMARY KEY ([CompanyCode], [AccountingDoc], [FiscalYear], [LineItem])
);
GO

