# UMC 採購風險儀表板：KRI 產品需求文件（PRD）

| 項目 | 內容 |
|---|---|
| 版本 | v1.0（2026-10-19） |
| 狀態 | 已核可，第一期開工 |
| 依據 | 《擬定清單 v2.2（UMC入選KRI）》、《初擬清單 v1.3 會議記錄 0506》、資料移轉規格 v2.3、過往專案 KRI 程式研究 |
| 範圍 | KRI 計算框架、KRI 邏輯、評分方向；不含 Power BI 畫面設計 |

這份文件是 KRI 開發的**決策紀錄**。寫程式時以這份為準；要改設計，先改這份（更新第 13 節的變更紀錄），再改程式。

---

## 1. 背景與目標

UMC 稽核（ADT）要從 SAP 採購、收貨、庫存、應付資料中，持續找出異常交易與風險樣態，呈現在採購風險儀表板上。

**目標**
1. 把入選的 KRI 寫成**可重複執行、結果可追溯**的 SQL，資料更新後一鍵重算。
2. 每個 KRI 的門檻（X 天、Y%）都能由 UMC/DTT 討論後**直接改參數**，不改程式。
3. 每一筆異常都有**影響金額**，讓不同 KRI 能用同一把尺比較嚴重性，之後彙總成供應商、料號層級的風險分數。
4. 先用**現有的 SAP 資料**做出第一批 KRI，需要外部系統（Notes、iPARTS、商工登記）的題目分期接入。

**不在範圍內**
- Power BI 報表的版面與互動設計（另案）。
- 外部系統的介接程式（eCAR、eContract、iPARTS API、商工登記爬蟲）：本文件只定義它們進來後要長什麼樣。

---

## 2. 使用者與使用情境

| 使用者 | 怎麼用 |
|---|---|
| UMC ADT（稽核） | 看儀表板上被標記的交易，挑樣本查核；調整門檻 |
| DTT 顧問 | 開發與維護 KRI 邏輯；和 UMC 對齊門檻與定義 |
| 資料維運（我們） | 匯入 SAP 資料 → 跑 ETL → 跑 KRI；排查失敗 |

**每次更新資料的流程**
```
excel-to-db 匯入 SAP 原表 → EXEC etl.LoadAll → EXEC kri.RunAll → Power BI 重新整理
```

---

## 3. 整體架構

```
┌──────────────┐   ┌──────────────────────┐   ┌───────────────────────┐   ┌──────────┐
│ SAP 原表      │   │ 業務表（ETL）          │   │ KRI 層                 │   │ Power BI │
│ dbo.EKKO …   │──▶│ prc / mst / inv / fin │──▶│ kri.K14_Detail …       │──▶│ 儀表板    │
│ (excel-to-db)│   │ etl.LoadAll           │   │ kri.Flag（統一標記）     │   │          │
└──────────────┘   └──────────────────────┘   │ kri.Score（第二期）      │   └──────────┘
                                              │ kri.RunAll             │
                                              └───────────────────────┘
        外部系統（之後）：eCAR、eContract、iPARTS、商工登記 → ext schema → KRI 層
```

---

## 4. 設計決策

每個決策：**選了什麼／為什麼／放棄了什麼**。

### D1. KRI 只讀業務表，不讀 SAP 原表
- **選擇**：KRI 的來源是 `prc`、`mst`、`inv`、`fin`。唯一例外是公司別本幣（`dbo.T001`），由一支共用函式讀取。
- **原因**：欄位清洗、去重、一對多 JOIN 的處理已經在 ETL 做完（例如 EKKN 多筆分攤、PR 轉多張 PO）。KRI 直接讀原表會把這些問題再踩一次。
- **放棄**：過往專案在每個 KRI 裡直接 JOIN SAP 原表，同樣的 JOIN bug 在多個 KRI 重複出現。

### D2. 設定拆成多張有型別的表
- **選擇**：`kri.Definition`（KRI 定義）、`kri.Parameter`（門檻）、`kri.Exclusion`（排除清單）、`kri.ApprovalMatrix`（核決權限）。
- **原因**：過往專案把定義、全域設定、門檻、執行紀錄混在同一張表，查詢全靠「參數名稱剛好不重複」。也沒有啟用開關，排程寫死在程式裡。
- **放棄**：一張萬用設定表。

