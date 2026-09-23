@echo off
REM 在「目標機器」執行，完全不需要網路，不會碰到 proxy 407。
REM 前提：wheels\ 資料夾已經帶過來，且版本與這台的 Python 相符。
REM
REM 用法：install_offline.bat
REM       install_offline.bat requirements-api.txt
REM
REM 省略參數時裝 requirements.txt（excel-to-db 本身）。

if not exist wheels (
  echo 找不到 wheels 資料夾。
  echo 請在有網路的開發機執行 fetch_wheels.bat 取得後一併帶過來。
  pause
  exit /b 1
)

set REQ=%~1
if "%REQ%"=="" set REQ=requirements.txt

echo 安裝 %REQ%...
python -m pip install --no-index --find-links=wheels -r %REQ%
if errorlevel 1 (
  echo.
  echo 安裝失敗。最常見的原因是 wheel 的 Python 版本不符，
  echo 例如 wheel 是 cp312 但這台是 3.13。
  echo 執行 python check_env.py 查看本機版本，回報給開發機重抓。
  pause
  exit /b 1
)

echo.
echo 安裝完成，檢查環境：
python check_env.py
pause
