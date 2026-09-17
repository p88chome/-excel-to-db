@echo off
REM 在「目標機器」執行，完全不需要網路，不會碰到 proxy 407。
REM 前提：wheels\ 資料夾已經帶過來，且版本與這台的 Python 相符。

if not exist wheels (
  echo 找不到 wheels 資料夾。
  echo 請在有網路的開發機執行 fetch_wheels.bat 取得後一併帶過來。
  pause
  exit /b 1
)

python -m pip install --no-index --find-links=wheels -r requirements.txt
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
