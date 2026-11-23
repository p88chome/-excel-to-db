-- KRI 預設設定：定義、暫定門檻、白名單。可以重複執行：
--   * kri.Definition：名稱、說明、期別等會更新成這份的內容，但不動 Enabled（你們關掉的題目不會被打開）
--   * kri.Parameter、kri.ValueList：只補沒有的，已經調過的值不會被覆蓋
-- 門檻一律是暫定值（IsTentative = 1），客戶確認後直接 UPDATE kri.Parameter，並把 IsTentative 改成 0。

MERGE kri.Definition AS t
USING (VALUES
 ('K08', N'疑似拆單（PR）', N'同成本中心、同供應商在 {WindowDays} 天內開立多張 PR，單筆低於簽核門檻、合計需要更高層級核決。', N'請購', 'PR', 'kri.Run_K08', 12, 1, 1, 0, 1, 0, 0,
         N'需要 kri.ApprovalMatrix（核決權限，由客戶提供）才會有結果。部門暫以成本中心代表。'),
 ('K13', N'跨據點同料號單價差異', N'同料號在相近期間、相近採購量下，某據點的單價比其他據點最低單價高 {PriceTolerance} 以上。', N'採購', 'PO', 'kri.Run_K13', 12, 1, 1, 0, 0, 1, 1,
         N'目前只比同幣別、同訂購單位；跨幣別要等匯率表。'),
 ('K14', N'PO 單價高於主檔價', N'PO 單價比下單日有效的採購資訊記錄價格（A017 優先、其次 A018）高 {PriceTolerance} 以上。', N'採購', 'PO', 'kri.Run_K14', 12, 1, 1, 1, 0, 0, 1,
         N'級距價格（KONM）尚未下載；PB00 是毛價、PO 是淨價。'),
 ('K18', N'Open PO 收貨進度異常', N'Open PO 已超過交貨日 {OverdueDays} 天，收貨比例低於 {MinReceivedRatio}。', N'採購', 'PO', 'kri.Run_K18', 36, 1, 1, 0, 0, 1, 0,
         N'收貨比例以數量計；EKBE.MENGE 的單位待確認與 PO 訂購單位一致。'),
 ('K01', N'品質異常期間仍下單', N'供應商有未結案的品質異常單期間，仍對它下 PO；同一張單期間內 PO 項目達 {MinPoCount} 筆以上。', N'供應商管理', 'PO', 'kri.Run_K01', 12, 1, 2, 1, 0, 1, 0,
         N'讀 ext.QualityIssue（由品質異常系統匯出後整理）；已結案但沒有結案日的單略過。'),
 ('K03', N'已停用供應商短暫啟用交易', N'供應商凍結解除後 {MaxOpenDays} 天內又凍結，期間內有 PO 或應付傳票。', N'供應商管理', 'VENDOR', 'kri.Run_K03', 12, 1, 2, 1, 1, 0, 0,
         N'PO 日目前用文件日（BEDAT）；EKKO.AEDAT 進來後改用系統建立日。異動紀錄的期間要涵蓋觀察期間前的狀態。'),
 ('K04', N'付款條件比主檔差', N'PO 付款條件和主檔不同、或應付傳票和 PO 不同，而且提早 {MinDaysWorse} 天以上付款。', N'供應商管理', 'PO', 'kri.Run_K04', 12, 1, 2, 1, 0, 0, 1,
         N'客戶是否執行待確認。天數先從付款條件代碼推估，拿到 T052 後填 kri.PaymentTerm。'),
 ('K10', N'先入庫才補請採購單', N'第一次收貨在 PO 日後 {MaxGapDays} 天內（含早於 PO），排除緊急採購關鍵字，整張 PO 金額不超過 {MaxPoAmount}。', N'請購', 'PO', 'kri.Run_K10', 12, 1, 2, 1, 1, 0, 0,
         N'緊急採購關鍵字放 kri.ValueList（ExcludeTextPattern，LIKE 樣式）。目前比對收貨的項目說明；EKPO.TXZ01 進來後再加 PO 項目說明。'),
 ('K19', N'GR 日期異常貼近 PR/PO 建立日', N'第一次收貨在 PR 建立日（沒有 PR 用 PO 日）後 {MaxGapDays} 天內。', N'驗收', 'PO', 'kri.Run_K19', 12, 1, 2, 1, 0, 1, 0,
         N'和 K10 共用收貨日；K10 看 PO→GR，K19 看 PR→GR，同一筆可能兩題都標。'),
 ('K09', N'疑似拆單（direct AP）', N'同公司別、同供應商（同成本中心）在 {WindowDays} 天內多張沒有 PO 的應付傳票，單張低於核決門檻、合計需要更高層級。', N'請款', 'AP', 'kri.Run_K09', 12, 1, 2, 1, 1, 0, 0,
         N'需要 kri.ApprovalMatrix 的 AP 核決權限。成本中心目前只看供應商行；費用行進來後改從同傳票帶。沖銷傳票要等 BKPF.STBLG。'),
 ('K12', N'集中且買貴', N'兩年內只跟一家買的料號，一年單價漲幅比同物料群組其他料號平均多 {PriceTolerance} 以上。', N'採購', 'MATERIAL', 'kri.Run_K12', 12, 1, 2, 0, 1, 0, 1,
         N'獨家先用 PO 資料判斷（客戶的獨家料號清單、製造商料號進來後改用）；合理獨家放 ValueList AllowedSingleSource。'),
 ('K02', N'工商登記關聯供應商', N'統編、電話、地址、銀行帳號相同或商工登記有關聯的不同供應商：一家凍結另一家仍交易，或兩家買同料號。', N'供應商管理', 'VENDOR', 'kri.Run_K02', 12, 1, 4, 1, 1, 0, 0,
         N'先做 SAP 內部版；商工登記的關聯放 ext.VendorRelation。銀行帳號讀 dbo.LFBK（kri.vVendorBank）。'),
 ('K05', N'Open PO 超過供應商資本額', N'Open PO 未收金額超過實收資本額的 {CapitalRatio} 倍。', N'供應商管理', 'VENDOR', 'kri.Run_K05', 36, 1, 4, 0, 1, 1, 0,
         N'資本額放 ext.VendorCapital（商工登記）；查不到的列「無資本額」。'),
 ('K06', N'用量 vs 請購量 vs 庫存', N'請購當天庫存 + 在途可用超過 {MaxCoverageMonths} 個月（或沒有耗用）仍請購。', N'請購', 'PR', 'kri.Run_K06', 12, 1, 3, 0, 0, 1, 1,
         N'庫存用目前快照回推；回推準度看異動資料是否完整。'),
 ('K07', N'本期 vs 預期請購量', N'料號當月請購量是預期量（或過去月平均）的 {Multiplier} 倍以上。', N'請購', 'MATERIAL', 'kri.Run_K07', 12, 1, 3, 0, 0, 1, 0,
         N'預期量放 ext.ExpectedDemand；沒有時用過去 12 個月平均。'),
 ('K11', N'非緊急之緊急採購', N'緊急採購的 PO，下單前已有庫存、或 MOU／待用量顯示不急。', N'採購', 'PO', 'kri.Run_K11', 12, 1, 4, 1, 0, 1, 0,
         N'緊急採購的判斷放 ValueList EmergencyPoType／EmergencyTextPattern；MOU、待用放 ext.PartUsage。'),
 ('K15', N'已屆呆滯之警示', N'{WarnDays} 天內就會認列呆滯的料號。', N'庫存', 'MATERIAL', 'kri.Run_K15', 12, 1, 3, 0, 0, 1, 1,
         N'優先用呆滯報表（ext.SlowMoving）；沒有時用最後異動日推估。'),
 ('K16', N'呆滯料仍進行採購', N'料號已呆滯、有庫存仍下 PO，最近 3 個月有 {MinConsecMonths} 個月以上。', N'採購', 'PO', 'kri.Run_K16', 12, 1, 3, 0, 0, 1, 1,
         N'同 K15 的呆滯判斷。'),
 ('K17', N'重大工程未簽合約', N'工程類 PO 金額 {MajorAmount} 以上，沒有合約或合約晚於 PO。', N'採購', 'PO', 'kri.Run_K17', 12, 1, 4, 1, 0, 0, 0,
         N'工程類的判斷放 ValueList（ConstructionPoType／MaterialGroup／GlPattern）；合約放 ext.Contract。'),
 ('K20', N'驗退後未及時處理', N'轉入待退倉後超過 {MaxOpenDays} 天才處理完（或還沒處理）。', N'驗收', 'MOVEMENT', 'kri.Run_K20', 12, 1, 3, 0, 0, 1, 1,
         N'待退倉放 ValueList ReturnStorLoc；先進先出配對出倉。')
) AS s (KriCode, Name, Description, Stage, EntityType, ProcName, WindowMonths, Enabled, Phase,
        IsCompliance, IsFraud, IsOperation, IsFinancial, Notes)
