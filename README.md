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

```
pip install -r requirements.txt
copy config.example.json config.json
```

然後編輯 `config.json` 的 `conn`，把 `SERVER` 和 `DB` 換成實際的。

`config.json` 不進版控（可能含密碼）。

## 前置需求

目標機器必須裝有 **ODBC Driver 17 for SQL Server**。這是 Windows 系統元件，
不會被 pip 或 PyInstaller 打包帶走。檢查（不需要 Python）：

```
reg query "HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers"
```

看不到 `ODBC Driver 17 for SQL Server` 就要先去微軟官網裝。

## 使用

命令列版本：

```
python import_data.py data
```

UI 版本：施工中，見 [docs/design.md](docs/design.md)。

## 狀態

- [x] 命令列匯入（`import_data.py`）
- [ ] `core.py` — 抽出匯入邏輯、加型別推斷
- [ ] `app.pyw` — tkinter 預覽 UI
- [ ] `build.bat` — PyInstaller 打包

設計文件：[docs/design.md](docs/design.md)
