# 採購風險儀表板 ETL

SAP 原表（excel-to-db 匯進 `dbo`）→ 規格表 v2.3 定義的 12 張業務表（`prc` / `mst` / `inv` / `fin`）。

## 在 SSMS 執行

依序開檔、按 F5：

| 檔案 | 做什麼 | 什麼時候跑 |
|---|---|---|
| `sql/00_check_staging.sql` | 列出 stg 表缺的表或欄位，結果空白就是齊了 | 每次重新下載 SAP 資料後 |
| `sql/01_create_tables.sql` | 建 schema 和 12 張目標表 | 第一次，或規格改了之後。**會 DROP 重建** |
| `sql/02_load_procedures.sql` | 建 `etl.Load_*` 載入程序與 `etl.LoadAll` | 第一次，或程序改了之後 |

`00` 列出缺的欄位、但還沒辦法回 SAP 重新下載時：把 `00` 裡的 `@fill` 改成 1 再跑一次，
缺的欄位會補成空欄，`02` 就建得起來，那幾欄先是 NULL。重新匯入後 stg 表會整張重建，補的空欄自然消失。

之後每次要更新資料：

```sql
EXEC etl.LoadAll;                 -- 全部，最後列出每張表的筆數與結果
EXEC etl.Load_PurchaseOrderDetail; -- 只跑一張
```

`LoadAll` 一張失敗不影響其他張；失敗的那張會回滾，保留上一次的資料。

結果不對、又沒辦法把畫面複製出來的時候，跑 `sql/90_diagnose.sql`：
輸出三行「代號=數字」（各表筆數、空白主鍵、重複鍵），代號說明在檔案開頭，只有數字不含資料內容。

要盤點資料庫裡每張表的欄位結構（給 user 看、或對照規格的「是否有資料」）時，跑 `sql/91_column_inventory.sql`：
列出每張表的筆數、每個欄位的型別；`@fill = 1` 再加上每個欄位有值的筆數與比例。

要直接存成 Excel：在專案根目錄跑 `python column_inventory.py`，輸出 Schema、表、欄位、型別、可為NULL
（全部 schema，SAP 原表與目標表都在）。連線讀 `config.json` / `.env`，跟匯入工具同一個資料庫。
`--schemas dbo,prc` 只盤點指定的 schema；第一個參數可以指定輸出檔名。

## KRI

設計與每題規格見 [`docs/KRI_PRD.md`](../docs/KRI_PRD.md)。ETL 跑完之後：

| 檔案 | 做什麼 | 什麼時候跑 |
|---|---|---|
| `sql/10_kri_framework.sql` | 建 `kri` schema：設定表、執行紀錄、`kri.Flag`、`kri.RunAll` | 第一次，或框架改了之後（不會清掉已調的設定） |
| `sql/11_kri_procedures.sql` | 建各題 KRI 的明細表與程序 | 第一次，或 KRI 改了之後 |
| `sql/12_kri_seed.sql` | 補上預設定義、暫定門檻、白名單（只補沒有的） | 第一次，或新增 KRI 之後 |

```sql
EXEC kri.RunAll;                            -- 跑全部啟用的 KRI，基準日今天
EXEC kri.RunAll @AsOfDate = '2025-12-31';   -- 指定基準日
EXEC kri.RunAll @Only = N'K14';              -- 只跑某幾題
SELECT * FROM kri.vFlagLatest;              -- 每題最新一次成功的標記（儀表板接這個）
```

- **調門檻：** `UPDATE kri.Parameter SET ParamValue = 0.1, IsTentative = 0 WHERE KriCode = 'K14' AND ParamName = 'PriceTolerance';`
- **加排除名單：** `INSERT kri.ValueList (KriCode, ListName, ListValue, Note) VALUES ('*', 'ExcludeVendorPrefix', 'X', N'一次性供應商');`
- **K08 要先填核決權限：** `kri.ApprovalMatrix`，沒有資料時 K08 不會標記，`RunAll` 的說明欄會提示。

## 抽樣到 exp

`sql/20_sample_exp.sql` 建 `exp.SampleAll`：把業務表與 SAP 原表各抽一小份到 `exp`，
表名不變（`prc.PurchaseOrderDetail` → `exp.PurchaseOrderDetail`、`dbo.EKKO` → `exp.EKKO`）。

```sql
EXEC exp.SampleAll;                          -- 每張業務表 1000 筆
EXEC exp.SampleAll @Rows = 500, @Seed = 42;  -- 同一個 seed 抽同一批
EXEC exp.SampleAll @PreferFilled = 0;        -- 不挑空欄位少的，純隨機
EXEC exp.SampleAll @CapRaw = 1;              -- 一對多的原表也砍到 1000 筆（明細會不完整）
EXEC exp.SampleAll @RecentFirst = 0;         -- 交易類不挑最近的
```

1. **業務表各 `@Rows` 筆**：PO 明細隨機抽，其他業務表先帶跟這批 PO 有關的，再調到 `@Rows` 筆（超過隨機留、不足隨機補）。
2. **SAP 原表從業務表回推**：一對一的（EKPO、EBAN、MSEG、LFA1、MARA、A017…）不會超過 `@Rows` 筆；
   一對多的（EKKN、EKET、EKBE、EBKN、BSEG、MAKT、MBEW、KONP）照實際帶，`@CapRaw = 1` 才砍。
3. **沒組進業務表的表各 `@Rows` 筆**：LFBK、MBEWH、ANLA 先帶有關聯的再調；ZTM、ADT 直接隨機；T 開頭的設定表整張。

挑資料的順序：**重要欄位**空值少的（`exp.ImportantColumn`，預設是原表裡 ETL 用到的欄位）→ 交易類**日期新的**
（`exp.DateColumn`，`@RecentFirst = 0` 關掉）→ 全部欄位空值少的 → seed 隨機。業務表預設沒有重要欄位，所以是日期新的優先。
最近的優先時，交易類的結果主要由日期決定，換 seed 只會換掉同一天裡的那幾筆；要換 seed 就換一批，給 `@RecentFirst = 0`。
結果最後一欄是這次用的 seed。每次執行會重建 exp 裡的表。**exp 裡仍是客戶真實資料，不要帶出客戶環境。**

## 規格改了

```
python etl/gen_ddl.py 規格.xlsx > etl/sql/01_create_tables.sql
```

DDL 從規格表產生（刪除線的列不建；規格上的 VARCHAR 一律建成 NVARCHAR）。載入邏輯在 `02_load_procedures.sql` 手寫，
欄位有增減要跟著改，`00_check_staging.sql` 的清單也是。

## 測試

```
python etl/test_etl.py      # ETL
python etl/test_kri.py      # KRI
python etl/test_sample.py   # 抽樣
```

在 LocalDB 建一個暫存資料庫，塞進多筆分攤、沖銷、PR 拆多張 PO、分割評價、
A017/A018 多個 KOPOS 這類資料，驗證結果後刪掉資料庫。
