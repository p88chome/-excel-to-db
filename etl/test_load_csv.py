"""測 load_csv.py：連線字串怎麼組、.env 怎麼讀存，再實際匯一份 CSV 到 LocalDB。

    python etl/test_load_csv.py               # 測 load_csv.py
    python etl/test_load_csv.py dist\\load_csv\\load_csv.exe   # 另外測打包好的 exe

只碰 (localdb)\\MSSQLLocalDB 上的 load_csv_scratch，跑完會刪掉。
"""
import os
import subprocess
import sys
import tempfile
from argparse import Namespace
from pathlib import Path

import pyodbc

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import load_csv as L  # noqa: E402

SERVER = r"(localdb)\MSSQLLocalDB"
DB = "load_csv_scratch"
checks = []


def check(name, got, want):
    ok = got == want
    checks.append(ok)
    print(f"{'OK ' if ok else 'NG '} {name}" + ("" if ok else f"\n     得到 {got!r}\n     預期 {want!r}"))


def args(**kw):
    base = dict(server=None, database=None, auth=None, user=None, driver=None, trust_cert=False)
    base.update(kw)
    return Namespace(**base)


def clear_env():
    for k in ("SQL_SERVER", "SQL_DATABASE", "SQL_AUTH", "SQL_USER", "SQL_PASSWORD", "SQL_DRIVER", "SQL_TRUST_CERT"):
        os.environ.pop(k, None)


# ---------------------------------------------------------------- 連線字串
D = "ODBC Driver 18 for SQL Server"
c = L.build_conn({"server": "SQL01,1433", "database": "kri", "auth": "windows", "driver": D})
check("Windows 驗證", c, f"Driver={{{D}}};Server=SQL01,1433;Database=kri;Trusted_Connection=yes;")

c = L.build_conn({"server": "SQL01", "database": "kri", "auth": "sql", "user": "loader", "password": "a;b}c", "driver": D})
check("SQL 驗證：密碼有 ; } 會用 {} 包起來", c,
      f"Driver={{{D}}};Server=SQL01;Database=kri;UID=loader;PWD={{a;b}}}}c}};")
check("遮密碼（含 {} 包起來的）", L.mask(c), f"Driver={{{D}}};Server=SQL01;Database=kri;UID=loader;PWD=***;")

c = L.build_conn({"server": "abc.database.windows.net", "database": "kri", "auth": "entra-interactive",
                  "user": "me@corp.com", "driver": "ODBC Driver 17 for SQL Server"})
check("雲端 Entra 互動登入：不放密碼、一定加密", c,
      "Driver={ODBC Driver 17 for SQL Server};Server=abc.database.windows.net;Database=kri;"
      "Authentication=ActiveDirectoryInteractive;UID=me@corp.com;Encrypt=yes;")
c = L.build_conn({"server": "abc.database.windows.net", "database": "kri", "auth": "entra-msi", "driver": D})
check("受控識別：沒有帳號密碼", c,
      f"Driver={{{D}}};Server=abc.database.windows.net;Database=kri;Authentication=ActiveDirectoryMsi;Encrypt=yes;")
c = L.build_conn({"server": "SQL01", "database": "kri", "auth": "windows", "driver": D, "trust_cert": True})
check("自簽憑證要明講才跳過驗證", c.endswith("TrustServerCertificate=yes;"), True)
check("連線字串讀得出資料庫名稱", L.db_name("Driver={x};Server=s;Database={kri};"), "kri")

# ---------------------------------------------------------------- 設定的優先順序
clear_env()
check("什麼都沒有 → None（要互動詢問）", L.settings_from(args()), None)
os.environ.update(SQL_SERVER="ENV01", SQL_DATABASE="envdb", SQL_USER="envuser", SQL_PASSWORD="pw")
s = L.settings_from(args(server="CLI01"))
check("命令列蓋過 .env；給了帳號預設 sql 驗證", (s["server"], s["database"], s["user"], s["auth"], s["password"]),
      ("CLI01", "envdb", "envuser", "sql", "pw"))
clear_env()
os.environ.update(SQL_SERVER="ENV01")
check("沒帳號預設 Windows 驗證", L.settings_from(args())["auth"], "windows")
os.environ["SQL_AUTH"] = "bogus"
try:
    L.settings_from(args())
    check("不認得的驗證方式要報錯", False, True)
except SystemExit as e:
    check("不認得的驗證方式要報錯", "bogus" in str(e), True)
clear_env()

with tempfile.TemporaryDirectory() as t:
    env = Path(t) / ".env"
    L.save_env({"server": "abc.database.windows.net", "database": "kri", "auth": "sql", "user": "loader",
                "password": "secret", "driver": None, "trust_cert": False}, env)
    text = env.read_text("utf-8")
    check("存 .env 不存密碼", ("secret" in text, any(x.startswith("SQL_PASSWORD") for x in text.splitlines())),
          (False, False))
    L.load_env(env)
    s = L.settings_from(args())
    check(".env 讀回來一樣", (s["server"], s["database"], s["auth"], s["user"]),
          ("abc.database.windows.net", "kri", "sql", "loader"))
    clear_env()

# ---------------------------------------------------------------- 點兩下時的問答
import builtins  # noqa: E402

