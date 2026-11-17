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
                          SUM(IIF(BackdateDays > @days AND PoCount = 0, 1, 0)))
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
        SELECT IssueNo, Status, Material, OpenedOn,
               IIF(IsClosed = 1, ClosedOn, @AsOfDate) AS WindowEnd,
               -- 純數字的供應商代碼補前導零到 10 碼（SAP 的 LIFNR 格式）
               IIF(Vendor NOT LIKE '%[^0-9]%' AND LEN(Vendor) < 10,
                   RIGHT(REPLICATE('0', 10) + Vendor, 10), Vendor) AS Vendor
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
        CROSS APPLY kri.PoBase('K01', IIF(q.OpenedOn > @PeriodFrom, q.OpenedOn, @PeriodFrom),
                                      IIF(q.WindowEnd < @PeriodTo, q.WindowEnd, @PeriodTo)) b
        WHERE b.Vendor = q.Vendor
          AND (@same = 0 OR (ISNULL(q.Material, '') <> '' AND b.Material = q.Material))
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
           MAX(Vendor), MAX(Material), PoNumber, PoItem, MAX(PoDate), COUNT(*), @min,
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
                       AND x.FieldName = u.FieldName AND ISNULL(x.NewValue, '') <> '' AND x.ChangeAt > u.ChangeAt
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
          AND (w.TableName <> 'LFM1' OR b.PurchOrg = w.Scope)
          AND (w.TableName <> 'LFB1' OR b.CompanyCode = w.Scope)
    ) po
    OUTER APPLY (
        SELECT COUNT(DISTINCT CONCAT(a.CompanyCode, '-', a.AccountingDoc, '-', a.FiscalYear)) AS Cnt
        FROM fin.AccountsPayable a
        WHERE a.Vendor = w.Vendor
          AND a.PostingDate BETWEEN w.ChangeDate AND ISNULL(w.ReblockDate, @AsOfDate)
          AND (w.TableName <> 'LFB1' OR a.CompanyCode = w.Scope)
    ) ap;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, PurchOrg, CompanyCode, Vendor,
                     DocNumber, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K03', CONCAT(Vendor, '-', TableName, '-', FieldName, '-', UnblockChange), 'VENDOR',
           IIF(TableName = 'LFM1', Scope, NULL), IIF(TableName = 'LFB1', Scope, NULL), Vendor,
           UnblockChange, UnblockDate, OpenDays, @days, PoAmountLocal, LocalCurrency,
           CONCAT(TableName, N'.', FieldName, N' 解凍 ', OpenDays, N' 天後再凍結；期間內 PO 項目 ', PoCount,
                  N' 筆、應付傳票 ', ApCount, N' 張', IIF(UnblockedBy = ReblockedBy, N'；解凍與再凍結同一人', N''))
    FROM kri.K03_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'解凍事件 ', COUNT(*), N'；尚未再凍結 ', SUM(IIF(ReblockDate IS NULL, 1, 0)))
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
    CONSTRAINT PK_kri_K04_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K04
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @min  INT           = kri.Param('K04', 'MinDaysWorse'),
            @rate DECIMAL(19,6) = kri.Param('K04', 'AnnualRate'),
            @lvl  INT           = kri.Param('K04', 'MasterLevel');   -- 1 = 只認 LFM1；2 = 和 LFB1 一樣也算一致

    WITH b AS (
        SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Vendor, b.VendorName,
               b.NetValue, b.Currency, b.ExchangeRate, b.LocalCurrency, p.PaymentTerm AS PoTerm,
               (SELECT TOP 1 v.PurchOrgPaymentTerms FROM mst.Vendor v
                WHERE v.Vendor = b.Vendor AND v.PurchOrg = b.PurchOrg AND ISNULL(v.PurchOrgPaymentTerms, '') <> ''
                ORDER BY v.CompanyCode) AS MasterTerm,
               (SELECT TOP 1 v.PaymentTerms FROM mst.Vendor v
                WHERE v.Vendor = b.Vendor AND v.CompanyCode = b.CompanyCode AND ISNULL(v.PaymentTerms, '') <> ''
                ORDER BY v.PurchOrg) AS CompanyTerm,
               (SELECT TOP 1 a.PaymentTerms FROM fin.AccountsPayable a
                WHERE a.PoNumber = b.PoNumber AND a.PoItem = b.PoItem AND ISNULL(a.PaymentTerms, '') <> ''
                ORDER BY ISNULL(kri.TermDays(a.PaymentTerms), 2147483647), a.PaymentTerms) AS ApTerm
        FROM kri.PoBase('K04', @PeriodFrom, @PeriodTo) b
        JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
        WHERE ISNULL(b.Vendor, '') <> '' AND ISNULL(p.PaymentTerm, '') <> ''
    ), d AS (
        SELECT b.*, kri.TermDays(PoTerm) AS PoDays, kri.TermDays(MasterTerm) AS MasterDays,
               kri.TermDays(ApTerm) AS ApDays,
               kri.ToLocal(NetValue, Currency, LocalCurrency, ExchangeRate) AS AmountLocal
        FROM b
    ), m AS (           -- PO 和主檔算不算不同：MasterLevel = 2 時，和公司別層（LFB1）一樣也算一致
        SELECT d.*, IIF(PoTerm <> MasterTerm AND NOT (@lvl = 2 AND PoTerm = CompanyTerm), 1, 0) AS PoDiff,
               IIF(ApTerm IS NOT NULL AND ApTerm <> PoTerm, 1, 0) AS ApDiff
        FROM d
    ), s AS (
        SELECT m.*,
               CASE WHEN MasterTerm IS NULL THEN N'缺主檔'
                    WHEN PoDiff = 1 AND ApDiff = 1 THEN N'都不同'
                    WHEN PoDiff = 1 THEN N'PO與主檔不同'
                    WHEN ApDiff = 1 THEN N'AP與PO不同'
                    WHEN PoTerm <> MasterTerm THEN N'同公司別主檔'
                    ELSE N'一致' END AS Status,
               (SELECT MAX(v) FROM (VALUES (IIF(PoDiff = 1, MasterDays - PoDays, NULL)),
                                           (IIF(ApDiff = 1, PoDays - ApDays, NULL))) x(v)) AS WorseDays
        FROM m
    )
    INSERT kri.K04_Detail
    SELECT @RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Vendor, VendorName,
           PoTerm, MasterTerm, CompanyTerm, ApTerm, PoDays, MasterDays, ApDays, Status, WorseDays,
           AmountLocal, LocalCurrency,
           IIF(WorseDays >= @min, 1, 0),
           IIF(WorseDays >= @min, AmountLocal * WorseDays / 365.0 * @rate, NULL)
    FROM s;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Vendor,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K04', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Vendor,
           PoNumber, PoItem, PoDate, WorseDays, @min, EffectLocal, LocalCurrency,
           CONCAT(N'付款條件 PO ', PoTerm, N' / 主檔 ', MasterTerm,
                  IIF(ApTerm IS NOT NULL, CONCAT(N' / 應付 ', ApTerm), N''), N'，提早 ', WorseDays, N' 天付款')
    FROM kri.K04_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'PO 項目 ', COUNT(*), N'；PO與主檔不同 ', SUM(IIF(Status IN (N'PO與主檔不同', N'都不同'), 1, 0)),
                          N'、AP與PO不同 ', SUM(IIF(Status IN (N'AP與PO不同', N'都不同'), 1, 0)),
                          N'、缺主檔 ', SUM(IIF(Status = N'缺主檔', 1, 0)),
                          N'、和 LFM1 不同但同 LFB1 ', SUM(IIF(Status = N'同公司別主檔', 1, 0)),
                          N'；條件不同但推不出天數 ',
                          SUM(IIF(Status NOT IN (N'一致', N'缺主檔', N'同公司別主檔') AND WorseDays IS NULL, 1, 0)))
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
    PoAmountLocal    DECIMAL(19,4) NULL,     -- 整張 PO 的本幣金額（母體內的項目合計）
    AmountCheck      NVARCHAR(20)  NOT NULL, -- 未超過 / 超過上限 / 未判斷 / 不限
    ItemAmountLocal  DECIMAL(19,4) NULL,
    LocalCurrency    NVARCHAR(5)   NULL,
    IsFlagged        BIT           NOT NULL,
    CONSTRAINT PK_kri_K10_Detail PRIMARY KEY (RunId, PoNumber, PoItem)
);
GO

