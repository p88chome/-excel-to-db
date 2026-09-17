"""檢查這台機器的 Python 環境，判斷要用哪種部署方式。

只用標準函式庫，全新的 Python 也跑得動。
把完整輸出複製回來即可。

    python check_env.py
"""
import platform
import subprocess
import sys
from pathlib import Path

try:
    from importlib.metadata import distributions
except ImportError:
    distributions = None

NEEDED = ["pandas", "sqlalchemy", "pyodbc", "openpyxl"]


def line(title):
    print(f"\n--- {title} " + "-" * max(0, 58 - len(title)))


def run(*cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return (out.stdout + out.stderr).strip()
    except Exception as e:
        return f"(無法執行：{e})"


line("這個 Python")
print("版本    ", sys.version.split()[0], platform.architecture()[0])
print("位置    ", sys.executable)
print("架構    ", platform.machine())
print("系統    ", platform.platform())

line("pip 屬於哪個 Python")
# pip 和 python 指向不同安裝，是「裝了卻找不到」最常見的原因。
print("python -m pip:", run(sys.executable, "-m", "pip", "--version") or "(沒有 pip)")
print("PATH 上的 pip:", run("pip", "--version") or "(PATH 上沒有 pip)")
print("PATH 上的 python:", run("where", "python") or "(不在 PATH 上)")

line("這台裝了哪些 Python")
print(run("py", "-0p") or "(py launcher 不存在)")

line("import 會去哪裡找（sys.path）")
for p in sys.path:
    tag = "" if not p or Path(p).exists() else "   <- 不存在"
    print("  ", p or "(目前目錄)", tag)

line("已安裝的套件（直接讀 metadata，不經過 pip）")
if distributions is None:
    print("  Python 太舊，無法檢查")
else:
    found = sorted({d.metadata["Name"]: d.version for d in distributions()}.items())
    print(f"  共 {len(found)} 個")
    for name, version in found:
        print(f"   {name} {version}")

line("這個專案需要的套件")
for name in NEEDED:
    try:
        mod = __import__(name)
        print(f"  [有] {name:12} {getattr(mod, '__version__', '?'):10} {getattr(mod, '__file__', '')}")
    except ImportError as e:
        print(f"  [缺] {name:12} {e}")

line("ODBC 驅動程式（不需要 pyodbc）")
try:
    import winreg
    key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                         r"SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers")
    drivers = []
    for i in range(winreg.QueryInfoKey(key)[1]):
        drivers.append(winreg.EnumValue(key, i)[0])
    sql = [d for d in drivers if "SQL Server" in d]
    print("  " + ("\n  ".join(sql) if sql else "找不到任何 SQL Server 驅動程式"))
    if not any("ODBC Driver" in d for d in sql):
        print("\n  ⚠ 缺少 ODBC Driver 17 for SQL Server，連不上資料庫。")
except Exception as e:
    print(f"  (無法讀取登錄檔：{e})")

line("結論")
missing = [n for n in NEEDED if n not in sys.modules]
if missing:
    print("  缺少套件，兩種裝法擇一：")
    print("    1. 有網路： pip install -r requirements.txt")
    print("    2. 沒網路： pip install --no-index --find-links=wheels -r requirements.txt")
    print(f"\n  離線 wheel 必須對應 Python {sys.version_info.major}.{sys.version_info.minor}"
          f" / {platform.machine()}，版本不合會裝不起來。")
else:
    print("  套件齊全，可以直接執行 app.pyw。")
