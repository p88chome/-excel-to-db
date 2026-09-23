@echo off
REM 打包成免安裝的資料夾版本，輸出在 dist\excel-to-db\
REM
REM 刻意不用 --onefile：--onefile 每次執行都要把 86MB 解壓到 temp，
REM 實測冷啟動 45 秒、熱啟動 31 秒。onedir 熱啟動只要 2 秒。
REM
REM 注意：ODBC Driver 17 for SQL Server 是 Windows 系統元件，
REM 不會被打包進去，目標機器必須自行安裝。

python -m PyInstaller --onedir --clean --noconsole -n excel-to-db ^
  --exclude-module matplotlib ^
  --exclude-module IPython ^
  --exclude-module pytest ^
  --exclude-module scipy ^
  --exclude-module PIL ^
  --exclude-module notebook ^
  --add-data "config.example.json;." ^
  --add-data ".env.example;." ^
  app.pyw

echo.
echo 完成。把整個 dist\excel-to-db 資料夾壓縮後帶到目標機器，
echo 解壓縮後執行 excel-to-db.exe 即可，不需要安裝 Python。
pause
