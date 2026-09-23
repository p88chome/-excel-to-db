@echo off
REM 在「有網路的開發機」執行，把目標機器要用的套件抓成 wheel 檔。
REM
REM 用法：fetch_wheels.bat 3.12
REM       fetch_wheels.bat 3.14 requirements-api.txt
REM
REM 第一個參數是「目標機器」的 Python 版本，不是這台的。
REM 第二個參數是要抓的 requirements 檔，省略時用 requirements.txt。
REM
REM 跨版本抓是可以的：在 3.14 的機器上一樣抓得到 cp312 的 wheel。

if "%~1"=="" (
  echo 用法: fetch_wheels.bat 目標機器的Python版本
  echo 例如: fetch_wheels.bat 3.12
  echo.
  echo 版本號從目標機器執行 check_env.py 取得。
  exit /b 1
)

set REQ=%~2
if "%REQ%"=="" set REQ=requirements.txt

echo 抓取 %REQ% 的 wheel（目標 Python %1 / win_amd64）...
python -m pip download -r %REQ% -d wheels ^
  --only-binary=:all: --python-version %1 --platform win_amd64

echo.
echo 完成。wheels\ 資料夾連同整個專案帶到目標機器，
echo 在那邊執行 install_offline.bat 即可，不需要網路。
pause
