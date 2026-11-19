-- ======================================================================
-- K17 重大工程未簽合約
--
-- 【抓什麼】金額很大的工程類 PO，卻沒有合約，或合約是在 PO 開出來之後才補簽的。
-- 【為什麼有風險】重大工程沒有合約，責任、驗收標準、罰則都沒有約定，出問題時沒有依據；
--                 先下單後補約，代表事前的審核被跳過。
--
-- 【怎麼判斷】
--   第 1 步：找出觀察期間內的 PO 項目，判斷是不是工程類：PO 類型在 ConstructionPoType、
--            物料群組在 ConstructionMaterialGroup、或總帳科目符合 ConstructionGlPattern，任一個就算。
--   第 2 步：有任一個工程類項目的 PO，整張 PO 加總本幣金額（有項目換不出本幣，整張就不算）。
--   第 3 步：整張金額 >= MajorAmount（只看本幣在 AmountCurrency 名單裡的）的 PO，找合約：
--            PO 上有參照 SAP 合約就算有；否則找 ext.Contract（先找指定這張 PO 的，再找同供應商、
--            有效期間涵蓋下單日的），只看基準日以前簽的。
--   第 4 步：沒有合約、或合約簽約日晚於 PO 日 → 標記。
--
-- 【門檻】（kri.Parameter，KriCode = 'K17'）
--   MajorAmount  整張 PO 本幣金額達多少算重大工程
--
-- 【名單】（kri.ValueList）
--   ConstructionPoType         工程類的 PO 類型
--   ConstructionMaterialGroup  工程類的物料群組
--   ConstructionGlPattern      工程類的總帳科目（LIKE 樣式，例：'1501%'）
--   AmountCurrency             金額門檻適用的本幣（例：TWD）
--
-- 【明細表 kri.K17_Detail 怎麼看】一列 = 一張 PO
--   PoAmountLocal     整張 PO 的本幣金額
--   SapContract       PO 參照的 SAP 合約號碼；ExtContract、ContractSignedOn 外部合約號碼、簽約日
--   Status            有合約 / 合約晚於PO / 無合約
--
-- 【限制】
--   三種工程類條件都沒設定時，這題不會標記任何資料（備註會提示）。
--   合約簽約日空白的視為在下單前就簽了。
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

    -- 門檻
    DECLARE @majorAmount DECIMAL(19,4) = kri.Param('K17', 'MajorAmount');   -- 整張 PO 多少錢算重大工程

    -- 第 1 步：期間內的 PO 項目，判斷是不是工程類
    SELECT b.PoNumber, b.PoDate, b.CompanyCode, b.PurchOrg, b.Vendor, b.VendorName, b.LocalCurrency,
           kri.ToLocal(b.NetValue, b.Currency, b.LocalCurrency, b.ExchangeRate) AS AmountLocal,
           NULLIF(p.Contract, '') AS Contract,
           CASE WHEN p.PoType IN (SELECT Value FROM kri.List('K17', 'ConstructionPoType'))
                  OR p.MaterialGroup IN (SELECT Value FROM kri.List('K17', 'ConstructionMaterialGroup'))
                  OR EXISTS (SELECT 1 FROM kri.List('K17', 'ConstructionGlPattern') l WHERE p.GlAccount LIKE l.Value)
                THEN 1 ELSE 0 END AS IsConstruction
    INTO #PoItems
    FROM kri.PoBase('K17', @PeriodFrom, @PeriodTo) b
    JOIN prc.PurchaseOrderDetail p ON p.PoNumber = b.PoNumber AND p.PoItem = b.PoItem;

    -- 第 2 步：有任一工程類項目的 PO，整張 PO 的金額
    SELECT PoNumber, MIN(PoDate) AS PoDate, MAX(CompanyCode) AS CompanyCode, MAX(PurchOrg) AS PurchOrg,
           MAX(Vendor) AS Vendor, MAX(VendorName) AS VendorName, MAX(LocalCurrency) AS LocalCurrency,
           CASE WHEN COUNT(*) = COUNT(AmountLocal) THEN SUM(AmountLocal) END AS Amount,   -- 有項目換不出本幣就不算
           MAX(Contract) AS Contract
    INTO #ConstructionPo
    FROM #PoItems
    GROUP BY PoNumber
    HAVING MAX(IsConstruction) = 1;

    -- 第 3 步：重大的工程 PO，找外部合約
    SELECT po.*, x.ContractNo, x.SignedOn
    INTO #WithContract
    FROM #ConstructionPo po
    OUTER APPLY (SELECT TOP 1 k.ContractNo, k.SignedOn
                 FROM ext.Contract k
                 WHERE (   k.PoNumber = po.PoNumber                                   -- 指定這張 PO 的
                        OR (k.PoNumber IS NULL AND k.Vendor = po.Vendor               -- 或同供應商、期間涵蓋下單日的
                            AND po.PoDate BETWEEN ISNULL(k.ValidFrom, '1900-01-01') AND ISNULL(k.ValidTo, '9999-12-31')))
                   AND ISNULL(k.SignedOn, '1900-01-01') <= @AsOfDate                  -- 基準日以前簽的
                 ORDER BY CASE WHEN k.PoNumber IS NULL THEN 1 ELSE 0 END,             -- 指定 PO 的優先
                          CASE WHEN k.SignedOn IS NULL THEN 1 ELSE 0 END,             -- 有簽約日的優先
                          k.SignedOn) x                                               -- 最早簽的
    WHERE po.Amount >= @majorAmount
      AND po.LocalCurrency IN (SELECT Value FROM kri.List('K17', 'AmountCurrency'));

    -- 第 4 步：沒有合約、或合約晚於 PO → 標記；寫進明細
    INSERT kri.K17_Detail (RunId, PoNumber, PoDate, CompanyCode, PurchOrg, Vendor, VendorName, PoAmountLocal,
                           LocalCurrency, SapContract, ExtContract, ContractSignedOn, Status, IsFlagged)
    SELECT @RunId, c.PoNumber, c.PoDate, c.CompanyCode, c.PurchOrg, c.Vendor, c.VendorName, c.Amount,
           c.LocalCurrency, c.Contract, c.ContractNo, c.SignedOn, s.Status,
           CASE WHEN s.Status = N'有合約' THEN 0 ELSE 1 END
    FROM #WithContract c
    CROSS APPLY (SELECT CASE
        WHEN c.Contract IS NOT NULL                                                  THEN N'有合約'   -- PO 參照 SAP 合約
        WHEN c.ContractNo IS NOT NULL AND ISNULL(c.SignedOn, c.PoDate) <= c.PoDate   THEN N'有合約'   -- 下單前就簽了
        WHEN c.ContractNo IS NOT NULL                                                THEN N'合約晚於PO'
        ELSE N'無合約' END AS Status) s;

    -- 寫標記
    INSERT kri.Flag (RunId, KriCode, FlagKey, EntityType, CompanyCode, PurchOrg, Vendor, DocNumber, DocDate,
                     MetricValue, ThresholdValue, EffectLocal, LocalCurrency, Reason)
    SELECT RunId, 'K17', PoNumber, 'PO', CompanyCode, PurchOrg, Vendor, PoNumber, PoDate,
           PoAmountLocal, @majorAmount, PoAmountLocal, LocalCurrency,
           CASE WHEN Status = N'無合約'
                THEN CONCAT(N'工程 PO ', FORMAT(PoAmountLocal, 'N0'), N' 沒有合約')
                ELSE CONCAT(N'工程 PO ', FORMAT(PoAmountLocal, 'N0'), N'，合約 ', ExtContract, N' 在 ', ContractSignedOn,
                            N' 才簽（PO ', PoDate, N'）') END
    FROM kri.K17_Detail
    WHERE RunId = @RunId AND IsFlagged = 1;

    -- 執行結果的說明
    IF NOT EXISTS (SELECT 1 FROM kri.ValueList WHERE KriCode IN ('K17', '*')
                     AND ListName IN ('ConstructionPoType', 'ConstructionMaterialGroup', 'ConstructionGlPattern'))
        SET @Note = N'沒有設定工程類 PO 的判斷條件（ConstructionPoType／MaterialGroup／GlPattern），這題不會標記任何資料';
    ELSE
        SELECT @Note = CONCAT(N'重大工程 PO ', COUNT(*), N'；無合約 ', COUNT(CASE WHEN Status = N'無合約' THEN 1 END),
                              N'、合約晚於 PO ', COUNT(CASE WHEN Status = N'合約晚於PO' THEN 1 END))
        FROM kri.K17_Detail WHERE RunId = @RunId;
END;
GO
