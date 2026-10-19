-- 由 etl/gen_ddl.py 從規格表產生，不要手改。

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
    [PoNumber]      NVARCHAR(10) NOT NULL,
    [PoItem]        NVARCHAR(5) NOT NULL,
    [PoType]        NVARCHAR(4) NULL,
    [CompanyCode]   NVARCHAR(4) NULL,
    [PurchOrg]      NVARCHAR(4) NULL,
    [PurchGroup]    NVARCHAR(3) NULL,
    [PoDate]        DATE NULL,
    [Vendor]        NVARCHAR(10) NULL,
    [PaymentTerm]   NVARCHAR(4) NULL,
    [VendorName]    NVARCHAR(80) NULL,
    [VendorCountry] NVARCHAR(3) NULL,
    [Material]      NVARCHAR(18) NULL,
    [MaterialDesc]  NVARCHAR(40) NULL,
    [MaterialGroup] NVARCHAR(9) NULL,
    [Plant]         NVARCHAR(4) NULL,
    [StorLoc]       NVARCHAR(4) NULL,
    [GlAccount]     NVARCHAR(10) NULL,
    [CostCenter]    NVARCHAR(10) NULL,
    [IntOrder]      NVARCHAR(12) NULL,
    [OrderQty]      DECIMAL(19,4) NULL,
    [OrderUom]      NVARCHAR(3) NULL,
    [NetPrice]      DECIMAL(19,4) NULL,
    [PriceUnit]     DECIMAL(19,4) NULL,
    [NetValue]      DECIMAL(19,4) NULL,
    [Currency]      NVARCHAR(5) NULL,
    [ExchangeRate]  DECIMAL(19,5) NULL,
    [DelivDate]     DATE NULL,
    [DelivComplInd] NVARCHAR(1) NULL,
    [GrInd]         NVARCHAR(1) NULL,
    [IrInd]         NVARCHAR(1) NULL,
    [DeletionInd]   NVARCHAR(1) NULL,
    [GrQty]         DECIMAL(19,4) NULL,
    [GrAmount]      DECIMAL(19,4) NULL,
    [LastGrDate]    DATE NULL,
    [IrQty]         DECIMAL(19,4) NULL,
    [IrAmount]      DECIMAL(19,4) NULL,
    [LastIrDate]    DATE NULL,
    [PrNumber]      NVARCHAR(10) NULL,
    [PrItem]        NVARCHAR(5) NULL,
    [Contract]      NVARCHAR(10) NULL,
    [ContractItem]  NVARCHAR(5) NULL,
    CONSTRAINT PK_prc_PurchaseOrderDetail PRIMARY KEY ([PoNumber], [PoItem])
);
GO

IF OBJECT_ID(N'prc.PurchaseRequisition', N'U') IS NOT NULL DROP TABLE prc.PurchaseRequisition;
CREATE TABLE prc.PurchaseRequisition (
    [PrNumber]        NVARCHAR(10) NOT NULL,
    [PrItem]          NVARCHAR(5) NOT NULL,
    [PrType]          NVARCHAR(4) NULL,
    [PrDate]          DATE NULL,
    [CreatedBy]       NVARCHAR(12) NULL,
    [Material]        NVARCHAR(18) NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   NVARCHAR(9) NULL,
    [Plant]           NVARCHAR(4) NULL,
    [StorLoc]         NVARCHAR(4) NULL,
    [ReqQty]          DECIMAL(19,4) NULL,
    [Uom]             NVARCHAR(3) NULL,
    [DelivDate]       DATE NULL,
    [ValPrice]        DECIMAL(19,4) NULL,
    [Currency]        NVARCHAR(5) NULL,
    [PurchGroup]      NVARCHAR(3) NULL,
    [PurchOrg]        NVARCHAR(4) NULL,
    [Vendor]          NVARCHAR(10) NULL,
    [VendorName]      NVARCHAR(80) NULL,
    [AcctAssCat]      NVARCHAR(1) NULL,
    [CostCenter]      NVARCHAR(10) NULL,
    [GlAccount]       NVARCHAR(10) NULL,
    [ReleaseInd]      NVARCHAR(1) NULL,
    [ReleaseStrategy] NVARCHAR(2) NULL,
    [PoNumber]        NVARCHAR(10) NULL,
    [PoItem]          NVARCHAR(5) NULL,
    [PoItemCount]     INT NULL,
    [DeletionInd]     NVARCHAR(1) NULL,
    CONSTRAINT PK_prc_PurchaseRequisition PRIMARY KEY ([PrNumber], [PrItem])
);
GO

