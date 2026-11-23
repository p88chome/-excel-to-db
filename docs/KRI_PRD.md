# 採購風險儀表板：KRI 產品需求文件（PRD）

| 項目 | 內容 |
|---|---|
| 版本 | v1.3（2026-11-18） |
| 狀態 | 第一期與第二批已實作（`etl/sql/10～12`，測試 `etl/test_kri.py`），待客戶實際資料驗收 |
| 依據 | 客戶提供的 KRI 擬定清單與會議記錄、資料移轉規格 v2.3、過往專案 KRI 程式研究 |
| 範圍 | KRI 計算框架、KRI 邏輯、評分方向；不含 Power BI 畫面設計 |

這份文件是 KRI 開發的**決策紀錄**。寫程式時以這份為準；要改設計，先改這份（更新第 13 節的變更紀錄），再改程式。

---

## 1. 背景與目標

客戶的稽核單位要從 SAP 採購、收貨、庫存、應付資料中，持續找出異常交易與風險樣態，呈現在採購風險儀表板上。

**目標**
1. 把入選的 KRI 寫成**可重複執行、結果可追溯**的 SQL，資料更新後一鍵重算。
2. 每個 KRI 的門檻（X 天、Y%）都能由客戶與顧問討論後**直接改參數**，不改程式。
3. 每一筆異常都有**影響金額**，讓不同 KRI 能用同一把尺比較嚴重性，之後彙總成供應商、料號層級的風險分數。
4. 先用**現有的 SAP 資料**做出第一批 KRI，需要外部系統（表單系統、零件生命週期系統、商工登記）的題目分期接入。

**不在範圍內**
- Power BI 報表的版面與互動設計（另案）。
- 外部系統的介接程式（品質異常系統、合約系統、零件生命週期系統 API、商工登記爬蟲）：本文件只定義它們進來後要長什麼樣。

---

## 2. 使用者與使用情境

| 使用者 | 怎麼用 |
|---|---|
| 客戶稽核單位 | 看儀表板上被標記的交易，挑樣本查核；調整門檻 |
| 顧問 | 開發與維護 KRI 邏輯；和客戶對齊門檻與定義 |
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
└──────────────┘   └──────────────────────┘   │ kri.Score / vBi*       │   └──────────┘
                                              │ kri.RunAll             │
                                              └───────────────────────┘
        外部系統（之後）：品質異常、合約、零件生命週期、商工登記 → ext schema → KRI 層