### D3. 門檻與排除清單全部參數化
- **選擇**：程式裡**不寫死任何門檻、廠商代碼前綴、採購組織、傳票類型**。全部從 `kri.Parameter` / `kri.Exclusion` 讀。還沒定案的值標 `IsTentative = 1`，儀表板要顯示「暫定」。
- **原因**：過往專案很多 KRI 宣告了門檻參數卻沒有使用，實際值寫死在 SQL，改設定表不會生效，也沒人發現。
- **放棄**：先寫死、之後再改。

### D4. 結果以 RunId 保存，不 DROP 重建
- **選擇**：每次 `kri.RunAll` 產生一個 RunId，所有輸出表都帶 RunId。表用固定 DDL 建立、有主鍵。儀表板看「每個 KRI 最新一次成功的 Run」（`kri.vFlagLatest`）。保留最近 N 次（參數 `KeepRuns`）。
- **原因**：過往專案每次 `DROP` + `SELECT INTO`，沒有主鍵、型別會漂移。歷史表用 `SELECT *` 寫入，欄位一改就壞。執行到一半失敗，BI 會讀到缺表或半套資料。
- **放棄**：依期間 delete+insert 的歷史表（RunId 已經涵蓋同樣的需求，而且更簡單）。

### D5. 統一的標記表 `kri.Flag` + 影響金額
- **選擇**：每個 KRI 除了自己的明細表（`kri.Kxx_Detail`），一律把被標記的對象寫一列到 `kri.Flag`。每一列都有影響金額，**以本幣計算**（`EffectLocal` + `LocalCurrency`），台幣欄位（`EffectTWD`）等匯率表到位後補上。
- **原因**：一張統一的事實表，才能做跨 KRI 的評分，Power BI 也只要接一張。影響金額是過往專案最有價值的概念。
- **放棄**：每個 KRI 各自一種輸出格式。

### D6. 價格比較的標準化規則（所有比價類 KRI 共用）
- **選擇**：
  1. **單價 = 價格 ÷ 價格單位**（PO 用 `NetPrice / PriceUnit`，主檔用 `ConditionPrice / PriceUnit`）。
  2. **幣別相同、訂購單位相同才比較。** 跨幣別要等匯率表；跨單位要等單位換算表。
  3. **比不了的不能悄悄丟掉**：在明細表標成「未比對」並註明原因（無主檔價、幣別不同、單位不同），讓覆蓋率看得見。
- **原因**：過往專案的比價 KRI 有三個重複出現的 bug：匯率被乘兩次、級距價格造成同一行重複計算、LEFT JOIN 被 WHERE 變成 INNER JOIN，讓沒有主檔價的 PO 悄悄消失。
- **放棄**：把所有金額先換成台幣再比（現在沒有匯率表）。

### D7. 每個 KRI 獨立執行、獨立失敗
- **選擇**：`kri.RunAll` 依 `kri.Definition` 裡啟用的 KRI 逐一執行。每一題各自 TRY/CATCH，失敗記錄在 `kri.RunStep`，其他照跑，最後列出結果。跟 `etl.LoadAll` 的行為一致。
- **原因**：過往專案外層只包了一個 TRY/CATCH，前面一個 KRI 失敗，後面全部不跑，排程卻顯示成功。
- **放棄**：一個失敗就全停。

### D8. 期間用「基準日 + 回看月數」
- **選擇**：`kri.RunAll @AsOfDate`（預設今天）。每個 KRI 的觀察期間 = 基準日往前 `WindowMonths` 個月（在 Definition 設定，可被參數覆寫）。
- **原因**：比 Period 偏移量加 Frequency 的組合直覺，要回補歷史時直接給基準日就好。
- **放棄**：過往專案的 Period/Frequency 模式。

### D9. 評分放在第二期，用固定尺度
- **選擇**：第一期只產出標記與影響金額。第二期做 `kri.Score`：沿用「影響金額 × 異常程度權重 → 依對象加總」的概念，但**正規化改用固定尺度或歷史百分位**。
- **原因**：過往專案用「本次執行的最大值」做正規化，分數會隨其他廠商的分數變動，不能跨期比較趨勢。
- **放棄**：照搬過往專案的評分公式。

### D10. KRI 編號沿用 DTT 清單
- **選擇**：`K01`～`K20` 對應《UMC入選KRI(DTT整理)》的「TEST / KRI NO.」。本文件新增的題目從 `K21` 開始。
- **原因**：跟 UMC、DTT 溝通時編號一致，不用對照表。