IF OBJECT_ID(N'prc.GoodsReceipt', N'U') IS NOT NULL DROP TABLE prc.GoodsReceipt;
CREATE TABLE prc.GoodsReceipt (
    [MaterialDoc]     NVARCHAR(10) NOT NULL,
    [MaterialDocYear] NVARCHAR(4) NOT NULL,
    [MaterialDocItem] NVARCHAR(4) NOT NULL,
    [PostingDate]     DATE NULL,
    [DocumentDate]    DATE NULL,
    [EntryDate]       DATE NULL,
    [EnteredBy]       NVARCHAR(12) NULL,
    [RefDoc]          NVARCHAR(16) NULL,
    [MovementType]    NVARCHAR(3) NULL,
    [Material]        NVARCHAR(18) NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   NVARCHAR(9) NULL,
    [Plant]           NVARCHAR(4) NULL,
    [StorLoc]         NVARCHAR(4) NULL,
    [Batch]           NVARCHAR(10) NULL,
    [CompanyCode]     NVARCHAR(4) NULL,
    [Quantity]        DECIMAL(19,4) NULL,
    [DebitCreditInd]  NVARCHAR(1) NULL,
    [BaseUom]         NVARCHAR(3) NULL,
    [LocalAmount]     DECIMAL(19,4) NULL,
    [Currency]        NVARCHAR(5) NULL,
    [PoNumber]        NVARCHAR(10) NULL,
    [PoItem]          NVARCHAR(5) NULL,
    [PoDate]          DATE NULL,
    [Vendor]          NVARCHAR(10) NULL,
    [VendorName]      NVARCHAR(80) NULL,
    [PurchGroup]      NVARCHAR(3) NULL,
    [CostCenter]      NVARCHAR(10) NULL,
    [GlAccount]       NVARCHAR(10) NULL,
    [ItemText]        NVARCHAR(50) NULL,
    [FiscalYear]      NVARCHAR(4) NULL,
    CONSTRAINT PK_prc_GoodsReceipt PRIMARY KEY ([MaterialDoc], [MaterialDocYear], [MaterialDocItem])
);
GO

IF OBJECT_ID(N'mst.VendorChangeHistory', N'U') IS NOT NULL DROP TABLE mst.VendorChangeHistory;
CREATE TABLE mst.VendorChangeHistory (
    [Vendor]          NVARCHAR(10) NOT NULL,
    [ChangeNumber]    NVARCHAR(10) NOT NULL,
    [ChangeDate]      DATE NULL,
    [ChangeTime]      TIME NULL,
    [ChangedBy]       NVARCHAR(12) NULL,
    [TransactionCode] NVARCHAR(20) NULL,
    [TableName]       NVARCHAR(30) NOT NULL,
    [TableKey]        NVARCHAR(70) NOT NULL,
    [FieldName]       NVARCHAR(30) NOT NULL,
    [OldValue]        NVARCHAR(255) NULL,
    [NewValue]        NVARCHAR(255) NULL,
    [ChangeInd]       NVARCHAR(1) NULL,
    CONSTRAINT PK_mst_VendorChangeHistory PRIMARY KEY ([Vendor], [ChangeNumber], [TableName], [TableKey], [FieldName])
);
GO

