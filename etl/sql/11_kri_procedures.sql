-- KRI 程序。第一期：K08、K13、K14、K18、K21；第二批：K01、K03、K04、K10、K19。規格見 docs/KRI_PRD.md 第 9 節。
--
-- 每題一張明細表 kri.Kxx_Detail（帶 RunId），被標記的列另寫一列到 kri.Flag。
-- 程序由 kri.RunAll 呼叫，交易與執行紀錄由 RunAll 處理，程序本身不開交易。
-- 明細表只在不存在時建立；改了欄位要先手動 DROP 那張明細表再跑這支。

-- ======================================================================
-- K14 PO 單價高於主檔價
-- ======================================================================
IF OBJECT_ID(N'kri.K14_Detail', N'U') IS NULL
CREATE TABLE kri.K14_Detail (
    RunId           INT           NOT NULL,
    PoNumber        NVARCHAR(10)  NOT NULL,
    PoItem          NVARCHAR(5)   NOT NULL,
    PoDate          DATE          NULL,
    CompanyCode     NVARCHAR(4)   NULL,
    PurchOrg        NVARCHAR(4)   NULL,
    Plant           NVARCHAR(4)   NULL,
    Vendor          NVARCHAR(10)  NULL,
    VendorName      NVARCHAR(80)  NULL,
    Material        NVARCHAR(18)  NULL,
    MaterialDesc    NVARCHAR(40)  NULL,
    OrderQty        DECIMAL(19,4) NULL,
    OrderUom        NVARCHAR(3)   NULL,
    Currency        NVARCHAR(5)   NULL,
    PoUnitPrice     DECIMAL(19,6) NULL,
    InfoSource      NVARCHAR(4)   NULL,      -- A017 / A018
    ConditionRecord NVARCHAR(10)  NULL,
    ConditionType   NVARCHAR(4)   NULL,
    InfoValidFrom   DATE          NULL,
    InfoUnitPrice   DECIMAL(19,6) NULL,
    InfoCurrency    NVARCHAR(5)   NULL,
    InfoUom         NVARCHAR(3)   NULL,
    MatchStatus     NVARCHAR(20)  NOT NULL,  -- 已比對 / 無主檔價 / 幣別不同 / 單位不同 / 缺PO單價 / 主檔無單價
    DiffRatio       DECIMAL(19,6) NULL,
    IsFlagged       BIT           NOT NULL,
    EffectDoc       DECIMAL(19,4) NULL,
    EffectLocal     DECIMAL(19,4) NULL,
    LocalCurrency   NVARCHAR(5)   NULL,
    CONSTRAINT PK_kri_K14_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K14
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tol DECIMAL(19,6) = kri.Param('K14', 'PriceTolerance');

    -- 比不了的列也寫進明細並註明原因，不能悄悄消失（D6）
    INSERT kri.K14_Detail
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant,
           b.Vendor, b.VendorName, b.Material, b.MaterialDesc, b.OrderQty, b.OrderUom,
           b.Currency, b.UnitPrice,
           i.Source, i.ConditionRecord, i.ConditionType, i.ValidFrom, i.UnitPrice, i.Currency, i.OrderUom,
           m.Status, d.DiffRatio,
           IIF(d.DiffRatio > @tol, 1, 0),
           e.EffectDoc,
           kri.ToLocal(e.EffectDoc, b.Currency, b.LocalCurrency, b.ExchangeRate),
           b.LocalCurrency
    FROM (SELECT * FROM kri.PoBase('K14', @PeriodFrom, @PeriodTo) WHERE IsGeneric = 0) b    -- 通用料號沒有可比的主檔價
    OUTER APPLY kri.InfoPriceAt('K14', b.Vendor, b.Material, b.PurchOrg, b.Plant, b.PoDate) i
    CROSS APPLY (SELECT CASE
        WHEN b.UnitPrice IS NULL                               THEN N'缺PO單價'
        WHEN i.Source IS NULL                                  THEN N'無主檔價'
        WHEN i.UnitPrice IS NULL OR i.UnitPrice = 0            THEN N'主檔無單價'
        WHEN i.Currency <> b.Currency                          THEN N'幣別不同'
        WHEN i.OrderUom IS NOT NULL AND i.OrderUom <> b.OrderUom THEN N'單位不同'
        ELSE N'已比對' END AS Status) m
    CROSS APPLY (SELECT IIF(m.Status = N'已比對', b.UnitPrice / i.UnitPrice - 1, NULL) AS DiffRatio) d
    CROSS APPLY (SELECT IIF(d.DiffRatio > @tol, (b.UnitPrice - i.UnitPrice) * b.OrderQty, NULL) AS EffectDoc) e
    WHERE ISNULL(b.Material, '') <> '';

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K14', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tol, EffectLocal, LocalCurrency,
           CONCAT(N'PO 單價高於', InfoSource, N' 主檔價 ', FORMAT(DiffRatio, 'P1'))
    FROM kri.K14_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'已比對 ', COUNT(CASE WHEN MatchStatus = N'已比對' THEN 1 END), N' / ', COUNT(*),
                          N'；無主檔價 ', COUNT(CASE WHEN MatchStatus = N'無主檔價' THEN 1 END),
                          N'、幣別不同 ', COUNT(CASE WHEN MatchStatus = N'幣別不同' THEN 1 END),
                          N'、單位不同 ', COUNT(CASE WHEN MatchStatus = N'單位不同' THEN 1 END))
    FROM kri.K14_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K13 跨據點同料號單價差異
-- 比較群組 = 料號 + 幣別 + 訂購單位 + 季度 + 數量級距；據點 = 公司別（EntityLevel=1）或工廠（=2）。
-- 每一行跟「其他據點」在同群組的最低單價比。
-- ======================================================================
IF OBJECT_ID(N'kri.K13_Detail', N'U') IS NULL
CREATE TABLE kri.K13_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoItem           NVARCHAR(5)   NOT NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Plant            NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    Material         NVARCHAR(18)  NULL,
    MaterialDesc     NVARCHAR(40)  NULL,
    Entity           NVARCHAR(4)   NULL,
    PeriodQuarter    DATE          NULL,
    QtyBand          INT           NULL,
    OrderQty         DECIMAL(19,4) NULL,
    OrderUom         NVARCHAR(3)   NULL,
    Currency         NVARCHAR(5)   NULL,
    UnitPrice        DECIMAL(19,6) NULL,
    EntityCount      INT           NULL,     -- 同群組有幾個據點
    OtherEntity      NVARCHAR(4)   NULL,     -- 最便宜的其他據點
    OtherMinPrice    DECIMAL(19,6) NULL,
    DiffRatio        DECIMAL(19,6) NULL,
    IsFlagged        BIT           NOT NULL,
    EffectDoc        DECIMAL(19,4) NULL,
    EffectLocal      DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    CONSTRAINT PK_kri_K13_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K13
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tol  DECIMAL(19,6) = kri.Param('K13', 'PriceTolerance'),
            @band FLOAT         = kri.Param('K13', 'QtyBandRatio'),
            @lvl  INT           = kri.Param('K13', 'EntityLevel');
    IF @band <= 1 THROW 50000, N'K13.QtyBandRatio 要大於 1', 1;

    WITH b AS (
        SELECT p.*, IIF(@lvl = 2, p.Plant, p.CompanyCode) AS Entity,
               DATEFROMPARTS(YEAR(p.PoDate), (DATEPART(QUARTER, p.PoDate) - 1) * 3 + 1, 1) AS PeriodQuarter,
               CAST(FLOOR(LOG(CAST(p.OrderQty AS FLOAT)) / LOG(@band)) AS INT) AS QtyBand
        FROM kri.PoBase('K13', @PeriodFrom, @PeriodTo) p
        WHERE ISNULL(p.Material, '') <> '' AND p.UnitPrice > 0 AND p.IsGeneric = 0
    ), em AS (          -- 每個據點在群組裡的最低單價
        SELECT Material, Currency, OrderUom, PeriodQuarter, QtyBand, Entity, MIN(UnitPrice) AS MinPrice
        FROM b WHERE ISNULL(Entity, '') <> ''
        GROUP BY Material, Currency, OrderUom, PeriodQuarter, QtyBand, Entity
    ), rk AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY Material, Currency, OrderUom, PeriodQuarter, QtyBand
                                     ORDER BY MinPrice, Entity) AS rn,
                  COUNT(*)     OVER (PARTITION BY Material, Currency, OrderUom, PeriodQuarter, QtyBand) AS cnt
        FROM em
    ), g AS (           -- 最便宜與第二便宜的據點：自己是最便宜的，就跟第二便宜的比
        SELECT Material, Currency, OrderUom, PeriodQuarter, QtyBand, MAX(cnt) AS EntityCount,
               MAX(IIF(rn = 1, Entity, NULL)) AS E1, MAX(IIF(rn = 1, MinPrice, NULL)) AS P1,
               MAX(IIF(rn = 2, Entity, NULL)) AS E2, MAX(IIF(rn = 2, MinPrice, NULL)) AS P2
        FROM rk
        GROUP BY Material, Currency, OrderUom, PeriodQuarter, QtyBand
        HAVING MAX(cnt) >= 2
    )
    INSERT kri.K13_Detail
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor,
           b.Material, b.MaterialDesc, b.Entity, b.PeriodQuarter, b.QtyBand, b.OrderQty, b.OrderUom,
           b.Currency, b.UnitPrice, g.EntityCount, o.OtherEntity, o.OtherMinPrice, d.DiffRatio,
           IIF(d.DiffRatio > @tol, 1, 0), e.EffectDoc,
           kri.ToLocal(e.EffectDoc, b.Currency, b.LocalCurrency, b.ExchangeRate), b.LocalCurrency
    FROM b
    JOIN g ON g.Material = b.Material AND g.Currency = b.Currency AND g.OrderUom = b.OrderUom
          AND g.PeriodQuarter = b.PeriodQuarter AND g.QtyBand = b.QtyBand
    CROSS APPLY (SELECT IIF(b.Entity = g.E1, g.E2, g.E1) AS OtherEntity,
                        IIF(b.Entity = g.E1, g.P2, g.P1) AS OtherMinPrice) o
    CROSS APPLY (SELECT b.UnitPrice / o.OtherMinPrice - 1 AS DiffRatio) d
    CROSS APPLY (SELECT IIF(d.DiffRatio > @tol, (b.UnitPrice - o.OtherMinPrice) * b.OrderQty, NULL) AS EffectDoc) e;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K13', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tol, EffectLocal, LocalCurrency,
           CONCAT(N'單價比據點 ', OtherEntity, N' 高 ', FORMAT(DiffRatio, 'P1'))
    FROM kri.K13_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'可跨據點比較的 PO 項目 ', COUNT(*)) FROM kri.K13_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K08 疑似拆單（PR）