answers = iter(["abc.database.windows.net", "kri", "3", "me@corp.com", ""])
real_input, builtins.input = builtins.input, lambda prompt="": next(answers)
try:
    s = L.interactive_settings()
finally:
    builtins.input = real_input
check("問答：雲端 + Entra 互動登入", (s["server"], s["database"], s["auth"], s["user"], s["trust_cert"]),
      ("abc.database.windows.net", "kri", "entra-interactive", "me@corp.com", False))
answers = iter(["", "", ""])          # 全部按 Enter
builtins.input = lambda prompt="": next(answers)
try:
    s = L.interactive_settings()
finally:
    builtins.input = real_input
check("問答：全部按 Enter = 本機 LocalDB、Windows 驗證", (s["server"], s["database"], s["auth"]),
      (L.LOCALDB, L.DEFAULT_DB, "windows"))

# ---------------------------------------------------------------- 實際匯入（LocalDB）
master = pyodbc.connect(f"Driver={{ODBC Driver 17 for SQL Server}};Server={SERVER};Database=master;"
                        "Trusted_Connection=yes", autocommit=True)


def drop_db():
    master.execute(f"IF DB_ID('{DB}') IS NOT NULL BEGIN ALTER DATABASE [{DB}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;"
                   f" DROP DATABASE [{DB}]; END")


def write_csvs(folder):
    (folder / "EKKO.csv").write_text(
        '"EBELN"|"BUKRS"|"BEDAT"|"NETWR"\n'
        '"4500000001"|"1000"|"2023/09/06 上午 12:00:00"|"123.45"\n'
        '"0450000002"|"1000"|"2023/09/07 下午 01:30:00"|""\n', encoding="utf-8-sig")
    (folder / "Vendor.csv").write_text(
        '"Vendor"|"CompanyCode"|"PurchOrg"|"VendorName"\n'
        '"V1"|"1000"|"P001"|"測試供應商"\n', encoding="utf-8-sig")


def db_rows(sql):
    cn = pyodbc.connect(f"Driver={{ODBC Driver 17 for SQL Server}};Server={SERVER};Database={DB};"
                        "Trusted_Connection=yes", autocommit=True)
    try:
        return [tuple(r) for r in cn.execute(sql).fetchall()]
    finally:
        cn.close()


def run_tool(cmd, folder, extra=(), env_file=None):
    """用另一個 process 跑（不吃 stdin，等於排程模式）。"""
    full = [*cmd, "--folder", str(folder), "--yes", *extra]
    if env_file:
        full += ["--env", str(env_file)]
    r = subprocess.run(full, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       stdin=subprocess.DEVNULL, env={**os.environ, "PYTHONIOENCODING": "utf-8"})
    return r.returncode, r.stdout + r.stderr


def suite(label, cmd):
    drop_db()
    with tempfile.TemporaryDirectory() as t:
        folder = Path(t) / "csv"
        folder.mkdir()
        write_csvs(folder)

        code, out = run_tool(cmd, folder, ["--server", SERVER, "--database", DB, "--test"])
        check(f"{label}：--test 只測連線（LocalDB 會自動建庫）、不匯入",
              (code, "連線測試成功" in out, db_rows("SELECT COUNT(*) FROM sys.tables")), (0, True, [(0,)]))

        code, out = run_tool(cmd, folder, ["--server", SERVER, "--database", DB])
        check(f"{label}：參數連線、匯入成功", (code, "2 張成功，0 張失敗" in out), (0, True))
        check(f"{label}：dbo 原表型別（前導零保留、日期、小數）",
              db_rows("SELECT EBELN, BEDAT, NETWR FROM dbo.EKKO ORDER BY EBELN"),
              [("0450000002", __import__("datetime").datetime(2023, 9, 7, 13, 30), None),
               ("4500000001", __import__("datetime").datetime(2023, 9, 6, 0, 0),
                __import__("decimal").Decimal("123.45"))])
        check(f"{label}：業務表照規格", db_rows("SELECT Vendor, PurchOrg, VendorName FROM mst.Vendor"),
              [("V1", "P001", "測試供應商")])

        env = Path(t) / "my.env"
        env.write_text(f"SQL_SERVER={SERVER}\nSQL_DATABASE={DB}\n", encoding="utf-8")
        code, out = run_tool(cmd, folder, env_file=env)
        check(f"{label}：只靠 .env 也連得上", (code, "2 張成功" in out, "讀取設定" in out), (0, True, True))

        code, out = run_tool(cmd, folder, ["--server", SERVER, "--database", DB, "--auth", "sql", "--user", "nobody"])
        check(f"{label}：不能互動又沒密碼 → 不連線、報錯", (code != 0, "SQL_PASSWORD" in out), (True, True))

        code, out = run_tool(cmd, folder, ["--server", r"(localdb)\NoSuchInstance", "--database", DB, "--test"])
        check(f"{label}：連不上時給提示、不當掉", (code, "--test" in out), (1, True))
    drop_db()


suite("python", [sys.executable, str(ROOT / "load_csv.py")])
if len(sys.argv) > 1:
    suite("exe", [str(Path(sys.argv[1]).resolve())])
master.close()

print(f"\n{sum(checks)}/{len(checks)} 通過")
sys.exit(0 if all(checks) else 1)