IF OBJECT_ID(N'mst.Vendor', N'U') IS NOT NULL DROP TABLE mst.Vendor;
CREATE TABLE mst.Vendor (
    [Vendor]               NVARCHAR(10) NOT NULL,
    [CompanyCode]          NVARCHAR(4) NOT NULL,
    [PurchOrg]             NVARCHAR(4) NOT NULL,
    [VendorName]           NVARCHAR(80) NULL,
    [VendorName2]          NVARCHAR(80) NULL,
    [SearchTerm]           NVARCHAR(20) NULL,
    [Country]              NVARCHAR(3) NULL,
    [Region]               NVARCHAR(3) NULL,
    [City]                 NVARCHAR(35) NULL,
    [PostalCode]           NVARCHAR(10) NULL,
    [Address]              NVARCHAR(60) NULL,
    [Language]             NVARCHAR(2) NULL,
    [Phone]                NVARCHAR(30) NULL,
    [Fax]                  NVARCHAR(30) NULL,
    [TaxNumber]            NVARCHAR(20) NULL,
    [VendorAccountGroup]   NVARCHAR(4) NULL,
    [CreatedOn]            DATE NULL,
    [CreatedBy]            NVARCHAR(12) NULL,
    [PaymentTerms]         NVARCHAR(4) NULL,
    [PurchOrgPaymentTerms] NVARCHAR(4) NULL,
    [PaymentMethod]        NVARCHAR(10) NULL,
    [PaymentBlock]         NVARCHAR(1) NULL,
    [PostingBlock]         NVARCHAR(1) NULL,
    [PurchasingBlock]      NVARCHAR(1) NULL,
    [DeletionInd]          NVARCHAR(1) NULL,
    [CentralPostingBlock]  NVARCHAR(1) NULL,
    [CentralPurchBlock]    NVARCHAR(1) NULL,
    [Incoterms]            NVARCHAR(3) NULL,
    [OrderCurrency]        NVARCHAR(5) NULL,
    [SalesPerson]          NVARCHAR(30) NULL,
    [VendorRowNo]          INT NULL,
    CONSTRAINT PK_mst_Vendor PRIMARY KEY ([Vendor], [CompanyCode], [PurchOrg])
);
GO

IF OBJECT_ID(N'mst.Material', N'U') IS NOT NULL DROP TABLE mst.Material;
CREATE TABLE mst.Material (
    [Material]           NVARCHAR(18) NOT NULL,
    [MaterialDesc]       NVARCHAR(40) NULL,
    [MaterialType]       NVARCHAR(4) NULL,
    [MaterialGroup]      NVARCHAR(9) NULL,
    [BaseUom]            NVARCHAR(3) NULL,
    [IndustrySector]     NVARCHAR(1) NULL,
    [Division]           NVARCHAR(2) NULL,
    [MaterialStatus]     NVARCHAR(2) NULL,
    [GrossWeight]        DECIMAL(19,4) NULL,
    [NetWeight]          DECIMAL(19,4) NULL,
    [WeightUnit]         NVARCHAR(3) NULL,
    [Volume]             DECIMAL(19,4) NULL,
    [VolumeUnit]         NVARCHAR(3) NULL,
    [SizeDimension]      NVARCHAR(32) NULL,
    [BasicMaterial]      NVARCHAR(18) NULL,
    [ManufacturerPartNo] NVARCHAR(40) NULL,
    [CreatedOn]          DATE NULL,
    [CreatedBy]          NVARCHAR(12) NULL,
    [DeletionFlag]       NVARCHAR(1) NULL,
    CONSTRAINT PK_mst_Material PRIMARY KEY ([Material])
);
GO

IF OBJECT_ID(N'mst.PurchasingInfoRecord', N'U') IS NOT NULL DROP TABLE mst.PurchasingInfoRecord;
CREATE TABLE mst.PurchasingInfoRecord (
    [Vendor]           NVARCHAR(10) NOT NULL,
    [Material]         NVARCHAR(18) NOT NULL,
    [PurchOrg]         NVARCHAR(4) NOT NULL,
    [InfoCategory]     NVARCHAR(1) NOT NULL,
    [InfoRecord]       NVARCHAR(10) NULL,
    [VendorMaterial]   NVARCHAR(35) NULL,
    [MaterialDesc]     NVARCHAR(40) NULL,
    [VendorName]       NVARCHAR(80) NULL,
    [PurchGroup]       NVARCHAR(3) NULL,
    [Plant]            NVARCHAR(4) NOT NULL,
    [PlannedDelivTime] INT NULL,
    [StandardQty]      DECIMAL(19,4) NULL,
    [OrderCurrency]    NVARCHAR(5) NULL,
    [Incoterms]        NVARCHAR(3) NULL,
    [ConfirmationCtrl] NVARCHAR(4) NULL,
    [DeletionInd]      NVARCHAR(1) NULL,
    [CreatedOn]        DATE NULL,
    [CreatedBy]        NVARCHAR(12) NULL,
    CONSTRAINT PK_mst_PurchasingInfoRecord PRIMARY KEY ([Vendor], [Material], [PurchOrg], [InfoCategory], [Plant])
);
GO

