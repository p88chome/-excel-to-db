-- 第一期 KRI：K08、K13、K14、K18、K21。規格見 docs/KRI_PRD.md 第 9 節。
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
    FROM kri.PoBase('K14', @PeriodFrom, @PeriodTo) b
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

    SELECT @Note = CONCAT(N'已比對 ', SUM(IIF(MatchStatus = N'已比對', 1, 0)), N' / ', COUNT(*),
                          N'；無主檔價 ', SUM(IIF(MatchStatus = N'無主檔價', 1, 0)),
                          N'、幣別不同 ', SUM(IIF(MatchStatus = N'幣別不同', 1, 0)),
                          N'、單位不同 ', SUM(IIF(MatchStatus = N'單位不同', 1, 0)))
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
        WHERE ISNULL(p.Material, '') <> '' AND p.UnitPrice > 0
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
    DECLARE @days INT = kri.Param('K21', 'BackdateDays');

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
           IIF(DATEDIFF(DAY, c.ValidFrom, c.CreatedOn) > @days, 1, 0)
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

    SELECT @Note = CONCAT(N'建立日晚於生效日的條件記錄 ', COUNT(*)) FROM kri.K21_Detail WHERE RunId = @RunId;
END;
GO
