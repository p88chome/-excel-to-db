-- KRI 預設設定：定義、暫定門檻、白名單。可以重複執行：
--   * kri.Definition：名稱、說明、期別等會更新成這份的內容，但不動 Enabled（你們關掉的題目不會被打開）
--   * kri.Parameter、kri.ValueList：只補沒有的，已經調過的值不會被覆蓋
-- 門檻一律是暫定值（IsTentative = 1），UMC/DTT 確認後直接 UPDATE kri.Parameter，並把 IsTentative 改成 0。

MERGE kri.Definition AS t
USING (VALUES
 ('K08', N'疑似拆單（PR）', N'同成本中心、同供應商在 {WindowDays} 天內開立多張 PR，單筆低於簽核門檻、合計需要更高層級核決。', N'請購', 'PR', 'kri.Run_K08', 12, 1, 1, 0, 1, 0, 0,
         N'需要 kri.ApprovalMatrix（核決權限，由 UMC 提供）才會有結果。部門暫以成本中心代表。'),
 ('K13', N'跨據點同料號單價差異', N'同料號在相近期間、相近採購量下，某據點的單價比其他據點最低單價高 {PriceTolerance} 以上。', N'採購', 'PO', 'kri.Run_K13', 12, 1, 1, 0, 0, 1, 1,
         N'目前只比同幣別、同訂購單位；跨幣別要等匯率表。'),
 ('K14', N'PO 單價高於主檔價', N'PO 單價比下單日有效的採購資訊記錄價格（A017 優先、其次 A018）高 {PriceTolerance} 以上。', N'採購', 'PO', 'kri.Run_K14', 12, 1, 1, 1, 0, 0, 1,
         N'級距價格（KONM）尚未下載；PB00 是毛價、PO 是淨價。'),
 ('K18', N'Open PO 收貨進度異常', N'Open PO 已超過交貨日 {OverdueDays} 天，收貨比例低於 {MinReceivedRatio}。', N'採購', 'PO', 'kri.Run_K18', 36, 1, 1, 0, 0, 1, 0,
         N'收貨比例以數量計；EKBE.MENGE 的單位待確認與 PO 訂購單位一致。'),
 ('K21', N'主檔價倒填', N'價格條件的建立日晚於生效日 {BackdateDays} 天以上，並列出倒填期間內受影響的 PO。', N'採購', 'CONDITION', 'kri.Run_K21', 12, 1, 1, 1, 1, 0, 0,
         N'新增題目（不在 DTT 清單）。')
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
            s.Enabled, s.Phase, s.IsCompliance, s.IsFraud, s.IsOperation, s.IsFinancial, s.Notes);

INSERT kri.Parameter (KriCode, ParamName, ParamValue, Unit, Description)
SELECT s.KriCode, s.ParamName, s.ParamValue, s.Unit, s.Description
FROM (VALUES
 ('*',   'KeepRuns',         10,   'count',  N'kri.RunAll 保留最近幾次的結果'),
 ('K08', 'WindowDays',       30,   'days',   N'滾動視窗天數'),
 ('K08', 'MinCount',         2,    'count',  N'視窗內至少幾張 PR 才算'),
 ('K13', 'PriceTolerance',   0.30, 'ratio',  N'比其他據點最低單價高出多少比例才標記'),
 ('K13', 'QtyBandRatio',     10,   'ratio',  N'數量級距：每差幾倍算不同級距'),
 ('K13', 'EntityLevel',      1,    'code',   N'據點層級：1 = 公司別、2 = 工廠'),
 ('K14', 'PriceTolerance',   0.05, 'ratio',  N'PO 單價比主檔價高出多少比例才標記'),
 ('K18', 'MinReceivedRatio', 0.5,  'ratio',  N'收貨比例低於多少'),
 ('K18', 'OverdueDays',      30,   'days',   N'超過交貨日幾天'),
 ('K21', 'BackdateDays',     30,   'days',   N'建立日晚於生效日幾天以上')
) AS s (KriCode, ParamName, ParamValue, Unit, Description)
WHERE NOT EXISTS (SELECT 1 FROM kri.Parameter p WHERE p.KriCode = s.KriCode AND p.ParamName = s.ParamName);

INSERT kri.ValueList (KriCode, ListName, ListValue, Note)
SELECT s.KriCode, s.ListName, s.ListValue, s.Note
FROM (VALUES
 ('*', 'AllowedConditionType', 'PB00', N'毛價。ZPB0 意義待 UMC 確認後再決定是否加入'),
 ('*', 'AllowedInfoCategory',  '0',    N'標準資訊記錄；寄售(2)、外包(3) 暫不比')
) AS s (KriCode, ListName, ListValue, Note)
WHERE NOT EXISTS (SELECT 1 FROM kri.ValueList v
                  WHERE v.KriCode = s.KriCode AND v.ListName = s.ListName AND v.ListValue = s.ListValue);

SELECT KriCode, Name, Enabled FROM kri.Definition ORDER BY KriCode;