IF OBJECT_ID(N'mst.PurchasingCondA017', N'U') IS NOT NULL DROP TABLE mst.PurchasingCondA017;
CREATE TABLE mst.PurchasingCondA017 (
    [Vendor]          NVARCHAR(10) NOT NULL,
    [Material]        NVARCHAR(18) NOT NULL,
    [PurchOrg]        NVARCHAR(4) NOT NULL,
    [Plant]           NVARCHAR(4) NOT NULL,
    [InfoCategory]    NVARCHAR(1) NOT NULL,
    [ConditionType]   NVARCHAR(4) NOT NULL,
    [ValidFrom]       DATE NOT NULL,
    [ValidTo]         DATE NULL,
    [ConditionRecord] NVARCHAR(10) NULL,
    [ConditionPrice]  DECIMAL(19,4) NULL,
    [Currency]        NVARCHAR(5) NULL,
    [PriceUnit]       DECIMAL(19,4) NULL,
    [OrderUom]        NVARCHAR(3) NULL,
    [CreatedOn]       DATE NULL,
    [CreatedBy]       NVARCHAR(12) NULL,
    [DeletionInd]     NVARCHAR(1) NULL,
    CONSTRAINT PK_mst_PurchasingCondA017 PRIMARY KEY ([Vendor], [Material], [PurchOrg], [Plant], [InfoCategory], [ConditionType], [ValidFrom])
);
GO

IF OBJECT_ID(N'mst.PurchasingCondA018', N'U') IS NOT NULL DROP TABLE mst.PurchasingCondA018;
CREATE TABLE mst.PurchasingCondA018 (
    [Vendor]          NVARCHAR(10) NOT NULL,
    [Material]        NVARCHAR(18) NOT NULL,
    [PurchOrg]        NVARCHAR(4) NOT NULL,
    [InfoCategory]    NVARCHAR(1) NOT NULL,
    [ConditionType]   NVARCHAR(4) NOT NULL,
    [ValidFrom]       DATE NOT NULL,
    [ValidTo]         DATE NULL,
    [ConditionRecord] NVARCHAR(10) NULL,
    [ConditionPrice]  DECIMAL(19,4) NULL,
    [Currency]        NVARCHAR(5) NULL,
    [PriceUnit]       DECIMAL(19,4) NULL,
    [OrderUom]        NVARCHAR(3) NULL,
    [CreatedOn]       DATE NULL,
    [CreatedBy]       NVARCHAR(12) NULL,
    [DeletionInd]     NVARCHAR(1) NULL,
    CONSTRAINT PK_mst_PurchasingCondA018 PRIMARY KEY ([Vendor], [Material], [PurchOrg], [InfoCategory], [ConditionType], [ValidFrom])
);
GO

IF OBJECT_ID(N'inv.MaterialMovement', N'U') IS NOT NULL DROP TABLE inv.MaterialMovement;
CREATE TABLE inv.MaterialMovement (
    [MaterialDoc]     NVARCHAR(10) NOT NULL,
    [MaterialDocYear] NVARCHAR(4) NOT NULL,
    [MaterialDocItem] NVARCHAR(4) NOT NULL,
    [PostingDate]     DATE NULL,
    [DocumentDate]    DATE NULL,
    [EnteredBy]       NVARCHAR(12) NULL,
    [RefDoc]          NVARCHAR(16) NULL,
    [MovementType]    NVARCHAR(3) NULL,
    [Material]        NVARCHAR(18) NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   NVARCHAR(9) NULL,
    [Plant]           NVARCHAR(4) NULL,
    [StorLoc]         NVARCHAR(4) NULL,
    [Batch]           NVARCHAR(10) NULL,
    [CompanyCode]     NVARCHAR(4) NULL,
    [Quantity]        DECIMAL(19,4) NULL,
    [DebitCreditInd]  NVARCHAR(1) NULL,
    [BaseUom]         NVARCHAR(3) NULL,
    [LocalAmount]     DECIMAL(19,4) NULL,
    [Vendor]          NVARCHAR(10) NULL,
    [VendorName]      NVARCHAR(80) NULL,
    [PoNumber]        NVARCHAR(10) NULL,
    [PoItem]          NVARCHAR(5) NULL,
    [CostCenter]      NVARCHAR(10) NULL,
    [GlAccount]       NVARCHAR(10) NULL,
    [ProductionOrder] NVARCHAR(12) NULL,
    [Customer]        NVARCHAR(10) NULL,
    [FiscalYear]      NVARCHAR(4) NULL,
    CONSTRAINT PK_inv_MaterialMovement PRIMARY KEY ([MaterialDoc], [MaterialDocYear], [MaterialDocItem])
);
GO

