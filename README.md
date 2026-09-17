# excel-to-db

把一個資料夾底下的 Excel/CSV 檔匯入 SQL Server，匯入前可預覽資料與欄位型別。

## 資料夾怎麼擺

```
data/
  customers/          -> 匯入成 table customers（夾內檔案合併）
    cust_2024.xlsx
    cust_2025.csv
  orders.csv          -> 匯入成 table orders
```

子資料夾 = 一張表（夾內所有檔案合併），散檔 = 一張表（表名為檔名）。

## 安裝

有網路的機器：

```
pip install -r requirements.txt
copy config.example.json config.json
```

### 沒網路 / proxy 擋住的機器

公司的 proxy 需要認證時，`pip install` 會噴 `407 Proxy Authentication Required`。
pip 只支援 basic auth，遇到 NTLM/Kerberos 的 proxy 帳密打對也照樣失敗，
不要跟它耗，直接走離線安裝：

`wheels\` 裡已經放好 Python **3.14**（`cp314`／`win_amd64`）的檔案，約 27 MB。
目標機器是 3.14.2，wheel tag 只認 minor 版本，3.14.x 都適用。直接執行：

```
install_offline.bat
```

換到其他 Python 版本的機器時，在**有網路的開發機**補抓：

```
fetch_wheels.bat 3.12        參數是目標機器的 Python 版本
```

跨版本抓沒問題，在 3.14 的機器上一樣抓得到 `cp312` 的 wheel。

裝完會自動跑 `check_env.py` 驗證。

wheel 綁 Python 版本與架構（`pandas-2.3.3-cp312-cp312-win_amd64.whl`），
版本不合會裝不起來，這時重跑 `fetch_wheels.bat` 換正確的版本號即可。

### 設定連線

編輯 `config.json` 的 `conn`（見下方「連線字串填在哪」）。
`config.json` 不進版控，因為可能含密碼。

## 前置需求

目標機器必須裝有 **ODBC Driver 17 for SQL Server**。這是 Windows 系統元件，
不會被 pip 或 PyInstaller 打包帶走。檢查（不需要 Python）：

```
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers"
```

看不到 `ODBC Driver 17 for SQL Server` 就要先去微軟官網裝。

## 使用

圖形介面（雙擊 `app.pyw`，或）：

```
python app.pyw
```

1. 選資料夾 → 按「掃描」
2. 上方列出每張表的檔數、列數、狀態。欄位不一致的表會標紅並略過
3. 點一張表 → 下方顯示欄位、推斷型別、範例值
4. 點一個欄位 → 用下拉選單改型別，改動會存進 `config.json`，下次自動套用
5. 選 replace 或 append → 按「開始匯入」

命令列版本（沒有預覽，其餘功能相同，適合排程執行）：

```
python import_data.py              # 用 config.json 裡的資料夾與模式
python import_data.py data         # 指定資料夾
python import_data.py data append  # 指定資料夾與寫入模式
```

兩個版本共用 `config.json`，連線字串與型別覆寫只需設定一次。
有任何一張表失敗時，命令列版會回傳 exit code 1，方便排程判斷成敗。

## 連線字串填在哪

擇一即可，UI 最方便：

- **UI**：「連線設定…」按鈕，存好後寫進 `config.json`
- **手動**：複製 `config.example.json` 成 `config.json`，改 `conn` 那行

```json
{ "conn": "mssql+pyodbc://@主機/資料庫?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes" }
```

用帳號密碼登入的話：

```json
{ "conn": "mssql+pyodbc://帳號:密碼@主機/資料庫?driver=ODBC+Driver+17+for+SQL+Server" }
```

`config.json` 已列入 `.gitignore`，不會被推上 GitHub。

## 型別推斷

預設的 `to_sql` 會把所有文字欄位建成 `NVARCHAR(MAX)`，不能建索引也佔空間。
本工具改為實際量測資料後指定：

| 資料 | 推斷結果 |
|---|---|
| 整數（int32 範圍內／超出） | `INT` / `BIGINT` |
| 小數 | `DECIMAL(18, 實際小數位數)`，超過 6 位則用 `FLOAT` |
| 日期／日期時間（含 CSV 裡的字串） | `DATE` / `DATETIME` |
| 布林 | `BIT` |
| 文字 | `NVARCHAR(最大長度 × 2)`，介於 20 與 4000 之間 |

在 UI 改過的型別會寫進 `config.json`。因為 replace 模式每次都會 drop 重建，
直接在 SSMS 改型別會被下次匯入蓋掉 —— 要改請改這裡。

## 打包成免安裝版

目標機器沒有 Python 時，在**開發機**執行：

```
build.bat
```

產出 `dist\excel-to-db\`（約 193 MB）。整個資料夾壓縮後帶去目標機器，
解壓執行 `excel-to-db.exe` 即可。

刻意不用 `--onefile`：實測冷啟動 45 秒（每次都要解壓 86 MB 到 temp），
`--onedir` 熱啟動只要 2 秒。

ODBC Driver 17 仍需另外安裝，打包帶不走。

## 狀態

- [x] `core.py` — 掃描、型別推斷、匯入（不依賴 UI，可用 sqlite 測）
- [x] `app.pyw` — tkinter 預覽 UI
- [x] `build.bat` — PyInstaller 打包，已驗證可啟動
- [x] `import_data.py` — 早期的命令列版本，保留

設計文件：[docs/design.md](docs/design.md)
