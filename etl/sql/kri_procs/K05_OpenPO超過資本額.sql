-- ======================================================================
-- K05 Open PO 超過供應商資本額
--
-- 【抓什麼】給一家供應商的未交貨 PO 金額，比它的實收資本額還大很多。
-- 【為什麼有風險】小公司接遠超過自己規模的訂單，可能交不出貨（供應風險），
--                 也可能是人頭公司、空殼公司（舞弊風險）。
--
-- 【怎麼判斷】
--   第 1 步：觀察期間內下單、基準日當時還沒結案、還沒收齊的 PO 項目，算出未收金額（換成本幣）。
--            基準日當時已收多少用 kri.PoReceivedAt 算，基準日之後才收的貨不算已收。
--   第 2 步：每家供應商的未收金額合計。有任何一個項目換不出本幣，合計就不算（未判斷）。
--   第 3 步：找供應商的實收資本額（ext.VendorCapital）：先用供應商代碼對，對不到再用統編對；
--            同一家有好幾筆時取基準日以前最新的一筆。
--   第 4 步：未收金額 ÷ 資本額 > CapitalRatio → 標記。
--            影響金額 = 超過的部分（未收金額 − 資本額 × CapitalRatio）。
--
-- 【門檻】（kri.Parameter，KriCode = 'K05'）
--   CapitalRatio  Open PO 未收金額 ÷ 實收資本額超過多少（1 = 超過資本額）
--   WindowMonths  只看最近幾個月下的 PO（預設 36）
--
-- 【明細表 kri.K05_Detail 怎麼看】一列 = 一家有 Open PO 的供應商
--   OpenAmountLocal  基準日當時的未收金額合計（本幣）
--   Capital          實收資本額；CapitalCurrency 是它的幣別
--   Ratio            未收金額 ÷ 資本額
--   Status           已比對 / 無資本額（例如國外廠商查不到）/ 未判斷（幣別不同、跨本幣、換不出本幣）
--
-- 【限制】
--   資本額要從商工登記另外整理進 ext.VendorCapital；不同幣別不換算，直接列「未判斷」。
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

    -- 門檻
    DECLARE @capitalRatio DECIMAL(19,6) = kri.Param('K05', 'CapitalRatio');   -- 未收金額 ÷ 資本額超過多少

    -- 第 1 步：基準日當時還沒結案、還沒收齊的 PO 項目，和未收金額（本幣）
    SELECT b.Vendor, b.VendorName, b.LocalCurrency,
           kri.ToLocal((b.OrderQty - r.ReceivedQty) * b.UnitPrice, b.Currency, b.LocalCurrency, b.ExchangeRate) AS OpenLocal
    INTO #OpenPo
    FROM kri.PoBase('K05', @PeriodFrom, @PeriodTo) b
    CROSS APPLY kri.PoReceivedAt(b.PoNumber, b.PoItem, b.GrQty, b.DelivComplInd, b.PoDate, @AsOfDate) r
    WHERE ISNULL(b.Vendor, '') <> ''
      AND r.IsClosed = 0                    -- 基準日當時還沒結案
      AND r.ReceivedQty < b.OrderQty;       -- 還沒收齊

    -- 第 2 步：每家供應商的未收金額合計
    SELECT Vendor, MAX(VendorName) AS VendorName, COUNT(*) AS OpenPoCount,
           CASE WHEN COUNT(*) = COUNT(OpenLocal) THEN SUM(OpenLocal) END AS OpenAmount,   -- 有任一項目換不了本幣就不算
           COUNT(DISTINCT LocalCurrency) AS Currencies,
           MAX(LocalCurrency) AS LocalCurrency
    INTO #VendorOpen
    FROM #OpenPo
    GROUP BY Vendor;

    -- 第 3 步：找實收資本額（供應商代碼優先，其次統編；取基準日以前最新的）
    SELECT o.*, c.Capital, c.Currency AS CapitalCurrency
    INTO #WithCapital
    FROM #VendorOpen o
    OUTER APPLY (SELECT TOP 1 x.Capital, x.Currency
                 FROM ext.VendorCapital x
                 WHERE (x.Vendor = o.Vendor
                        OR (x.Vendor IS NULL
                            AND x.TaxNumber IN (SELECT NULLIF(LTRIM(RTRIM(v.TaxNumber)), '')
                                                FROM mst.Vendor v WHERE v.Vendor = o.Vendor)))
                   AND (x.DataDate IS NULL OR x.DataDate <= @AsOfDate)
                 ORDER BY CASE WHEN x.Vendor IS NULL THEN 1 ELSE 0 END,    -- 代碼對到的優先
                          x.DataDate DESC) c;

    -- 第 4 步：能不能比、比例多少，超過門檻 → 標記；寫進明細
    SELECT w.*,
           CASE WHEN w.Capital IS NULL OR w.Capital <= 0                         THEN N'無資本額'
                WHEN w.Currencies <> 1 OR w.LocalCurrency <> w.CapitalCurrency
                     OR w.OpenAmount IS NULL                                     THEN N'未判斷'
                ELSE N'已比對' END AS Status
    INTO #Result
    FROM #WithCapital w;

    INSERT kri.K05_Detail (RunId, Vendor, VendorName, OpenPoCount, OpenAmountLocal, LocalCurrency,
                           Capital, CapitalCurrency, Ratio, Status, IsFlagged)
    SELECT @RunId, Vendor, VendorName, OpenPoCount,
           CASE WHEN Currencies = 1 THEN OpenAmount END,        -- 跨不同本幣不加總
           CASE WHEN Currencies = 1 THEN LocalCurrency END,
           Capital, CapitalCurrency,
           CASE WHEN Status = N'已比對' THEN OpenAmount / Capital END,
           Status,
           CASE WHEN Status = N'已比對' AND OpenAmount / Capital > @capitalRatio THEN 1 ELSE 0 END
    FROM #Result;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, Vendor, MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K05', Vendor, 'VENDOR', Vendor, Ratio, @capitalRatio,
           OpenAmountLocal - Capital * @capitalRatio,             -- 超過的部分
           LocalCurrency,
           CONCAT(N'Open PO 未收金額 ', FORMAT(OpenAmountLocal, 'N0'), N' 是實收資本額的 ', FORMAT(Ratio, 'P0'))
    FROM kri.K05_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    SELECT @Note = CONCAT(N'有 Open PO 的供應商 ', COUNT(*), N'；已比對 ', COUNT(CASE WHEN Status = N'已比對' THEN 1 END),
                          N'、無資本額 ', COUNT(CASE WHEN Status = N'無資本額' THEN 1 END),
                          N'、未判斷 ', COUNT(CASE WHEN Status = N'未判斷' THEN 1 END),
                          CASE WHEN NOT EXISTS (SELECT 1 FROM ext.VendorCapital) THEN N'（ext.VendorCapital 沒有資料）' ELSE N'' END)
    FROM kri.K05_Detail WHERE RunId = @RunId;
END;
GO