ON t.KriCode = s.KriCode
WHEN MATCHED THEN UPDATE SET
    Name = s.Name, Description = s.Description, Stage = s.Stage, EntityType = s.EntityType,
    ProcName = s.ProcName, WindowMonths = s.WindowMonths, Phase = s.Phase,
    IsCompliance = s.IsCompliance, IsFraud = s.IsFraud, IsOperation = s.IsOperation,
    IsFinancial = s.IsFinancial, Notes = s.Notes
WHEN NOT MATCHED THEN INSERT (KriCode, Name, Description, Stage, EntityType, ProcName, WindowMonths,
                              Enabled, Phase, IsCompliance, IsFraud, IsOperation, IsFinancial, Notes)
    VALUES (s.KriCode, s.Name, s.Description, s.Stage, s.EntityType, s.ProcName, s.WindowMonths,
            s.Enabled, s.Phase, s.IsCompliance, s.IsFraud, s.IsOperation, s.IsFinancial, s.Notes)
-- 這份清單已經拿掉的題目（舊版部署留下來的）：從 Definition 移除，kri.RunAll 就不會再跑。
-- 只動 Kxx 編號的題目；程序、明細表和 kri.Flag 裡的舊結果都留著，只是 vFlagLatest 不再顯示。
WHEN NOT MATCHED BY SOURCE AND t.KriCode LIKE 'K[0-9][0-9]' THEN DELETE;

