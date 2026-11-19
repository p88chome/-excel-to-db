@echo off
chcp 65001 >nul
REM 把 load_csv.py（CSV 匯入工具）打包成單一個 exe，輸出在 dist\load_csv\
REM
REM 只用到 pyodbc 和標準庫（SAP 欄名規則在 sapfields.py，不 import core），
REM 所以不會把 pandas、openpyxl 那些帶進去，exe 只有幾 MB，用 --onefile 也啟動得快。
REM
REM ODBC Driver for SQL Server（17 或 18）是 Windows 系統元件，不會被打包進去，目標機器要自己裝。
REM 用 Entra 互動登入（entra-interactive）時，Driver 17 要 17.6 以上；建議裝 18。
REM
REM --hidden-import uuid、locale：pyodbc 是在 C 程式裡 import 它們，PyInstaller 掃不到。
REM 少了 uuid，打包版寫入資料時會出「returned a result with an exception set」甚至直接當掉，
REM 開發機上卻正常。
REM
REM 01_create_tables.sql 打包一份進 exe，另外也複製一份放在 exe 旁邊：
REM 規格改了只要換旁邊那份，不用重新打包（程式優先讀旁邊的）。

python -m PyInstaller --onefile --clean --console -n load_csv ^
  --distpath dist\load_csv ^
  --workpath build\load_csv ^
  --exclude-module pandas ^
  --exclude-module numpy ^
  --exclude-module openpyxl ^
  --exclude-module sqlalchemy ^
  --exclude-module tkinter ^
  --hidden-import uuid ^
  --hidden-import locale ^
  --add-data "etl\sql\01_create_tables.sql;." ^
  load_csv.py
if errorlevel 1 goto :fail

copy /y etl\sql\01_create_tables.sql dist\load_csv\ >nul
copy /y load_csv.env.example dist\load_csv\.env.example >nul
if not exist dist\load_csv\Data mkdir dist\load_csv\Data

echo.
echo 完成：dist\load_csv\
echo   load_csv.exe            點兩下會一步一步問連線；也可以用命令列參數（load_csv.exe --help）
echo   .env.example            連線設定範本，複製成 .env 就不用每次重打
echo   01_create_tables.sql    業務表規格，改了直接換這份
echo   Data\                   CSV 放這裡（或用 --folder 指定）
echo 整個資料夾帶走即可，不需要安裝 Python；目標機器要有 ODBC Driver for SQL Server。
goto :eof

:fail
echo.
echo 打包失敗，看上面的錯誤訊息。
exit /b 1
