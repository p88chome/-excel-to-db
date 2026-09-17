# Excel/CSV → SQL Server 匯入工具 設計文件

日期：2026-09-17

## 目標

把一個資料夾底下的 Excel/CSV 檔匯入 SQL Server。支援「一個檔案 = 一張表」，
也支援「多個檔案 = 同一張表」。匯入前要能預覽資料與欄位型別。

## 檔案對應規則

掃描 root 的第一層（不遞迴）：

```
data/
  customers/          -> table customers（夾內所有檔案 concat 成一張表）
    cust_2024.xlsx
    cust_2025.csv
  orders.csv          -> table orders
  stock.xlsx          -> table stock
```

- 子資料夾 → table 名 = 資料夾名，夾內所有 `.csv/.xlsx/.xls` 合併
- 散檔 → table 名 = 檔名去副檔名

不遞迴是刻意的：遞迴會讓「資料夾 = table」這條規則變得沒有唯一解。

## 模組切分

| 檔案 | 職責 | 依賴 |
|---|---|---|
| `core.py` | 掃檔、讀檔、型別推斷、寫入 DB | pandas, sqlalchemy, pyodbc |
| `app.pyw` | tkinter UI | core.py, tkinter |
| `config.json` | 連線字串、型別覆寫、寫入模式 | — |
| `build.bat` | PyInstaller onedir 打包 | — |

`core.py` 不 import tkinter。換 UI 或加 CLI 都不用動它，也讓它能用 sqlite 單獨測試。

## UI

單一視窗，三段：

```
+----------------------------------------------------+
| 資料夾 [C:\data            ] [瀏覽]  [連線設定...]  |
+----------------------------------------------------+
| table      | 檔數 | 列數  | 狀態                   |
| customers  |  2   | 1,204 | OK                     |
| orders     |  1   |   340 | ⚠ 欄位不一致           |
+----------------------------------------------------+
| 預覽: customers        (點上面的列切換)             |
| 欄位      | 推斷型別        | 範例值                |
| id        | [INT        v] | 1, 2, 3               |
| city      | [NVARCHAR(50)v]| taipei, tainan        |
| amount    | [DECIMAL(18,2)v]| 100.5, 88.0          |
+----------------------------------------------------+
| 寫入模式 (o)replace ( )append   [測試連線]  [匯入]  |
+----------------------------------------------------+
```

掃描階段每個檔只讀前 200 列，用來算列數估計、推型別、出預覽。
按下「匯入」才讀全檔。大檔不會卡住 UI。

## 型別推斷

預設 `to_sql` 會把 `object` 欄位建成 `NVARCHAR(MAX)`，不能建索引且佔空間。
本工具改成明確指定：

| 資料 | 推斷型別 |
|---|---|
| 整數，範圍在 int32 內 | `INT` |
| 整數，超出 int32 | `BIGINT` |
| 小數 | `DECIMAL(18,2)` |
| 日期（無時間） | `DATE` |
| 日期時間 | `DATETIME` |
| 布林 | `BIT` |
| 文字 | `NVARCHAR(實測最大長度 × 2，下限 20、上限 4000)` |

UI 下拉可覆寫，存進 `config.json` 的 `dtypes`，下次同名 table 自動套用。
因為 `replace` 模式每次都會 drop 重建，型別必須留在設定檔裡 —— 在 SSMS 手改會被蓋掉。

## 寫入模式

- `replace`（預設）：drop 後重建。重跑結果一致。
- `append`：表不存在就建，存在就接在後面。重跑會產生重複資料。

UI 上以 radio button 切換，選擇存進 `config.json`。

## 錯誤處理

- **每張表獨立成敗**：一張表失敗不影響其他表。失敗的那張在 DB 內回滾。
- **欄位不一致**：同一張表的多個檔案，欄位集合（set）不同即視為不一致 —— 該表標紅、
  不給匯入，其他表照常。欄位順序不同不算不一致，會自動對齊成第一個檔的順序。
- **ODBC driver 缺失**：啟動時檢查 `pyodbc.drivers()`，缺少就直接提示
  「請安裝 ODBC Driver 17 for SQL Server」，而不是等到匯入才丟 stack trace。
- 所有錯誤寫進 `import.log`。

## 測試

`core.py` 用 sqlite 測（`sqlite:///test.db`），不需要真的 MSSQL 連線。
已驗證這個做法可行。

## 部署

目標機環境尚未確認，兩條路都留著。決定點：目標機有沒有 Python、版本為何。

| 方式 | 大小 | 熱啟動 | 目標機需求 |
|---|---|---|---|
| PyInstaller `--onedir` + zip | 192 MB（zip 約 70–80 MB） | 2 秒 | 無 |
| PyInstaller `--onefile` | 86 MB | **31 秒** | 無 |
| 原始碼 + 離線 wheels | 27 MB | 2 秒 | Python 3.14 win_amd64 |

`--onefile` 已排除：每次執行都要解壓 86 MB 到 temp，實測冷啟動 45 秒。

不論哪一種，**ODBC Driver 17 都必須預先安裝在目標機上**，它是 Windows 系統元件，
打包帶不走。檢查指令（不需要 Python）：

```
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers"
```

## 已知限制

- 整張表一次讀進記憶體。單表超過數百 MB 才需要改成分塊。
- 不遞迴掃子資料夾的子資料夾。
- 沒有 upsert。需要依 key 更新的話要另外設計。