INSERT kri.Parameter (KriCode, ParamName, ParamValue, Unit, Description)
SELECT s.KriCode, s.ParamName, s.ParamValue, s.Unit, s.Description
FROM (VALUES
 ('*',   'KeepRuns',         10,   'count',  N'kri.RunAll 每題保留最近幾次的結果'),
 ('*',   'ScoreAmountUnit',  100000, 'amount', N'風險分數：台幣金額單位；每筆點數 = 權重 ×（基本分 + LOG10(1 + 金額 ÷ 單位)）'),
 ('*',   'ScoreBasePoints',  1,    'count',  N'風險分數：每筆標記的基本分（沒有台幣金額時只算這個）'),
 ('*',   'ScoreScaleK',      10,   'count',  N'風險分數：分數 = 100 ×（1 − EXP(−點數 ÷ ScaleK)）'),
 ('*',   'ScoreHighCut',     70,   'count',  N'風險分數：幾分以上算高風險'),
 ('*',   'ScoreMediumCut',   40,   'count',  N'風險分數：幾分以上算中風險'),
 ('*',   'ScoreWeight',      1,    'ratio',  N'風險分數：每題的權重；要某題加重就設 KriCode = 該題'),
 ('K08', 'WindowDays',       30,   'days',   N'滾動視窗天數'),
 ('K08', 'MinCount',         2,    'count',  N'視窗內至少幾張 PR 才算'),
 ('K13', 'PriceTolerance',   0.30, 'ratio',  N'比其他據點最低單價高出多少比例才標記'),
 ('K13', 'QtyBandRatio',     10,   'ratio',  N'數量級距：每差幾倍算不同級距'),
 ('K13', 'EntityLevel',      1,    'code',   N'據點層級：1 = 公司別、2 = 工廠'),
 ('K14', 'PriceTolerance',   0.05, 'ratio',  N'PO 單價比主檔價高出多少比例才標記'),
 ('K18', 'MinReceivedRatio', 0.5,  'ratio',  N'收貨比例低於多少'),
 ('K18', 'OverdueDays',      30,   'days',   N'超過交貨日幾天'),
 ('K01', 'MinPoCount',          1,      'count',  N'一張異常單期間內至少幾筆 PO 項目才標記'),
 ('K01', 'RequireSameMaterial', 0,      'code',   N'1 = 只看和異常單同料號的 PO；0 = 同供應商就算'),
 ('K03', 'MaxOpenDays',         30,     'days',   N'解凍後幾天內又凍結算「短暫」'),
 ('K04', 'MinDaysWorse',        1,      'days',   N'提早幾天以上付款才標記'),
 ('K04', 'AnnualRate',          0.02,   'ratio',  N'資金成本年利率，用來換算影響金額'),
 ('K04', 'MasterLevel',         2,      'code',   N'1 = PO 只跟採購組織層（LFM1）比；2 = 跟公司別層（LFB1）一樣也算一致'),
 ('K10', 'MaxGapDays',          1,      'days',   N'PO 日到第一次收貨在幾天內（含收貨早於 PO）'),
 ('K10', 'MaxPoAmount',         500000, 'amount', N'整張 PO 本幣金額上限；0 = 不限。只在本幣屬於 AmountCurrency 時判斷'),
 ('K19', 'MaxGapDays',          3,      'days',   N'PR（或 PO）建立日到第一次收貨在幾天內'),
 ('K09', 'WindowDays',          30,     'days',   N'滾動視窗天數'),
 ('K09', 'MinCount',            2,      'count',  N'視窗內至少幾張傳票才算'),
 ('K12', 'PriceTolerance',      0.10,   'ratio',  N'漲幅比群組基準多出多少才標記'),
 ('K12', 'MinGroupMaterials',   3,      'count',  N'群組內至少幾個其他料號可比才當基準；不夠以 0 計'),
 ('K02', 'MaxGroupSize',        5,      'count',  N'同一個統編／電話／地址／銀行帳號超過幾家共用就不配對（代理商、總機）'),
 ('K05', 'CapitalRatio',        1,      'ratio',  N'Open PO 未收金額 ÷ 實收資本額超過多少'),
 ('K06', 'MaxCoverageMonths',   6,      'months', N'庫存 + 在途可用超過幾個月仍請購'),
 ('K06', 'UsageMonths',         12,     'months', N'平均月耗用看過去幾個月'),
 ('K06', 'FlagNoUsage',         1,      'code',   N'1 = 沒有耗用但有庫存或在途仍請購也標記'),
 ('K07', 'Multiplier',          3,      'ratio',  N'當月請購量是預期量的幾倍以上'),
 ('K07', 'MinHistoryMonths',    3,      'months', N'沒有預期量表時，歷史至少幾個月才判斷'),
 ('K11', 'MinStockQty',         0,      'qty',    N'下單前庫存超過多少算不急'),
 ('K11', 'MaxMou',              3,      'ratio',  N'MOU 超過多少算不急'),
 ('K11', 'MinWaitingForUse',    2,      'qty',    N'待用量達多少算不急'),
 ('K15', 'WarnDays',            14,     'days',   N'幾天內會認列呆滯就警示'),
 ('K15', 'SlowDays',            365,    'days',   N'沒有呆滯報表時：最後異動後幾天算呆滯'),
 ('K15', 'UseSapFallback',      1,      'code',   N'1 = 沒有呆滯報表時用最後異動日推估'),
 ('K16', 'MinConsecMonths',     1,      'months', N'最近 3 個月有幾個月呆滯仍下單才標記'),
 ('K16', 'SlowDays',            365,    'days',   N'沒有呆滯報表時：最後異動後幾天算呆滯'),
 ('K16', 'UseSapFallback',      1,      'code',   N'1 = 沒有呆滯報表時用最後異動日推估'),
 ('K17', 'MajorAmount',         10000000, 'amount', N'整張 PO 本幣金額達多少算重大工程（本幣在 AmountCurrency 時）'),
 ('K20', 'MaxOpenDays',         30,     'days',   N'轉入待退倉後幾天內要處理完')
) AS s (KriCode, ParamName, ParamValue, Unit, Description)
WHERE NOT EXISTS (SELECT 1 FROM kri.Parameter p WHERE p.KriCode = s.KriCode AND p.ParamName = s.ParamName);