### D11. 文字分群（Python）放到第三期
- **選擇**：需要文字相似度的題目（沒有料號的重複採購、品名比對）第三期再做。屆時沿用「SQL 準備 → Python → SQL 收尾」的分工，但要加 RunId 檢查，避免讀到上一次的 Python 輸出。
- **原因**：第一批 KRI 都有料號可以用，不需要文字分群。

### D12. 延續 ETL 的既有決策
- 目標表文字欄一律 NVARCHAR。
- `mst.Vendor` 粒度為「供應商 × 採購組織 × 公司別」，算家數用 `VendorRowNo = 1`。
- 主鍵欄位空白存成空字串，不讓一筆異常資料拖垮整張表。
- stg 缺欄位時可以用 `@fill` 補空欄先組起來。

---

## 5. 資料模型（schema `kri`）

### 5.1 設定

**kri.Definition**：KRI 定義，一題一列
| 欄位 | 說明 |
|---|---|
| KriCode (PK) | `K14` |
| Name | 簡稱，例：PO 單價高於主檔價 |
| Description | 完整說明（可含 `{X}` 參數佔位，由 view 代入實際值） |
| Stage | 採購作業階段：供應商管理 / 請購 / 採購 / 驗收 / 應付 |
| EntityType | 標記的對象：`PO`、`PR`、`VENDOR`、`MATERIAL`、`CONDITION` |
| ProcName | 執行的程序，例：`kri.Run_K14` |
| WindowMonths | 預設觀察期間（月） |
| Enabled | 1 = 由 RunAll 執行 |
| Phase | 開發期別 |
| IsCompliance / IsFraud / IsOperation / IsFinancial | 風險分類（可複選） |
| Notes | 備註、待確認事項 |

**kri.Parameter**：門檻
| 欄位 | 說明 |
|---|---|
| KriCode, ParamName (PK) | 例：`K14`, `PriceTolerance` |
| ParamValue | DECIMAL(19,6) |
| Unit | `ratio`、`days`、`months`、`amount` |
| Description | 意義 |
| IsTentative | 1 = 暫定值，尚未經 UMC/DTT 確認 |
| UpdatedAt, UpdatedBy | 最後修改 |

**kri.Exclusion**：排除清單
| 欄位 | 說明 |
|---|---|
| KriCode | 適用的 KRI；`*` = 全部 |
| ExclType | `VendorPrefix`、`Vendor`、`PurchOrg`、`Plant`、`PoType`、`MaterialGroup`、`ConditionType` … |
| ExclValue | 值 |
| Reason | 原因 |

**kri.ApprovalMatrix**：核決權限（K08 用，**由 UMC 提供**）
| 欄位 | 說明 |
|---|---|
| DocType | `PR` / `PO` |
| CompanyCode | `*` = 全部 |
| Currency | 金額門檻的幣別 |
| MinAmount, MaxAmount | 金額區間 [Min, Max) |
| ApprovalLevel | 核決層級（數字越大層級越高） |
| ValidFrom, ValidTo | 生效期間 |

### 5.2 執行紀錄

**kri.Run**：RunId (PK, identity)、AsOfDate、StartedAt、EndedAt、Status（`RUNNING` / `OK` / `PARTIAL` / `FAILED`）

**kri.RunStep**：RunId + KriCode (PK)、PeriodFrom、PeriodTo、StartedAt、EndedAt、DetailRows、FlagRows、Status、ErrorMessage

### 5.3 輸出

**kri.Flag**：所有 KRI 共用的標記事實表
| 欄位 | 說明 |
|---|---|
| RunId, KriCode, FlagKey (PK) | FlagKey = 對象鍵，例：`4500000001-00010` |
| EntityType | 同 Definition |
| CompanyCode, PurchOrg, Plant, Vendor, Material | 篩選與彙總用（沒有的留 NULL） |
| DocNumber, DocItem | 單據號碼、項次 |
| DocDate | 單據日期 |
| MetricValue | 觸發標記的數值，例：價差比例 0.23 |
| ThresholdValue | 當次使用的門檻 |
| EffectLocal, LocalCurrency | 影響金額（本幣） |
| EffectTWD | 影響金額（台幣，匯率表到位後才有值） |
| Reason | 一句話說明，例：「PO 單價高於主檔 23.0%」 |