-- 同成本中心 + 同供應商 + 同幣別，往前 WindowDays 天（滾動）內的 PR 合計金額
-- 對到的核決層級，高於單筆的核決層級，且至少 MinCount 張 PR → 標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K08_Detail', N'U') IS NULL
CREATE TABLE kri.K08_Detail (
    RunId         INT           NOT NULL,
    PrNumber      NVARCHAR(10)  NOT NULL,
    PrItem        NVARCHAR(5)   NOT NULL,
    PrDate        DATE          NULL,
    CostCenter    NVARCHAR(10)  NULL,
    Vendor        NVARCHAR(10)  NULL,
    Material      NVARCHAR(18)  NULL,
    Plant         NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Currency      NVARCHAR(5)   NULL,
    Amount        DECIMAL(19,4) NULL,
    WindowAmount  DECIMAL(19,4) NULL,
    WindowPrCount INT           NULL,
    OwnLevel      INT           NULL,
    WindowLevel   INT           NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K08_Detail PRIMARY KEY (RunId, PrNumber, PrItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K08
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @days INT = kri.Param('K08', 'WindowDays'),
            @min  INT = kri.Param('K08', 'MinCount');

    -- PR 金額 = 數量 × 評價價格（PR 的價格單位不在規格內，先視為 1）。
    -- 供應商：PR 指定的固定供應商，沒有就用轉出的 PO 的供應商。成本中心或供應商空白的不分群。
    WITH pr AS (
        SELECT r.PrNumber, r.PrItem, r.PrDate, r.CostCenter, r.Material, r.Plant, r.PurchOrg,
               r.Currency, COALESCE(NULLIF(r.Vendor, ''), po.Vendor) AS Vendor,
               CAST(r.ReqQty * r.ValPrice AS DECIMAL(19,4)) AS Amount
        FROM prc.PurchaseRequisition r
        LEFT JOIN prc.PurchaseOrderDetail po ON po.PoNumber = r.PoNumber AND po.PoItem = r.PoItem
        WHERE r.PrDate BETWEEN DATEADD(DAY, -(@days - 1), @PeriodFrom) AND @PeriodTo   -- 視窗要往前多抓
          AND ISNULL(r.DeletionInd, '') = ''
          AND r.ReqQty > 0 AND r.ValPrice > 0
    ), k AS (
        SELECT * FROM pr WHERE ISNULL(CostCenter, '') <> '' AND ISNULL(Vendor, '') <> ''
    ), w AS (
        SELECT i.PrNumber, i.PrItem, SUM(j.Amount) AS WindowAmount, COUNT(DISTINCT j.PrNumber) AS WindowPrCount
        FROM k i
        JOIN k j ON j.CostCenter = i.CostCenter AND j.Vendor = i.Vendor AND j.Currency = i.Currency
                AND j.PrDate BETWEEN DATEADD(DAY, -(@days - 1), i.PrDate) AND i.PrDate
        WHERE i.PrDate BETWEEN @PeriodFrom AND @PeriodTo
        GROUP BY i.PrNumber, i.PrItem
        HAVING COUNT(DISTINCT j.PrNumber) >= @min
    )
    INSERT kri.K08_Detail
    SELECT @RunId, k.PrNumber, k.PrItem, k.PrDate, k.CostCenter, k.Vendor, k.Material, k.Plant, k.PurchOrg,
           k.Currency, k.Amount, w.WindowAmount, w.WindowPrCount, own.Lvl, win.Lvl,
           IIF(win.Lvl > own.Lvl, 1, 0)
    FROM w
    JOIN k ON k.PrNumber = w.PrNumber AND k.PrItem = w.PrItem
    OUTER APPLY (SELECT TOP 1 ApprovalLevel AS Lvl FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'PR' AND a.CompanyCode = '*' AND a.Currency = k.Currency
                   AND k.Amount >= a.MinAmount AND k.Amount < a.MaxAmount
                   AND k.PrDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY a.ApprovalLevel DESC) own
    OUTER APPLY (SELECT TOP 1 ApprovalLevel AS Lvl FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'PR' AND a.CompanyCode = '*' AND a.Currency = k.Currency
                   AND w.WindowAmount >= a.MinAmount AND w.WindowAmount < a.MaxAmount
                   AND k.PrDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY a.ApprovalLevel DESC) win;

    -- PR 沒有匯率，影響金額先以 PR 幣別計（PRD 第 9 節）
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, PurchOrg, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K08', CONCAT(PrNumber, '-', PrItem), 'PR', Plant, PurchOrg, Vendor, Material,
           PrNumber, PrItem, PrDate, WindowAmount, NULL, Amount, Currency,
           CONCAT(@days, N' 天內同成本中心同供應商 ', WindowPrCount, N' 張 PR，合計需第 ', WindowLevel,
                  N' 層核決，單筆只需第 ', OwnLevel, N' 層')
    FROM kri.K08_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    IF NOT EXISTS (SELECT 1 FROM kri.ApprovalMatrix WHERE DocType = 'PR')
        SET @Note = N'kri.ApprovalMatrix 沒有 PR 的核決權限，這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'候選 PR 項目 ', COUNT(*)) FROM kri.K08_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K18 Open PO 收貨進度異常
-- 母體不看觀察期間的下單日，而是所有仍未結案、已過交貨日的 PO（WindowMonths 只用來限制多舊的 PO）。
-- 收貨比例用數量算：GrAmount 是本幣、NetValue 是文件幣別，不能直接相除。
-- ======================================================================
IF OBJECT_ID(N'kri.K18_Detail', N'U') IS NULL
CREATE TABLE kri.K18_Detail (
    RunId         INT           NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    PoDate        DATE          NULL,
    DelivDate     DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    VendorName    NVARCHAR(80)  NULL,
    Material      NVARCHAR(18)  NULL,
    OrderQty      DECIMAL(19,4) NULL,
    GrQty         DECIMAL(19,4) NULL,
    OpenQty       DECIMAL(19,4) NULL,
    ReceivedRatio DECIMAL(19,6) NULL,
    OverdueDays   INT           NULL,
    Currency      NVARCHAR(5)   NULL,
    UnitPrice     DECIMAL(19,6) NULL,
    OpenAmountDoc DECIMAL(19,4) NULL,
    IsFlagged     BIT           NOT NULL,
    EffectLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    CONSTRAINT PK_kri_K18_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K18
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ratio DECIMAL(19,6) = kri.Param('K18', 'MinReceivedRatio'),
            @days  INT           = kri.Param('K18', 'OverdueDays');

    INSERT kri.K18_Detail
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.DelivDate, b.CompanyCode, b.PurchOrg, b.Plant,
           b.Vendor, b.VendorName, b.Material, b.OrderQty, ISNULL(b.GrQty, 0), q.OpenQty, q.Ratio,
           q.Overdue, b.Currency, b.UnitPrice, q.OpenQty * b.UnitPrice,
           IIF(q.Ratio < @ratio AND q.Overdue > @days, 1, 0),
           IIF(q.Ratio < @ratio AND q.Overdue > @days,
               kri.ToLocal(q.OpenQty * b.UnitPrice, b.Currency, b.LocalCurrency, b.ExchangeRate), NULL),
           b.LocalCurrency
    FROM kri.PoBase('K18', @PeriodFrom, @PeriodTo) b
    CROSS APPLY (SELECT b.OrderQty - ISNULL(b.GrQty, 0)               AS OpenQty,
                        ISNULL(b.GrQty, 0) / b.OrderQty                AS Ratio,
                        DATEDIFF(DAY, b.DelivDate, @AsOfDate)          AS Overdue) q
    WHERE ISNULL(b.DelivComplInd, '') = ''
      AND ISNULL(b.GrQty, 0) < b.OrderQty
      AND b.DelivDate < @AsOfDate;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K18', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, ReceivedRatio, @ratio, EffectLocal, LocalCurrency,
           CONCAT(N'逾期 ', OverdueDays, N' 天，只收貨 ', FORMAT(ReceivedRatio, 'P0'))
    FROM kri.K18_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'已過交貨日的 Open PO 項目 ', COUNT(*)) FROM kri.K18_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K21 主檔價倒填
-- 觀察期間內建立的條件記錄，建立日晚於生效日超過 BackdateDays 天 → 標記。
-- 附上「生效日到建立日之間」同供應商＋料號（＋採購組織，A017 再加工廠）下的 PO。
-- ======================================================================
IF OBJECT_ID(N'kri.K21_Detail', N'U') IS NULL
CREATE TABLE kri.K21_Detail (
    RunId           INT           NOT NULL,
    Source          NVARCHAR(4)   NOT NULL,   -- A017 / A018
    ConditionRecord NVARCHAR(10)  NOT NULL,
    Vendor          NVARCHAR(10)  NULL,
    Material        NVARCHAR(18)  NULL,
    PurchOrg        NVARCHAR(4)   NULL,
    Plant           NVARCHAR(4)   NULL,
    InfoCategory    NVARCHAR(1)   NULL,
    ConditionType   NVARCHAR(4)   NULL,
    ValidFrom       DATE          NULL,
    ValidTo         DATE          NULL,
    CreatedOn       DATE          NULL,
    CreatedBy       NVARCHAR(12)  NULL,
    UnitPrice       DECIMAL(19,6) NULL,
    Currency        NVARCHAR(5)   NULL,
    BackdateDays    INT           NULL,
    PoCount         INT           NULL,       -- 倒填期間內的 PO 項目數
    PoAmountLocal   DECIMAL(19,4) NULL,
    LocalCurrency   NVARCHAR(5)   NULL,       -- PO 跨不同本幣時留 NULL、金額也留 NULL
    IsFlagged       BIT           NOT NULL,
    CONSTRAINT PK_kri_K21_Detail PRIMARY KEY (RunId, Source, ConditionRecord)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K21
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @days INT = kri.Param('K21', 'BackdateDays'),
            @req  INT = kri.Param('K21', 'RequirePo');   -- 1 = 倒填期間內要有 PO 才標記（批次回溯調價很常見）

    WITH c AS (
        SELECT 'A017' AS Source, ConditionRecord, Vendor, Material, PurchOrg, Plant, InfoCategory,
               ConditionType, ValidFrom, ValidTo, CreatedOn, CreatedBy, ConditionPrice, PriceUnit, Currency, DeletionInd
        FROM mst.PurchasingCondA017
        UNION ALL
        SELECT 'A018', ConditionRecord, Vendor, Material, PurchOrg, NULL, InfoCategory,
               ConditionType, ValidFrom, ValidTo, CreatedOn, CreatedBy, ConditionPrice, PriceUnit, Currency, DeletionInd
        FROM mst.PurchasingCondA018
    )
    INSERT kri.K21_Detail
    SELECT @RunId, c.Source, c.ConditionRecord, c.Vendor, c.Material, c.PurchOrg, c.Plant, c.InfoCategory,
           c.ConditionType, c.ValidFrom, c.ValidTo, c.CreatedOn, c.CreatedBy,
           CAST(c.ConditionPrice / NULLIF(c.PriceUnit, 0) AS DECIMAL(19,6)), c.Currency,
           DATEDIFF(DAY, c.ValidFrom, c.CreatedOn),
           ISNULL(po.Cnt, 0), IIF(po.Currencies = 1, po.Amount, NULL), IIF(po.Currencies = 1, po.Cur, NULL),
           IIF(DATEDIFF(DAY, c.ValidFrom, c.CreatedOn) > @days AND (@req = 0 OR ISNULL(po.Cnt, 0) > 0), 1, 0)
    FROM c
    OUTER APPLY (
        SELECT COUNT(*) AS Cnt, COUNT(DISTINCT b.LocalCurrency) AS Currencies, MAX(b.LocalCurrency) AS Cur,
               SUM(kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate)) AS Amount
        FROM kri.PoBase('K21', c.ValidFrom, DATEADD(DAY, -1, c.CreatedOn)) b
        WHERE b.Vendor = c.Vendor AND b.Material = c.Material AND b.PurchOrg = c.PurchOrg
          AND (c.Plant IS NULL OR b.Plant = c.Plant)
    ) po
    WHERE c.CreatedOn BETWEEN @PeriodFrom AND @PeriodTo
      AND c.CreatedOn > c.ValidFrom
      AND ISNULL(c.DeletionInd, '') = ''
      AND c.ConditionType IN (SELECT ListValue FROM kri.ValueList
                              WHERE KriCode IN ('K21', '*') AND ListName = 'AllowedConditionType');

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K21', CONCAT(Source, '-', ConditionRecord), 'CONDITION', PurchOrg, Plant, Vendor, Material,
           ConditionRecord, CreatedOn, BackdateDays, @days, PoAmountLocal, LocalCurrency,
           CONCAT(Source, N' 價格條件建立日晚於生效日 ', BackdateDays, N' 天；期間內有 ', PoCount, N' 筆 PO')
    FROM kri.K21_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'建立日晚於生效日的條件記錄 ', COUNT(*), N'；超過門檻但期間內沒有 PO ',
                          COUNT(CASE WHEN BackdateDays > @days AND PoCount = 0 THEN 1 END))
    FROM kri.K21_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 第二批：K01、K03、K04、K10、K19（客戶清單 TEST 1、3、4、10、19）。規格見 docs/KRI_PRD.md 第 9 節。
-- ######################################################################

-- ======================================================================
-- K01 品質異常期間仍下單
-- 品質異常單（ext.QualityIssue）開立到結案（未結案算到基準日）之間，同供應商下的 PO 項目。
-- 同料號另外註明。同一張單期間內的 PO 項目數 >= MinPoCount 才標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K01_Detail', N'U') IS NULL
CREATE TABLE kri.K01_Detail (
    RunId         INT           NOT NULL,
    IssueNo       NVARCHAR(50)  NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    IssueStatus   NVARCHAR(50)  NULL,
    OpenedOn      DATE          NULL,
    WindowEnd     DATE          NULL,      -- 結案日；未結案 = 基準日
    PoDate        DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    VendorName    NVARCHAR(80)  NULL,
    Material      NVARCHAR(18)  NULL,
    IssueMaterial NVARCHAR(40)  NULL,
    SameMaterial  BIT           NOT NULL,
    IssuePoCount  INT           NULL,      -- 這張單期間內同供應商的 PO 項目數
    AmountLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K01_Detail PRIMARY KEY (RunId, IssueNo, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K01
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @min  INT = kri.Param('K01', 'MinPoCount'),
            @same INT = kri.Param('K01', 'RequireSameMaterial');

    WITH q AS (
        SELECT IssueNo, Status, OpenedOn,
               -- 結案日晚於基準日（回補歷史基準日）時，當時還沒結案，算到基準日
               IIF(IsClosed = 1 AND ClosedOn <= @AsOfDate, ClosedOn, @AsOfDate) AS WindowEnd,
               -- 純數字的代碼補前導零：供應商 10 碼（LIFNR）、料號 18 碼（MATNR）
               IIF(Vendor NOT LIKE '%[^0-9]%' AND LEN(Vendor) < 10,
                   RIGHT(REPLICATE('0', 10) + Vendor, 10), Vendor) AS Vendor,
               IIF(ISNULL(Material, '') <> '' AND Material NOT LIKE '%[^0-9]%' AND LEN(Material) < 18,
                   RIGHT(REPLICATE('0', 18) + Material, 18), Material) AS Material
        FROM ext.QualityIssue
        WHERE ISNULL(Vendor, '') <> '' AND OpenedOn <= @PeriodTo
          AND (IsClosed = 0 OR ClosedOn >= @PeriodFrom)
    ), hit AS (
        SELECT q.IssueNo, q.Status, q.OpenedOn, q.WindowEnd, q.Material AS IssueMaterial,
               b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
               b.Material, b.LocalCurrency,
               IIF(ISNULL(q.Material, '') <> '' AND b.Material = q.Material, 1, 0) AS SameMaterial,
               kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal
        FROM q
        JOIN kri.PoBase('K01', @PeriodFrom, @PeriodTo) b      -- 整段期間只叫一次，再依每張單的期間對
          ON b.Vendor = q.Vendor AND b.PoDate BETWEEN q.OpenedOn AND q.WindowEnd
        WHERE (@same = 0 OR (ISNULL(q.Material, '') <> '' AND b.Material = q.Material))
    )
    INSERT kri.K01_Detail
    SELECT @RunId, IssueNo, PoNumber, PoItem, Status, OpenedOn, WindowEnd, PoDate, CompanyCode, PurchOrg,
           Plant, Vendor, VendorName, Material, IssueMaterial, SameMaterial,
           COUNT(*) OVER (PARTITION BY IssueNo), AmountLocal, LocalCurrency, 0
    FROM hit;

    UPDATE kri.K01_Detail SET IsFlagged = 1 WHERE RunId = @RunId AND IssuePoCount >= @min;

    -- 一個 PO 項目可能落在好幾張單的期間內：標記以 PO 項目為單位，列出單數
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT @RunId, 'K01', CONCAT(PoNumber, '-', PoItem), 'PO', MAX(CompanyCode), MAX(PurchOrg), MAX(Plant),
           MAX(Vendor), MAX(Material), PoNumber, PoItem, MAX(PoDate), MAX(IssuePoCount), @min,
           MAX(AmountLocal), MAX(LocalCurrency),
           CONCAT(N'下單時供應商有 ', COUNT(*), N' 張品質異常單未結案（', MIN(IssueNo),
                  IIF(COUNT(*) > 1, N' 等', N''), N'）', IIF(MAX(CAST(SameMaterial AS INT)) = 1, N'，含同料號', N''))
    FROM kri.K01_Detail
    WHERE RunId = @RunId AND IsFlagged = 1
    GROUP BY PoNumber, PoItem;

    SELECT @Note = CONCAT(N'異常單 ', (SELECT COUNT(*) FROM ext.QualityIssue),
                          N' 張（未結案 ', (SELECT COUNT(*) FROM ext.QualityIssue WHERE IsClosed = 0),
                          N'、已結案但沒有結案日略過 ',
                          (SELECT COUNT(*) FROM ext.QualityIssue WHERE IsClosed = 1 AND ClosedOn IS NULL),
                          N'）；期間內對到的 PO 項目 ', COUNT(DISTINCT CONCAT(PoNumber, '-', PoItem)))
    FROM kri.K01_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K03 已停用供應商短暫啟用交易
-- 凍結欄位（白名單 BlockField）從有值改成空白 = 解凍；同一個 Table + TableKey + 欄位
-- 下一次改回有值 = 再凍結。解凍期間 <= MaxOpenDays 天，而且期間內有 PO 或應付傳票 → 標記。
-- LFM1 只看該採購組織的 PO，LFB1 只看該公司別的 PO 與傳票（TableKey 第 14 碼起 4 碼）。
-- 採購凍結（SPERM）只算 PO、過帳凍結（SPERR）只算應付傳票；其他凍結欄位兩種都算。
-- ======================================================================
IF OBJECT_ID(N'kri.K03_Detail', N'U') IS NULL
CREATE TABLE kri.K03_Detail (
    RunId          INT           NOT NULL,
    Vendor         NVARCHAR(10)  NOT NULL,
    TableName      NVARCHAR(30)  NOT NULL,
    TableKey       NVARCHAR(70)  NOT NULL,
    FieldName      NVARCHAR(30)  NOT NULL,
    UnblockChange  NVARCHAR(10)  NOT NULL,
    Scope          NVARCHAR(4)   NULL,      -- LFM1 = 採購組織、LFB1 = 公司別、LFA1 = 空白（全部）
    UnblockDate    DATE          NULL,
    UnblockedBy    NVARCHAR(12)  NULL,
    ReblockDate    DATE          NULL,      -- 還沒再凍結 = NULL
    ReblockedBy    NVARCHAR(12)  NULL,
    OpenDays       INT           NULL,      -- 沒再凍結的算到基準日
    PoCount        INT           NULL,
    PoAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency  NVARCHAR(5)   NULL,      -- PO 跨不同本幣時留 NULL、金額也留 NULL
    ApCount        INT           NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K03_Detail PRIMARY KEY (RunId, Vendor, TableName, TableKey, FieldName, UnblockChange)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K03
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @days INT = kri.Param('K03', 'MaxOpenDays');

    WITH h AS (
        SELECT h.*, DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME), ISNULL(h.ChangeTime, '00:00')),
                            CAST(h.ChangeDate AS DATETIME2(0))) AS ChangeAt
        FROM mst.VendorChangeHistory h
        WHERE h.FieldName IN (SELECT ListValue FROM kri.ValueList
                              WHERE KriCode IN ('K03', '*') AND ListName = 'BlockField')
    ), u AS (           -- 解凍
        SELECT h.*, IIF(h.TableName IN ('LFM1', 'LFB1'), SUBSTRING(h.TableKey, 14, 4), '') AS Scope
        FROM h
        WHERE ISNULL(h.OldValue, '') <> '' AND ISNULL(h.NewValue, '') = ''
          AND h.ChangeDate BETWEEN @PeriodFrom AND @PeriodTo
    ), w AS (
        SELECT u.*, r.ChangeDate AS ReblockDate, r.ChangedBy AS ReblockedBy
        FROM u
        OUTER APPLY (SELECT TOP 1 x.ChangeDate, x.ChangedBy FROM h x
                     WHERE x.Vendor = u.Vendor AND x.TableName = u.TableName AND x.TableKey = u.TableKey
                       AND x.FieldName = u.FieldName AND ISNULL(x.NewValue, '') <> ''
                       AND (x.ChangeAt > u.ChangeAt OR (x.ChangeAt = u.ChangeAt AND x.ChangeNumber > u.ChangeNumber))
                       AND x.ChangeDate <= @AsOfDate          -- 回補歷史基準日時，不能看到基準日之後的異動
                     ORDER BY x.ChangeAt, x.ChangeNumber) r
    )
    INSERT kri.K03_Detail
    SELECT @RunId, w.Vendor, w.TableName, w.TableKey, w.FieldName, w.ChangeNumber, w.Scope,
           w.ChangeDate, w.ChangedBy, w.ReblockDate, w.ReblockedBy,
           DATEDIFF(DAY, w.ChangeDate, ISNULL(w.ReblockDate, @AsOfDate)),
           ISNULL(po.Cnt, 0), IIF(po.Currencies = 1, po.Amount, NULL), IIF(po.Currencies = 1, po.Cur, NULL),
           ISNULL(ap.Cnt, 0),
           IIF(w.ReblockDate IS NOT NULL AND DATEDIFF(DAY, w.ChangeDate, w.ReblockDate) <= @days
               AND (ISNULL(po.Cnt, 0) + ISNULL(ap.Cnt, 0)) > 0, 1, 0)
    FROM w
    OUTER APPLY (
        SELECT COUNT(*) AS Cnt, COUNT(DISTINCT b.LocalCurrency) AS Currencies, MAX(b.LocalCurrency) AS Cur,
               SUM(kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate)) AS Amount
        FROM kri.PoBase('K03', w.ChangeDate, ISNULL(w.ReblockDate, @AsOfDate)) b
        WHERE b.Vendor = w.Vendor
          AND w.FieldName <> 'SPERR'                            -- 過帳凍結只擋傳票，不算 PO
          AND (w.TableName <> 'LFM1' OR b.PurchOrg = w.Scope)
          AND (w.TableName <> 'LFB1' OR b.CompanyCode = w.Scope)
    ) po
    OUTER APPLY (
        SELECT COUNT(DISTINCT CONCAT(a.CompanyCode, '-', a.AccountingDoc, '-', a.FiscalYear)) AS Cnt
        FROM fin.AccountsPayable a
        WHERE a.Vendor = w.Vendor
          AND w.FieldName <> 'SPERM'                            -- 採購凍結只擋 PO，不算傳票
          -- 凍結擋的是輸入當下：系統輸入日（沒有才用過帳日）落在解凍期間才算，過帳日倒填也抓得到
          AND ISNULL(a.EntryDate, a.PostingDate) BETWEEN w.ChangeDate AND ISNULL(w.ReblockDate, @AsOfDate)
          AND ISNULL(a.EntryDate, a.PostingDate) <= @AsOfDate   -- 基準日之後才補入帳的不算
          AND (w.TableName <> 'LFB1' OR a.CompanyCode = w.Scope)
    ) ap;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, PurchOrg, CompanyCode, Vendor,
                     DocNumber, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K03', CONCAT(Vendor, '-', TableName, '-', Scope, '-', FieldName, '-', UnblockChange), 'VENDOR',
           IIF(TableName = 'LFM1', Scope, NULL), IIF(TableName = 'LFB1', Scope, NULL), Vendor,
           UnblockChange, UnblockDate, OpenDays, @days, PoAmountLocal, LocalCurrency,
           CONCAT(TableName, N'.', FieldName, N' 解凍 ', OpenDays, N' 天後再凍結；期間內 PO 項目 ', PoCount,
                  N' 筆、應付傳票 ', ApCount, N' 張', IIF(UnblockedBy = ReblockedBy, N'；解凍與再凍結同一人', N''))
    FROM kri.K03_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'解凍事件 ', COUNT(*), N'；尚未再凍結 ', COUNT(CASE WHEN ReblockDate IS NULL THEN 1 END))
    FROM kri.K03_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K04 付款條件比主檔差
