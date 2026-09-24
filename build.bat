@echo off
REM 打包成免安裝的資料夾版本，輸出在 dist\excel-to-db\
REM
REM 刻意不用 --onefile：--onefile 每次執行都要把 86MB 解壓到 temp，
REM 實測冷啟動 45 秒、熱啟動 31 秒。onedir 熱啟動只要 2 秒。
REM
REM 注意：ODBC Driver 17 for SQL Server 是 Windows 系統元件，
REM 不會被打包進去，目標機器必須自行安裝。
REM
REM 開發機如果也裝了 requirements-api.txt，PyInstaller 會把 pyarrow、
REM lxml、cryptography、psycopg2 那些一起拖進來——光 pyarrow 就 81MB，
REM 整包從 86MB 漲到 193MB。這支程式一個都沒用到（XML 走標準庫的
REM ElementTree，資料庫走 pyodbc），排除掉。
REM
REM --add-data "docs;docs"：整個資料夾一起包，不要在這裡寫中文檔名。
REM cmd.exe 用 OEM codepage（cp950）讀 .bat，UTF-8 的中文路徑會解錯。
REM
REM --hidden-import xlrd：pandas 讀舊版 .xls 時才會 import xlrd，
REM 程式碼裡沒有一行 import 它，PyInstaller 掃不到。少了它打包版
REM 讀 .xls 會噴 Missing optional dependency，開發機上卻正常。

python -m PyInstaller --onedir --clean --noconsole -n excel-to-db ^
  --exclude-module matplotlib ^
  --exclude-module IPython ^
  --exclude-module pytest ^
  --exclude-module scipy ^
  --exclude-module PIL ^
  --exclude-module notebook ^
  --exclude-module pyarrow ^
  --exclude-module lxml ^
  --exclude-module cryptography ^
  --exclude-module psycopg2 ^
  --exclude-module pymysql ^
  --exclude-module selenium ^
  --exclude-module fastapi ^
  --exclude-module uvicorn ^
  --exclude-module bs4 ^
  --hidden-import xlrd ^
  --add-data "config.example.json;." ^
  --add-data ".env.example;." ^
  --add-data "sniff.py;." ^
  --add-data "docs;docs" ^
  app.pyw

echo.
echo 完成。把整個 dist\excel-to-db 資料夾壓縮後帶到目標機器，
echo 解壓縮後執行 excel-to-db.exe 即可，不需要安裝 Python。
echo 交接給非技術同事時，請一併提醒他們看 docs\使用說明.md。
pause