**kri.Kxx_Detail**：每個 KRI 自己的明細表，欄位依題目而定，一律帶 RunId。明細表會包含**未被標記但有參與比較的列**（例如比價 KRI 的「未比對」列），用來算覆蓋率。

**kri.vFlagLatest**（view）：每個 KRI 最新一次成功 Run 的 Flag。儀表板接這張。

---

## 6. KRI 程序的介面

每個 KRI 一支程序 `kri.Run_Kxx @RunId, @AsOfDate`：
1. 從 `kri.Parameter` 讀門檻（透過共用函式 `kri.Param(@KriCode, @Name)`，找不到就報錯，不靜默使用預設值）。
2. 計算觀察期間 `[PeriodFrom, PeriodTo]`。
3. 寫入 `kri.Kxx_Detail`（帶 RunId）。
4. 寫入 `kri.Flag`（帶 RunId）。
5. 回傳明細筆數與標記筆數，交給 RunAll 記錄。

程序內**不自己開關交易、不寫 RunStep**；這些由 `kri.RunAll` 統一處理，確保每題的行為一致。

---

## 7. 共用計算規則

| 規則 | 定義 |
|---|---|
| **PO 單價** | `NetPrice / NULLIF(PriceUnit, 0)`（PriceUnit 缺值時由 ETL 反推，見 v2.3 規格） |
| **主檔單價** | `ConditionPrice / NULLIF(PriceUnit, 0)` |
| **主檔價取用** | 先找 A017（分工廠：Vendor + Material + PurchOrg + Plant + InfoCategory），找不到再用 A018（不分工廠）。條件類型依 `kri.Exclusion` 的 `ConditionType` 白名單（預設 PB00）。PO 日期落在 `[ValidFrom, ValidTo]`，排除刪除標記 |
| **文件幣別 → 本幣** | `WKURS > 0`：金額 × WKURS；`WKURS < 0`（間接報價）：金額 ÷ \|WKURS\|；文件幣別 = 本幣：× 1 |
| **本幣** | 公司別的 `T001.WAERS` |
| **台幣** | 第二期：從匯率表 TCURR 取文件日期當月的匯率（**不是**最新匯率） |
| **排除條件** | PO 刪除標記、數量 ≤ 0、`kri.Exclusion` 列出的對象 |

---

## 8. KRI 清單與分期

狀態說明：✅ 第一期 ⏩ 第二期 📥 要補資料 🔌 要接外部系統

| KRI | 名稱 | 期別 | 卡在哪裡 |
|---|---|---|---|
| K01 | 供應商評選不符門檻仍有交易 | 🔌 第四期 | Notes eCAR、OS 服務需求單 |
| K02 | 工商登記關聯供應商 | 🔌 第四期 | 商工登記；`LFA1` 統編欄位待確認 |
| K03 | 已停用供應商短暫啟用交易 | ⏩ 第二期 | 資料已有（VendorChangeHistory），排在第一批之後 |
| K04 | 付款條件比主檔差 | 📥 第三期 | **UMC 曾回覆不執行，待確認**；需 T052 |
| K05 | Open PO 超過供應商資本額 | 🔌 第四期 | 商工登記 |
| K06 | 用量 vs 請購量 vs 庫存 | 📥 第三期 | 歷史庫存 MBEWH |
| K07 | 本期 vs 預期請購量 | 📥 第三期 | ZRM449；資料期間只有 3 年 |
| **K08** | **疑似拆單（PR）** | ✅ 第一期 | 程式先做；**核決權限表由 UMC 提供後才有結果** |
| K09 | 疑似拆單（direct AP） | ⏩ 第二期 | 未入選；AP 借貸別缺 |
| K10 / K19 | 先入庫才補單／GR 貼近 PO | ⏩ 第二期 | 需補 `EKKO.AEDAT`、FirstGrDate、`EKPO.TXZ01` |
| K11 | 非緊急之緊急採購 | 🔌 第四期 | iPARTS |
| K12 | 集中且買貴 | ⏩ 第二期 | single source 定義（ZISK） |
| **K13** | **跨據點同料號單價差異** | ✅ 第一期 | — |
| **K14** | **PO 單價高於主檔價** | ✅ 第一期 | — |
| K15 / K16 | 呆滯警示／呆滯仍採購 | 📥 第三期 | ZIR3 呆滯報表 |
| K17 | 重大工程未簽合約 | 🔌 第四期 | eContract |
| **K18** | **Open PO 收貨進度異常** | ✅ 第一期 | — |
| K20 | 驗退後未及時處理 | 📥 第三期 | MSEG.UMLGO |
| **K21** | **主檔價倒填**（新增） | ✅ 第一期 | — |
| K22 | 主檔價大漲（新增） | ⏩ 第二期 | — |
| K23 | 便宜主檔價已生效，舊 Open PO 仍用高價（新增） | ⏩ 第二期 | — |
| K24 | 休眠供應商重新啟用、價格偏高（新增） | ⏩ 第二期 | — |