-- PO 的付款條件和供應商主檔（採購組織層 LFM1）比；應付傳票的付款條件和 PO 比。
-- 天數用 kri.TermDays（kri.PaymentTerm 對照表，沒有就從代碼推估）。
-- 付得比較早（天數比較少）而且差 >= MinDaysWorse 天 → 標記。
-- 影響金額 = 金額 × 提早天數 ÷ 365 × AnnualRate（提早付款的資金成本）。
-- ======================================================================
IF OBJECT_ID(N'kri.K04_Detail', N'U') IS NULL
CREATE TABLE kri.K04_Detail (
    RunId          INT           NOT NULL,
    PoNumber       NVARCHAR(10)  NOT NULL,
    PoItem         NVARCHAR(5)   NOT NULL,
    PoDate         DATE          NULL,
    CompanyCode    NVARCHAR(4)   NULL,
    PurchOrg       NVARCHAR(4)   NULL,
    Vendor         NVARCHAR(10)  NULL,
    VendorName     NVARCHAR(80)  NULL,
    PoTerm         NVARCHAR(4)   NULL,
    MasterTerm     NVARCHAR(4)   NULL,      -- LFM1（PO 預設帶這個）
    CompanyTerm    NVARCHAR(4)   NULL,      -- LFB1（參考）
    ApTerm         NVARCHAR(4)   NULL,      -- 這個 PO 項目的應付傳票中，天數最少的付款條件
    PoDays         INT           NULL,
    MasterDays     INT           NULL,
    ApDays         INT           NULL,
    Status         NVARCHAR(20)  NOT NULL,  -- 一致 / 同公司別主檔 / PO與主檔不同 / AP與PO不同 / 都不同 / 缺主檔
    WorseDays      INT           NULL,      -- 提早幾天付款（兩項比較取較大者）
    AmountLocal    DECIMAL(19,4) NULL,
    LocalCurrency  NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    EffectLocal    DECIMAL(19,4) NULL,
    DaysEstimated  BIT           NULL,      -- 1 = 用到的天數有從代碼推估的（不在 kri.PaymentTerm）
    CONSTRAINT PK_kri_K04_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO
IF COL_LENGTH('kri.K04_Detail', 'DaysEstimated') IS NULL
    ALTER TABLE kri.K04_Detail ADD DaysEstimated BIT NULL;
GO

CREATE OR ALTER PROCEDURE kri.Run_K04
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @min  INT           = kri.Param('K04', 'MinDaysWorse'),
            @rate DECIMAL(19,6) = kri.Param('K04', 'AnnualRate'),
            @lvl  INT           = kri.Param('K04', 'MasterLevel');   -- 1 = 只認 LFM1；2 = 和 LFB1 一樣也算一致

    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Vendor, b.VendorName,
           b.LocalCurrency, ISNULL(p.PaymentTerm, '') AS PoTerm,      -- 空白 = 立即付款（0 天）
           (SELECT TOP 1 v.PurchOrgPaymentTerms FROM mst.Vendor v
            WHERE v.Vendor = b.Vendor AND v.PurchOrg = b.PurchOrg AND ISNULL(v.PurchOrgPaymentTerms, '') <> ''
            ORDER BY v.CompanyCode) AS MasterTerm,
           (SELECT TOP 1 v.PaymentTerms FROM mst.Vendor v
            WHERE v.Vendor = b.Vendor AND v.CompanyCode = b.CompanyCode AND ISNULL(v.PaymentTerms, '') <> ''
            ORDER BY v.PurchOrg) AS CompanyTerm,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal
    INTO #b
    FROM kri.PoBase('K04', @PeriodFrom, @PeriodTo) b
    JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
    WHERE ISNULL(b.Vendor, '') <> '';

    -- 應付傳票上出現過的付款條件（只看基準日當時已入帳的）
    SELECT DISTINCT a.PoNumber, a.PoItem, a.PaymentTerms AS Code
    INTO #ap
    FROM fin.AccountsPayable a
    JOIN #b ON #b.PoNumber = a.PoNumber AND #b.PoItem = a.PoItem
    WHERE ISNULL(a.PaymentTerms, '') <> ''
      AND ISNULL(a.DebitCreditInd, '') <> 'S'   -- 排除借方（貸項通知單、預付沖回，條件常是立即）；借貸別空白的照樣比
      AND a.PostingDate <= @AsOfDate AND ISNULL(a.EntryDate, a.PostingDate) <= @AsOfDate;

    -- 每個代碼只算一次天數；Estimated = 不在 kri.PaymentTerm、從代碼推估
    SELECT c.Code, kri.TermDays(c.Code) AS Days,
           CAST(IIF(EXISTS (SELECT 1 FROM kri.PaymentTerm t WHERE t.Code = c.Code), 0, 1) AS BIT) AS Estimated
    INTO #term
    FROM (SELECT PoTerm AS Code FROM #b UNION SELECT MasterTerm FROM #b
          UNION SELECT CompanyTerm FROM #b UNION SELECT Code FROM #ap) c
    WHERE ISNULL(c.Code, '') <> '';

    WITH apmin AS (     -- 每個 PO 項目取天數最少（最早付款）的應付付款條件
        SELECT a.PoNumber, a.PoItem, a.Code,
               ROW_NUMBER() OVER (PARTITION BY a.PoNumber, a.PoItem       -- 和 PO 不同的優先，再取天數最少
                                  ORDER BY IIF(a.Code = IIF(b.PoTerm = '', b.MasterTerm, b.PoTerm), 1, 0),  -- PO 空白時跟主檔比
                                           ISNULL(t.Days, 2147483647), a.Code) AS rn
        FROM #ap a JOIN #term t ON t.Code = a.Code
        JOIN #b b ON b.PoNumber = a.PoNumber AND b.PoItem = a.PoItem
    ), m AS (           -- PO 和主檔算不算不同：MasterLevel = 2 時，和公司別層（LFB1）一樣也算一致
        SELECT b.*, ap.Code AS ApTerm, eff.Term AS EffTerm,
               -- PO 條件空白：發票會帶主檔條件，有應付就用應付的天數；沒有應付才當立即付款（0 天）
               IIF(b.PoTerm = '', IIF(ap.Code IS NULL, 0, ta.Days), tp.Days) AS PoDays,
               tm.Days AS MasterDays, ta.Days AS ApDays,
               -- PO 條件空白而且有應付：實際條件 = 應付的條件（發票帶主檔），用它跟主檔比、應付不再跟 PO 比
               IIF(eff.Term <> b.MasterTerm
                   AND NOT (@lvl = 2 AND ISNULL(b.CompanyTerm, '') <> '' AND eff.Term = b.CompanyTerm), 1, 0) AS PoDiff,
               IIF(ap.Code IS NOT NULL AND ap.Code <> eff.Term, 1, 0) AS ApDiff,
               IIF(b.PoTerm = '', IIF(ap.Code IS NULL, 0, ta.Estimated), tp.Estimated) AS PoEst,
               tm.Estimated AS MasterEst, ta.Estimated AS ApEst
        FROM #b b
        LEFT JOIN apmin ap ON ap.PoNumber = b.PoNumber AND ap.PoItem = b.PoItem AND ap.rn = 1
        LEFT JOIN #term tp ON tp.Code = b.PoTerm
        LEFT JOIN #term tm ON tm.Code = b.MasterTerm
        LEFT JOIN #term ta ON ta.Code = ap.Code
        CROSS APPLY (SELECT IIF(b.PoTerm = '' AND ap.Code IS NOT NULL, ap.Code, b.PoTerm) AS Term) eff
    ), s AS (
        SELECT m.*,
               CASE WHEN MasterTerm IS NULL THEN N'缺主檔'
                    WHEN PoDiff = 1 AND ApDiff = 1 THEN N'都不同'
                    WHEN PoDiff = 1 THEN N'PO與主檔不同'
                    WHEN ApDiff = 1 THEN N'AP與PO不同'
                    WHEN EffTerm <> MasterTerm THEN N'同公司別主檔'
                    ELSE N'一致' END AS Status,
               (SELECT MAX(v) FROM (VALUES (IIF(PoDiff = 1, MasterDays - PoDays, NULL)),
                                           (IIF(ApDiff = 1, PoDays - ApDays, NULL))) x(v)) AS WorseDays,
               -- 用到的天數裡有推估的
               CAST(IIF(PoEst = 1 OR (PoDiff = 1 AND MasterEst = 1) OR (ApDiff = 1 AND ApEst = 1), 1, 0) AS BIT)
                   AS DaysEstimated
        FROM m
    )
    INSERT kri.K04_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Vendor, VendorName,
           PoTerm, MasterTerm, CompanyTerm, ApTerm, PoDays, MasterDays, ApDays, Status, WorseDays,
           AmountLocal, LocalCurrency, IsFlagged, EffectLocal, DaysEstimated)
    SELECT @RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Vendor, VendorName,
           PoTerm, MasterTerm, CompanyTerm, ApTerm, PoDays, MasterDays, ApDays, Status, WorseDays,
           AmountLocal, LocalCurrency,
           IIF(WorseDays >= @min, 1, 0),
           IIF(WorseDays >= @min, AmountLocal * WorseDays / 365.0 * @rate, NULL),
           DaysEstimated
    FROM s;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Vendor,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K04', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Vendor,
           PoNumber, PoItem, PoDate, WorseDays, @min, EffectLocal, LocalCurrency,
           CONCAT(N'付款條件 PO ', IIF(PoTerm = '', N'（空白）', PoTerm), N' / 主檔 ', MasterTerm,
                  IIF(ApTerm IS NOT NULL, CONCAT(N' / 應付 ', ApTerm), N''), N'，提早 ', WorseDays, N' 天付款',
                  IIF(DaysEstimated = 1, N'（天數為推估）', N''))
    FROM kri.K04_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'PO 項目 ', COUNT(*), N'；PO與主檔不同 ', COUNT(CASE WHEN Status IN (N'PO與主檔不同', N'都不同') THEN 1 END),
                          N'、AP與PO不同 ', COUNT(CASE WHEN Status IN (N'AP與PO不同', N'都不同') THEN 1 END),
                          N'、缺主檔 ', COUNT(CASE WHEN Status = N'缺主檔' THEN 1 END),
                          N'、PO 條件空白 ', COUNT(CASE WHEN PoTerm = '' THEN 1 END),
                          N'、和 LFM1 不同但同 LFB1 ', COUNT(CASE WHEN Status = N'同公司別主檔' THEN 1 END),
                          N'；條件不同但推不出天數 ',
                          COUNT(CASE WHEN Status NOT IN (N'一致', N'缺主檔', N'同公司別主檔') AND WorseDays IS NULL THEN 1 END),
                          N'；標記中天數為推估 ', COUNT(CASE WHEN IsFlagged = 1 AND DaysEstimated = 1 THEN 1 END))
    FROM kri.K04_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K10 先入庫才補請採購單 ／ K19 GR 日期異常貼近 PR/PO 建立日
-- 共用 kri.PoReceipt（第一次收貨日、第一次收貨的系統輸入日、是否含排除關鍵字）。
--   K10：PO 日 → 第一次收貨，間隔 <= MaxGapDays（含收貨早於 PO），排除關鍵字，
--        整張 PO 本幣金額 <= MaxPoAmount（只在本幣屬於 AmountCurrency 白名單時判斷，其他標「未判斷」照樣可標記）
--   K19：PR 日（沒有 PR 用 PO 日）→ 第一次收貨，間隔 <= MaxGapDays，排除關鍵字，不限金額
-- 收貨日取「過帳日」與「系統輸入日」較早的：過帳日可以手動填，輸入日不行。
-- ======================================================================
IF OBJECT_ID(N'kri.K10_Detail', N'U') IS NULL
CREATE TABLE kri.K10_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoItem           NVARCHAR(5)   NOT NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Plant            NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    VendorName       NVARCHAR(80)  NULL,
    Material         NVARCHAR(18)  NULL,
    FirstGrDate      DATE          NULL,
    FirstGrEntryDate DATE          NULL,
    GapDays          INT           NULL,     -- 較早的收貨日 − PO 日；負數 = 收貨早於 PO
    HasExcludedText  BIT           NOT NULL,
    PoAmountLocal    DECIMAL(19,4) NULL,     -- 整張 PO 的本幣金額（母體內所有項目合計，含未收貨；有項目換不出本幣 = NULL）
    AmountCheck      NVARCHAR(20)  NOT NULL, -- 未超過 / 超過上限 / 未判斷 / 不限
    ItemAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    IsFlagged        BIT           NOT NULL,
    FirstDocDate     DATE          NULL,     -- 最早的收貨文件日（送貨單日）
    DocGapDays       INT           NULL,     -- 文件日 − PO 日；負數 = 送貨單早於 PO（照樣標記）
    CONSTRAINT PK_kri_K10_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO
IF COL_LENGTH('kri.K10_Detail', 'FirstDocDate') IS NULL
    ALTER TABLE kri.K10_Detail ADD FirstDocDate DATE NULL, DocGapDays INT NULL;
GO

CREATE OR ALTER PROCEDURE kri.Run_K10
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @gap INT           = kri.Param('K10', 'MaxGapDays'),
            @max DECIMAL(19,4) = kri.Param('K10', 'MaxPoAmount');    -- 0 = 不限

    WITH b AS (         -- 整張 PO 的金額要算全部項目（含還沒收貨的），所以先 LEFT JOIN 收貨
        SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
               b.Material, b.LocalCurrency, r.PoNumber AS GrPo, r.FirstGrDate, r.FirstGrEntryDate, r.FirstDate,
               r.FirstDocDate,
               r.HasExcludedText,
               kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS ItemAmountLocal
        FROM kri.PoBase('K10', @PeriodFrom, @PeriodTo) b
        LEFT JOIN kri.PoReceipt('K10', @AsOfDate) r ON r.PoNumber = b.PoNumber AND r.PoItem = b.PoItem
    ), t AS (
        SELECT b.*,
               -- 有任何一個項目換不出本幣，整張 PO 金額就不算（留 NULL → 未判斷）
               IIF(COUNT(*) OVER (PARTITION BY PoNumber) = COUNT(ItemAmountLocal) OVER (PARTITION BY PoNumber),
                   SUM(ItemAmountLocal) OVER (PARTITION BY PoNumber), NULL) AS PoAmountLocal,
               DATEDIFF(DAY, PoDate, FirstDate) AS GapDays,
               DATEDIFF(DAY, PoDate, FirstDocDate) AS DocGapDays
        FROM b
    ), c AS (
        SELECT t.*,
               CASE WHEN @max = 0 THEN N'不限'
                    WHEN ISNULL(LocalCurrency, '') NOT IN (SELECT ListValue FROM kri.ValueList
                                               WHERE KriCode IN ('K10', '*') AND ListName = 'AmountCurrency') THEN N'未判斷'
                    WHEN PoAmountLocal IS NULL THEN N'未判斷'
                    WHEN PoAmountLocal > @max THEN N'超過上限'
                    ELSE N'未超過' END AS AmountCheck
        FROM t
        WHERE GrPo IS NOT NULL      -- 明細只留有收貨的項目
    )
    INSERT kri.K10_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, VendorName,
           Material, FirstGrDate, FirstGrEntryDate, GapDays, HasExcludedText, PoAmountLocal, AmountCheck,
           ItemAmountLocal, LocalCurrency, IsFlagged, FirstDocDate, DocGapDays)
    SELECT @RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, VendorName, Material,
           FirstGrDate, FirstGrEntryDate, GapDays, HasExcludedText, PoAmountLocal, AmountCheck,
           ItemAmountLocal, LocalCurrency,
           IIF((GapDays <= @gap OR DocGapDays < 0) AND HasExcludedText = 0 AND AmountCheck <> N'超過上限', 1, 0),
           FirstDocDate, DocGapDays
    FROM c;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K10', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate,
           IIF(GapDays > @gap AND DocGapDays < 0, DocGapDays, GapDays), IIF(GapDays > @gap AND DocGapDays < 0, 0, @gap),
           ItemAmountLocal, LocalCurrency,
           CONCAT(IIF(GapDays > @gap AND DocGapDays < 0, CONCAT(N'送貨單早於 PO ', -DocGapDays, N' 天；'), N''),
                  IIF(GapDays < 0, CONCAT(N'收貨早於 PO ', -GapDays, N' 天'), CONCAT(N'PO 後 ', GapDays, N' 天就收貨')),
                  IIF(GapDays <= @gap AND DocGapDays < 0, CONCAT(N'；送貨單早於 PO ', -DocGapDays, N' 天'), N''),
                  IIF(AmountCheck = N'未判斷', N'（金額上限未判斷）', N''))
    FROM kri.K10_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'有收貨的 PO 項目 ', COUNT(*), N'；收貨早於 PO ', COUNT(CASE WHEN GapDays < 0 THEN 1 END),
                          N'；送貨單早於 PO ', COUNT(CASE WHEN DocGapDays < 0 THEN 1 END),
                          N'；排除關鍵字 ', COUNT(CASE WHEN HasExcludedText = 1 THEN 1 END),
                          N'；超過金額上限 ', COUNT(CASE WHEN AmountCheck = N'超過上限' THEN 1 END),
                          N'；金額未判斷 ', COUNT(CASE WHEN AmountCheck = N'未判斷' THEN 1 END))
    FROM kri.K10_Detail WHERE RunId = @RunId;
END;
GO

IF OBJECT_ID(N'kri.K19_Detail', N'U') IS NULL
CREATE TABLE kri.K19_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoItem           NVARCHAR(5)   NOT NULL,
    PrNumber         NVARCHAR(10)  NULL,
    PrItem           NVARCHAR(5)   NULL,
    RefType          NVARCHAR(2)   NOT NULL, -- PR / PO（沒有 PR 時用 PO 日）
    RefDate          DATE          NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Plant            NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    Material         NVARCHAR(18)  NULL,
    FirstGrDate      DATE          NULL,
    FirstGrEntryDate DATE          NULL,
    GapDays          INT           NULL,
    HasExcludedText  BIT           NOT NULL,
    ItemAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    IsFlagged        BIT           NOT NULL,
    CONSTRAINT PK_kri_K19_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K19
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @gap INT = kri.Param('K19', 'MaxGapDays');

    WITH b AS (
        SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.Material,
               b.LocalCurrency, p.PrNumber, p.PrItem, pr.PrDate,
               r.FirstGrDate, r.FirstGrEntryDate, r.FirstDate, r.HasExcludedText,
               kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS ItemAmountLocal
        FROM kri.PoBase('K19', @PeriodFrom, @PeriodTo) b
        JOIN kri.PoReceipt('K19', @AsOfDate) r ON r.PoNumber = b.PoNumber AND r.PoItem = b.PoItem
        JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
        LEFT JOIN prc.PurchaseRequisition pr ON pr.PrNumber = p.PrNumber AND pr.PrItem = p.PrItem
    ), t AS (
        -- 有 PR 號碼但 PR 不在資料裡：不退回 PO 日（會低估間隔），留 NULL 不判斷
        SELECT b.*, IIF(ISNULL(PrNumber, '') <> '', 'PR', 'PO') AS RefType,
               IIF(ISNULL(PrNumber, '') <> '', PrDate, PoDate) AS RefDate,
               DATEDIFF(DAY, IIF(ISNULL(PrNumber, '') <> '', PrDate, PoDate), FirstDate) AS GapDays
        FROM b
    )
    INSERT kri.K19_Detail
    SELECT @RunId, PoNumber, PoItem, PrNumber, PrItem, RefType, RefDate, PoDate, CompanyCode, PurchOrg, Plant,
           Vendor, Material, FirstGrDate, FirstGrEntryDate, GapDays, HasExcludedText, ItemAmountLocal, LocalCurrency,
           IIF(GapDays <= @gap AND HasExcludedText = 0, 1, 0)
    FROM t;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K19', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, GapDays, @gap, ItemAmountLocal, LocalCurrency,
           IIF(GapDays < 0, CONCAT(N'收貨早於 ', RefType, N' ', -GapDays, N' 天'),
               CONCAT(RefType, N' 建立後 ', GapDays, N' 天就收貨'))
    FROM kri.K19_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'有收貨的 PO 項目 ', COUNT(*), N'（有 PR ', COUNT(CASE WHEN RefType = 'PR' THEN 1 END),
                          N'，PR 找不到 ', COUNT(CASE WHEN RefType = 'PR' AND RefDate IS NULL THEN 1 END),
                          N'）；排除關鍵字 ', COUNT(CASE WHEN HasExcludedText = 1 THEN 1 END))
    FROM kri.K19_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 第三批：K09、K12、K22、K23、K24。規格見 docs/KRI_PRD.md 第 9c 節。