INSERT kri.ValueList (KriCode, ListName, ListValue, Note)
SELECT s.KriCode, s.ListName, s.ListValue, s.Note
FROM (VALUES
 ('*', 'AllowedConditionType', 'PB00', N'毛價。ZPB0 意義待客戶確認後再決定是否加入'),
 ('*', 'AllowedInfoCategory',  '0',    N'標準資訊記錄；寄售(2)、外包(3) 暫不比'),
 ('*', 'GrMovementType',       '101',  N'PO 收貨（K10、K19）'),
 ('K03', 'BlockField',         'SPERM', N'採購凍結'),
 ('K03', 'BlockField',         'SPERR', N'過帳凍結'),
 ('K10', 'AmountCurrency',     'TWD',  N'金額上限 MaxPoAmount 的幣別；本幣不是這個的公司別不判斷金額'),
 ('K09', 'ExcludeDocType',     'KZ',   N'付款傳票（SAP 標準類型）'),
 ('K09', 'ExcludeDocType',     'ZP',   N'付款傳票（SAP 標準類型）'),
 ('K09', 'ExcludeDocType',     'AB',   N'清帳／一般傳票（SAP 標準類型）'),
 ('K02', 'MatchAttribute',     'TaxNumber', N'統編相同'),
 ('K02', 'MatchAttribute',     'Phone',     N'電話相同'),
 ('K02', 'MatchAttribute',     'Address',   N'地址相同'),
 ('K02', 'MatchAttribute',     'BankAccount', N'銀行帳號相同'),
 ('K06', 'ConsumptionMovementType', '201', N'領用至成本中心'),
 ('K06', 'ConsumptionMovementType', '202', N'201 沖回'),
 ('K06', 'ConsumptionMovementType', '221', N'領用至專案'),
 ('K06', 'ConsumptionMovementType', '222', N'221 沖回'),
 ('K06', 'ConsumptionMovementType', '261', N'領用至工單'),
 ('K06', 'ConsumptionMovementType', '262', N'261 沖回'),
 ('K06', 'ConsumptionMovementType', '281', N'領用至網路'),
 ('K06', 'ConsumptionMovementType', '282', N'281 沖回'),
 ('K15', 'ConsumptionMovementType', '201', N'領用至成本中心'),
 ('K15', 'ConsumptionMovementType', '221', N'領用至專案'),
 ('K15', 'ConsumptionMovementType', '261', N'領用至工單'),
 ('K15', 'ConsumptionMovementType', '281', N'領用至網路'),
 ('K16', 'ConsumptionMovementType', '201', N'領用至成本中心'),
 ('K16', 'ConsumptionMovementType', '221', N'領用至專案'),
 ('K16', 'ConsumptionMovementType', '261', N'領用至工單'),
 ('K16', 'ConsumptionMovementType', '281', N'領用至網路'),
 ('K17', 'AmountCurrency',     'TWD',  N'重大工程金額門檻的幣別'),
 ('K20', 'ReturnTransferType', '311',  N'倉間轉撥')
) AS s (KriCode, ListName, ListValue, Note)
WHERE NOT EXISTS (SELECT 1 FROM kri.ValueList v
                  WHERE v.KriCode = s.KriCode AND v.ListName = s.ListName AND v.ListValue = s.ListValue);

SELECT KriCode, Name, Enabled FROM kri.Definition ORDER BY KriCode;
