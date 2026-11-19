-- ======================================================================
-- K14 PO 單價高於主檔價
--
-- 【抓什麼】PO 上的單價，比下單那天有效的主檔價（採購資訊記錄的價格條件）還貴的 PO 項目。
-- 【為什麼有風險】主檔價是談好的價格，PO 卻用更高的價格下單：可能是採購人員手動改價、
--                 圖利供應商，或主檔沒更新導致多付錢。
--
-- 【怎麼判斷】
--   第 1 步：找出觀察期間內的 PO 項目（kri.PoBase，排除通用料號和沒有料號的），
--            再找下單日有效的主檔價（kri.InfoPriceAt：A017 分工廠的優先，沒有才用 A018）。
--            只用基準日以前已經建立的主檔價，基準日之後才建、生效日倒填的不算。
--   第 2 步：判斷能不能比：缺 PO 單價、找不到主檔價、主檔沒有單價、幣別不同、單位不同，都不比，
--            照樣寫進明細並註明原因。能比的算差異比例 = PO 單價 ÷ 主檔單價 − 1。
--   第 3 步：差異比例超過 PriceTolerance → 標記。影響金額 =（PO 單價 − 主檔單價）× 訂購數量，換成本幣。
--
-- 【門檻】（kri.Parameter，KriCode = 'K14'）
--   PriceTolerance  PO 單價比主檔價高出多少比例才標記（0.05 = 5%）
--   WindowMonths    觀察期間：只看最近幾個月下的 PO（預設 12）
--
-- 【名單】（kri.ValueList，KriCode = 'K14' 或 '*'）
--   AllowedConditionType  拿來比的價格條件類型（例：PB00）
--   AllowedInfoCategory   拿來比的資訊記錄類別（例：0 = 標準）
--   ExcludeVendorPrefix 等 PO 排除名單、GenericMaterial 通用料號
--
-- 【明細表 kri.K14_Detail 怎麼看】
--   PoUnitPrice    PO 單價（淨價 ÷ 價格單位）
--   InfoSource     主檔價來自 A017 或 A018；InfoUnitPrice 主檔單價
--   MatchStatus    已比對 / 無主檔價 / 幣別不同 / 單位不同 / 缺PO單價 / 主檔無單價
--   DiffRatio      PO 單價比主檔價高多少（0.2 = 高 20%）；比不了的是空的
--   EffectDoc      多付的金額（PO 幣別）；EffectLocal 換成本幣
--
-- 【限制】
--   級距價格（KONM）還沒下載，數量越多越便宜的級距價看不到。
--   主檔 PB00 是毛價、PO 是淨價（扣過折扣），有折扣時 PO 會比較便宜，不會誤標。
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

    -- 門檻
    DECLARE @tolerance DECIMAL(19,6) = kri.Param('K14', 'PriceTolerance');   -- 高出多少比例才標記

    -- 第 1 步：期間內的 PO 項目，配上下單日有效的主檔價
    SELECT b.PoNumber, b.PoItem, b.PoDate, b.CompanyCode, b.PurchOrg, b.Plant,
           b.Vendor, b.VendorName, b.Material, b.MaterialDesc, b.OrderQty, b.OrderUom,
           b.Currency, b.UnitPrice AS PoUnitPrice, b.LocalCurrency, b.ExchangeRate,
           i.Source AS InfoSource, i.ConditionRecord, i.ConditionType, i.ValidFrom AS InfoValidFrom,
           i.UnitPrice AS InfoUnitPrice, i.Currency AS InfoCurrency, i.OrderUom AS InfoUom
    INTO #PoWithInfo
    FROM kri.PoBase('K14', @PeriodFrom, @PeriodTo) b
    -- 只用基準日以前已建立的主檔價（@AsOfDate）
    OUTER APPLY kri.InfoPriceAt('K14', b.Vendor, b.Material, b.PurchOrg, b.Plant, b.PoDate, @AsOfDate) i
    WHERE b.IsGeneric = 0                    -- 通用料號沒有可比的主檔價
      AND ISNULL(b.Material, '') <> '';      -- 沒有料號的不比

    -- 第 2 步：能不能比？能比的算差異比例
    SELECT p.*, s.MatchStatus,
           CASE WHEN s.MatchStatus = N'已比對' THEN p.PoUnitPrice / p.InfoUnitPrice - 1 END AS DiffRatio
    INTO #Compared
    FROM #PoWithInfo p
    CROSS APPLY (SELECT CASE
        WHEN p.PoUnitPrice IS NULL                                  THEN N'缺PO單價'
        WHEN p.InfoSource IS NULL                                   THEN N'無主檔價'
        WHEN p.InfoUnitPrice IS NULL OR p.InfoUnitPrice = 0         THEN N'主檔無單價'
        WHEN p.InfoCurrency <> p.Currency                           THEN N'幣別不同'
        WHEN p.InfoUom IS NOT NULL AND p.InfoUom <> p.OrderUom      THEN N'單位不同'
        ELSE N'已比對' END AS MatchStatus) s;

    -- 第 3 步：貴超過門檻 → 標記，算多付的金額；比不了的也寫進明細（不能悄悄消失）
    INSERT kri.K14_Detail (RunId, PoNumber, PoItem, PoDate, CompanyCode, PurchOrg, Plant, Vendor, VendorName,
                           Material, MaterialDesc, OrderQty, OrderUom, Currency, PoUnitPrice,
                           InfoSource, ConditionRecord, ConditionType, InfoValidFrom, InfoUnitPrice, InfoCurrency, InfoUom,
                           MatchStatus, DiffRatio, IsFlagged, EffectDoc, EffectLocal, LocalCurrency)
    SELECT @RunId, c.PoNumber, c.PoItem, c.PoDate, c.CompanyCode, c.PurchOrg, c.Plant, c.Vendor, c.VendorName,
           c.Material, c.MaterialDesc, c.OrderQty, c.OrderUom, c.Currency, c.PoUnitPrice,
           c.InfoSource, c.ConditionRecord, c.ConditionType, c.InfoValidFrom, c.InfoUnitPrice, c.InfoCurrency, c.InfoUom,
           c.MatchStatus, c.DiffRatio,
           CASE WHEN c.DiffRatio > @tolerance THEN 1 ELSE 0 END,
           e.EffectDoc,
           kri.ToLocal(e.EffectDoc, c.Currency, c.LocalCurrency, c.ExchangeRate),
           c.LocalCurrency
    FROM #Compared c
    CROSS APPLY (SELECT CASE WHEN c.DiffRatio > @tolerance
                             THEN (c.PoUnitPrice - c.InfoUnitPrice) * c.OrderQty END AS EffectDoc) e;   -- 多付的金額（PO 幣別）

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Plant, Vendor, Material,
                     DocNumber, DocItem, DocDate, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K14', CONCAT(PoNumber, '-', PoItem), 'PO', CompanyCode, PurchOrg, Plant, Vendor, Material,
           PoNumber, PoItem, PoDate, DiffRatio, @tolerance, EffectLocal, LocalCurrency,
           CONCAT(N'PO 單價高於', InfoSource, N' 主檔價 ', FORMAT(DiffRatio, 'P1'))
    FROM kri.K14_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'已比對 ', COUNT(CASE WHEN MatchStatus = N'已比對' THEN 1 END), N' / ', COUNT(*),
                          N'；無主檔價 ', COUNT(CASE WHEN MatchStatus = N'無主檔價' THEN 1 END),
                          N'、幣別不同 ', COUNT(CASE WHEN MatchStatus = N'幣別不同' THEN 1 END),
                          N'、單位不同 ', COUNT(CASE WHEN MatchStatus = N'單位不同' THEN 1 END))
    FROM kri.K14_Detail WHERE RunId = @RunId;
END;
GO