-- ######################################################################

-- ======================================================================
-- K09 疑似拆單（direct AP）
-- 沒有 PO 的應付傳票（一張傳票 + 供應商一筆，本幣金額合計），同公司別 + 同供應商 + 同成本中心，
-- 往前 WindowDays 天內合計金額對到的核決層級（kri.ApprovalMatrix，DocType = 'AP'）高於單張 → 標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K09_Detail', N'U') IS NULL
CREATE TABLE kri.K09_Detail (
    RunId          INT           NOT NULL,
    CompanyCode    NVARCHAR(4)   NOT NULL,
    AccountingDoc  NVARCHAR(10)  NOT NULL,
    FiscalYear     NVARCHAR(4)   NOT NULL,
    Vendor         NVARCHAR(10)  NOT NULL,
    VendorName     NVARCHAR(80)  NULL,
    PostingDate    DATE          NULL,
    DocumentType   NVARCHAR(2)   NULL,
    CostCenter     NVARCHAR(10)  NULL,      -- 空白 = 供應商行沒有成本中心，整個供應商算一群
    LocalCurrency  NVARCHAR(5)   NULL,
    Amount         DECIMAL(19,4) NULL,
    WindowAmount   DECIMAL(19,4) NULL,
    WindowDocCount INT           NULL,
    OwnLevel       INT           NULL,
    WindowLevel    INT           NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K09_Detail PRIMARY KEY (RunId, CompanyCode, AccountingDoc, FiscalYear, Vendor)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K09
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @days INT = kri.Param('K09', 'WindowDays'),
            @min  INT = kri.Param('K09', 'MinCount');
    DECLARE @types INT = (SELECT COUNT(*) FROM kri.ValueList WHERE KriCode IN ('K09', '*') AND ListName = 'IncludeDocType');

    SELECT a.CompanyCode, a.AccountingDoc, a.FiscalYear, a.Vendor, MAX(a.VendorName) AS VendorName,
           MIN(a.PostingDate) AS PostingDate, MAX(a.DocumentType) AS DocumentType,
           ISNULL(MAX(NULLIF(a.CostCenter, '')), '') AS CostCenter, MAX(c.LocalCurrency) AS LocalCurrency,
           SUM(a.LocalAmount) AS Amount
    INTO #d
    FROM fin.AccountsPayable a
    LEFT JOIN kri.vCompanyCurrency c ON c.CompanyCode = a.CompanyCode
    WHERE ISNULL(a.PoNumber, '') = '' AND ISNULL(a.Vendor, '') <> ''
      AND ISNULL(a.DebitCreditInd, '') <> 'S'                 -- 借方（貸項、沖回）不算
      AND ISNULL(a.ClearingDoc, '') <> a.AccountingDoc         -- 付款、清帳傳票自己清自己，不是發票
      AND ISNULL(a.DocumentType, '') NOT IN (SELECT ListValue FROM kri.ValueList
                                             WHERE KriCode IN ('K09', '*') AND ListName = 'ExcludeDocType')
      AND a.PostingDate BETWEEN DATEADD(DAY, -(@days - 1), @PeriodFrom) AND @PeriodTo   -- 視窗要往前多抓
      AND ISNULL(a.EntryDate, a.PostingDate) <= @AsOfDate
      AND (@types = 0 OR a.DocumentType IN (SELECT ListValue FROM kri.ValueList
                                            WHERE KriCode IN ('K09', '*') AND ListName = 'IncludeDocType'))
      AND NOT EXISTS (SELECT 1 FROM kri.ValueList x
                      WHERE x.KriCode IN ('K09', '*') AND x.ListName = 'ExcludeVendorPrefix'
                        AND a.Vendor LIKE x.ListValue + '%')
    GROUP BY a.CompanyCode, a.AccountingDoc, a.FiscalYear, a.Vendor
    HAVING SUM(a.LocalAmount) > 0;
    CREATE CLUSTERED INDEX cx ON #d (CompanyCode, Vendor, CostCenter, PostingDate);   -- 視窗自我 join 用日期範圍找

    WITH w AS (
        SELECT i.CompanyCode, i.AccountingDoc, i.FiscalYear, i.Vendor,
               SUM(j.Amount) AS WindowAmount, COUNT(*) AS WindowDocCount
        FROM #d i
        JOIN #d j ON j.CompanyCode = i.CompanyCode AND j.Vendor = i.Vendor AND j.CostCenter = i.CostCenter
                 AND j.PostingDate BETWEEN DATEADD(DAY, -(@days - 1), i.PostingDate) AND i.PostingDate
        WHERE i.PostingDate BETWEEN @PeriodFrom AND @PeriodTo
        GROUP BY i.CompanyCode, i.AccountingDoc, i.FiscalYear, i.Vendor
        HAVING COUNT(*) >= @min
    )
    INSERT kri.K09_Detail
    SELECT @RunId, d.CompanyCode, d.AccountingDoc, d.FiscalYear, d.Vendor, d.VendorName, d.PostingDate,
           d.DocumentType, d.CostCenter, d.LocalCurrency, d.Amount, w.WindowAmount, w.WindowDocCount,
           own.Lvl, win.Lvl, IIF(win.Lvl > own.Lvl, 1, 0)
    FROM w
    JOIN #d d ON d.CompanyCode = w.CompanyCode AND d.AccountingDoc = w.AccountingDoc
             AND d.FiscalYear = w.FiscalYear AND d.Vendor = w.Vendor
    OUTER APPLY (SELECT TOP 1 ApprovalLevel AS Lvl FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'AP' AND a.CompanyCode IN (d.CompanyCode, '*') AND a.Currency = d.LocalCurrency
                   AND d.Amount >= a.MinAmount AND d.Amount < a.MaxAmount
                   AND d.PostingDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY IIF(a.CompanyCode = '*', 1, 0), a.ApprovalLevel DESC) own
    OUTER APPLY (SELECT TOP 1 ApprovalLevel AS Lvl FROM kri.ApprovalMatrix a
                 WHERE a.DocType = 'AP' AND a.CompanyCode IN (d.CompanyCode, '*') AND a.Currency = d.LocalCurrency
                   AND w.WindowAmount >= a.MinAmount AND w.WindowAmount < a.MaxAmount
                   AND d.PostingDate BETWEEN a.ValidFrom AND a.ValidTo
                 ORDER BY IIF(a.CompanyCode = '*', 1, 0), a.ApprovalLevel DESC) win;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, Vendor,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K09', CONCAT(CompanyCode, '-', AccountingDoc, '-', FiscalYear, '-', Vendor), 'AP', CompanyCode, Vendor,
           AccountingDoc, FiscalYear, PostingDate, WindowAmount, NULL, Amount, LocalCurrency,
           CONCAT(@days, N' 天內同供應商', IIF(CostCenter <> '', N'同成本中心', N''), N' ', WindowDocCount,
                  N' 張沒有 PO 的應付傳票，合計需第 ', WindowLevel, N' 層核決，單張只需第 ', OwnLevel, N' 層')
    FROM kri.K09_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    IF NOT EXISTS (SELECT 1 FROM kri.ApprovalMatrix WHERE DocType = 'AP')
        SET @Note = N'kri.ApprovalMatrix 沒有 AP 的核決權限，這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'候選傳票 ', COUNT(*), N'（期間內沒有 PO 的應付傳票 ',
                              (SELECT COUNT(*) FROM #d WHERE PostingDate BETWEEN @PeriodFrom AND @PeriodTo), N'）',
                              IIF(@types = 0 AND NOT EXISTS (SELECT 1 FROM fin.AccountsPayable WHERE ISNULL(DebitCreditInd, '') <> ''),
                                  N'；沒有設定 IncludeDocType、借貸別也是空的，付款或貸項可能混在裡面', N''))
        FROM kri.K09_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K12 集中且買貴
-- 前一年 + 本期（共兩個期間）只跟一家供應商買的料號（白名單 AllowedSingleSource 除外），
-- 本期均價比前一年漲幅，超過同物料群組其他料號（同幣別、同單位）平均漲幅 PriceTolerance → 標記。
-- 群組可比的料號不到 MinGroupMaterials 個時，基準當 0（只看自己漲多少）。
-- ======================================================================
IF OBJECT_ID(N'kri.K12_Detail', N'U') IS NULL
CREATE TABLE kri.K12_Detail (
    RunId          INT           NOT NULL,
    Material       NVARCHAR(18)  NOT NULL,
    Vendor         NVARCHAR(10)  NOT NULL,
    Currency       NVARCHAR(5)   NOT NULL,
    OrderUom       NVARCHAR(10)  NOT NULL,
    MaterialGroup  NVARCHAR(20)  NULL,
    VendorCount    INT           NULL,      -- 兩個期間內這個料號的供應商家數
    PriorQty       DECIMAL(19,4) NULL,
    PriorPrice     DECIMAL(19,6) NULL,
    CurQty         DECIMAL(19,4) NULL,
    CurPrice       DECIMAL(19,6) NULL,
    PriceChange    DECIMAL(19,6) NULL,      -- 本期均價 ÷ 前一年均價 − 1
    GroupChange    DECIMAL(19,6) NULL,      -- 同群組其他料號的平均漲幅；NULL = 可比的不夠
    GroupMaterials INT           NULL,
    ExcessChange   DECIMAL(19,6) NULL,      -- PriceChange − 基準
    EffectLocal    DECIMAL(19,4) NULL,      -- （本期均價 − 前一年均價 ×（1 + 基準））× 本期數量
    LocalCurrency  NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K12_Detail PRIMARY KEY (RunId, Material, Vendor, Currency, OrderUom)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K12
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tol DECIMAL(19,6) = kri.Param('K12', 'PriceTolerance'),
            @grp INT           = kri.Param('K12', 'MinGroupMaterials');
    DECLARE @prevFrom DATE = DATEADD(YEAR, -1, @PeriodFrom);

    WITH p AS (
        SELECT b.Material, b.Vendor, b.Currency, b.OrderUom, b.MaterialGroup, b.OrderQty, b.NetValue,
               kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal, b.LocalCurrency,
               IIF(b.PoDate >= @PeriodFrom, 1, 0) AS IsCur
        FROM kri.PoBase('K12', @prevFrom, @PeriodTo) b
        WHERE ISNULL(b.Material, '') <> '' AND b.IsGeneric = 0 AND ISNULL(b.Vendor, '') <> '' AND b.NetValue IS NOT NULL
    ), vc AS (          -- 供應商家數不套工廠、採購組織等排除條件，免得被排掉的供應商讓料號看起來像獨家
        SELECT Material, COUNT(DISTINCT Vendor) AS VendorCount FROM prc.PurchaseOrderDetail d
        WHERE PoDate BETWEEN @prevFrom AND @PeriodTo AND ISNULL(DeletionInd, '') = '' AND ISNULL(Vendor, '') <> ''
          AND OrderQty > 0 AND Material IN (SELECT Material FROM p)
          AND NOT EXISTS (SELECT 1 FROM kri.ValueList x       -- 刻意排除的供應商（關係企業等）不算來源
                          WHERE x.KriCode IN ('K12', '*') AND x.ListName = 'ExcludeVendorPrefix'
                            AND d.Vendor LIKE x.ListValue + '%')
        GROUP BY Material
    ), a AS (
        SELECT Material, Vendor, Currency, OrderUom, MAX(MaterialGroup) AS MaterialGroup,
               SUM(IIF(IsCur = 0, OrderQty, 0)) AS PriorQty, SUM(IIF(IsCur = 0, NetValue, 0)) AS PriorAmt,
               SUM(IIF(IsCur = 1, OrderQty, 0)) AS CurQty, SUM(IIF(IsCur = 1, NetValue, 0)) AS CurAmt,
               SUM(IIF(IsCur = 1, AmountLocal, 0)) AS CurAmtLocal,
               COUNT(CASE WHEN IsCur = 1 AND AmountLocal IS NULL THEN 1 END) AS CurNoLocal,
               IIF(COUNT(DISTINCT LocalCurrency) = 1, MAX(LocalCurrency), NULL) AS LocalCurrency
        FROM p GROUP BY Material, Vendor, Currency, OrderUom
    ), c AS (
        SELECT a.*, vc.VendorCount,
               a.PriorAmt / NULLIF(a.PriorQty, 0) AS PriorPrice, a.CurAmt / NULLIF(a.CurQty, 0) AS CurPrice,
               (a.CurAmt / NULLIF(a.CurQty, 0)) / NULLIF(a.PriorAmt / NULLIF(a.PriorQty, 0), 0) - 1 AS PriceChange
        FROM a JOIN vc ON vc.Material = a.Material
        WHERE a.PriorQty > 0 AND a.CurQty > 0
    ), mat AS (         -- 料號層級的漲幅（多家供應商的料號合併算一次）
        SELECT Material, Currency, OrderUom, MaterialGroup,
               (SUM(CurAmt) / SUM(CurQty)) / NULLIF(SUM(PriorAmt) / SUM(PriorQty), 0) - 1 AS MatChange
        FROM c WHERE MaterialGroup IS NOT NULL GROUP BY Material, Currency, OrderUom, MaterialGroup
    ), g AS (           -- 同群組、同幣別、同單位的「其他」料號平均漲幅；沒有物料群組的不比
        SELECT c.*, pe.n AS GroupMaterials, pe.AvgChange AS GroupAvg
        FROM c
        OUTER APPLY (SELECT COUNT(*) AS n, AVG(m.MatChange) AS AvgChange FROM mat m
                     WHERE m.MaterialGroup = c.MaterialGroup AND m.Currency = c.Currency AND m.OrderUom = c.OrderUom
                       AND m.Material <> c.Material) pe
    ), r AS (
        SELECT g.*, IIF(GroupMaterials >= @grp, GroupAvg, NULL) AS GroupChange,
               PriceChange - ISNULL(IIF(GroupMaterials >= @grp, GroupAvg, NULL), 0) AS ExcessChange
        FROM g
    )
    INSERT kri.K12_Detail
    SELECT @RunId, Material, Vendor, Currency, OrderUom, MaterialGroup, VendorCount, PriorQty, PriorPrice, CurQty,
           CurPrice, PriceChange, GroupChange, GroupMaterials, ExcessChange,
           IIF(f.Flag = 1 AND CurNoLocal = 0 AND LocalCurrency IS NOT NULL,
               (CurPrice - PriorPrice * (1 + ISNULL(GroupChange, 0))) * CurQty * CurAmtLocal / NULLIF(CurAmt, 0), NULL),
           LocalCurrency, f.Flag
    FROM r
    CROSS APPLY (SELECT IIF(VendorCount = 1 AND ExcessChange > @tol
                            AND Material NOT IN (SELECT ListValue FROM kri.ValueList
                                                 WHERE KriCode IN ('K12', '*') AND ListName = 'AllowedSingleSource'),
                            1, 0) AS Flag) f;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Vendor, Material,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K12', CONCAT(Material, '-', Vendor, '-', Currency, '-', OrderUom), 'MATERIAL', Vendor, Material,
           ExcessChange, @tol, EffectLocal, LocalCurrency,
           CONCAT(N'獨家供應料號，單價一年漲 ', FORMAT(PriceChange, 'P1'),
                  IIF(GroupChange IS NULL, N'（群組可比料號不足，基準以 0 計）',
                      CONCAT(N'，同群組平均 ', FORMAT(GroupChange, 'P1'))))
    FROM kri.K12_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'兩期都有採購的料號×供應商 ', COUNT(*), N'；獨家 ', COUNT(CASE WHEN VendorCount = 1 THEN 1 END),
                          N'；群組可比料號不足 ', COUNT(CASE WHEN VendorCount = 1 AND GroupChange IS NULL THEN 1 END))
    FROM kri.K12_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K22 主檔價大漲
-- 觀察期間內建立的價格條件，和同一組合（同表、供應商、料號、採購組織、工廠、資訊記錄類別、條件類型）
-- 前一筆（生效日較早、基準日前已建立）比，單價漲超過 IncreaseRatio → 標記。
-- 影響金額：生效日之後同組合 PO 的 數量 ×（新價 − 舊價）。
-- ======================================================================
IF OBJECT_ID(N'kri.K22_Detail', N'U') IS NULL
CREATE TABLE kri.K22_Detail (
    RunId           INT           NOT NULL,
    Source          NVARCHAR(4)   NOT NULL,
    ConditionRecord NVARCHAR(10)  NOT NULL,
    Vendor          NVARCHAR(10)  NULL,
    Material        NVARCHAR(18)  NULL,
    PurchOrg        NVARCHAR(4)   NULL,
    Plant           NVARCHAR(4)   NULL,
    InfoCategory    NVARCHAR(1)   NULL,
    ConditionType   NVARCHAR(4)   NULL,
    ValidFrom       DATE          NULL,
    CreatedOn       DATE          NULL,      -- 空白時用生效日判斷是否在觀察期間
    CreatedBy       NVARCHAR(12)  NULL,
    Currency        NVARCHAR(5)   NULL,
    OrderUom        NVARCHAR(10)  NULL,
    UnitPrice       DECIMAL(19,6) NULL,
    PrevRecord      NVARCHAR(10)  NULL,
    PrevValidFrom   DATE          NULL,
    PrevUnitPrice   DECIMAL(19,6) NULL,
    CompareStatus   NVARCHAR(10)  NOT NULL,  -- 已比對 / 無前一筆 / 幣別不同 / 單位不同
    IncreaseRatio   DECIMAL(19,6) NULL,
    PoCount         INT           NULL,
    EffectLocal     DECIMAL(19,4) NULL,
    LocalCurrency   NVARCHAR(5)   NULL,
    IsFlagged       BIT           NOT NULL,
    CONSTRAINT PK_kri_K22_Detail PRIMARY KEY (RunId, Source, ConditionRecord)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K22
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inc DECIMAL(19,6) = kri.Param('K22', 'IncreaseRatio');

    WITH c AS (
        SELECT 'A017' AS Source, ConditionRecord, Vendor, Material, PurchOrg, Plant, InfoCategory, ConditionType,
               ValidFrom, ValidTo, CreatedOn, CreatedBy, Currency, OrderUom, DeletionInd,
               CAST(ConditionPrice / NULLIF(PriceUnit, 0) AS DECIMAL(19,6)) AS UnitPrice
        FROM mst.PurchasingCondA017
        UNION ALL
        SELECT 'A018', ConditionRecord, Vendor, Material, PurchOrg, NULL, InfoCategory, ConditionType,
               ValidFrom, ValidTo, CreatedOn, CreatedBy, Currency, OrderUom, DeletionInd,
               CAST(ConditionPrice / NULLIF(PriceUnit, 0) AS DECIMAL(19,6))
        FROM mst.PurchasingCondA018
    ), ok AS (
        SELECT * FROM c
        WHERE ISNULL(DeletionInd, '') = ''
          AND ConditionType IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K22', '*') AND ListName = 'AllowedConditionType')
          -- 不套資訊記錄類別白名單：只跟同類別的前一筆比
    ), x AS (
        SELECT n.*, nx.NextFrom, p.ConditionRecord AS PrevRecord, p.ValidFrom AS PrevValidFrom, p.UnitPrice AS PrevUnitPrice,
               CASE WHEN p.ConditionRecord IS NULL THEN N'無前一筆'
                    WHEN p.Currency <> n.Currency THEN N'幣別不同'
                    WHEN p.OrderUom <> n.OrderUom THEN N'單位不同'
                    ELSE N'已比對' END AS CompareStatus
        FROM ok n
        OUTER APPLY (SELECT TOP 1 o.ConditionRecord, o.ValidFrom, o.UnitPrice, o.Currency, o.OrderUom FROM ok o
                     WHERE o.Source = n.Source AND o.Vendor = n.Vendor AND o.Material = n.Material
                       AND o.PurchOrg = n.PurchOrg AND ISNULL(o.Plant, '') = ISNULL(n.Plant, '')
                       AND o.InfoCategory = n.InfoCategory AND o.ConditionType = n.ConditionType
                       AND o.ValidFrom < n.ValidFrom AND ISNULL(o.CreatedOn, o.ValidFrom) <= @AsOfDate
                     ORDER BY o.ValidFrom DESC) p
        OUTER APPLY (SELECT MIN(o.ValidFrom) AS NextFrom FROM ok o      -- 下一筆生效前一天為止，避免兩次漲價重複算同一批 PO
                     WHERE o.Source = n.Source AND o.Vendor = n.Vendor AND o.Material = n.Material
                       AND o.PurchOrg = n.PurchOrg AND ISNULL(o.Plant, '') = ISNULL(n.Plant, '')
                       AND o.InfoCategory = n.InfoCategory AND o.ConditionType = n.ConditionType
                       AND o.ValidFrom > n.ValidFrom AND ISNULL(o.CreatedOn, o.ValidFrom) <= @AsOfDate) nx
        WHERE ISNULL(n.CreatedOn, n.ValidFrom) BETWEEN @PeriodFrom AND @PeriodTo   -- 建立日空白用生效日
    ), r AS (
        SELECT x.*, IIF(CompareStatus = N'已比對', UnitPrice / NULLIF(PrevUnitPrice, 0) - 1, NULL) AS IncreaseRatio,
               (SELECT MIN(v) FROM (VALUES (@AsOfDate), (x.ValidTo), (DATEADD(DAY, -1, x.NextFrom))) t(v)) AS PoTo
        FROM x
    )
    INSERT kri.K22_Detail
    SELECT @RunId, r.Source, r.ConditionRecord, r.Vendor, r.Material, r.PurchOrg, r.Plant, r.InfoCategory, r.ConditionType,
           r.ValidFrom, r.CreatedOn, r.CreatedBy, r.Currency, r.OrderUom, r.UnitPrice, r.PrevRecord, r.PrevValidFrom,
           r.PrevUnitPrice, r.CompareStatus, r.IncreaseRatio, ISNULL(po.Cnt, 0),
           IIF(r.IncreaseRatio > @inc AND po.Currencies = 1, po.ValLocal - po.QtyLocal * r.PrevUnitPrice, NULL), IIF(po.Currencies = 1, po.Cur, NULL),
           IIF(r.IncreaseRatio > @inc, 1, 0)
    FROM r
    OUTER APPLY (       -- 這筆條件有效期間內、同幣別同單位的 PO：實際單價比舊價多付的金額
        SELECT COUNT(*) AS Cnt, COUNT(DISTINCT b.LocalCurrency) AS Currencies, MAX(b.LocalCurrency) AS Cur,
               -- 換算是線性的：Σ 本幣(單價 × 數量) − 舊價 × Σ 本幣(數量)
               SUM(kri.ToLocal(b.UnitPrice * b.OrderQty, b.Currency, b.LocalCurrency, b.ExchangeRate)) AS ValLocal,
               SUM(kri.ToLocal(b.OrderQty, b.Currency, b.LocalCurrency, b.ExchangeRate)) AS QtyLocal
        FROM kri.PoBase('K22', r.ValidFrom, r.PoTo) b
        WHERE r.IncreaseRatio > @inc AND b.IsGeneric = 0
          AND b.Vendor = r.Vendor AND b.Material = r.Material AND b.PurchOrg = r.PurchOrg
          AND (r.Plant IS NULL OR b.Plant = r.Plant)
          AND b.Currency = r.Currency AND b.OrderUom = r.OrderUom
    ) po;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K22', CONCAT(Source, '-', ConditionRecord), 'CONDITION', PurchOrg, Plant, Vendor, Material,
           ConditionRecord, ISNULL(CreatedOn, ValidFrom), IncreaseRatio, @inc, EffectLocal, LocalCurrency,
           CONCAT(Source, N' 價格條件比前一筆（', PrevValidFrom, N' 生效）漲 ', FORMAT(IncreaseRatio, 'P1'),
                  N'；生效後 PO ', PoCount, N' 筆')
    FROM kri.K22_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'期間內建立的條件記錄 ', COUNT(*), N'；已比對 ', COUNT(CASE WHEN CompareStatus = N'已比對' THEN 1 END),
                          N'、無前一筆 ', COUNT(CASE WHEN CompareStatus = N'無前一筆' THEN 1 END),
                          N'、幣別或單位不同 ', COUNT(CASE WHEN CompareStatus IN (N'幣別不同', N'單位不同') THEN 1 END))
    FROM kri.K22_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K23 便宜主檔價已生效，舊 Open PO 仍用高價
-- 未結案的 PO 項目（還有未收數量），基準日有效的主檔價在下單之後才生效、
-- 而且比 PO 單價低超過 PriceTolerance → 標記。影響金額 =（PO 單價 − 主檔價）× 未收數量。
-- ======================================================================
IF OBJECT_ID(N'kri.K23_Detail', N'U') IS NULL
CREATE TABLE kri.K23_Detail (
    RunId          INT           NOT NULL,
    PoNumber       NVARCHAR(10)  NOT NULL,
    PoItem         NVARCHAR(5)   NOT NULL,
    PoDate         DATE          NULL,
    CompanyCode    NVARCHAR(4)   NULL,
    PurchOrg       NVARCHAR(4)   NULL,
    Plant          NVARCHAR(4)   NULL,
    Vendor         NVARCHAR(10)  NULL,
    VendorName     NVARCHAR(80)  NULL,
    Material       NVARCHAR(18)  NULL,
    Currency       NVARCHAR(5)   NULL,
    OrderUom       NVARCHAR(10)  NULL,
    PoUnitPrice    DECIMAL(19,6) NULL,
    InfoSource     NVARCHAR(4)   NULL,
    InfoValidFrom  DATE          NULL,
    InfoUnitPrice  DECIMAL(19,6) NULL,
    DiffRatio      DECIMAL(19,6) NULL,      -- PO 單價 ÷ 主檔價 − 1
    OpenQty        DECIMAL(19,4) NULL,
    EffectLocal    DECIMAL(19,4) NULL,
    LocalCurrency  NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K23_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K23
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tol DECIMAL(19,6) = kri.Param('K23', 'PriceTolerance');

    INSERT kri.K23_Detail
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
           b.Material, b.Currency, b.OrderUom, b.UnitPrice, i.Source, i.ValidFrom, i.UnitPrice, d.Ratio, q.OpenQty,
           IIF(d.Ratio > @tol, kri.ToLocal((b.UnitPrice - i.UnitPrice) * q.OpenQty, b.Currency, b.LocalCurrency,
                                           b.ExchangeRate), NULL),
           b.LocalCurrency, IIF(d.Ratio > @tol, 1, 0)
    FROM (SELECT * FROM kri.PoBase('K23', @PeriodFrom, @PeriodTo) WHERE IsGeneric = 0) b
    CROSS APPLY kri.InfoPriceAt('K23', b.Vendor, b.Material, b.PurchOrg, b.Plant, @AsOfDate) i
    -- 基準日當時已收：收貨資料是基本單位、PO 是訂購單位，所以用「基準日前已收 ÷ 全部已收」的比例乘 PO 的已收量
    OUTER APPLY (SELECT SUM(IIF(g.DebitCreditInd = 'H', -g.Quantity, g.Quantity)) AS Tot,
                        SUM(IIF(g.PostingDate <= @AsOfDate AND ISNULL(g.EntryDate, g.PostingDate) <= @AsOfDate,
                                IIF(g.DebitCreditInd = 'H', -g.Quantity, g.Quantity), 0)) AS AsOf
                 FROM prc.GoodsReceipt g
                 WHERE g.PoNumber = b.PoNumber AND g.PoItem = b.PoItem) gr
    CROSS APPLY (SELECT b.OrderQty - IIF(gr.Tot > 0, ISNULL(b.GrQty, 0) * gr.AsOf / gr.Tot, ISNULL(b.GrQty, 0)) AS OpenQty) q
    CROSS APPLY (SELECT b.UnitPrice / NULLIF(i.UnitPrice, 0) - 1 AS Ratio) d
    WHERE ISNULL(b.DelivComplInd, '') = '' AND q.OpenQty > 0
      AND i.ValidFrom > b.PoDate                       -- 下單之後才生效的主檔價
      AND i.Currency = b.Currency AND ISNULL(i.OrderUom, b.OrderUom) = b.OrderUom
      AND d.Ratio > 0;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K23', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tol, EffectLocal, LocalCurrency,
           CONCAT(N'主檔價 ', InfoValidFrom, N' 起降為 ', InfoUnitPrice, N'，Open PO 單價仍高 ', FORMAT(DiffRatio, 'P1'),
                  N'，未收 ', OpenQty)
    FROM kri.K23_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'下單後主檔價變便宜的 Open PO 項目 ', COUNT(*)) FROM kri.K23_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K24 休眠供應商重新啟用、價格偏高
-- 供應商上一張 PO 到這一張隔了 DormantDays 天以上 = 重新啟用；啟用後 FollowDays 天內的 PO 項目，
-- 單價和其他供應商過去一年同料號（同幣別、同單位）的加權均價比，高超過 PriceTolerance → 標記。
-- 沒有其他供應商可比的留在明細、不標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K24_Detail', N'U') IS NULL
CREATE TABLE kri.K24_Detail (
    RunId          INT           NOT NULL,
    PoNumber       NVARCHAR(10)  NOT NULL,
    PoItem         NVARCHAR(5)   NOT NULL,
    PoDate         DATE          NULL,
    CompanyCode    NVARCHAR(4)   NULL,
    PurchOrg       NVARCHAR(4)   NULL,
    Plant          NVARCHAR(4)   NULL,
    Vendor         NVARCHAR(10)  NULL,
    VendorName     NVARCHAR(80)  NULL,
    Material       NVARCHAR(18)  NULL,
    ReactivatedOn  DATE          NULL,      -- 重新啟用後第一張 PO 的日期
    PrevPoDate     DATE          NULL,      -- 休眠前最後一張 PO 的日期
    DormantDays    INT           NULL,
    Currency       NVARCHAR(5)   NULL,
    OrderUom       NVARCHAR(10)  NULL,
    UnitPrice      DECIMAL(19,6) NULL,
    RefUnitPrice   DECIMAL(19,6) NULL,
    RefVendorCount INT           NULL,
    RefPoCount     INT           NULL,      -- 參考 PO 筆數，少於 MinRefPos 不比
    RefSpread      DECIMAL(19,6) NULL,      -- 參考 PO 的最高單價 ÷ 最低單價；太分散（通用料號）不比
    DiffRatio      DECIMAL(19,6) NULL,
    OrderQty       DECIMAL(19,4) NULL,
    EffectLocal    DECIMAL(19,4) NULL,
    LocalCurrency  NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K24_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K24
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dormant INT           = kri.Param('K24', 'DormantDays'),
            @follow  INT           = kri.Param('K24', 'FollowDays'),
            @tol     DECIMAL(19,6) = kri.Param('K24', 'PriceTolerance'),
            @spread  DECIMAL(19,6) = kri.Param('K24', 'MaxRefSpread'),
            @minref  INT           = kri.Param('K24', 'MinRefPos');

    -- 重新啟用事件：供應商每個下單日和前一個下單日的間隔（看全部 PO，不限觀察期間）
    WITH d AS (
        SELECT DISTINCT Vendor, PoDate FROM prc.PurchaseOrderDetail
        WHERE ISNULL(Vendor, '') <> '' AND ISNULL(DeletionInd, '') = '' AND PoDate <= @PeriodTo
    ), e AS (
        SELECT Vendor, PoDate AS ReactivatedOn, LAG(PoDate) OVER (PARTITION BY Vendor ORDER BY PoDate) AS PrevPoDate
        FROM d
    )
    SELECT Vendor, ReactivatedOn, PrevPoDate, DATEDIFF(DAY, PrevPoDate, ReactivatedOn) AS DormantDays
    INTO #e
    FROM e
    WHERE DATEDIFF(DAY, PrevPoDate, ReactivatedOn) >= @dormant
      AND ReactivatedOn >= DATEADD(DAY, -@follow, @PeriodFrom);

    -- 參考價的 PO 先抓一次（期間前一年到期間末），之後用料號找
    SELECT Material, Vendor, Currency, OrderUom, PoDate, UnitPrice, OrderQty
    INTO #ref
    FROM kri.PoBase('K24', DATEADD(YEAR, -1, @PeriodFrom), @PeriodTo)
    WHERE ISNULL(Material, '') <> '' AND UnitPrice > 0 AND OrderQty > 0 AND IsGeneric = 0;
    CREATE CLUSTERED INDEX cx ON #ref (Material, Currency, OrderUom, PoDate);

    INSERT kri.K24_Detail
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
           b.Material, e.ReactivatedOn, e.PrevPoDate, e.DormantDays, b.Currency, b.OrderUom, b.UnitPrice,
           ref.Price, ref.Vendors, ref.Pos, ref.Spread, d.Ratio, b.OrderQty,
           IIF(f.Flag = 1, kri.ToLocal((b.UnitPrice - ref.Price) * b.OrderQty, b.Currency, b.LocalCurrency,
                                       b.ExchangeRate), NULL),
           b.LocalCurrency, f.Flag
    FROM (SELECT * FROM kri.PoBase('K24', @PeriodFrom, @PeriodTo) WHERE IsGeneric = 0) b
    CROSS APPLY (SELECT TOP 1 * FROM #e x
                 WHERE x.Vendor = b.Vendor AND b.PoDate BETWEEN x.ReactivatedOn AND DATEADD(DAY, @follow, x.ReactivatedOn)
                 ORDER BY x.ReactivatedOn DESC) e
    OUTER APPLY (SELECT SUM(o.UnitPrice * o.OrderQty) / NULLIF(SUM(o.OrderQty), 0) AS Price,
                        COUNT(DISTINCT o.Vendor) AS Vendors, COUNT(*) AS Pos,
                        MAX(o.UnitPrice) / NULLIF(MIN(o.UnitPrice), 0) AS Spread
                 FROM #ref o
                 WHERE o.Material = b.Material AND o.Currency = b.Currency AND o.OrderUom = b.OrderUom
                   AND o.PoDate >= DATEADD(YEAR, -1, b.PoDate) AND o.PoDate < b.PoDate
                   AND o.Vendor <> b.Vendor) ref
    CROSS APPLY (SELECT b.UnitPrice / NULLIF(ref.Price, 0) - 1 AS Ratio) d
    CROSS APPLY (SELECT IIF(d.Ratio > @tol AND ref.Spread <= @spread AND ref.Pos >= @minref, 1, 0) AS Flag) f
    WHERE ISNULL(b.Material, '') <> '';

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K24', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tol, EffectLocal, LocalCurrency,
           CONCAT(N'供應商休眠 ', DormantDays, N' 天後 ', ReactivatedOn, N' 重新下單；單價比其他 ', RefVendorCount,
                  N' 家供應商過去一年均價高 ', FORMAT(DiffRatio, 'P1'))
    FROM kri.K24_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'重新啟用的供應商 ', COUNT(DISTINCT Vendor), N'；啟用後 PO 項目 ', COUNT(*),
                          N'；沒有其他供應商可比 ', COUNT(CASE WHEN RefUnitPrice IS NULL THEN 1 END),
                          N'；參考 PO 太少 ', COUNT(CASE WHEN RefPoCount BETWEEN 1 AND @minref - 1 THEN 1 END),
                          N'；參考價太分散不比 ', COUNT(CASE WHEN RefSpread > @spread THEN 1 END))
    FROM kri.K24_Detail WHERE RunId = @RunId;
END;
GO

-- ######################################################################
-- 第四批：K02、K05、K06、K07、K11、K15、K16、K17、K20（要外部資料或補欄位的題目）。
-- 外部資料在 ext.*，沒資料時程式照跑、備註說明。規格見 docs/KRI_PRD.md 第 9d 節。
-- ######################################################################

-- ======================================================================
-- K02 工商登記關聯供應商（先做 SAP 內部版）
-- 不同供應商代碼但統編、電話或地址相同（MatchAttribute 白名單），或商工登記列為關聯（ext.VendorRelation）。
-- 同一個值超過 MaxGroupSize 家共用（代理商、園區總機）的不配對。
-- 標記：①其中一家凍結（帳戶群組 ExcludeAccountGroup 除外），另一家期間內有 PO；②兩家期間內買過同料號。
-- ======================================================================
IF OBJECT_ID(N'kri.K02_Detail', N'U') IS NULL
CREATE TABLE kri.K02_Detail (
    RunId           INT           NOT NULL,
    VendorA         NVARCHAR(10)  NOT NULL,
    VendorB         NVARCHAR(10)  NOT NULL,
    MatchType       NVARCHAR(30)  NOT NULL,   -- TaxNumber / Phone / Address / 商工登記的關係類型
    MatchValue      NVARCHAR(200) NULL,
    ABlocked        BIT           NOT NULL,
    BBlocked        BIT           NOT NULL,
    APoCount        INT           NULL,
    BPoCount        INT           NULL,
    APoAmountLocal  DECIMAL(19,4) NULL,
    BPoAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency   NVARCHAR(5)   NULL,
    CommonMaterials INT           NULL,
    Scenario        NVARCHAR(30)  NULL,       -- 凍結廠商關聯交易 / 關聯廠商同料號
    IsFlagged       BIT           NOT NULL,
    CONSTRAINT PK_kri_K02_Detail PRIMARY KEY (RunId, VendorA, VendorB, MatchType)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K02
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @maxg INT = kri.Param('K02', 'MaxGroupSize');

    -- 基準日之後才改的凍結欄位：基準日當時的值 = 基準日後第一筆異動的舊值
    SELECT Vendor, TableName, FieldName, Scope, ISNULL(OldValue, '') AS OldValue
    INTO #fut
    FROM (SELECT h.Vendor, h.TableName, h.FieldName, h.OldValue,
                 IIF(h.TableName IN ('LFM1', 'LFB1'), SUBSTRING(h.TableKey, 14, 4), '') AS Scope,
                 ROW_NUMBER() OVER (PARTITION BY h.Vendor, h.TableName, h.TableKey, h.FieldName
                                    ORDER BY h.ChangeDate, h.ChangeTime, h.ChangeNumber) AS rn
          FROM mst.VendorChangeHistory h
          WHERE h.ChangeDate > @AsOfDate AND h.FieldName IN ('SPERM', 'SPERR')
            AND h.TableName IN ('LFA1', 'LFM1', 'LFB1')) x
    WHERE rn = 1;

    SELECT Vendor,
           MAX(NULLIF(LTRIM(RTRIM(TaxNumber)), '')) AS Tax,
           MAX(NULLIF(REPLACE(REPLACE(REPLACE(Phone, '-', ''), ' ', ''), '+', ''), '')) AS Phone,
           MAX(NULLIF(UPPER(REPLACE(REPLACE(REPLACE(Address, ' ', ''), ',', ''), '.', '')), '')) AS Addr,
           -- 凍結 = 中央凍結，或每個採購組織／公司別都凍結（只凍結某一個組織不算）
           IIF(MAX(ListValue) IS NULL AND (MAX(Central) = 1 OR MIN(OrgBlk) = 1), 1, 0) AS Blocked
    INTO #v
    FROM (SELECT v.*, x.ListValue,                                   -- 排除的帳戶群組（ExcludeAccountGroup）不算凍結
                 IIF(COALESCE(f1.OldValue, v.CentralPurchBlock, '') <> '' OR COALESCE(f2.OldValue, v.CentralPostingBlock, '') <> '', 1, 0) AS Central,
                 IIF(COALESCE(f3.OldValue, v.PurchasingBlock, '') <> '' OR COALESCE(f4.OldValue, v.PostingBlock, '') <> '', 1, 0) AS OrgBlk
          FROM mst.Vendor v
          LEFT JOIN kri.ValueList x ON x.KriCode IN ('K02', '*') AND x.ListName = 'ExcludeAccountGroup'
                                   AND x.ListValue = v.VendorAccountGroup
          OUTER APPLY (SELECT MAX(OldValue) AS OldValue FROM #fut WHERE Vendor = v.Vendor AND TableName = 'LFA1' AND FieldName = 'SPERM') f1
          OUTER APPLY (SELECT MAX(OldValue) AS OldValue FROM #fut WHERE Vendor = v.Vendor AND TableName = 'LFA1' AND FieldName = 'SPERR') f2
          OUTER APPLY (SELECT MAX(OldValue) AS OldValue FROM #fut WHERE Vendor = v.Vendor AND TableName = 'LFM1' AND FieldName = 'SPERM'
                         AND Scope = v.PurchOrg) f3
          OUTER APPLY (SELECT MAX(OldValue) AS OldValue FROM #fut WHERE Vendor = v.Vendor AND TableName = 'LFB1' AND FieldName = 'SPERR'
                         AND Scope = v.CompanyCode) f4) v
    GROUP BY Vendor;

    -- 填充值不算相同（NA、NANANA、0000000000、-）：統編、電話要有足夠的數字，而且不能整串同一個字
    WITH a0 AS (
        SELECT Vendor, 'TaxNumber' AS MatchType, Tax AS MatchValue, 4 AS MinDigits FROM #v WHERE Tax IS NOT NULL
        UNION ALL SELECT Vendor, 'Phone', Phone, 6 FROM #v WHERE Phone IS NOT NULL
        UNION ALL SELECT Vendor, 'Address', Addr, 0 FROM #v WHERE Addr IS NOT NULL AND LEN(Addr) >= 6
    ), a AS (
        SELECT Vendor, MatchType, MatchValue FROM a0
        WHERE LEN(MatchValue) - LEN(REPLACE(TRANSLATE(MatchValue, '0123456789', '##########'), '#', '')) >= MinDigits
          AND REPLACE(MatchValue, LEFT(MatchValue, 1), '') <> ''
          AND REPLACE(MatchValue, 'NA', '') <> ''
    ), g AS (
        SELECT a.*, COUNT(*) OVER (PARTITION BY MatchType, MatchValue) AS n FROM a
        WHERE MatchType IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K02', '*') AND ListName = 'MatchAttribute')
    ), r AS (           -- 商工登記：A、B 正反兩筆、多種關係都併成一對
        SELECT IIF(VendorA < VendorB, VendorA, VendorB) AS VendorA, IIF(VendorA < VendorB, VendorB, VendorA) AS VendorB,
               RelationType + ISNULL(N'（' + Note + N'）', N'') AS Rel
        FROM ext.VendorRelation WHERE VendorA <> VendorB
    )
    SELECT x.Vendor AS VendorA, y.Vendor AS VendorB, x.MatchType, x.MatchValue
    INTO #p
    FROM g x JOIN g y ON y.MatchType = x.MatchType AND y.MatchValue = x.MatchValue AND x.Vendor < y.Vendor
    WHERE x.n <= @maxg
    UNION ALL
    SELECT VendorA, VendorB, N'商工登記', LEFT(STRING_AGG(CAST(Rel AS NVARCHAR(MAX)), N'；') WITHIN GROUP (ORDER BY Rel), 200)
    FROM (SELECT DISTINCT VendorA, VendorB, Rel FROM r) r
    GROUP BY VendorA, VendorB;

    SELECT b.Vendor, b.Material, b.LocalCurrency,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal
    INTO #po
    FROM kri.PoBase('K02', @PeriodFrom, @PeriodTo) b
    WHERE b.Vendor IN (SELECT VendorA FROM #p UNION SELECT VendorB FROM #p);

    WITH s AS (
        SELECT Vendor, COUNT(*) AS Cnt, SUM(AmountLocal) AS Amt, COUNT(DISTINCT LocalCurrency) AS Curs,
               MAX(LocalCurrency) AS Cur
        FROM #po GROUP BY Vendor
    )
    INSERT kri.K02_Detail
    SELECT @RunId, p.VendorA, p.VendorB, p.MatchType, p.MatchValue, va.Blocked, vb.Blocked,
           ISNULL(sa.Cnt, 0), ISNULL(sb.Cnt, 0),
           IIF(ISNULL(sa.Curs, 1) = 1 AND ISNULL(sb.Curs, 1) = 1 AND (sa.Cur IS NULL OR sb.Cur IS NULL OR sa.Cur = sb.Cur), sa.Amt, NULL),
           IIF(ISNULL(sa.Curs, 1) = 1 AND ISNULL(sb.Curs, 1) = 1 AND (sa.Cur IS NULL OR sb.Cur IS NULL OR sa.Cur = sb.Cur), sb.Amt, NULL),
           COALESCE(sa.Cur, sb.Cur), cm.n,
           CASE WHEN (va.Blocked = 1 AND sb.Cnt > 0) OR (vb.Blocked = 1 AND sa.Cnt > 0) THEN N'凍結廠商關聯交易'
                WHEN cm.n > 0 THEN N'關聯廠商同料號' END,
           IIF((va.Blocked = 1 AND sb.Cnt > 0) OR (vb.Blocked = 1 AND sa.Cnt > 0) OR cm.n > 0, 1, 0)
    FROM #p p
    LEFT JOIN #v va ON va.Vendor = p.VendorA
    LEFT JOIN #v vb ON vb.Vendor = p.VendorB
    LEFT JOIN s sa ON sa.Vendor = p.VendorA
    LEFT JOIN s sb ON sb.Vendor = p.VendorB
    OUTER APPLY (SELECT COUNT(*) AS n FROM (SELECT DISTINCT Material FROM #po WHERE Vendor = p.VendorA AND ISNULL(Material, '') <> ''
                                            INTERSECT
                                            SELECT DISTINCT Material FROM #po WHERE Vendor = p.VendorB) m) cm
    WHERE va.Vendor IS NOT NULL AND vb.Vendor IS NOT NULL;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Vendor, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K02', CONCAT(VendorA, '-', VendorB, '-', MatchType), 'VENDOR', VendorA, CommonMaterials, NULL,
           CASE WHEN Scenario = N'凍結廠商關聯交易' THEN IIF(ABlocked = 1, BPoAmountLocal, APoAmountLocal)
                ELSE ISNULL(APoAmountLocal, 0) + ISNULL(BPoAmountLocal, 0) END, LocalCurrency,
           CONCAT(N'供應商 ', VendorA, N' 和 ', VendorB, N' ', MatchType, N' 相同；', Scenario,
                  IIF(CommonMaterials > 0, CONCAT(N'（共同料號 ', CommonMaterials, N'）'), N''))
    FROM kri.K02_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'關聯供應商配對 ', COUNT(*), N'（商工登記 ', COUNT(CASE WHEN MatchType = N'商工登記' THEN 1 END),
                          N'）；有凍結的配對 ', COUNT(CASE WHEN ABlocked = 1 OR BBlocked = 1 THEN 1 END))
    FROM kri.K02_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K05 Open PO 超過供應商資本額
-- 觀察期間（36 個月）內下單、未交貨完成的 PO 未收金額（本幣）合計 ÷ 實收資本額（ext.VendorCapital）> CapitalRatio → 標記。
-- 本幣和資本額幣別不同、或跨不同本幣的標「未判斷」；查不到資本額（例如國外廠商）標「無資本額」，留在明細。
-- ======================================================================
IF OBJECT_ID(N'kri.K05_Detail', N'U') IS NULL
CREATE TABLE kri.K05_Detail (
    RunId            INT           NOT NULL,
    Vendor           NVARCHAR(10)  NOT NULL,
    VendorName       NVARCHAR(80)  NULL,
    OpenPoCount      INT           NULL,
    OpenAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    Capital          DECIMAL(19,2) NULL,
    CapitalCurrency  NVARCHAR(5)   NULL,
    Ratio            DECIMAL(19,6) NULL,
    Status           NVARCHAR(10)  NOT NULL,  -- 已比對 / 無資本額 / 未判斷
    IsFlagged        BIT           NOT NULL,
    CONSTRAINT PK_kri_K05_Detail PRIMARY KEY (RunId, Vendor)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K05
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ratio DECIMAL(19,6) = kri.Param('K05', 'CapitalRatio');

    WITH o AS (
        SELECT b.Vendor, MAX(b.VendorName) AS VendorName, COUNT(*) AS Cnt,
               IIF(COUNT(*) = COUNT(b.OpenLocal), SUM(b.OpenLocal), NULL) AS Amt,     -- 有任一項目換不了本幣就不判斷
               COUNT(DISTINCT b.LocalCurrency) AS Curs, MAX(b.LocalCurrency) AS Cur
        FROM (SELECT b.*, kri.ToLocal((b.OrderQty - ISNULL(b.GrQty, 0)) * b.UnitPrice, b.Currency, b.LocalCurrency, b.ExchangeRate) AS OpenLocal
              FROM kri.PoBase('K05', @PeriodFrom, @PeriodTo) b
              WHERE ISNULL(b.Vendor, '') <> '' AND ISNULL(b.DelivComplInd, '') = '' AND ISNULL(b.GrQty, 0) < b.OrderQty) b
        GROUP BY b.Vendor
    ), t AS (
        SELECT o.*, c.Capital, c.Currency AS CapCur
        FROM o
        OUTER APPLY (SELECT TOP 1 x.Capital, x.Currency FROM ext.VendorCapital x
                     WHERE (x.Vendor = o.Vendor
                            OR (x.Vendor IS NULL AND x.TaxNumber IN (SELECT NULLIF(LTRIM(RTRIM(v.TaxNumber)), '')
                                                                     FROM mst.Vendor v WHERE v.Vendor = o.Vendor)))
                       AND (x.DataDate IS NULL OR x.DataDate <= @AsOfDate)
                     ORDER BY IIF(x.Vendor IS NULL, 1, 0), x.DataDate DESC) c
    ), s AS (
        SELECT t.*, CASE WHEN Capital IS NULL OR Capital <= 0 THEN N'無資本額'
                         WHEN Curs <> 1 OR Cur <> CapCur OR Amt IS NULL THEN N'未判斷'
                         ELSE N'已比對' END AS Status
        FROM t
    )
    INSERT kri.K05_Detail
    SELECT @RunId, Vendor, VendorName, Cnt, IIF(Curs = 1, Amt, NULL), IIF(Curs = 1, Cur, NULL), Capital, CapCur,
           IIF(Status = N'已比對', Amt / Capital, NULL), Status,
           IIF(Status = N'已比對' AND Amt / Capital > @ratio, 1, 0)
    FROM s;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Vendor, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K05', Vendor, 'VENDOR', Vendor, Ratio, @ratio, OpenAmountLocal - Capital * @ratio, LocalCurrency,
           CONCAT(N'Open PO 未收金額 ', FORMAT(OpenAmountLocal, 'N0'), N' 是實收資本額的 ', FORMAT(Ratio, 'P0'))
    FROM kri.K05_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'有 Open PO 的供應商 ', COUNT(*), N'；已比對 ', COUNT(CASE WHEN Status = N'已比對' THEN 1 END),
                          N'、無資本額 ', COUNT(CASE WHEN Status = N'無資本額' THEN 1 END),
                          N'、未判斷 ', COUNT(CASE WHEN Status = N'未判斷' THEN 1 END),
                          IIF(NOT EXISTS (SELECT 1 FROM ext.VendorCapital), N'（ext.VendorCapital 沒有資料）', N''))
    FROM kri.K05_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K06 用量 vs 請購量 vs 庫存
-- 請購當天的（庫存 + 在途 PO）÷ 過去 UsageMonths 個月平均月耗用 = 覆蓋月數，> MaxCoverageMonths 仍請購 → 標記。
-- 過去沒有耗用、手上又有庫存或在途的（FlagNoUsage = 1）也標記。
-- 庫存用 kri.StockAt 回推；耗用 = ConsumptionMovementType 的異動（貸方加、借方減）。
-- ======================================================================
IF OBJECT_ID(N'kri.K06_Detail', N'U') IS NULL
CREATE TABLE kri.K06_Detail (
    RunId          INT           NOT NULL,
    PrNumber       NVARCHAR(10)  NOT NULL,
    PrItem         NVARCHAR(5)   NOT NULL,
    PrDate         DATE          NULL,
    Material       NVARCHAR(18)  NULL,
    Plant          NVARCHAR(4)   NULL,
    CostCenter     NVARCHAR(10)  NULL,
    ReqQty         DECIMAL(19,4) NULL,
    Uom            NVARCHAR(3)   NULL,
    StockAtPr      DECIMAL(19,4) NULL,
    OpenPoQty      DECIMAL(19,4) NULL,
    AvgMonthlyUse  DECIMAL(19,4) NULL,
    CoverageMonths DECIMAL(19,4) NULL,
    Status         NVARCHAR(10)  NOT NULL,  -- 已比對 / 無耗用 / 無庫存資料
    Amount         DECIMAL(19,4) NULL,      -- PR 數量 × 評價價格（PR 幣別）
    Currency       NVARCHAR(5)   NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K06_Detail PRIMARY KEY (RunId, PrNumber, PrItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K06
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cov    DECIMAL(19,4) = kri.Param('K06', 'MaxCoverageMonths'),
            @months INT           = kri.Param('K06', 'UsageMonths'),
            @nouse  INT           = kri.Param('K06', 'FlagNoUsage');

    WITH r AS (
        SELECT r.PrNumber, r.PrItem, r.PrDate, r.Material, r.Plant, r.CostCenter, r.ReqQty, r.Uom, r.Currency,
               CAST(r.ReqQty * r.ValPrice AS DECIMAL(19,4)) AS Amount
        FROM prc.PurchaseRequisition r
        WHERE r.PrDate BETWEEN @PeriodFrom AND @PeriodTo
          AND ISNULL(r.DeletionInd, '') = '' AND r.ReqQty > 0
          AND ISNULL(r.Material, '') <> '' AND ISNULL(r.Plant, '') <> ''
          AND NOT EXISTS (SELECT 1 FROM kri.IsGeneric('K06', r.Material))     -- 通用料號的庫存、耗用不能比
    ), x AS (
        SELECT r.*, st.StockQty AS StockAtPr, ISNULL(op.Qty, 0) AS OpenPoQty, ISNULL(u.Qty, 0) / @months AS AvgMonthlyUse
        FROM r
        OUTER APPLY kri.StockAt(r.Material, r.Plant, r.PrDate) st
        OUTER APPLY (       -- 請購當天的在途：當天以前下單、扣掉當天以前收貨的數量（PO 訂購單位）
            SELECT SUM(IIF(q.OpenQty > 0, q.OpenQty * q.BasePerUnit, 0)) AS Qty   -- 換成基本單位（和庫存、耗用一致）
            FROM prc.PurchaseOrderDetail p
            OUTER APPLY (SELECT SUM(gr.Qty) AS Tot, SUM(gr.AsOfQty) AS AsOf, MAX(gr.PostingDate) AS LastGr
                         FROM (SELECT gr.PostingDate, IIF(gr.DebitCreditInd = 'H', -gr.Quantity, gr.Quantity) AS Qty,
                                      IIF(gr.PostingDate <= r.PrDate AND ISNULL(gr.EntryDate, gr.PostingDate) <= r.PrDate,
                                          IIF(gr.DebitCreditInd = 'H', -gr.Quantity, gr.Quantity), 0) AS AsOfQty
                               FROM prc.GoodsReceipt gr
                               WHERE gr.PoNumber = p.PoNumber AND gr.PoItem = p.PoItem) gr) g
            -- 收貨的單位可能是基本單位：用「當天以前收貨 ÷ 全部收貨」的比例換成 PO 上的已收數量
            -- 每個訂購單位 = 幾個基本單位：用收貨量 ÷ PO 已收數量推估，沒收過貨當 1
            CROSS APPLY (SELECT p.OrderQty - IIF(g.Tot > 0, ISNULL(p.GrQty, 0) * g.AsOf / g.Tot, ISNULL(p.GrQty, 0)) AS OpenQty,
                                IIF(g.Tot > 0 AND p.GrQty > 0, g.Tot / p.GrQty, 1) AS BasePerUnit) q
            WHERE p.Material = r.Material AND p.Plant = r.Plant AND p.PoDate <= r.PrDate
              AND p.PoDate > DATEADD(YEAR, -2, r.PrDate) AND ISNULL(p.DeletionInd, '') = '' AND p.OrderQty > 0
              AND NOT (ISNULL(p.PrNumber, '') = r.PrNumber AND ISNULL(p.PrItem, '') = r.PrItem)    -- 這張 PR 自己轉的 PO 不算
              AND NOT (ISNULL(p.DelivComplInd, '') <> '' AND ISNULL(g.LastGr, p.PoDate) <= r.PrDate)) op   -- 已結案的不算
        OUTER APPLY (
            SELECT SUM(IIF(m.DebitCreditInd = 'H', m.Quantity, -m.Quantity)) AS Qty
            FROM inv.MaterialMovement m
            WHERE m.Material = r.Material AND m.Plant = r.Plant
              AND m.PostingDate > DATEADD(MONTH, -@months, r.PrDate) AND m.PostingDate <= r.PrDate
              AND m.MovementType IN (SELECT ListValue FROM kri.ValueList
                                     WHERE KriCode IN ('K06', '*') AND ListName = 'ConsumptionMovementType')) u
    ), s AS (
        SELECT x.*,
               CASE WHEN StockAtPr IS NULL THEN N'無庫存資料'
                    WHEN AvgMonthlyUse <= 0 THEN N'無耗用'
                    ELSE N'已比對' END AS Status,
               IIF(AvgMonthlyUse > 0, (ISNULL(StockAtPr, 0) + OpenPoQty) / AvgMonthlyUse, NULL) AS Coverage
        FROM x
    )
    INSERT kri.K06_Detail
    SELECT @RunId, PrNumber, PrItem, PrDate, Material, Plant, CostCenter, ReqQty, Uom, StockAtPr, OpenPoQty,
           AvgMonthlyUse, Coverage, Status, Amount, Currency,
           IIF((Status = N'已比對' AND Coverage > @cov)
               OR (Status = N'無耗用' AND @nouse = 1 AND StockAtPr + OpenPoQty > 0), 1, 0)
    FROM s;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocNumber, DocItem, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K06', CONCAT(PrNumber, '-', PrItem), 'PR', Plant, Material, PrNumber, PrItem, PrDate,
           CoverageMonths, @cov, Amount, Currency,
           IIF(Status = N'無耗用',
               CONCAT(N'過去 ', @months, N' 個月沒有耗用，庫存 + 在途 ', FORMAT(StockAtPr + OpenPoQty, 'N0'), N' 仍請購'),
               CONCAT(N'庫存 + 在途可用 ', FORMAT(CoverageMonths, 'N1'), N' 個月仍請購'))
    FROM kri.K06_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'有料號的 PR 項目 ', COUNT(*), N'；無耗用 ', COUNT(CASE WHEN Status = N'無耗用' THEN 1 END),
                          N'；無庫存資料 ', COUNT(CASE WHEN Status = N'無庫存資料' THEN 1 END))
    FROM kri.K06_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K07 本期 vs 預期請購量
-- 料號 × 工廠 × 月的請購量，和預期量比：有 ext.ExpectedDemand 用它，沒有用過去 12 個月「有請購的月份」的平均
-- （有請購的月份少於 MinHistoryMonths 不判斷）。比例 > Multiplier → 標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K07_Detail', N'U') IS NULL
CREATE TABLE kri.K07_Detail (
    RunId          INT           NOT NULL,
    Material       NVARCHAR(18)  NOT NULL,
    Plant          NVARCHAR(4)   NOT NULL,
    Uom            NVARCHAR(3)   NOT NULL,
    Month          DATE          NOT NULL,
    MonthQty       DECIMAL(19,4) NULL,
    ExpectedQty    DECIMAL(19,4) NULL,
    ExpectedSource NVARCHAR(10)  NULL,      -- 預期量表 / 歷史平均
    HistoryMonths  INT           NULL,      -- 過去 12 個月有請購的月份數
    Ratio          DECIMAL(19,6) NULL,
    IsFlagged      BIT           NOT NULL,
    CONSTRAINT PK_kri_K07_Detail PRIMARY KEY (RunId, Material, Plant, Uom, Month)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K07
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @mult DECIMAL(19,6) = kri.Param('K07', 'Multiplier'),
            @minh INT           = kri.Param('K07', 'MinHistoryMonths');

    WITH m AS (
        SELECT Material, Plant, ISNULL(Uom, '') AS Uom, DATEFROMPARTS(YEAR(PrDate), MONTH(PrDate), 1) AS Month,
               SUM(ReqQty) AS Qty
        FROM prc.PurchaseRequisition
        WHERE PrDate BETWEEN DATEADD(MONTH, -12, DATEFROMPARTS(YEAR(@PeriodFrom), MONTH(@PeriodFrom), 1)) AND @PeriodTo
          AND ISNULL(DeletionInd, '') = '' AND ReqQty > 0
          AND ISNULL(Material, '') <> '' AND ISNULL(Plant, '') <> ''
          AND NOT EXISTS (SELECT 1 FROM kri.IsGeneric('K07', Material))       -- 通用料號的數量是不同東西加總
        GROUP BY Material, Plant, ISNULL(Uom, ''), DATEFROMPARTS(YEAR(PrDate), MONTH(PrDate), 1)
    ), c AS (
        SELECT m.*, h.Qty AS HistQty, h.Months AS HistMonths, e.Qty AS ExtQty
        FROM m
        OUTER APPLY (SELECT SUM(h.Qty) AS Qty, COUNT(*) AS Months FROM m h      -- 過去 12 個月內有請購的月份
                     WHERE h.Material = m.Material AND h.Plant = m.Plant AND h.Uom = m.Uom
                       AND h.Month >= DATEADD(MONTH, -12, m.Month) AND h.Month < m.Month) h
        LEFT JOIN ext.ExpectedDemand e ON e.Material = m.Material AND e.Plant = m.Plant AND e.Month = m.Month
        WHERE m.Month >= DATEFROMPARTS(YEAR(@PeriodFrom), MONTH(@PeriodFrom), 1)
    ), x AS (
        SELECT c.*,
               CASE WHEN ExtQty IS NOT NULL THEN ExtQty
                    WHEN HistMonths >= @minh THEN HistQty / HistMonths END AS Expected,   -- 有請購月份的平均（零星採購不會被 0 稀釋）
               CASE WHEN ExtQty IS NOT NULL THEN N'預期量表' WHEN HistMonths >= @minh THEN N'歷史平均' END AS Src
        FROM c
    )
    INSERT kri.K07_Detail
    SELECT @RunId, Material, Plant, Uom, Month, Qty, Expected, Src, HistMonths,
           Qty / NULLIF(Expected, 0),
           IIF(Expected > 0 AND Qty / Expected > @mult, 1, 0)
    FROM x;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocDate,
                     MetricValue, ThresholdValue, Reason)
    SELECT RunId, 'K07', CONCAT(Material, '-', Plant, '-', Uom, '-', FORMAT(Month, 'yyyyMM')), 'MATERIAL', Plant, Material, Month,
           Ratio, @mult,
           CONCAT(FORMAT(Month, 'yyyy-MM'), N' 請購 ', FORMAT(MonthQty, 'N0'), N'，是', ExpectedSource, N' ',
                  FORMAT(ExpectedQty, 'N1'), N' 的 ', FORMAT(Ratio, 'N1'), N' 倍')
    FROM kri.K07_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'料號×工廠×月 ', COUNT(*), N'；用預期量表 ', COUNT(CASE WHEN ExpectedSource = N'預期量表' THEN 1 END),
                          N'；歷史不足不判斷（過去 12 個月有請購的月份少於 ', @minh, N'）', COUNT(CASE WHEN ExpectedSource IS NULL THEN 1 END))
    FROM kri.K07_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K11 非緊急之緊急採購
-- 緊急採購 = PO 類型在 EmergencyPoType，或收貨說明符合 EmergencyTextPattern。
-- 下單前一天工廠庫存 > MinStockQty、或零件系統 MOU > MaxMou、或 waiting for use >= MinWaitingForUse → 不該走緊急 → 標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K11_Detail', N'U') IS NULL
CREATE TABLE kri.K11_Detail (
    RunId         INT           NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    PoDate        DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    Material      NVARCHAR(18)  NULL,
    EmergencyBy   NVARCHAR(10)  NOT NULL,  -- PO類型 / 說明文字
    StockAtPo     DECIMAL(19,4) NULL,      -- 下單前一天的工廠庫存
    Mou           DECIMAL(19,4) NULL,
    WaitingForUse DECIMAL(19,4) NULL,
    AmountLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K11_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K11
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @stock DECIMAL(19,4) = kri.Param('K11', 'MinStockQty'),
            @mou   DECIMAL(19,4) = kri.Param('K11', 'MaxMou'),
            @wfu   DECIMAL(19,4) = kri.Param('K11', 'MinWaitingForUse');

    WITH e AS (
        SELECT b.*, CASE WHEN p.PoType IN (SELECT ListValue FROM kri.ValueList
                                           WHERE KriCode IN ('K11', '*') AND ListName = 'EmergencyPoType') THEN N'PO類型'
                         WHEN EXISTS (SELECT 1 FROM prc.GoodsReceipt g JOIN kri.ValueList x
                                        ON x.KriCode IN ('K11', '*') AND x.ListName = 'EmergencyTextPattern'
                                       AND g.ItemText LIKE x.ListValue
                                      WHERE g.PoNumber = b.PoNumber AND g.PoItem = b.PoItem
                                        AND ISNULL(g.EntryDate, g.PostingDate) <= @AsOfDate) THEN N'說明文字' END AS EmergencyBy
        FROM kri.PoBase('K11', @PeriodFrom, @PeriodTo) b
        JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
        WHERE ISNULL(b.Material, '') <> ''
    )
    INSERT kri.K11_Detail
    SELECT @RunId, e.PoNumber, e.PoItem, e.PoDate, e.CompanyCode, e.PurchOrg, e.Plant, e.Vendor, e.Material,
           e.EmergencyBy, st.StockQty, u.Mou, u.WaitingForUse,
           kri.ToLocal(e.NetValue, e.Currency, e.LocalCurrency, e.ExchangeRate), e.LocalCurrency,
           IIF(st.StockQty > @stock OR u.Mou > @mou OR u.WaitingForUse >= @wfu, 1, 0)
    FROM e
    OUTER APPLY kri.StockAt(e.Material, e.Plant, DATEADD(DAY, -1, e.PoDate)) st
    OUTER APPLY (SELECT TOP 1 Mou, WaitingForUse FROM ext.PartUsage x
                 WHERE x.Material = e.Material AND x.Plant = e.Plant AND x.SnapshotDate < e.PoDate
                 ORDER BY x.SnapshotDate DESC) u
    WHERE e.EmergencyBy IS NOT NULL;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K11', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, StockAtPo, @stock, AmountLocal, LocalCurrency,
           CONCAT(N'緊急採購（', EmergencyBy, N'）但',
                  CONCAT_WS(N'、', IIF(StockAtPo > @stock, CONCAT(N'下單前庫存 ', FORMAT(StockAtPo, 'N0')), NULL),
                                   IIF(Mou > @mou, CONCAT(N'MOU ', FORMAT(Mou, 'N1')), NULL),
                                   IIF(WaitingForUse >= @wfu, CONCAT(N'待用 ', FORMAT(WaitingForUse, 'N0')), NULL)))
    FROM kri.K11_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'緊急採購 PO 項目 ', COUNT(*), N'；沒有庫存資料 ', COUNT(CASE WHEN StockAtPo IS NULL THEN 1 END),
                          IIF(NOT EXISTS (SELECT 1 FROM ext.PartUsage), N'（ext.PartUsage 沒有資料，只看庫存）', N''),
                          IIF(NOT EXISTS (SELECT 1 FROM kri.ValueList WHERE KriCode IN ('K11', '*')
                                            AND ListName IN ('EmergencyPoType', 'EmergencyTextPattern')),
                              N'（沒有設定緊急採購的判斷條件）', N''))
    FROM kri.K11_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- 呆滯判斷（K15、K16 共用）：優先用呆滯報表快照（ext.SlowMoving，取指定日以前最新一份）；
-- 沒有快照而且 UseSapFallback = 1 時，用最後一次異動日 + SlowDays 推估認列呆滯的日期。
-- ======================================================================
CREATE OR ALTER FUNCTION kri.SlowStatusAt (@Material NVARCHAR(18), @Plant NVARCHAR(4), @OnDate DATE,
                                            @SlowDays INT, @UseSapFallback INT)
RETURNS TABLE
AS RETURN
SELECT TOP 1 *
FROM (
    SELECT 1 AS Pref, N'呆滯報表' AS Source, s.SnapshotDate, s.Status, s.SlowOn, CAST(NULL AS DATE) AS LastMoveDate,
           s.StockQty, s.StockValue, s.Currency
    FROM ext.SlowMoving s
    WHERE s.Material = @Material AND s.Plant = @Plant AND s.SnapshotDate <= @OnDate
      AND s.SnapshotDate = (SELECT MAX(SnapshotDate) FROM ext.SlowMoving WHERE SnapshotDate <= @OnDate)
    UNION ALL
    SELECT 2, N'SAP推估', NULL, NULL, DATEADD(DAY, @SlowDays, m.LastMove), m.LastMove, NULL, NULL, NULL
    FROM (SELECT MAX(PostingDate) AS LastMove FROM inv.MaterialMovement
          WHERE Material = @Material AND Plant = @Plant AND PostingDate <= @OnDate) m
    WHERE @UseSapFallback = 1 AND m.LastMove IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM ext.SlowMoving WHERE SnapshotDate <= @OnDate)
) x
ORDER BY Pref;
GO

-- ======================================================================
-- K15 已屆呆滯之警示
-- 基準日有庫存、還沒認列呆滯、WarnDays 天內就會認列的料號 × 工廠 → 標記（提前警示）。
-- ======================================================================
IF OBJECT_ID(N'kri.K15_Detail', N'U') IS NULL
CREATE TABLE kri.K15_Detail (
    RunId        INT           NOT NULL,
    Material     NVARCHAR(18)  NOT NULL,
    Plant        NVARCHAR(4)   NOT NULL,
    Source       NVARCHAR(10)  NOT NULL,   -- 呆滯報表 / SAP推估
    SnapshotDate DATE          NULL,
    Status       NVARCHAR(20)  NULL,
    LastMoveDate DATE          NULL,
    SlowOn       DATE          NULL,
    DaysToSlow   INT           NULL,
    StockQty     DECIMAL(19,4) NULL,
    StockValue   DECIMAL(19,4) NULL,
    IsFlagged    BIT           NOT NULL,
    CONSTRAINT PK_kri_K15_Detail PRIMARY KEY (RunId, Material, Plant)
);
GO
IF COL_LENGTH('kri.K15_Detail', 'Currency') IS NULL
    ALTER TABLE kri.K15_Detail ADD Currency NVARCHAR(5) NULL;
GO

CREATE OR ALTER PROCEDURE kri.Run_K15
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @warn INT = kri.Param('K15', 'WarnDays'),
            @slow INT = kri.Param('K15', 'SlowDays'),
            @fb   INT = kri.Param('K15', 'UseSapFallback');

    WITH k AS (         -- 有呆滯報表用報表的料號；沒有用庫存表裡的料號（基準日庫存另外回推）
        SELECT Material, Plant FROM ext.SlowMoving
        WHERE SnapshotDate = (SELECT MAX(SnapshotDate) FROM ext.SlowMoving WHERE SnapshotDate <= @AsOfDate)
        UNION
        SELECT Material, Plant FROM inv.InventoryBalance
        WHERE NOT EXISTS (SELECT 1 FROM ext.SlowMoving WHERE SnapshotDate <= @AsOfDate)
        GROUP BY Material, Plant
    ), d AS (
        SELECT k.Material, k.Plant, s.Source, s.SnapshotDate, s.Status, s.LastMoveDate, s.SlowOn,
               IIF(s.Source = N'呆滯報表', s.StockQty, st.StockQty) AS Qty,
               -- 推估：金額用目前的庫存金額按基準日數量比例換算
               IIF(s.Source = N'呆滯報表', s.StockValue, ib.Value * st.StockQty / NULLIF(ib.Qty, 0)) AS Value,
               IIF(s.Source = N'呆滯報表', s.Currency, cc.LocalCurrency) AS Currency
        FROM k
        CROSS APPLY kri.SlowStatusAt(k.Material, k.Plant, @AsOfDate, @slow, @fb) s
        OUTER APPLY (SELECT StockQty FROM kri.StockAt(k.Material, k.Plant, @AsOfDate) WHERE s.Source = N'SAP推估') st
        OUTER APPLY (SELECT SUM(ISNULL(StockQty, 0) + ISNULL(QualityStock, 0) + ISNULL(BlockedStock, 0)) AS Qty,
                            MAX(StockValue) AS Value          -- 庫存金額是工廠層級，每個倉都重複，不能加總
                     FROM inv.InventoryBalance i
                     WHERE i.Material = k.Material AND i.Plant = k.Plant AND s.Source = N'SAP推估') ib
        OUTER APPLY (SELECT TOP 1 c.LocalCurrency FROM inv.MaterialMovement m      -- 工廠的本幣：從異動的公司別帶
                     JOIN kri.vCompanyCurrency c ON c.CompanyCode = m.CompanyCode
                     WHERE m.Material = k.Material AND m.Plant = k.Plant AND s.Source = N'SAP推估'
                     ORDER BY m.PostingDate DESC) cc
    )
    INSERT kri.K15_Detail (RunId, Material, Plant, Source, SnapshotDate, Status, LastMoveDate, SlowOn, DaysToSlow,
                           StockQty, StockValue, IsFlagged, Currency)
    SELECT @RunId, Material, Plant, Source, SnapshotDate, Status, LastMoveDate, SlowOn, DATEDIFF(DAY, @AsOfDate, SlowOn),
           Qty, Value, IIF(DATEDIFF(DAY, @AsOfDate, SlowOn) BETWEEN 0 AND @warn
                           AND (Qty > 0 OR (Source = N'呆滯報表' AND Qty IS NULL)), 1, 0), Currency   -- 報表沒填數量當有庫存
    FROM d
    WHERE Source = N'呆滯報表' OR Qty > 0;           -- 推估時只留基準日有庫存的

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K15', CONCAT(Material, '-', Plant), 'MATERIAL', Plant, Material, SlowOn,
           DaysToSlow, @warn, IIF(Currency IS NULL, NULL, StockValue), Currency,
           CONCAT(N'再 ', DaysToSlow, N' 天（', SlowOn, N'）認列呆滯；庫存 ', FORMAT(StockQty, 'N0'),
                  IIF(Source = N'SAP推估', CONCAT(N'（最後異動 ', LastMoveDate, N'，推估）'), N''))
    FROM kri.K15_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'料號×工廠 ', COUNT(*), N'；來源 ', ISNULL(MAX(Source), N'—'),
                          N'；已呆滯 ', COUNT(CASE WHEN DaysToSlow < 0 THEN 1 END))
    FROM kri.K15_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K16 呆滯料仍進行採購
-- PO 下單時料號已呆滯（呆滯報表的認列日 <= 下單日，或狀態在 SlowStatus；沒有報表時用最後異動 + SlowDays 推估）
-- 而且下單前有庫存。同料號 × 工廠最近 3 個月有幾個月這樣下單 >= MinConsecMonths → 標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K16_Detail', N'U') IS NULL
CREATE TABLE kri.K16_Detail (
    RunId         INT           NOT NULL,
    PoNumber      NVARCHAR(10)  NOT NULL,
    PoItem        NVARCHAR(5)   NOT NULL,
    PoDate        DATE          NULL,
    CompanyCode   NVARCHAR(4)   NULL,
    PurchOrg      NVARCHAR(4)   NULL,
    Plant         NVARCHAR(4)   NULL,
    Vendor        NVARCHAR(10)  NULL,
    Material      NVARCHAR(18)  NULL,
    Source        NVARCHAR(10)  NOT NULL,
    SlowStatus    NVARCHAR(20)  NULL,
    SlowOn        DATE          NULL,
    LastMoveDate  DATE          NULL,
    StockAtPo     DECIMAL(19,4) NULL,
    SlowMonths    INT           NULL,      -- 最近 3 個月（含當月）有呆滯仍下單的月數
    AmountLocal   DECIMAL(19,4) NULL,
    LocalCurrency NVARCHAR(5)   NULL,
    IsFlagged     BIT           NOT NULL,
    CONSTRAINT PK_kri_K16_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K16
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @minm INT = kri.Param('K16', 'MinConsecMonths'),
            @slow INT = kri.Param('K16', 'SlowDays'),
            @fb   INT = kri.Param('K16', 'UseSapFallback');

    INSERT kri.K16_Detail
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.Material,
           s.Source, s.Status, s.SlowOn, s.LastMoveDate, st.StockQty, NULL,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate), b.LocalCurrency, 0
    FROM kri.PoBase('K16', DATEADD(MONTH, -2, DATEFROMPARTS(YEAR(@PeriodFrom), MONTH(@PeriodFrom), 1)), @PeriodTo) b   -- 往前多抓兩個月算月數
    CROSS APPLY kri.SlowStatusAt(b.Material, b.Plant, DATEADD(DAY, -1, b.PoDate), @slow, @fb) s
    OUTER APPLY (SELECT StockQty FROM kri.StockAt(b.Material, b.Plant, DATEADD(DAY, -1, b.PoDate))
                 WHERE s.Source = N'SAP推估') st                                  -- 有呆滯報表時不用回推庫存
    WHERE ISNULL(b.Material, '') <> ''
      AND (s.SlowOn <= b.PoDate
           OR s.Status IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K16', '*') AND ListName = 'SlowStatus'))
      AND (s.Source = N'呆滯報表' OR st.StockQty > 0);

    UPDATE d SET SlowMonths = m.n
    FROM kri.K16_Detail d
    CROSS APPLY (SELECT COUNT(DISTINCT DATEFROMPARTS(YEAR(x.PoDate), MONTH(x.PoDate), 1)) AS n
                 FROM kri.K16_Detail x
                 WHERE x.RunId = d.RunId AND x.Material = d.Material AND x.Plant = d.Plant
                   AND x.PoDate >= DATEADD(MONTH, -2, DATEFROMPARTS(YEAR(d.PoDate), MONTH(d.PoDate), 1))
                   AND x.PoDate <= d.PoDate) m
    WHERE d.RunId = @RunId;

    DELETE kri.K16_Detail WHERE RunId = @RunId AND PoDate < @PeriodFrom;   -- 多抓的只用來算月數
    UPDATE kri.K16_Detail SET IsFlagged = 1 WHERE RunId = @RunId AND SlowMonths >= @minm;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K16', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, SlowMonths, @minm, AmountLocal, LocalCurrency,
           CONCAT(N'料號 ', IIF(Source = N'SAP推估', CONCAT(N'最後異動 ', LastMoveDate, N'、推估 ', SlowOn, N' 已呆滯'),
                                CONCAT(N'呆滯報表 ', ISNULL(SlowStatus, N''), N' ', ISNULL(CONVERT(NVARCHAR(10), SlowOn), N''))),
                  N'，仍下單；最近 3 個月有 ', SlowMonths, N' 個月這樣下單')
    FROM kri.K16_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'呆滯仍下單的 PO 項目 ', COUNT(*), N'；來源 ', ISNULL(MAX(Source), N'—'))
    FROM kri.K16_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K17 重大工程未簽合約
-- 工程類 PO（PO 類型 ConstructionPoType、物料群組 ConstructionMaterialGroup、總帳科目 ConstructionGlPattern 任一），
-- 整張 PO 本幣金額 >= MajorAmount（本幣在 AmountCurrency 時），沒有合約（PO 參照的 SAP 合約、或 ext.Contract）
-- 或合約簽約日晚於 PO → 標記。
-- ======================================================================
IF OBJECT_ID(N'kri.K17_Detail', N'U') IS NULL
CREATE TABLE kri.K17_Detail (
    RunId            INT           NOT NULL,
    PoNumber         NVARCHAR(10)  NOT NULL,
    PoDate           DATE          NULL,
    CompanyCode      NVARCHAR(4)   NULL,
    PurchOrg         NVARCHAR(4)   NULL,
    Vendor           NVARCHAR(10)  NULL,
    VendorName       NVARCHAR(80)  NULL,
    PoAmountLocal    DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    SapContract      NVARCHAR(10)  NULL,
    ExtContract      NVARCHAR(30)  NULL,
    ContractSignedOn DATE          NULL,
    Status           NVARCHAR(10)  NOT NULL,  -- 有合約 / 合約晚於PO / 無合約
    IsFlagged        BIT           NOT NULL,
    CONSTRAINT PK_kri_K17_Detail PRIMARY KEY (RunId, PoNumber)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K17
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @major DECIMAL(19,4) = kri.Param('K17', 'MajorAmount');

    WITH b AS (
        SELECT b.PoNumber, b.PoDate, b.CompanyCode, b.PurchOrg, b.Vendor, b.VendorName, b.LocalCurrency,
               kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal,
               NULLIF(p.Contract, '') AS Contract,
               IIF(p.PoType IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K17', '*') AND ListName = 'ConstructionPoType')
                   OR p.MaterialGroup IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K17', '*') AND ListName = 'ConstructionMaterialGroup')
                   OR EXISTS (SELECT 1 FROM kri.ValueList x WHERE x.KriCode IN ('K17', '*') AND x.ListName = 'ConstructionGlPattern'
                                AND p.GlAccount LIKE x.ListValue), 1, 0) AS IsConstruction
        FROM kri.PoBase('K17', @PeriodFrom, @PeriodTo) b
        JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
    ), po AS (          -- 有任一工程類項目的 PO，整張金額
        SELECT PoNumber, MIN(PoDate) AS PoDate, MAX(CompanyCode) AS CompanyCode, MAX(PurchOrg) AS PurchOrg,
               MAX(Vendor) AS Vendor, MAX(VendorName) AS VendorName, MAX(LocalCurrency) AS LocalCurrency,
               IIF(COUNT(*) = COUNT(AmountLocal), SUM(AmountLocal), NULL) AS Amount, MAX(Contract) AS Contract
        FROM b GROUP BY PoNumber HAVING MAX(IsConstruction) = 1
    ), c AS (
        SELECT po.*, x.ContractNo, x.SignedOn
        FROM po
        OUTER APPLY (SELECT TOP 1 ContractNo, SignedOn FROM ext.Contract k
                     WHERE (k.PoNumber = po.PoNumber
                            OR (k.PoNumber IS NULL AND k.Vendor = po.Vendor
                                AND po.PoDate BETWEEN ISNULL(k.ValidFrom, '1900-01-01') AND ISNULL(k.ValidTo, '9999-12-31')))
                       AND ISNULL(k.SignedOn, '1900-01-01') <= @AsOfDate
                     ORDER BY IIF(k.PoNumber IS NULL, 1, 0), IIF(k.SignedOn IS NULL, 1, 0), k.SignedOn) x
        WHERE po.Amount >= @major
          AND po.LocalCurrency IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K17', '*') AND ListName = 'AmountCurrency')
    )
    INSERT kri.K17_Detail
    SELECT @RunId, PoNumber, PoDate, CompanyCode, PurchOrg, Vendor, VendorName, Amount, LocalCurrency, Contract,
           ContractNo, SignedOn, s.Status, IIF(s.Status = N'有合約', 0, 1)
    FROM c
    CROSS APPLY (SELECT CASE WHEN Contract IS NOT NULL OR (ContractNo IS NOT NULL AND ISNULL(SignedOn, PoDate) <= PoDate) THEN N'有合約'
                             WHEN ContractNo IS NOT NULL THEN N'合約晚於PO'
                             ELSE N'無合約' END AS Status) s;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Vendor, DocNumber, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K17', PoNumber, 'PO', CompanyCode, PurchOrg, Vendor, PoNumber, PoDate,
           PoAmountLocal, @major, PoAmountLocal, LocalCurrency,
           IIF(Status = N'無合約', CONCAT(N'工程 PO ', FORMAT(PoAmountLocal, 'N0'), N' 沒有合約'),
               CONCAT(N'工程 PO ', FORMAT(PoAmountLocal, 'N0'), N'，合約 ', ExtContract, N' 在 ', ContractSignedOn,
                      N' 才簽（PO ', PoDate, N'）'))
    FROM kri.K17_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    IF NOT EXISTS (SELECT 1 FROM kri.ValueList WHERE KriCode IN ('K17', '*')
                     AND ListName IN ('ConstructionPoType', 'ConstructionMaterialGroup', 'ConstructionGlPattern'))
        SET @Note = N'沒有設定工程類 PO 的判斷條件（ConstructionPoType／MaterialGroup／GlPattern），這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'重大工程 PO ', COUNT(*), N'；無合約 ', COUNT(CASE WHEN Status = N'無合約' THEN 1 END),
                              N'、合約晚於 PO ', COUNT(CASE WHEN Status = N'合約晚於PO' THEN 1 END))
        FROM kri.K17_Detail WHERE RunId = @RunId;
END;
GO

-- ======================================================================
-- K20 驗退後未及時處理
-- 轉入待退倉（ReturnStorLoc）的異動（ReturnTransferType，借方），依先進先出配對同料號 × 工廠 × 倉 × 批號之後的出倉（貸方），
-- 全部出清的日期 = 處理日；停留超過 MaxOpenDays 天（未處理的算到基準日）→ 標記。
-- 待退倉在資料起始日以前的餘額當 0。
-- ======================================================================
IF OBJECT_ID(N'kri.K20_Detail', N'U') IS NULL
CREATE TABLE kri.K20_Detail (
    RunId           INT           NOT NULL,
    MaterialDoc     NVARCHAR(10)  NOT NULL,
    MaterialDocYear NVARCHAR(4)   NOT NULL,
    MaterialDocItem NVARCHAR(4)   NOT NULL,
    PostingDate     DATE          NULL,
    Material        NVARCHAR(18)  NULL,
    Plant           NVARCHAR(4)   NULL,
    StorLoc         NVARCHAR(4)   NULL,
    Batch           NVARCHAR(10)  NULL,
    Quantity        DECIMAL(19,4) NULL,
    BaseUom         NVARCHAR(3)   NULL,
    ClearedOn       DATE          NULL,      -- NULL = 基準日還沒處理完
    OpenDays        INT           NULL,
    AmountLocal     DECIMAL(19,4) NULL,
    IsFlagged       BIT           NOT NULL,
    CONSTRAINT PK_kri_K20_Detail PRIMARY KEY (RunId, MaterialDoc, MaterialDocYear, MaterialDocItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K20
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @days INT = kri.Param('K20', 'MaxOpenDays');

    SELECT m.MaterialDoc, m.MaterialDocYear, m.MaterialDocItem, m.PostingDate, m.Material, m.Plant, m.StorLoc,
           ISNULL(m.Batch, '') AS Batch, m.Quantity, m.BaseUom, m.LocalAmount, m.MovementType, m.DebitCreditInd
    INTO #f
    FROM inv.MaterialMovement m
    WHERE m.StorLoc IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K20', '*') AND ListName = 'ReturnStorLoc')
      AND m.PostingDate <= @AsOfDate AND m.Quantity > 0;

    SELECT f.Material, f.Plant, f.StorLoc, f.Batch, f.PostingDate,        -- 出待退倉：累計出量
           SUM(Quantity) OVER (PARTITION BY Material, Plant, StorLoc, Batch
                               ORDER BY PostingDate, MaterialDoc, MaterialDocItem ROWS UNBOUNDED PRECEDING) AS CumOut
    INTO #o
    FROM #f f WHERE DebitCreditInd = 'H';
    CREATE CLUSTERED INDEX cx ON #o (Material, Plant, StorLoc, Batch, CumOut);

    WITH i AS (         -- 進待退倉：累計進量
        SELECT f.*, SUM(Quantity) OVER (PARTITION BY Material, Plant, StorLoc, Batch
                                        ORDER BY PostingDate, MaterialDoc, MaterialDocItem ROWS UNBOUNDED PRECEDING) AS CumIn
        FROM #f f WHERE DebitCreditInd = 'S'
    )
    INSERT kri.K20_Detail
    SELECT @RunId, i.MaterialDoc, i.MaterialDocYear, i.MaterialDocItem, i.PostingDate, i.Material, i.Plant, i.StorLoc,
           NULLIF(i.Batch, ''), i.Quantity, i.BaseUom, c.ClearedOn,
           DATEDIFF(DAY, i.PostingDate, ISNULL(c.ClearedOn, @AsOfDate)), i.LocalAmount,
           IIF(DATEDIFF(DAY, i.PostingDate, ISNULL(c.ClearedOn, @AsOfDate)) > @days, 1, 0)
    FROM i
    OUTER APPLY (SELECT MIN(o.PostingDate) AS ClearedOn FROM #o o
                 WHERE o.Material = i.Material AND o.Plant = i.Plant AND o.StorLoc = i.StorLoc AND o.Batch = i.Batch
                   AND o.CumOut >= i.CumIn AND o.PostingDate >= i.PostingDate) c
    WHERE i.PostingDate BETWEEN @PeriodFrom AND @PeriodTo
      AND i.MovementType IN (SELECT ListValue FROM kri.ValueList WHERE KriCode IN ('K20', '*') AND ListName = 'ReturnTransferType');

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Plant, Material, DocNumber, DocItem, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, Reason)
    SELECT RunId, 'K20', CONCAT(MaterialDoc, '-', MaterialDocYear, '-', MaterialDocItem), 'MOVEMENT', Plant, Material,
           MaterialDoc, MaterialDocItem, PostingDate, OpenDays, @days, AmountLocal,
           CONCAT(N'轉入待退倉 ', StorLoc, N' 後 ', OpenDays, N' 天',
                  IIF(ClearedOn IS NULL, N'仍未處理', CONCAT(N'才處理完（', ClearedOn, N'）')))
    FROM kri.K20_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    IF NOT EXISTS (SELECT 1 FROM kri.ValueList WHERE KriCode IN ('K20', '*') AND ListName = 'ReturnStorLoc')
        SET @Note = N'沒有設定待退倉（ReturnStorLoc），這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'轉入待退倉 ', COUNT(*), N' 筆；基準日仍未處理 ', COUNT(CASE WHEN ClearedOn IS NULL THEN 1 END))
        FROM kri.K20_Detail WHERE RunId = @RunId;
END;
GO