**第一期**：框架 + K08、K13、K14、K18、K21。
**第二期**：評分、BI view、K03、K09、K10/19、K12、K22～K24。
**第三期**：補資料後的 K04、K06、K07、K15/16、K20；文字分群。
**第四期**：外部系統 K01、K02、K05、K11、K17。

---

## 9. 第一期 KRI 規格

參數預設值一律是**暫定**（`IsTentative = 1`），待 UMC/DTT 確認。

### K14 PO 單價高於主檔價
- **風險**：PO 單價明顯高於下單當時有效的採購資訊記錄價格，可能議價不實或取價錯誤。
- **母體**：觀察期間內的 PO 項目（`prc.PurchaseOrderDetail`），有料號、未刪除、數量 > 0。
- **邏輯**：
  1. 依第 7 節取下單日有效的主檔價：A017 優先，找不到再用 A018。
  2. 幣別或單位不同 → 明細標「未比對」，註明原因，不標記。
  3. 價差比例 = PO 單價 ÷ 主檔單價 − 1。
  4. 價差比例 > `PriceTolerance` → 標記。
- **影響金額**：(PO 單價 − 主檔單價) × 訂購數量，換算本幣。
- **參數**：`PriceTolerance` = 0.05（暫定）；`WindowMonths` = 12。
- **已知限制**：級距價格（KONM）沒有下載，目前只用第一筆 KONP。PB00 是毛價、PO 是淨價，有折扣條件的料號本來就會有價差。

### K13 跨據點同料號單價差異
- **風險**：同一料號在相近期間、相近採購量下，某個據點買得明顯比其他據點貴。
- **母體**：觀察期間內的 PO 項目，有料號、未刪除、數量 > 0。
- **邏輯**：
  1. 比較群組 = 料號 + 幣別 + 訂購單位 + 季度 + 數量級距。
  2. 「據點」= 公司別（參數 `EntityLevel`：1 = 公司別、2 = 工廠）。
  3. 每個據點取群組內的最低單價；每一行 PO 跟**其他據點**的最低單價比。
  4. 單價 ÷ 其他據點最低單價 − 1 > `PriceTolerance` → 標記。
- **影響金額**：(單價 − 其他據點最低單價) × 訂購數量，換算本幣。
- **參數**：`PriceTolerance` = 0.30（暫定）；`QtyBandRatio` = 10（數量級距：每 10 倍一級）；`EntityLevel` = 1；`WindowMonths` = 12。

### K08 疑似拆單（PR）
- **風險**：同部門、同供應商在短期內開多張 PR，每張都低於某個簽核門檻，合計卻超過，疑似拆單規避簽核層級。
- **母體**：觀察期間內的 PR 項目（`prc.PurchaseRequisition`），未刪除、金額 > 0。
- **邏輯**：
  1. PR 金額 = 請購數量 × 評價價格。
  2. 分群鍵 = 成本中心（部門）+ 供應商（PR 指定的供應商，沒有就用轉出的 PO 的供應商）+ 幣別。
  3. 每一筆 PR，往前 `WindowDays` 天內同群組的 PR 合計金額（滾動視窗，避免曆月邊界漏抓）。
  4. 用 `kri.ApprovalMatrix` 查單筆金額與合計金額的核決層級。
  5. 合計層級 > 單筆層級，且視窗內至少 `MinCount` 筆 → 標記。
- **影響金額**：該筆 PR 金額，換算本幣。
- **參數**：`WindowDays` = 30；`MinCount` = 2；`WindowMonths` = 12。
- **前置條件**：`kri.ApprovalMatrix` 沒有資料時，這題不會標記任何東西，RunStep 會記錄「核決權限表為空」。
- **待確認**：部門的定義（成本中心或請購人）；系統自動產生的 PR 要排除（需 `EBAN.ESTKZ`）；PR 價格單位（`EBAN.PEINH` 目前不在規格內，先視為 1）。