```

---

## 4. 設計決策

每個決策：**選了什麼／為什麼／放棄了什麼**。

### D1. KRI 只讀業務表，不讀 SAP 原表
- **選擇**：KRI 的來源是 `prc`、`mst`、`inv`、`fin`。例外是規格表沒有的欄位，各由一個 view 讀取：公司別本幣（`dbo.T001` → `kri.vCompanyCurrency`）、供應商銀行帳號（`dbo.LFBK` → `kri.vVendorBank`）、匯率換算因子（`dbo.TCURF` → `kri.vCurrencyFactorSap`）、PO 項目類別／退貨／單位換算（`dbo.EKPO` 的 PSTYP、RETPO、UMREZ、UMREN → `kri.vPoItemSap`）。原表或欄位不存在的環境，view 建成空的或那欄是 NULL，用到的題目照跑、相關判斷不作用。
- **原因**：欄位清洗、去重、一對多 JOIN 的處理已經在 ETL 做完（例如 EKKN 多筆分攤、PR 轉多張 PO）。KRI 直接讀原表會把這些問題再踩一次。
- **放棄**：過往專案在每個 KRI 裡直接 JOIN SAP 原表，同樣的 JOIN bug 在多個 KRI 重複出現。

### D2. 設定拆成多張有型別的表
- **選擇**：`kri.Definition`（KRI 定義）、`kri.Parameter`（數值門檻）、`kri.ValueList`（清單：排除名單與白名單）、`kri.ApprovalMatrix`（核決權限）。
- **原因**：過往專案把定義、全域設定、門檻、執行紀錄混在同一張表，查詢全靠「參數名稱剛好不重複」。也沒有啟用開關，排程寫死在程式裡。
- **放棄**：一張萬用設定表。

### D3. 門檻與排除清單全部參數化
- **選擇**：程式裡**不寫死任何門檻、廠商代碼前綴、採購組織、傳票類型**。全部從 `kri.Parameter` / `kri.ValueList` 讀。還沒定案的值標 `IsTentative = 1`，儀表板要顯示「暫定」。
- **原因**：過往專案很多 KRI 宣告了門檻參數卻沒有使用，實際值寫死在 SQL，改設定表不會生效，也沒人發現。
- **放棄**：先寫死、之後再改。

### D4. 結果以 RunId 保存，不 DROP 重建
- **選擇**：每次 `kri.RunAll` 產生一個 RunId，所有輸出表都帶 RunId。表用固定 DDL 建立、有主鍵。儀表板看「每個 KRI 基準日最新、同基準日取最後一次的成功 Run」（`kri.vLatestStep` → `kri.vFlagLatest`），回補過去的基準日不會蓋掉現在的結果。保留（參數 `KeepRuns`）每題各自算：每題留最近 N 次，另外一定留儀表板正在用的那次；用 `@Only` 重跑某題、或停用很久的題目，都不會把別題的結果擠掉。沒有任何一題留著的 Run 一併刪除。
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
- **原因**：過往專案的比價 KRI 有三個重複出現的 bug：匯率被乘兩次（少了括號）、級距價格只用條件編號串接造成同一行重複計算、沒有主檔價或沒有匯率的 PO 悄悄消失（主檔價直接 INNER JOIN；匯率 LEFT JOIN 之後又在 WHERE 用到，等於 INNER JOIN）。另外門檻宣告了卻寫死在 SQL、排除條件（廠商前綴、採購組織）寫死，客戶改不了。
- **放棄**：把所有金額先換成台幣再比（現在沒有匯率表）。

### D7. 每個 KRI 獨立執行、獨立失敗
- **選擇**：`kri.RunAll` 依 `kri.Definition` 裡啟用的 KRI 逐一執行。每一題各自一個交易和 TRY/CATCH：結果、筆數、OK 狀態一起 COMMIT；失敗的回滾，錯誤號碼、程序、行號記在 `kri.RunStep`，其他照跑，最後列出結果。跟 `etl.LoadAll` 的行為一致。同時只能跑一個 RunAll（`sp_getapplock`），開始時把上次中途斷掉、停在 RUNNING 的紀錄改成 ABORTED。排程用 `@RaiseOnFail = 1`：有題目失敗時最後丟出錯誤，SQL Agent 才看得到。
- **原因**：過往專案的錯誤處理不一致：沒有自己 TRY/CATCH 的程序一出錯，外層唯一的 CATCH 接住，後面全部不跑；有自己 TRY/CATCH 的則把錯誤寫進 log 就吞掉，連拉資料失敗都照跑後面的題目，最後排程仍記一筆成功。
- **放棄**：一個失敗就全停。

### D8. 期間用「基準日 + 回看月數」
- **選擇**：`kri.RunAll @AsOfDate`（預設今天）。每個 KRI 的觀察期間 = 基準日往前 `WindowMonths` 個月（在 Definition 設定，可被參數覆寫）。
- **原因**：比 Period 偏移量加 Frequency 的組合直覺，要回補歷史時直接給基準日就好。
- **放棄**：過往專案的 Period/Frequency 模式。

### D9. 風險分數用固定尺度，不跟其他廠商比
- **選擇**：`kri.RunAll` 各題跑完後呼叫 `kri.Run_Score`（RunStep 記成 `SCORE`），對供應商、料號算分數：
  - 每題用基準日（含）以前最近一次成功的結果；停用的題目不算。
  - 每筆標記的點數 = 權重 ×（基本分 + LOG10(1 + 台幣金額 ÷ 金額單位)）。金額取 EffectTWD，沒有時本幣是台幣就用 EffectLocal；都沒有的只算基本分，筆數記在 `FlagsWithoutAmount`。
  - 分數 = 100 ×（1 − EXP(−點數合計 ÷ ScaleK)），0～100。分成整體（OVERALL）和法遵、舞弊、營運、財務四類（依 `kri.Definition` 的風險分類）。
  - 參數都在 `kri.Parameter`（KriCode = `*`）：`ScoreAmountUnit`、`ScoreBasePoints`、`ScoreScaleK`、`ScoreHighCut`、`ScoreMediumCut`、`ScoreWeight`（要某題加重就設那一題的 ScoreWeight）。全部是暫定值。
  - 分數算失敗只記在 SCORE 那一步，不影響各題的結果。
- **原因**：過往專案用「本次執行的最大值」做正規化，分數會隨其他廠商的分數變動，不能跨期比較趨勢；影響金額為 0 的標記也被丟掉。固定尺度下一家的分數只看自己的標記；LOG10 讓金額大的加分但不會一筆蓋過全部；沒有金額的標記（例如凍結、付款條件類）也有基本分。
- **放棄**：照搬過往專案的評分公式；用歷史百分位（資料期數不夠時不穩定，之後可以再加）。

### D10. KRI 編號沿用客戶的擬定清單
- **選擇**：`K01`～`K20` 對應客戶 KRI 擬定清單的編號。清單以外的題目不放在這份文件。
- **原因**：跟客戶溝通時編號一致，不用對照表。

### D11. 文字分群（Python）放到第三期，介面先定好
- **選擇**：需要文字相似度的題目（沒有料號的重複採購、品名比對）第三期再做，SQL 和 Python 的分工先定好：
  - `kri.Definition` 加 `ExecMode`：`SQL`（現在全部）／`PY`。PY 題目分成「SQL 準備 → Python → SQL 收尾」三段。
  - SQL 準備把要比對的資料寫到 `kri.PyInput`（帶 RunId、KriCode），RunStep 記 `WAITING_PY`，RunAll 不等它、繼續跑下一題。
  - Python 讀「狀態是 WAITING_PY 的 RunId」的輸入，結果寫到 `kri.PyOutput`（帶同一個 RunId），然後呼叫 `kri.CompletePy @RunId, @KriCode`：檢查輸出的 RunId 對得上，再跑 SQL 收尾寫明細和標記，RunStep 改 OK／FAILED。
  - 超過 `PyTimeoutHours` 還是 WAITING_PY 的，下一次 RunAll 改成 ABORTED。
  - 風險分數只用 OK 的結果，等 Python 的題目在完成前沿用上一次。
- **原因**：過往專案 Python 讀寫固定的表、沒有執行編號，Python 沒跑完或失敗時，SQL 收尾會讀到上一次的輸出而不知道。第一批 KRI 都有料號可以用，還不需要文字分群。
- **放棄**：在 SQL Server 裡直接跑 Python（Machine Learning Services 需要另外安裝和授權）；RunAll 同步等 Python（一題卡住整次就卡住）。

### D12. 回補基準日只用「當時已知」的資料
- **選擇**：給過去的基準日重跑時，基準日之後才發生、才輸入的資料一律不能影響結果。業務表有些欄位只有「現在」的值，用共用函式還原：
  - `kri.PoReceivedAt`：PO 項目在某天已收多少（PO 上的已收數量 × 那天以前的收貨 ÷ 全部收貨），交貨完成碼有勾、而且所有收貨在那天以前都已過帳也已輸入才算已結案（K05、K06、K18）。
  - `kri.InfoPriceAt` 的 `@KnownBy`：只用那天以前已建立的主檔價（K14）；舊條件的迄日是被之後才建的條件縮短的（新條件生效日 = 舊迄日 + 1），當作那天還有效。
  - `kri.VendorValueAt`：供應商主檔欄位在某天的值 = 那天之後第一筆異動的舊值（K02 凍結、K04 付款條件）。
- **原因**：儀表板要看趨勢，同一個基準日今天跑和三個月後跑，結果不能不一樣。
- **放棄**：直接用現在的主檔、已收數量（回補的結果會偏好看）。

### D13. 一題一個檔，檔頭用白話寫規則
- **選擇**：每題的明細表和程序放在 `etl/sql/kri_procs/Kxx_題目.sql`，檔頭固定寫【抓什麼】【為什麼有風險】【怎麼判斷】（第 1 步、第 2 步…）【門檻】【名單】【明細表怎麼看】【限制】；程序裡一步一張暫存表，步驟跟檔頭對得上。`11_kri_procedures.sql` 由 `etl/build_kri_sql.py` 合併產生，SSMS 開一個檔就能全部部署。
- **原因**：使用者要能自己看懂、自己調整，不能只有寫的人看得懂。
- **放棄**：一個兩千多行、依開發批次排序的大檔。

### D14. 延續 ETL 的既有決策
- 目標表文字欄一律 NVARCHAR。
- `mst.Vendor` 粒度為「供應商 × 採購組織 × 公司別」，算家數用 `VendorRowNo = 1`。
- 主鍵欄位空白存成空字串，不讓一筆異常資料拖垮整張表。
- stg 缺欄位時可以用 `@fill` 補空欄先組起來。

### D15. 每題有自己的執行頻率，排程每天跑一次就好
- **選擇**：`kri.Definition.Frequency`、`RunDay` 設定每題的頻率。排程每天 `EXEC kri.RunAll`；`kri.LastDueDate` 算出基準日以前最近一次「該跑」的日子，那天到基準日之間已經成功跑過的題目，這次記 `SKIPPED`（說明寫上次的 RunId）不跑。排程漏跑那天，下一次執行就會補上。`@Only` 點名的題目、`@Force = 1` 不看頻率。SKIPPED 不算失敗、不算保留次數，儀表板繼續用上次的結果。日期都用基準日算，不受伺服器的 `DATEFIRST` 設定影響。
- **原因**：有些題目（呆滯料、主檔價變動）一個月看一次就夠，每天跑浪費也讓結果跳動。過往專案用執行當下的日期（GETDATE）判斷要不要跑，回補過去的基準日時判斷會錯，漏跑也不會補。
- **放棄**：每種頻率各開一個排程（排程多、容易漏設）；用「今天是不是月底」判斷（漏跑那天就整個月沒結果）。

### D16. 給 Power BI 的 view 先接好
- **選擇**：`kri.vBiKri`、`kri.vBiFlag`、`kri.vBiVendor`（第 5 節）把標記、題目說明、供應商、料號接好。供應商主檔一家多列，view 裡已經處理，筆數跟 `kri.vFlagLatest` 一樣。供應商的凍結狀態是「現在」的值，跟基準日當時可能不同（基準日當時的狀態看各題明細）。
- **原因**：過往專案把主檔接進 BI 時，LEFT JOIN 又在 WHERE 加條件（語言、地址有效日），沒有英文品名、地址的對象整筆消失；BI 端各自 JOIN 一家多列的主檔也容易重複計算。
- **放棄**：在 Power BI 裡自己 JOIN（每張報表各寫一次、容易錯）。

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
| Frequency / RunDay | 執行頻率（D15）：`DAILY`（預設）、`WEEKLY`（RunDay = 星期幾，1 = 星期一）、`MONTHLY`（RunDay = 幾號，空白 = 月底）、`QUARTERLY`（3、6、9、12 月的 RunDay 號，空白 = 季底） |
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
| IsTentative | 1 = 暫定值，尚未經客戶確認 |
| UpdatedAt, UpdatedBy | 最後修改 |

**kri.ValueList**：清單（排除名單與白名單）
| 欄位 | 說明 |
|---|---|
| KriCode | 適用的 KRI；`*` = 全部 |
| ListName | 排除：`ExcludeVendorPrefix`、`ExcludePurchOrg`、`ExcludePlant`、`ExcludePoType`、`ExcludeMaterialGroup`；白名單：`AllowedConditionType`、`AllowedInfoCategory` |
| ListValue | 值 |
| Note | 原因 |

**kri.ApprovalMatrix**：核決權限（K08 用，**由客戶提供**）
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

**kri.RunStep**：RunId + KriCode (PK)、PeriodFrom、PeriodTo、StartedAt、EndedAt、DetailRows、FlagRows、Status（RUNNING／OK／FAILED／ABORTED／SKIPPED）、ErrorMessage、ErrorNumber、ErrorSeverity、ErrorState、ErrorProcedure、ErrorLine

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

**kri.vLatestStep**（view）：每個 KRI 目前採用的那一次成功執行（基準日最新，同基準日取 RunId 最大）。

**kri.vFlagLatest**（view）：`kri.vLatestStep` 那一次的 Flag。

**kri.ScoreDetail**：RunId + EntityType + EntityKey + KriCode (PK)、SourceRunId（這題採用哪一次的結果）、FlagCount、AmountTWD、FlagsWithoutAmount、Weight、Points。一列 = 一個對象 × 一題。

**kri.Score**：RunId + EntityType + EntityKey + Category (PK)、AsOfDate、RawPoints、Score（0～100）、RiskLevel（HIGH／MEDIUM／LOW）、KriCount、FlagCount、AmountTWD、FlagsWithoutAmount。EntityType = `VENDOR`／`MATERIAL`；Category = `OVERALL`／`COMPLIANCE`／`FRAUD`／`OPERATION`／`FINANCIAL`。`kri.vScoreLatest` = 最新一次成功的分數。

**Power BI 用的 view**（D16）：
| view | 一列是 | 內容 |
|---|---|---|
| `kri.vBiKri` | 一題 | 設定、風險分類、頻率、說明（`{參數}` 換成現在的門檻值，`kri.DescribeKri`）、還有沒有暫定門檻、儀表板用的那次結果、最近一次執行的狀態和說明 |
| `kri.vBiFlag` | 一筆標記（筆數 = `kri.vFlagLatest`） | 標記 + 題目說明 + 供應商（整家資料取 `VendorRowNo = 1`；凍結、付款條件取標記那個公司別／採購組織的那列）+ 料號；`AmountTWD` = EffectTWD，沒有時本幣是台幣就用 EffectLocal |
| `kri.vBiVendor` | 一家被標記的供應商 | 幾題、幾筆、題號清單、AmountTWD 合計、沒有台幣金額的筆數、最新的整體分數和風險等級 |

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
| **主檔價取用** | 先找 A017（分工廠：Vendor + Material + PurchOrg + Plant + InfoCategory），找不到再用 A018（不分工廠）。條件類型依 `kri.ValueList` 的 `AllowedConditionType` 白名單（預設 PB00），資訊記錄類別依 `AllowedInfoCategory`（預設 0 = 標準）。PO 日期落在 `[ValidFrom, ValidTo]`，排除刪除標記 |
| **文件幣別 → 本幣** | `WKURS > 0`：金額 × WKURS；`WKURS < 0`（間接報價）：金額 ÷ \|WKURS\|；再乘換算因子 ToFactor ÷ FromFactor（例：100 SGD = 74.6 USD 時 WKURS 存 74.6，要 ÷ 100）。因子先找本地設定 `kri.CurrencyFactor`，再找 `dbo.TCURF`（匯率類型 M、最新一筆），都沒有當 1 : 1；文件幣別 = 本幣：× 1 |
| **本幣** | 公司別的 `T001.WAERS` |
| **台幣** | 第二期：從匯率表 TCURR 取文件日期當月的匯率（**不是**最新匯率） |
| **排除條件** | PO 刪除標記、數量 ≤ 0、`kri.ValueList` 排除名單列出的對象 |
| **基準日當時的狀態** | 見 D12：`kri.PoReceivedAt`、`kri.InfoPriceAt(@KnownBy)`、`kri.VendorValueAt` |
| **填充值** | `kri.IsPlaceholder`：空白、整串同一個字（0000000000、XXXXXXXXXX、----）、只有 NA 重複；比對統編、電話、地址、銀行帳號時不配對 |

---

## 8. KRI 清單與分期

狀態說明：✅ 第一期 ⏩ 第二期 📥 要補資料 🔌 要接外部系統

| KRI | 名稱 | 期別 | 卡在哪裡 |
|---|---|---|---|
| **K01** | **品質異常期間仍下單** | ✅ 第二批 | 讀 `ext.QualityIssue`；已結案的單要有結案日才算得到期間 |
| **K02** | **工商登記關聯供應商** | ✅ 第四批（SAP 內部版） | 商工登記放 `ext.VendorRelation`；銀行帳號讀 `dbo.LFBK` |
| **K03** | **已停用供應商短暫啟用交易** | ✅ 第二批 | PO 日暫用 BEDAT（待 `EKKO.AEDAT`） |
| **K04** | **付款條件比主檔差** | ✅ 第二批 | **客戶是否執行待確認**；天數先從代碼推估，T052 到了填 `kri.PaymentTerm` |
| **K05** | **Open PO 超過供應商資本額** | ✅ 第四批 | 資本額放 `ext.VendorCapital`（商工登記） |
| **K06** | **用量 vs 請購量 vs 庫存** | ✅ 第四批 | 庫存用快照回推；異動資料要完整 |
| **K07** | **本期 vs 預期請購量** | ✅ 第四批 | 預期量放 `ext.ExpectedDemand`；沒有時用歷史 |
| **K08** | **疑似拆單（PR）** | ✅ 第一期 | 程式先做；**核決權限表由客戶提供後才有結果** |
| **K09** | **疑似拆單（direct AP）** | ✅ 第三批 | 核決權限表（AP）由客戶提供；成本中心目前只看供應商行 |
| **K10 / K19** | **先入庫才補單／GR 貼近 PR、PO** | ✅ 第二批 | 排除關鍵字先比對收貨的項目說明；`EKPO.TXZ01`、`EKKO.AEDAT` 進來後再補 |
| **K11** | **非緊急之緊急採購** | ✅ 第四批 | 緊急採購的判斷條件要在本地設定；MOU 放 `ext.PartUsage` |
| **K12** | **集中且買貴** | ✅ 第三批 | 獨家先用 PO 資料判斷；客戶的獨家料號清單／製造商料號進來後改 |
| **K13** | **跨據點同料號單價差異** | ✅ 第一期 | — |
| **K14** | **PO 單價高於主檔價** | ✅ 第一期 | — |
| **K15 / K16** | **呆滯警示／呆滯仍採購** | ✅ 第四批 | 呆滯報表放 `ext.SlowMoving`；沒有時用最後領用推估 |
| **K17** | **重大工程未簽合約** | ✅ 第四批 | 工程類 PO 的判斷要在本地設定；合約放 `ext.Contract` |
| **K18** | **Open PO 收貨進度異常** | ✅ 第一期 | — |
| **K20** | **驗退後未及時處理** | ✅ 第四批 | 待退倉要在本地設定 |

**第一期**：框架 + K08、K13、K14、K18。
**第二批（已完成）**：K01、K03、K04、K10、K19。
**第三批（已完成）**：K09、K12。
**第四批（已完成）**：K02、K05、K06、K07、K11、K15、K16、K17、K20（外部資料走 `ext`，沒資料時照跑、備註說明）。
**第二期**：評分、BI view（已完成，參數暫定）。
**第三期**：補資料後的 K04、K06、K07、K15/16、K20；文字分群。
**第四期**：外部系統 K02、K05、K11、K17。

---

## 9. 第一期 KRI 規格

參數預設值一律是**暫定**（`IsTentative = 1`），待客戶確認。

### K14 PO 單價高於主檔價
- **風險**：PO 單價明顯高於下單當時有效的採購資訊記錄價格，可能議價不實或取價錯誤。
- **母體**：觀察期間內的 PO 項目（`prc.PurchaseOrderDetail`），有料號、未刪除、數量 > 0；退貨項目（`ExcludeReturnsInd`）、庫存轉移項目（`ExcludeItemCategory` = 7／U）不算。
- **邏輯**：
  1. 依第 7 節取下單日有效的主檔價：A017 優先，找不到再用 A018。PO 項目類別決定資訊記錄類別：外包（3／L）跟外包價、寄售（2／K）跟寄售價、其他跟標準價比（還要在 `AllowedInfoCategory` 白名單裡；目前只放 0，所以外包、寄售 PO 會是「無主檔價」，不會再拿去跟標準價比）。
  2. 單位不同、但主檔用料號基本單位時，用 PO 的換算比例（1 訂購單位 = UMREZ ÷ UMREN 基本單位）換成主檔單位再比；換不了才標「單位不同」。幣別不同 → 不比。都寫進明細並註明原因。
  3. 價差比例 = PO 單價（主檔單位）÷ 主檔單價 − 1。
  4. 價差比例 > `PriceTolerance` → 標記。
- **影響金額**：(PO 單價 − 主檔單價) × 數量（都用主檔單位），換算本幣。
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
- **影響金額**：該筆 PR 金額。PR 沒有匯率，所以先以 PR 幣別計（`LocalCurrency` 填 PR 幣別），匯率表到位後再換算。
- **參數**：`WindowDays` = 30；`MinCount` = 2；`WindowMonths` = 12。
- **前置條件**：`kri.ApprovalMatrix` 沒有資料時，這題不會標記任何東西，RunStep 會記錄「核決權限表為空」。
- **待確認**：部門的定義（成本中心或請購人）；系統自動產生的 PR 要排除（需 `EBAN.ESTKZ`）；PR 價格單位（`EBAN.PEINH` 目前不在規格內，先視為 1）。

### K18 Open PO 收貨進度異常
- **風險**：Open PO 已經過了交貨日很久，收貨比例還很低，可能需求已經不存在卻沒有結案，或者供應商交貨異常沒有被追蹤。
- **母體**：基準日當時的 Open PO 項目：未刪除、數量 > 0、基準日當時已收數量 < 訂購數量、還沒結案（`kri.PoReceivedAt`，見 D12）。
- **邏輯**：
  1. 收貨比例 = 已收數量 ÷ 訂購數量（用數量，不用金額：GrAmount 是本幣、NetValue 是文件幣別，不能直接相除）。
  2. 逾期天數 = 基準日 − 交貨日（EKET 最早的排程日）；交貨日早於 PO 日（補開的 PO）時從 PO 日起算，PO 還沒開的日子不算逾期。
  3. 收貨比例 < `MinReceivedRatio` 且逾期天數 > `OverdueDays` → 標記。
- **影響金額**：未交數量 × PO 單價，換算本幣。
- **參數**：`MinReceivedRatio` = 0.5；`OverdueDays` = 30（皆暫定）。
- **待確認**：`EKBE.MENGE` 的單位是否等於 PO 訂購單位。

## 9b. 第二批 KRI 規格（v1.3）

共通：參數一律暫定（`IsTentative = 1`）；PO 日目前用文件日 BEDAT。回補歷史基準日時，收貨、應付傳票只看基準日當時已存在的（過帳日與系統輸入日都 ≤ 基準日），異動紀錄只看基準日以前的。`10_kri_framework.sql` 會建 KRI 查詢用的索引（應付 PO / 供應商、PO 日、收貨 PO）；重跑 `01_create_tables.sql` 之後要再跑 10。

### K01 品質異常期間仍下單（客戶清單 TEST 1）
- **母體**：`ext.QualityIssue`（品質異常單，由各環境把原系統匯出整理進來；原始表到 ext 的對應不放在 repo）。
- **邏輯**：期間 = [開單日, 結案日]，未結案算到基準日；已結案但沒有結案日的單略過並在備註列出筆數。期間內同供應商的 PO 項目進明細（純數字的供應商代碼補前導零到 10 碼、料號補到 18 碼；結案日晚於基準日的當作未結案；開單當天的 PO 也算，因為只有日期、分不出先後），同料號另外註明。一張單期間內 PO 項目數 ≥ `MinPoCount` → 標記。標記以 PO 項目為單位。
- **影響金額**：PO 項目本幣金額。
- **參數**：`MinPoCount` = 1；`RequireSameMaterial` = 0（1 = 只看同料號）。
- **已知限制**：原系統只有狀態沒有結案日時，只有未結案的單能用。

### K03 已停用供應商短暫啟用交易（TEST 3）
- **邏輯**：凍結欄位（`kri.ValueList` 的 `BlockField`，預設 SPERM、SPERR）從有值改成空白 = 解凍；同一 Table + TableKey + 欄位下一次改回有值 = 再凍結（只看基準日以前的異動）。解凍天數 ≤ `MaxOpenDays`，且期間內有 PO 或應付傳票 → 標記。LFM1 只看該採購組織、LFB1 只看該公司別。採購凍結（SPERM）只算 PO、過帳凍結（SPERR）只算應付傳票（看系統輸入日落在解凍期間，沒有輸入日才用過帳日；過帳日倒填也抓得到）。同一時間的異動用異動單號排先後。同一張異動單解凍多個採購組織／公司別時，各算一筆。
- **影響金額**：期間內 PO 本幣金額合計。
- **參數**：`MaxOpenDays` = 30。
- **已知限制**：同一次解凍可能同時在 LFA1 和 LFM1/LFB1 各有一筆，會各標一次；解凍期間內的 PO 不一定是解凍造成的。

### K04 付款條件比主檔差（TEST 4，客戶是否執行待確認）
- **邏輯**：PO 付款條件 vs 主檔（LFM1）；應付傳票 vs PO。天數 = `kri.PaymentTerm` 對照表，沒有就取代碼中的數字。提早付款天數 ≥ `MinDaysWorse` → 標記。`MasterLevel` = 2 時，PO 和公司別層（LFB1）一樣也算一致（實際資料裡 PO 大多跟 LFB1 一致、和 LFM1 不同，那比較像主檔兩層不一致）。
- **影響金額**：金額 × 提早天數 ÷ 365 × `AnnualRate`（資金成本）。
- **參數**：`MinDaysWorse` = 1；`AnnualRate` = 0.02；`MasterLevel` = 2。
- **已知限制**：主檔用下單當時的值（`kri.VendorValueAt` 從異動紀錄還原 LFM1／LFB1 的 ZTERM；異動紀錄要有 ZTERM 才還原得了，目前下載的 CDPOS 只有凍結欄位）；付款條件代碼的天數是推估，明細 `DaysEstimated` = 1 的要等 T052 對照表進來再確認。LFB1 空白時只跟 LFM1 比。PO 條件空白時，發票會帶主檔條件，所以有應付就用應付的天數；沒有應付才當立即付款（0 天）；應付的條件推不出天數時不判斷、算在「推不出天數」。這種情況狀態標「PO與主檔不同」，實際不同的是應付條件（原因欄會列出應付條件）。應付只看非借方的行（排除貸項通知單；借貸別空白的照樣比）；同一 PO 項目有好幾種應付條件時，和 PO 不同的優先列出（推不出天數的也會列出、算在「推不出天數」）。預付款（特殊總帳）要等 UMSKZ 進來才能排除；一張傳票對多張 PO 時，目前 ETL 只帶第一個 PO 項目。

### K10 先入庫才補請採購單（TEST 10）／K19 GR 貼近 PR、PO 建立日（TEST 19）
- **共用**：`kri.PoReceipt`：每個 PO 項目的第一次收貨（`GrMovementType` 白名單、借方）。收貨日取過帳日與系統輸入日較早的一個。項目說明符合 `ExcludeTextPattern`（緊急採購關鍵字，LIKE 樣式）的排除。
- **K10**：PO 日 → 第一次收貨 ≤ `MaxGapDays`（含收貨早於 PO），整張 PO 本幣金額 ≤ `MaxPoAmount`。本幣不在 `AmountCurrency` 白名單的公司別不判斷金額（標「未判斷」，照樣可以標記）。
- **K19**：PR 日（沒有 PR 用 PO 日）→ 第一次收貨 ≤ `MaxGapDays`，不限金額。同一筆可能兩題都標，彙總影響金額時要去重。
- **參數**：K10 `MaxGapDays` = 1、`MaxPoAmount` = 500000、`AmountCurrency` = TWD；K19 `MaxGapDays` = 3。
- **K10 金額**：整張 PO 金額直接從 PO 明細加總所有未刪除項目（含還沒收貨、被排除名單濾掉的；排除名單只決定看哪些項目，不能讓金額變小）；有任何項目換不出本幣時標「未判斷」。
- **K10 送貨單日**：收貨文件日（BLDAT）早於 PO 日也標記（`DocGapDays` < 0）。收貨系統輸入日不可能早於 PO 建立，所以「收貨早於 PO」只會出現在 PO 文件日被改過、或收貨過帳日倒填；送貨單日才是貨先到的直接證據。
- **K19 PR 找不到**：PO 有 PR 號碼但 PR 不在資料裡時不退回 PO 日（會低估間隔），留空不判斷，備註列出筆數。
- **已知限制**：沖銷（102／貸方）不扣回，收貨後沖銷再重收的，第一次收貨日仍是被沖銷那筆；收貨資料沒有對應原始收貨的欄位，要等 EKBE 的參考欄位進來才能配對。

## 9c. 第三批 KRI 規格

共通：`kri.PoBase` 多一個排除清單 `ExcludeMaterial`（通用、雜項料號，所有用 PO 的題目一起排除；數字料號可以不補零）。

### K09 疑似拆單（direct AP）
- **母體**：沒有 PO 的應付傳票（供應商行），一張傳票 + 供應商一筆，本幣金額合計；借方（貸項、沖回）、清帳傳票是自己的（付款）、`ExcludeDocType`（預設 KZ、ZP、AB）不算；`IncludeDocType` 有設時只看這些傳票類型。借貸別空白、又沒設 IncludeDocType 時備註會提醒。
- **邏輯**：同公司別 + 同供應商 + 同成本中心（供應商行沒有成本中心的整個供應商算一群），往前 `WindowDays` 天內至少 `MinCount` 張，合計金額對到的核決層級（`kri.ApprovalMatrix`，DocType = 'AP'，公司別可以是 `*`）高於單張 → 標記。
- **參數**：`WindowDays` = 30、`MinCount` = 2。
- **已知限制**：成本中心在費用行，目前 ETL 只載供應商行；沖銷要等 BKPF.STBLG；員工代墊款的「供應商」是員工，帳戶群組進來後要分開；核決權限表沒給之前不會標記。

### K12 集中且買貴
- **邏輯**：前一年 + 本期都有採購、兩期合計只有一家供應商的料號（`AllowedSingleSource` 白名單除外），同幣別同單位比較本期均價 ÷ 前一年均價 − 1；基準 = 同物料群組（同幣別、同單位）其他料號的平均漲幅，可比的不到 `MinGroupMaterials` 個時基準以 0 計。漲幅 − 基準 > `PriceTolerance` → 標記。
- **影響金額**：（本期均價 − 前一年均價 ×（1 + 基準））× 本期數量，換本幣。
- **參數**：`PriceTolerance` = 0.10、`MinGroupMaterials` = 3。基準用料號層級平均（多家供應商的料號算一次）；沒有物料群組的不比；供應商家數不套 PoBase 的排除條件。
- **已知限制**：平均數會被極端值拉動，之後可以改中位數。客戶的定義用自訂的獨家料號清單（一個製造商料號底下只有一個料號），目前用 PO 資料推「獨家」；資料只有 3 年，前一年沒有採購的料號比不了。

## 9d. 第四批 KRI 規格

共通：外部資料都放 `ext` schema，由各環境把原系統匯出整理進來（對應不放 repo）；沒有資料時程式照跑，備註會說明。
`kri.StockAt(料號, 工廠, 日期)`：目前庫存快照（含品檢、凍結庫存）減掉指定日之後的異動，回推當天庫存；準度取決於異動資料是否完整。

| 外部表 | 用途 | 欄位 |
|---|---|---|
| `ext.VendorRelation` | K02 商工登記關聯 | VendorA、VendorB、RelationType |
| `ext.VendorCapital` | K05 實收資本額 | Vendor 或 TaxNumber、Capital、Currency、DataDate |
| `ext.ExpectedDemand` | K07 預期請購量 | Material、Plant、Month、Qty |
| `ext.PartUsage` | K11 MOU、待用量 | Material、Plant、SnapshotDate、Mou、WaitingForUse |
| `ext.SlowMoving` | K15、K16 呆滯報表快照 | SnapshotDate、Material、Plant、Status、SlowOn、StockQty、StockValue |
| `ext.Contract` | K17 合約 | ContractNo、Vendor、PoNumber、SignedOn、ValidFrom、ValidTo |

### K02 工商登記關聯供應商（SAP 內部版）
- **邏輯**：不同供應商代碼但統編、電話（去符號）、地址（去空白標點）、銀行帳號（國家-銀行代碼-帳號，帳號去空白和 -，至少 6 個數字）相同（`MatchAttribute`），或 `ext.VendorRelation` 列為關聯；同一個值超過 `MaxGroupSize` 家共用的不配對。商工登記同一對的多種關係併成一筆（MatchType = 商工登記）。填充值不算相同：統編至少 4 個數字、電話至少 6 個數字，整串同一個字（0000000000）或 NANANA 這種不配對。標記：①其中一家基準日當時凍結（中央凍結，或每個組織都凍結；`ExcludeAccountGroup` 除外；基準日之後才改的凍結用異動紀錄還原）、另一家期間內有 PO；②兩家期間內買過同料號。
- **參數**：`MaxGroupSize` = 5。
- **已知限制**：銀行帳號直接讀 `dbo.LFBK`（`kri.vVendorBank`，見 D1），是現在的資料，回補時之後才新增、刪除的帳號沒有還原；兩家共用多個帳號併成一對；「前 50% 家數」的重大性篩選還沒做，目前全部供應商都看。

### K05 Open PO 超過供應商資本額
- **邏輯**：觀察期間（36 個月）內下單、未交貨完成的 PO 未收金額（本幣）合計 ÷ 實收資本額 > `CapitalRatio` → 標記。資本額用供應商代碼對，沒有再用統編對；查不到的（國外廠商）列「無資本額」；幣別不同列「未判斷」。
- **參數**：`CapitalRatio` = 1。
- **已知限制**：未收數量是基準日當時的（`kri.PoReceivedAt`）；關聯企業合併計算等 K02 的關聯確定後再做。

### K06 用量 vs 請購量 vs 庫存
- **邏輯**：請購當天（庫存 + 在途 PO）÷ 過去 `UsageMonths` 個月平均月耗用 = 覆蓋月數，> `MaxCoverageMonths` 仍請購 → 標記；沒有耗用、但有庫存或在途的（`FlagNoUsage` = 1）也標記。在途 = 請購當天以前下單、扣掉當天以前收貨的數量（收貨用比例換成 PO 單位，再用收貨量 ÷ PO 已收數量換回基本單位；沒收過貨當單位相同）；不含這張 PR 自己轉的 PO、已結案（交貨完成且最後收貨在請購日以前）的 PO。耗用 = `ConsumptionMovementType`（201、221、261、281 和沖回）。
- **參數**：`MaxCoverageMonths` = 6、`UsageMonths` = 12、`FlagNoUsage` = 1。
- **已知限制**：PR、收貨、異動的單位假設都是基本單位；原物料和零件的請購邏輯不同，門檻之後可以分開。

### K07 本期 vs 預期請購量
- **邏輯**：料號 × 工廠 × 月的請購量，和預期量比：有 `ext.ExpectedDemand` 用它；沒有用過去 12 個月「有請購的月份」的平均（零星採購不會被 0 稀釋），有請購的月份少於 `MinHistoryMonths` 不判斷。比例 > `Multiplier` → 標記。
- **參數**：`Multiplier` = 3、`MinHistoryMonths` = 3。
- **已知限制**：客戶原本設計是 5 年回歸；資料只有 3 年，先用倍數。

### K11 非緊急之緊急採購
- **邏輯**：緊急採購 = PO 類型在 `EmergencyPoType`，或收貨說明符合 `EmergencyTextPattern`（兩個都只在本地設定）。下單前一天工廠庫存 > `MinStockQty`、或 MOU > `MaxMou`、或待用量 ≥ `MinWaitingForUse` → 標記。
- **參數**：`MinStockQty` = 0、`MaxMou` = 3、`MinWaitingForUse` = 2。
- **已知限制**：PO 項目說明（TXZ01）還沒有，先比對收貨說明。

### K15 已屆呆滯之警示 ／ K16 呆滯料仍進行採購
- **共用**：`kri.SlowStatusAt`：優先用呆滯報表（指定日以前最新一份快照的認列日 SlowOn）；沒有報表而且 `UseSapFallback` = 1 時，用最後一次領用日 + `SlowDays` 推估（領用 = `ConsumptionMovementType` 名單裡、從庫存扣出的異動；收貨、移倉、沖回不算，否則一直收貨的料永遠不會呆滯；沒領用過用第一次異動日）。
- **K15**：基準日有庫存（推估時用 `kri.StockAt` 回推）、還沒認列、`WarnDays` 天內會認列 → 標記。影響金額 = 庫存金額（推估時按基準日數量比例換算）。
- **K16**：下單前一天已呆滯（認列日 ≤ 下單日，或狀態在 `SlowStatus`）、而且有庫存（推估時）仍下 PO；同料號 × 工廠最近 3 個月有 `MinConsecMonths` 個月以上這樣下單 → 標記。
- **參數**：K15 `WarnDays` = 14、`SlowDays` = 365、`UseSapFallback` = 1；K16 `MinConsecMonths` = 1、`SlowDays` = 365、`UseSapFallback` = 1。
- **已知限制**：建議直接用會計認列的呆滯報表，推估版只是先看得到東西；`kri.StockAt` 逐筆回推，料號異動量很大時要注意效能（之後可改成先彙總每日淨異動）。

### K17 重大工程未簽合約
- **邏輯**：工程類 PO（`ConstructionPoType`、`ConstructionMaterialGroup`、`ConstructionGlPattern` 任一，只在本地設定），整張 PO 本幣金額 ≥ `MajorAmount`（本幣在 `AmountCurrency`），PO 沒有參照 SAP 合約、`ext.Contract` 也對不到 → 「無合約」；合約簽約日晚於 PO → 「合約晚於PO」，都標記。合約先用 PO 號碼對，沒有再用供應商 + 有效期間對。
- **參數**：`MajorAmount` = 10,000,000、`AmountCurrency` = TWD。
- **已知限制**：PO 的科目指派類別（KNTTP）不在規格內，工程類先用 PO 類型、物料群組、科目判斷。

### K20 驗退後未及時處理
- **邏輯**：轉入待退倉（`ReturnStorLoc`，本地設定）的異動（`ReturnTransferType` = 311，借方），依先進先出配對同料號 × 工廠 × 倉 × 批號之後的出倉（貸方，任何異動類型），全部出清的日期 = 處理日；停留 > `MaxOpenDays` 天（未處理的算到基準日）→ 標記。
- **參數**：`MaxOpenDays` = 30。
- **已知限制**：待退倉在資料起始日以前的餘額當 0；「單一站點超過一週」要等外部的驗退流程狀態；沒有批號管理的料號配對會不準。

## 9e. 通用料號（GenericMaterial）

有些料號底下其實是很多種不同的東西（雜項、費用類料號，PO 說明才看得出買什麼）：同一個料號單價可以差上千倍，
數量也是不同東西加總。拿它們比價、比量，標出來的幾乎都是誤報。

- **設定**：`kri.ValueList`（`KriCode` = `*`、`ListName` = `GenericMaterial`），料號只在本地設定、不放 repo；數字料號可以不補零。
- **找候選**：`EXEC kri.SuggestGenericMaterial @From, @To` 列出期間內同幣別、同單位下供應商 ≥ `@MinVendors`（5）
  而且最高價 ÷ 最低價 ≥ `@MinSpread`（20）的料號，確認後自己加進清單。
- **排除的題目**：比價、比量的 K06、K07、K12、K13、K14（`kri.PoBase` 多一欄 `IsGeneric`；PR 類用 `kri.IsGeneric`）。
- **不排除的題目**：流程類照常看，例如拆單（K08、K09）、付款條件（K04）、先收後補（K10、K19）——
  雜項採購反而最容易出現這些問題。
- 要讓某一題也看通用料號，把清單的 `KriCode` 改成個別題目即可（`*` 是全部比價、比量題）。

---

## 10. 資料缺口與待辦

| 缺口 | 影響 | 負責 | 狀態 |
|---|---|---|---|
| 匯率表 TCURR | 跨幣別比價、台幣影響金額（K05、K10、K12、K13、K14、K17） | 請客戶下載 | 待提供 |
| 核決權限表 | K08、K09 | 請客戶提供 | 待提供 |
| 級距價格 KONM | K14 精準度 | 請客戶下載 | 待評估 |
| `EKKO.AEDAT`、`EKPO.TXZ01`、FirstGrDate | K10/K19 | 規格 + ETL | 第二期 |
| `EBAN.ESTKZ`、`EBAN.PEINH` | K08 精準度 | 規格 + ETL | 待補 |
| MBEWH 歷史庫存 | K06 | 規格 + ETL | 第三期 |
| `MSEG.UMLGO` | K20 | 重抓 MSEG | 第三期 |
| `EKPO.PSTYP`、`RETPO`、`UMREZ`、`UMREN` | K14 母體和換算、K12／K13 排除庫存轉移、所有 PO 題目排除退貨 | 重抓 EKPO 勾選這幾欄後重跑 10（`kri.vPoItemSap`） | 待重抓 |
| 匯率換算因子 TCURF | 所有本幣金額（影響金額、金額門檻） | 匯入 `dbo.TCURF` 後重跑 10；或在本地 `kri.CurrencyFactor` 填 | 待匯入 |
| CDPOS 的 ZTERM、LFBK 異動 | K04 下單當時的主檔條件 | 重抓 CDPOS（ETL 已會收） | 待重抓 |
| T052 付款條件 | K04 | 請客戶下載 | 待 K04 是否執行 |
| `BSEG.SHKZG`、`KOART`、`BSCHL` | AP 借貸方向（K09） | 重抓 BSEG | 待重抓 |

---

## 11. 未決事項

| # | 事項 | 誰決定 |
|---|---|---|
| Q1 | K04 付款條件：客戶稽核單位曾回覆「不執行」，後續版本又列入選，要不要做 | 客戶 + 顧問 |
| Q2 | 所有暫定門檻的正式值 | 客戶 + 顧問 |
| Q3 | K08 的「部門」用成本中心還是請購人 | 客戶 |
| Q4 | 台灣廠商統一編號存在哪個 LFA1 欄位（K02、K05） | 客戶 SAP 團隊 |
| Q5 | 條件類型 ZPB0 的意義，比價時要不要納入 | 客戶 SAP 團隊 |

---

## 12. 驗收與測試

- 每個 KRI 都要有 LocalDB 自動測試（同 `etl/test_etl.py`）。測試資料要刻意放入**會觸發**和**不該觸發**的案例，至少包括：
  - 邊界值（剛好等於門檻）
  - 未比對的情況（無主檔價、幣別不同、單位不同）不能消失
  - 參數改了，結果要跟著變
  - 一題 KRI 失敗不影響其他題
- 第一期上線前，用客戶實際資料跑一次，抽樣 10 筆標記人工核對。

---

## 13. 變更紀錄

| 日期 | 版本 | 內容 |
|---|---|---|
| 2026-10-19 | v1.0 | 初版：框架決策 D1～D12、分期、第一期 KRI 規格 |
| 2026-10-19 | v1.1 | `kri.Exclusion` 改為 `kri.ValueList`，同時放排除名單與白名單；K08 影響金額以 PR 幣別計（PR 沒有匯率） |
| 2026-10-19 | v1.2 | 第一期實作完成：框架 + K08、K13、K14、K18，LocalDB 測試 37 項通過 |
| 2026-11-18 | v1.3 | 第二批：K01、K03、K04、K10、K19（第 9b 節）；新增 `ext.QualityIssue`、`kri.PaymentTerm`；LocalDB 測試 63 項通過 |
| 2026-11-19 | v1.4 | 一題一個檔（`etl/sql/kri_procs/`），檔頭用白話寫規則（D13）；回補基準日只用當時已知的資料（D12：K05、K06、K18 已收數量，K14 主檔價建立日，K04 下單當時的主檔付款條件）；K02 加銀行帳號；K08、K09 單筆低於核決表最低區間當第 0 層；LocalDB 測試 117 項通過 |
| 2026-11-23 | v1.5 | 本機驗證後的修正：本幣換算套 SAP 換算因子（TCURF）；RunAll 記錄錯誤細節、防重複執行、清掉中斷的執行；儀表板依基準日取最新結果、保留次數每題分開算（D4）；每題的執行頻率（D15）；Power BI 用的 view（D16）；風險分數（D9）；Python 題目的介面設計（D11）；參考過往專案：排除退貨和庫存轉移項目、K14 依項目類別挑資訊記錄類別、單位換算 |
