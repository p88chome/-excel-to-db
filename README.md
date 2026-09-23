# excel-to-db

把一個資料夾底下的 Excel/CSV/SAP txt 匯入 SQL Server，匯入前可預覽資料與欄位型別。

## 資料夾怎麼擺

```
data/
  customers/          -> 匯入成 table customers（夾內檔案合併）
    cust_2024.xlsx
    cust_2025.csv
  orders.csv          -> 匯入成 table orders
  ZMM001.txt          -> 匯入成 table ZMM001（SAP 匯出的 txt）
```

子資料夾 = 一張表（夾內所有檔案合併），散檔 = 一張表（表名為檔名）。
同一張表裡 `.xlsx` 與 `.txt` 可以混放，只要欄名一致就會合併。

支援的副檔名：`.xlsx` `.xls` `.csv` `.txt`。

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

```
copy .env.example .env
```

用記事本開 `.env`，填 `SQL_SERVER` 與 `SQL_DATABASE` 就好。
`.env` 與 `config.json` 都不進版控，密碼不會被推上 GitHub。
細節見下方「連線字串填在哪」。

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
2. 上方列出每張表的檔數、列數、狀態。欄位不一致的表會標**紅**並略過；
   有待確認欄位的表標**橘**，狀態寫「可匯入（n 欄待確認）」
3. 點一張表 → 下方顯示欄位、推斷型別、範例值。待確認的欄位標橘並附說明
4. 點一個欄位 → 用下拉選單改型別，改動會存進 `config.json`，下次自動套用
5. 選 replace 或 append → 按「開始匯入」

「待確認」= 欄名不在 SAP 代碼欄位清單、又被推斷成整數。是代碼就把型別
改成 `NVARCHAR`，是真的數字就不用管。

命令列版本（沒有預覽，其餘功能相同，適合排程執行）：

```
python import_data.py              # 用 config.json 裡的資料夾與模式
python import_data.py data         # 指定資料夾
python import_data.py data append  # 指定資料夾與寫入模式
python import_data.py data --check # 只檢查不寫入，也不連資料庫
```

`--check` 列出每張表的欄位型別與可疑欄位，是 Excel 的探路工具——
`sniff.py` 只看得懂 txt：

```
ZTM80（1 個檔案，2 列）
  MANDT                NVARCHAR(20)
  EKORG                NVARCHAR(20)
  EBELN                NVARCHAR(20)
  ZZDOCNO              BIGINT
  NETWR                DECIMAL(18,2)
  注意：ZZDOCNO 被推斷成整數，但欄名不在 SAP 代碼欄位清單。
```

兩個版本共用 `config.json`，連線字串與型別覆寫只需設定一次。
有任何一張表失敗時，命令列版會回傳 exit code 1，方便排程判斷成敗。

## SAP 匯出的 txt

SAP 的 txt 不是乾淨的 CSV，檔頭有報表標題、檔尾有統計列、負號掛在數字後面。
這些都會自動處理，不必先用 Excel 洗過一輪：

| SAP 吐出來 | 匯入後 |
|---|---|
| 檔頭 `Dynamic List Display` 與空行 | 跳過，往下找真正的欄名列 |
| 檔尾 `* 123 筆記錄` | 欄數對不上，自動丟掉 |
| ALV 的 `\|----\|` 框線與分頁重印的標題 | 丟掉 |
| `1.234,56-` | `-1234.56`（尾綴負號、德式小數點） |
| `31.12.2026` | `2026-12-31` |
| `00000000`、`#`、`n/a` | `NULL` |
| `000000000010001234` | 保持文字，不轉數字（前導零是料號的一部分） |
| `BUKRS` `BELNR` `GJAHR` 等 SAP 代碼欄位 | 一律文字，見下方 |
| UTF-8 BOM / UTF-16 / ANSI | 看 BOM 自動判斷編碼 |

千分位與小數點是整欄一起判斷的：欄裡只要有一個 `1.234,56`
就知道逗號是小數點。整欄都長得像 `1.234` 時無從判斷，一律當千分位（= 1234）。

### SAP 代碼欄位一律當文字

`BELNR` 1449008934、`BUKRS` 8104、`GJAHR` 2026 —— 這些在 SAP 裡是 CHAR，
只是長得像數字。當成數字會出兩種事：前導零掉了（`0000001000` 變 `1000`）跟主檔
JOIN 不到；還有同一欄位這個月的檔案沒有前導零、下個月有，`replace` 模式
每次重建表，欄位型別就在 INT 與 NVARCHAR 之間跳，下游跟著爛。

所以 `core.py` 帶一張 SAP 標準代碼欄位清單（`SAP_CODE_FIELDS`），
**只看欄名、不看值**，命中就當文字。**Excel、CSV、txt 都套用**——
不然同一個 `BELNR` 在 txt 是文字、在 Excel 被 pandas 讀成 int64，
兩張表就 JOIN 不起來。

因為只看欄名，自訂表（ZTM 開頭那種）只要欄名是標準的
（`MANDT` `EKORG` `IHREZ` `EBELN`…）一樣認得出來，不必另外設定。

Excel 有個救不回來的情況：儲存格本來就存成數字時，前導零在 SAP
匯出那一刻就沒了。這裡能保證的是**型別每次都一致**。目前 576 個欄名，逐一比對過這 32 張表：

```
A017  ANLA  BKPF  BSEG  CDHDR CDPOS T001  EBAN  EBKN  EINA  EINE
EKBE  EKET  EKKN  EKKO  EKPO  KONH  KONP  LFA1  LFB1  LFBK  LFM1
MAKT  MARA  MARC  MARD  MBEW  MBEWH MKPF  MSEG  T001W T001K
```

