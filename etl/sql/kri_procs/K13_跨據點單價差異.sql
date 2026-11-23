-- ======================================================================
-- K13 跨據點同料號單價差異
--
-- 【抓什麼】同一個料號，在差不多的時間、差不多的採購量下，某個據點買得比其他據點貴很多。
-- 【為什麼有風險】同一家公司不同據點各自議價，貴的那邊可能沒比價、議價不力，或有利益輸送。
--
-- 【怎麼判斷】
--   第 1 步：觀察期間內的 PO 項目（有料號、有單價，通用料號不看），分好比較群組：
--            料號 + 幣別 + 訂購單位 + 季度 + 數量級距（數量每差 QtyBandRatio 倍算不同級距）。
--            據點 = 公司別（EntityLevel = 1）或工廠（= 2）。
--   第 2 步：每個群組裡，每個據點的最低單價；找出最便宜和第二便宜的據點。至少要有 2 個據點才比。
--   第 3 步：每一行跟「其他據點」的最低單價比：自己就是最便宜的據點，就跟第二便宜的比。
--            單價 ÷ 其他據點最低單價 − 1 > PriceTolerance → 標記。
--            影響金額 =（單價 − 其他據點最低單價）× 數量，換成本幣。
--
-- 【門檻】（kri.Parameter，KriCode = 'K13'）
--   PriceTolerance  比其他據點最低單價高出多少比例才標記
--   QtyBandRatio    數量級距：每差幾倍算不同級距（要大於 1）
--   EntityLevel     據點層級：1 = 公司別、2 = 工廠
--
-- 【名單】（kri.ValueList）
--   ExcludeItemCategory   不比的 PO 項目類別（7／U = 庫存轉移，沒有採購價）；退貨項目（ExcludeReturnsInd）也不比
--   GenericMaterial  通用、雜項料號：單價沒有可比性，不看
--
-- 【明細表 kri.K13_Detail 怎麼看】（只留有其他據點可比的 PO 項目）
--   Entity          這一行的據點；PeriodQuarter 季度第一天；QtyBand 數量級距
--   EntityCount     同群組有幾個據點
--   OtherEntity     最便宜的其他據點；OtherMinPrice 是它的最低單價
--   DiffRatio       單價 ÷ OtherMinPrice − 1
--
-- 【限制】
--   只比同幣別、同訂購單位；跨幣別要等匯率表。
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

    -- 門檻
    DECLARE @tolerance    DECIMAL(19,6) = kri.Param('K13', 'PriceTolerance'),   -- 貴多少比例才標記
            @qtyBandRatio FLOAT         = kri.Param('K13', 'QtyBandRatio'),     -- 數量每差幾倍算不同級距
            @entityLevel  INT           = kri.Param('K13', 'EntityLevel');      -- 1 = 公司別、2 = 工廠
    IF @qtyBandRatio <= 1 THROW 50000, N'K13.QtyBandRatio 要大於 1', 1;

    -- 第 1 步：PO 項目和它的比較群組（季度、數量級距）、據點
    SELECT p.PoNumber, p.PoItem, p.PoDate, p.CompanyCode, p.PurchOrg, p.Plant, p.Vendor,
           p.Material, p.MaterialDesc, p.OrderQty, p.OrderUom, p.Currency, p.UnitPrice,
           p.LocalCurrency, p.ExchangeRate,
           CASE WHEN @entityLevel = 2 THEN p.Plant ELSE p.CompanyCode END AS Entity,
           DATEFROMPARTS(YEAR(p.PoDate), (DATEPART(QUARTER, p.PoDate) - 1) * 3 + 1, 1) AS PeriodQuarter,
           -- 數量級距：數量取對數（底數 = QtyBandRatio）後無條件捨去，例如底數 10 時 1～9 = 0、10～99 = 1
           CAST(FLOOR(LOG(CAST(p.OrderQty AS FLOAT)) / LOG(@qtyBandRatio)) AS INT) AS QtyBand
    INTO #Po
    FROM kri.PoBase('K13', @PeriodFrom, @PeriodTo) p
    WHERE ISNULL(p.Material, '') <> '' AND p.UnitPrice > 0 AND p.IsGeneric = 0;

    -- 第 2 步：每個群組裡每個據點的最低單價，排出便宜的順序
    SELECT Material, Currency, OrderUom, PeriodQuarter, QtyBand, Entity, MIN(UnitPrice) AS MinPrice
    INTO #EntityMin
    FROM #Po
    WHERE ISNULL(Entity, '') <> ''
    GROUP BY Material, Currency, OrderUom, PeriodQuarter, QtyBand, Entity;

    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY Material, Currency, OrderUom, PeriodQuarter, QtyBand
                              ORDER BY MinPrice, Entity) AS PriceRank,        -- 1 = 最便宜的據點
           COUNT(*)     OVER (PARTITION BY Material, Currency, OrderUom, PeriodQuarter, QtyBand) AS EntityCount
    INTO #EntityRank
    FROM #EntityMin;

    --   每個群組留下最便宜（E1、P1）和第二便宜（E2、P2）的據點；只有一個據點的群組沒得比
    SELECT Material, Currency, OrderUom, PeriodQuarter, QtyBand,
           MAX(EntityCount) AS EntityCount,
           MAX(CASE WHEN PriceRank = 1 THEN Entity END)   AS E1,
           MAX(CASE WHEN PriceRank = 1 THEN MinPrice END) AS P1,
           MAX(CASE WHEN PriceRank = 2 THEN Entity END)   AS E2,
           MAX(CASE WHEN PriceRank = 2 THEN MinPrice END) AS P2
    INTO #GroupBest
    FROM #EntityRank
    GROUP BY Material, Currency, OrderUom, PeriodQuarter, QtyBand
    HAVING MAX(EntityCount) >= 2;

    -- 第 3 步：每一行跟其他據點的最低單價比（自己就是最便宜的，就跟第二便宜的比）；寫進明細
    INSERT kri.K13_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor,
                           Material, MaterialDesc, Entity, PeriodQuarter, QtyBand, OrderQty, OrderUom,
                           Currency, UnitPrice, EntityCount, OtherEntity, OtherMinPrice, DiffRatio,
                           IsFlagged, EffectDoc, EffectLocal, LocalCurrency)
    SELECT @RunId, b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant, b.Vendor,
           b.Material, b.MaterialDesc, b.Entity, b.PeriodQuarter, b.QtyBand, b.OrderQty, b.OrderUom,
           b.Currency, b.UnitPrice, g.EntityCount, o.OtherEntity, o.OtherMinPrice, d.DiffRatio,
           CASE WHEN d.DiffRatio > @tolerance THEN 1 ELSE 0 END,
           e.EffectDoc,
           kri.ToLocal(e.EffectDoc, b.Currency, b.LocalCurrency, b.ExchangeRate),
           b.LocalCurrency
    FROM #Po b
    JOIN #GroupBest g ON g.Material = b.Material AND g.Currency = b.Currency AND g.OrderUom = b.OrderUom
                     AND g.PeriodQuarter = b.PeriodQuarter AND g.QtyBand = b.QtyBand
    CROSS APPLY (SELECT CASE WHEN b.Entity = g.E1 THEN g.E2 ELSE g.E1 END AS OtherEntity,
                        CASE WHEN b.Entity = g.E1 THEN g.P2 ELSE g.P1 END AS OtherMinPrice) o
    CROSS APPLY (SELECT b.UnitPrice / o.OtherMinPrice - 1 AS DiffRatio) d
    CROSS APPLY (SELECT CASE WHEN d.DiffRatio > @tolerance
                             THEN (b.UnitPrice - o.OtherMinPrice) * b.OrderQty END AS EffectDoc) e;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K13', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tolerance, EffectLocal, LocalCurrency,
           CONCAT(N'單價比據點 ', OtherEntity, N' 高 ', FORMAT(DiffRatio, 'P1'))
    FROM kri.K13_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'可跨據點比較的 PO 項目 ', COUNT(*)) FROM kri.K13_Detail WHERE RunId = @RunId;
END;
GO