CREATE OR ALTER PROCEDURE kri.Run_K10
    @RunId INT, @AsOfDate DATE, @PeriodFrom DATE, @PeriodTo DATE, @Note NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @gap INT           = kri.Param('K10', 'MaxGapDays'),
            @max DECIMAL(19,4) = kri.Param('K10', 'MaxPoAmount');    -- 0 = 不限

    WITH b AS (
        SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor, b.VendorName,
               b.Material, b.LocalCurrency, r.FirstGrDate, r.FirstGrEntryDate, r.HasExcludedText,
               kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS ItemAmountLocal
        FROM kri.PoBase('K10', @PeriodFrom, @PeriodTo) b
        JOIN kri.PoReceipt('K10') r ON r.PoNumber = b.PoNumber AND r.PoItem = b.PoItem
    ), t AS (
        SELECT b.*, SUM(ItemAmountLocal) OVER (PARTITION BY PoNumber) AS PoAmountLocal,
               DATEDIFF(DAY, PoDate, IIF(FirstGrEntryDate < FirstGrDate, FirstGrEntryDate, FirstGrDate)) AS GapDays
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
    )
    INSERT kri.K10_Detail
    SELECT @RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, VendorName, Material,
           FirstGrDate, FirstGrEntryDate, GapDays, HasExcludedText, PoAmountLocal, AmountCheck,
           ItemAmountLocal, LocalCurrency,
           IIF(GapDays <= @gap AND HasExcludedText = 0 AND AmountCheck <> N'超過上限', 1, 0)
    FROM c;

    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K10', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, GapDays, @gap, ItemAmountLocal, LocalCurrency,
           CONCAT(IIF(GapDays < 0, CONCAT(N'收貨早於 PO ', -GapDays, N' 天'), CONCAT(N'PO 後 ', GapDays, N' 天就收貨')),
                  IIF(AmountCheck = N'未判斷', N'（金額上限未判斷）', N''))
    FROM kri.K10_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    SELECT @Note = CONCAT(N'有收貨的 PO 項目 ', COUNT(*), N'；收貨早於 PO ', SUM(IIF(GapDays < 0, 1, 0)),
                          N'；排除關鍵字 ', SUM(IIF(HasExcludedText = 1, 1, 0)),
                          N'；超過金額上限 ', SUM(IIF(AmountCheck = N'超過上限', 1, 0)),
                          N'；金額未判斷 ', SUM(IIF(AmountCheck = N'未判斷', 1, 0)))
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
               r.FirstGrDate, r.FirstGrEntryDate, r.HasExcludedText,
               kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS ItemAmountLocal
        FROM kri.PoBase('K19', @PeriodFrom, @PeriodTo) b
        JOIN kri.PoReceipt('K19') r ON r.PoNumber = b.PoNumber AND r.PoItem = b.PoItem
        JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem
        LEFT JOIN prc.PurchaseRequisition pr ON pr.PrNumber = p.PrNumber AND pr.PrItem = p.PrItem
    ), t AS (
        SELECT b.*, IIF(PrDate IS NOT NULL, 'PR', 'PO') AS RefType, ISNULL(PrDate, PoDate) AS RefDate,
               DATEDIFF(DAY, ISNULL(PrDate, PoDate),
                        IIF(FirstGrEntryDate < FirstGrDate, FirstGrEntryDate, FirstGrDate)) AS GapDays
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

    SELECT @Note = CONCAT(N'有收貨的 PO 項目 ', COUNT(*), N'（有 PR ', SUM(IIF(RefType = 'PR', 1, 0)),
                          N'）；排除關鍵字 ', SUM(IIF(HasExcludedText = 1, 1, 0)))
    FROM kri.K19_Detail WHERE RunId = @RunId;
END;
GO