漏 0、誤判 0，而且鎖進 `test_sap.py` —— 之後改清單，退步會被測試擋下來。

清單認不出來的兩種情況：

- **Z 開頭的自訂欄位** —— 標準清單不可能有
- **用中文或英文說明當欄名的報表**（欄名是「憑證編號」而不是 `BELNR`）

這兩種走原本的猜值邏輯；真的猜錯就用 `dtypes` 釘死。反過來要把清單裡的
某一欄當數字，也是用 `dtypes` 指定 `INT` 或 `DECIMAL`：

```json
{ "dtypes": { "BESG": { "AUGBL": "BIGINT" } } }
```

要加新欄名，改 `core.py` 的 `SAP_CODE_FIELDS`。`sniff.py` 直接引用同一份，
不會有兩邊不同步的問題。

### 清單沒蓋到的，會跳警示

自訂欄名不可能列進清單，所以改成**事後提醒**：欄名不在清單、又被推斷成
整數的欄位會被標出來 —— 那正是「代碼被當數字」的唯一危險長相。

```
ZFI001：406,537 列 <- 1 個檔案
  注意：DOCTYPE 被推斷成整數，但欄名不在 SAP 代碼欄位清單。
  如果是代碼欄位，請在 config.json 的 dtypes 改成 NVARCHAR，否則前導零會掉、JOIN 不到來源表。
```

`sniff.py` 用 `N!` 標同一件事。不會誤報的情況：

| 欄位 | 為什麼不報 |
|---|---|
| 金額 `1.234,56` | 有小數，判斷有憑有據 |
| 日期 `31.12.2026` | 有格式 |
| `MENGE` `LFIMG` `ZBD1T` 等 | 在 `SAP_NUMERIC_FIELDS` 已知數字清單裡 |
| `BUKRS` `BELNR` 等 | 已經是文字了 |

所以看到 `N!` 就只有兩種可能：真的是代碼（用 `dtypes` 改成 NVARCHAR），
或是清單漏掉的數字欄位（加進 `SAP_NUMERIC_FIELDS`）。

### 先探一下格式

灌之前建議先跑 `sniff.py` 確認解析對不對。它只用標準函式庫，
沒裝 pandas 也能跑，也不會連資料庫或動到任何檔案：

```
python sniff.py D:\SAP\ZMM001.txt      單一檔案
python sniff.py D:\SAP                  整個資料夾的 txt
python sniff.py D:\SAP > sniff.txt      存成檔案方便貼給別人看
python sniff.py D:\SAP --short          每個檔壓成兩行
```

會印出編碼、分隔符、欄名在第幾行、每欄推斷的型別與前 3 筆值，
以及一段可以直接貼進 `config.json` 的設定。

機器之間沒連通、輸出只能用手抄時用 `--short`，一個檔兩行：

```
BESG | utf-8-sig | TAB | 20col | skip3 | 406537row
COL1:_ BUZEI:T! LIFNR:T! ZUONR:T! SGTXT:T HKONT:T! WRBTR:N- ZFBDT:D:slash?
```

代碼：`T` 文字、`T0` 文字有前導零、`T!` SAP 代碼欄位（強制文字）、
`N` 數字、`N-` 有尾綴負號、
`N?` 千分位待確認、`D:iso`／`D:dot`／`D:8` 日期格式、
`D:slash?` 日月順序待確認、`_` 整欄空白。
帶 `?` 的就是程式猜不準、需要人決定的欄位。

### 自動偵測猜錯時

在 `config.json` 的 `txt` 區用表名指定，三個欄位都可以省略：

```json
{
  "txt": {
    "ZMM001": { "encoding": "utf-8-sig", "sep": "	", "skiprows": 0 }
  }
}
```

- `encoding` — `utf-8-sig`／`utf-16`／`cp950`
- `sep` — `"	"`、`";"`、`","`、`"|"`
- `skiprows` — 最前面要先砍掉幾行（欄名被認成資料時才需要）

欄位型別另外用 `dtypes` 覆寫，例如逼料號留成文字：
`"dtypes": { "ZMM001": { "MATNR": "NVARCHAR(50)" } }`

固定寬度（沒有分隔符）的格式目前不支援，會直接報錯而不是亂切。

## 連線字串填在哪

擇一即可，`.env` 最適合遠端機器：

- **`.env`**：複製 `.env.example` 成 `.env`，填 `SQL_SERVER` 與 `SQL_DATABASE`
- **UI**：「連線設定…」按鈕，存好後寫進 `config.json`
- **手動**：複製 `config.example.json` 成 `config.json`，改 `conn` 那行

`.env` 的優先序最高，填了就會蓋掉 `config.json` 的 `conn`。
`.env` 放在程式旁邊即可，exe 版也讀得到。

```
SQL_SERVER=SQLPRD01,1433
SQL_DATABASE=UMC
SQL_USER=            留空 = 用 Windows 整合驗證
SQL_PASSWORD=
```

密碼裡的 `@` `:` `/` 不用跳脫，程式會自己編碼。
整條字串要自己寫死時用 `SQL_CONN=`，會蓋掉其他所有設定。

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
- [x] `sniff.py` — SAP txt 格式診斷，零相依單檔
- [x] `test_sap.py` — SAP txt 解析與 .env 的測試（`python -m pytest`）

實測：406,537 列、55.7 MB 的 txt，掃描 10 秒、匯入 30 秒。

設計文件：[docs/design.md](docs/design.md)
