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
```

在 LocalDB 建一個暫存資料庫，塞進多筆分攤、沖銷、PR 拆多張 PO、分割評價、
A017/A018 多個 KOPOS 這類資料，驗證結果後刪掉資料庫。