### K18 Open PO 收貨進度異常
- **風險**：Open PO 已經過了交貨日很久，收貨比例還很低，可能需求已經不存在卻沒有結案，或者供應商交貨異常沒有被追蹤。
- **母體**：所有 Open PO 項目：未刪除、未標交貨完成、數量 > 0、已收數量 < 訂購數量。
- **邏輯**：
  1. 收貨比例 = 已收數量 ÷ 訂購數量（用數量，不用金額：GrAmount 是本幣、NetValue 是文件幣別，不能直接相除）。
  2. 逾期天數 = 基準日 − 交貨日（EKET 最早的排程日）。
  3. 收貨比例 < `MinReceivedRatio` 且逾期天數 > `OverdueDays` → 標記。
- **影響金額**：未交數量 × PO 單價，換算本幣。
- **參數**：`MinReceivedRatio` = 0.5；`OverdueDays` = 30（皆暫定）。
- **待確認**：`EKBE.MENGE` 的單位是否等於 PO 訂購單位。

### K21 主檔價倒填（新增）
- **風險**：採購資訊記錄的價格條件在生效日之後才建立（倒填生效日），可能是事後補價格去配合已經下的單。
- **母體**：觀察期間內**建立**的 A017、A018 條件記錄，未刪除。
- **邏輯**：
  1. 倒填天數 = 建立日（KONH.ERDAT）− 生效日（DATAB）。
  2. 倒填天數 > `BackdateDays` → 標記。
  3. 附上「生效日到建立日之間」用這個供應商＋料號下的 PO：筆數與金額。
- **影響金額**：倒填期間內相關 PO 的金額合計，換算本幣。
- **參數**：`BackdateDays` = 30（暫定）；`WindowMonths` = 12。

---

## 10. 資料缺口與待辦

| 缺口 | 影響 | 負責 | 狀態 |
|---|---|---|---|
| 匯率表 TCURR | 跨幣別比價、台幣影響金額（K05、K10、K12、K13、K14、K17） | 請 UMC 下載 | 待提供 |
| 核決權限表 | K08、K09 | 請 UMC 提供 | 待提供 |
| 級距價格 KONM | K14 精準度 | 請 UMC 下載 | 待評估 |
| `EKKO.AEDAT`、`EKPO.TXZ01`、FirstGrDate | K10/K19 | 規格 + ETL | 第二期 |
| `EBAN.ESTKZ`、`EBAN.PEINH` | K08 精準度 | 規格 + ETL | 待補 |
| MBEWH 歷史庫存 | K06 | 規格 + ETL | 第三期 |
| `MSEG.UMLGO` | K20 | 重抓 MSEG | 第三期 |
| T052 付款條件 | K04 | 請 UMC 下載 | 待 K04 是否執行 |
| `BSEG.SHKZG`、`KOART`、`BSCHL` | AP 借貸方向（K09） | 重抓 BSEG | 待重抓 |

---

## 11. 未決事項

| # | 事項 | 誰決定 |
|---|---|---|
| Q1 | K04 付款條件：UMC ADT 曾回覆「不執行」，DTT 版又列入選，要不要做 | UMC + DTT |
| Q2 | 所有暫定門檻的正式值 | UMC + DTT |
| Q3 | K08 的「部門」用成本中心還是請購人 | UMC |
| Q4 | 台灣廠商統一編號存在哪個 LFA1 欄位（K02、K05） | UMC SAP 團隊 |
| Q5 | 條件類型 ZPB0 的意義，比價時要不要納入 | UMC SAP 團隊 |

---

## 12. 驗收與測試

- 每個 KRI 都要有 LocalDB 自動測試（同 `etl/test_etl.py`）。測試資料要刻意放入**會觸發**和**不該觸發**的案例，至少包括：
  - 邊界值（剛好等於門檻）
  - 未比對的情況（無主檔價、幣別不同、單位不同）不能消失
  - 參數改了，結果要跟著變
  - 一題 KRI 失敗不影響其他題
- 第一期上線前，用 UMC 實際資料跑一次，抽樣 10 筆標記人工核對。

---

## 13. 變更紀錄

| 日期 | 版本 | 內容 |
|---|---|---|
| 2026-10-19 | v1.0 | 初版：框架決策 D1～D12、分期、第一期 KRI 規格 |