IF OBJECT_ID(N'inv.InventoryBalance', N'U') IS NOT NULL DROP TABLE inv.InventoryBalance;
CREATE TABLE inv.InventoryBalance (
    [Material]        NVARCHAR(18) NOT NULL,
    [Plant]           NVARCHAR(4) NOT NULL,
    [StorLoc]         NVARCHAR(4) NOT NULL,
    [MaterialDesc]    NVARCHAR(40) NULL,
    [MaterialGroup]   NVARCHAR(9) NULL,
    [BaseUom]         NVARCHAR(3) NULL,
    [StockQty]        DECIMAL(19,4) NULL,
    [QualityStock]    DECIMAL(19,4) NULL,
    [BlockedStock]    DECIMAL(19,4) NULL,
    [TransferStock]   DECIMAL(19,4) NULL,
    [StockValue]      DECIMAL(19,4) NULL,
    [StandardPrice]   DECIMAL(19,4) NULL,
    [MovingAvgPrice]  DECIMAL(19,4) NULL,
    [PriceUnit]       DECIMAL(19,4) NULL,
    [PriceControl]    NVARCHAR(1) NULL,
    [SafetyStock]     DECIMAL(19,4) NULL,
    [ReorderPoint]    DECIMAL(19,4) NULL,
    [MaxStockLevel]   DECIMAL(19,4) NULL,
    [MrpType]         NVARCHAR(4) NULL,
    [MrpController]   NVARCHAR(3) NULL,
    [ProcurementType] NVARCHAR(1) NULL,
    [Planner]         NVARCHAR(20) NULL,
    [AbcIndicator]    NVARCHAR(1) NULL,
    [SnapshotDate]    DATE NULL,
    CONSTRAINT PK_inv_InventoryBalance PRIMARY KEY ([Material], [Plant], [StorLoc])
);
GO

IF OBJECT_ID(N'fin.AccountsPayable', N'U') IS NOT NULL DROP TABLE fin.AccountsPayable;
CREATE TABLE fin.AccountsPayable (
    [CompanyCode]    NVARCHAR(4) NOT NULL,
    [AccountingDoc]  NVARCHAR(10) NOT NULL,
    [FiscalYear]     NVARCHAR(4) NOT NULL,
    [LineItem]       NVARCHAR(3) NOT NULL,
    [DocumentType]   NVARCHAR(2) NULL,
    [PostingDate]    DATE NULL,
    [DocumentDate]   DATE NULL,
    [EntryDate]      DATE NULL,
    [CreatedBy]      NVARCHAR(12) NULL,
    [Vendor]         NVARCHAR(10) NULL,
    [VendorName]     NVARCHAR(80) NULL,
    [ReferenceDoc]   NVARCHAR(16) NULL,
    [Assignment]     NVARCHAR(18) NULL,
    [ItemText]       NVARCHAR(50) NULL,
    [GlAccount]      NVARCHAR(10) NULL,
    [CostCenter]     NVARCHAR(10) NULL,
    [Currency]       NVARCHAR(5) NULL,
    [DocAmount]      DECIMAL(19,4) NULL,
    [LocalAmount]    DECIMAL(19,4) NULL,
    [DebitCreditInd] NVARCHAR(1) NULL,
    [PaymentTerms]   NVARCHAR(4) NULL,
    [BaselineDate]   DATE NULL,
    [PaymentMethod]  NVARCHAR(10) NULL,
    [PaymentBlock]   NVARCHAR(1) NULL,
    [ClearingDoc]    NVARCHAR(10) NULL,
    [ClearingDate]   DATE NULL,
    [PoNumber]       NVARCHAR(10) NULL,
    [PoItem]         NVARCHAR(5) NULL,
    CONSTRAINT PK_fin_AccountsPayable PRIMARY KEY ([CompanyCode], [AccountingDoc], [FiscalYear], [LineItem])
);
GO

