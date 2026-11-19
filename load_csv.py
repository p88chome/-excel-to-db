"""把一個資料夾裡的 CSV 匯進 SQL Server，一個檔案一張表。

給 SSMS「匯出成 CSV」的檔案用：UTF-8、| 分隔、每格有雙引號、空值是 ""、
日期像 2023/09/06 上午 12:00:00。

連線設定（由上往下，先找到的算）：
  1. --conn "完整的 ODBC 連線字串"
  2. --server、--database、--auth、--user…（密碼不要打在命令列，會留在歷史紀錄；不給會另外問）
  3. 程式旁邊的 .env（SQL_SERVER、SQL_DATABASE、SQL_AUTH、SQL_USER、SQL_PASSWORD…，範本見 .env.example）
  4. 上面都沒有、而且是直接點兩下執行的：一步一步問，最後可以存成 .env（不存密碼）

    load_csv.exe                                            # 點兩下：一步一步問
    load_csv.exe --server (localdb)\\MSSQLLocalDB --database kri_sample --create-db
    load_csv.exe --server xxx.database.windows.net --database kri --auth entra-interactive --user me@corp.com
    load_csv.exe --server SQL01,1433 --database kri --auth sql --user loader   # 密碼另外問
    load_csv.exe --test                                     # 只測連線，不匯入
    load_csv.exe --folder D:\\sample --yes                  # 不問、直接匯入（排程用）

    （沒打包時把 load_csv.exe 換成 python load_csv.py，用法一樣）

驗證方式 --auth / SQL_AUTH：
  windows             Windows 整合驗證（目前登入的帳號；沒給帳號時的預設）
  sql                 SQL Server 帳號密碼（給了帳號時的預設）
  entra-interactive   Microsoft Entra（Azure AD）跳出登入視窗，支援 MFA。雲端最常用
  entra-password      Entra 帳號密碼（沒有 MFA 的帳號）
  entra-integrated    Entra 整合驗證（加入網域、已同步到 Entra 的電腦）
  entra-msi           Azure 上的受控識別（程式跑在 Azure VM／App 上時）

定序要跟來源資料庫一樣：來源分全形半形（_WS）時，像 TI001 和 ＴI001 這種在不分的定序下
會被當成同一個鍵，業務表會撞主鍵。在來源跑 SELECT DATABASEPROPERTYEX(DB_NAME(), 'Collation') 查。

* 檔名是業務表（PurchaseOrderDetail、Vendor…）的，先跑 01_create_tables.sql 建好
  prc / mst / inv / fin 的表（型別、主鍵照規格），再把 CSV 轉成那個型別寫進去。
  01_create_tables.sql 優先用程式旁邊的（規格改了不用重新打包），沒有才用打包進去的。
* 其他檔案（EKKO、Z 開頭的自訂表…）建在 dbo，表名 = 檔名，型別照 excel-to-db 的規則判斷：
  代碼欄位一律文字（前導零保留）、日期 DATE、有小數點或已知的金額數量欄位 DECIMAL、其餘 NVARCHAR。
* 空值存成 NULL；業務表的主鍵欄位（NOT NULL）存成空字串，跟 ETL 一樣。
* 每次執行都整張重建，原本的資料會不見。

畫面和 log 上的連線字串一律遮掉密碼。密碼不會寫進 .env，也不要把含密碼的連線字串放進版控。
"""
import argparse
import csv
import getpass
import os
import re
import sys
from datetime import datetime
from decimal import Decimal
from pathlib import Path

import pyodbc

import sapfields

# 打包成 exe 後：設定檔、Data 資料夾找 exe 旁邊；打包進去的檔案在 _MEIPASS
FROZEN = getattr(sys, "frozen", False)
HERE = Path(sys.executable).parent if FROZEN else Path(__file__).parent
BUNDLE = Path(getattr(sys, "_MEIPASS", HERE))
LOCALDB = r"(localdb)\MSSQLLocalDB"
DEFAULT_DB = "kri_sample"

AUTH = {   # --auth → ODBC 的設定；None = 不用 Authentication 關鍵字
    "windows": None, "sql": None,
    "entra-interactive": "ActiveDirectoryInteractive",
    "entra-password": "ActiveDirectoryPassword",
    "entra-integrated": "ActiveDirectoryIntegrated",
    "entra-msi": "ActiveDirectoryMsi",
}
NEEDS_USER = {"sql", "entra-password"}                 # 一定要帳號
NEEDS_PASSWORD = {"sql", "entra-password"}
YES = ("1", "y", "yes", "true")

DATE_RE = re.compile(r"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})"
                     r"(?:\s+(上午|下午|AM|PM)?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(上午|下午|AM|PM)?)?$", re.I)
NUM_RE = re.compile(r"^-?\d+(\.\d+)?$")
LEADING_ZERO = re.compile(r"^-?0\d")


# ---------- 連線 ----------

def mask(conn):
    return re.sub(r"(?i)(pwd|password)=(\{(?:[^}]|\}\})*\}|[^;]*)", r"\1=***", conn)


def db_name(conn):
    m = re.search(r"(?i)(?:database|initial catalog)=([^;]+)", conn)
    return m.group(1).strip().strip("{}") if m else None


def odbc_value(v):
    """ODBC 連線字串的值：有 ; { } 或前後空白時要用 {} 包起來，裡面的 } 寫兩次。"""
    v = str(v)
    if re.search(r"[;{}]|^\s|\s$", v):
        return "{" + v.replace("}", "}}") + "}"
    return v


def installed_drivers():
    """機器上裝的 SQL Server ODBC 驅動，版本高的排前面。"""
    found = [d for d in pyodbc.drivers() if "ODBC Driver" in d and "SQL Server" in d]
    return sorted(found, key=lambda d: int(re.search(r"\d+", d).group()) if re.search(r"\d+", d) else 0,
                  reverse=True)


def load_env(path):
    """讀 .env；已經有的環境變數優先（臨時用 set 蓋掉也有效）。"""
    if not path.exists():
        return False
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))
    return True


def settings_from(a):
    """命令列 > 環境變數（.env）。回傳 dict；連 server 都沒有就回 None。"""
    env = os.environ.get
    s = {"server": a.server or env("SQL_SERVER"), "database": a.database or env("SQL_DATABASE"),
         "auth": a.auth or env("SQL_AUTH"), "user": a.user or env("SQL_USER"),
         "password": env("SQL_PASSWORD") or None, "driver": a.driver or env("SQL_DRIVER"),
         "trust_cert": a.trust_cert or (env("SQL_TRUST_CERT") or "").strip().lower() in YES}
    if not s["server"]:
        return None
    s["auth"] = (s["auth"] or ("sql" if s["user"] else "windows")).strip().lower()
    if s["auth"] not in AUTH:
        raise SystemExit(f"不認得的驗證方式 {s['auth']!r}，可以用：{', '.join(AUTH)}")
    return s


def build_conn(s):
    """設定 → ODBC 連線字串。"""
    driver = s.get("driver") or (installed_drivers() or ["ODBC Driver 17 for SQL Server"])[0]
    parts = [f"Driver={{{driver}}}", f"Server={odbc_value(s['server'])}"]
    if s.get("database"):
        parts.append(f"Database={odbc_value(s['database'])}")
    auth = s["auth"]
    if auth == "windows":
        parts.append("Trusted_Connection=yes")
    else:
        if AUTH[auth]:
            parts.append(f"Authentication={AUTH[auth]}")
        if s.get("user"):
            parts.append(f"UID={odbc_value(s['user'])}")
        if auth in NEEDS_PASSWORD:
            parts.append(f"PWD={odbc_value(s.get('password') or '')}")
    # Azure SQL 一定要加密；Driver 17 預設不加密，所以明講。Driver 18 起預設就加密。
    cloud = re.search(r"\.database\.(windows|chinacloudapi|usgovcloudapi)\.net", s["server"], re.I)
    if cloud or auth.startswith("entra"):
        parts.append("Encrypt=yes")
    # Driver 18 會驗證伺服器憑證，內部自簽憑證會被擋。要跳過驗證必須明講，不自動開。
    if s.get("trust_cert"):
        parts.append("TrustServerCertificate=yes")
    return ";".join(parts) + ";"


def ask(prompt, default=None):
    tip = f"［{default}］" if default else ""
    v = input(f"{prompt}{tip}：").strip()
    return v or (default or "")


def interactive_settings():
    """點兩下執行、又沒有任何設定時：一步一步問。"""
    print("找不到連線設定（命令列、.env 都沒有），一步一步設定。直接按 Enter = 用［］裡的預設值。\n")
    server = ask("伺服器（雲端像 xxx.database.windows.net；本機測試用 LocalDB）", LOCALDB)
    database = ask("資料庫", DEFAULT_DB)
    print("驗證方式：" + "、".join(f"{i}={k}" for i, k in enumerate(AUTH, 1)))
    pick = ask("選哪一個（數字或名稱）", "1")
    names = list(AUTH)
    auth = names[int(pick) - 1] if pick.isdigit() and 1 <= int(pick) <= len(names) else pick.lower()
    if auth not in AUTH:
        raise SystemExit(f"不認得的驗證方式 {auth!r}")
    user = ""
    if auth != "windows" and auth != "entra-msi":
        user = ask("帳號" + ("" if auth in NEEDS_USER else "（可以留空）"))
    trust = server.lower() != LOCALDB.lower() and ask(
        "伺服器是自簽憑證、連線被憑證擋下來時才填 y；其他留空", "n").lower() in YES
    return {"server": server, "database": database, "auth": auth, "user": user, "password": None,
            "driver": None, "trust_cert": trust}


def save_env(s, path):
    """存成 .env，不存密碼。"""
    lines = ["# load_csv 的連線設定（由程式產生）。密碼不存在這裡，執行時另外問；",
             "# 排程不能互動時，自己在這台機器上加 SQL_PASSWORD=（這個檔案不要放進版控）。",
             f"SQL_SERVER={s['server']}", f"SQL_DATABASE={s.get('database') or ''}",
             f"SQL_AUTH={s['auth']}", f"SQL_USER={s.get('user') or ''}"]
    if s.get("driver"):
        lines.append(f"SQL_DRIVER={s['driver']}")
    lines.append(f"SQL_TRUST_CERT={'yes' if s.get('trust_cert') else 'no'}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def ddl_path():
    for p in (HERE / "01_create_tables.sql", HERE / "etl" / "sql" / "01_create_tables.sql",
              BUNDLE / "01_create_tables.sql"):
        if p.exists():
            return p
    raise SystemExit("找不到 01_create_tables.sql（程式旁邊、etl\\sql、打包進去的都沒有）")


# ---------- 讀 CSV ----------

def to_dt(v):
    """2023/09/06 上午 12:00:00 → datetime；不是日期回 None。"""
    m = DATE_RE.match(v)
    if not m:
        return None
    y, mo, d, ap1, hh, mi, ss, ap2 = m.groups()
    h = int(hh or 0)
    ap = (ap1 or ap2 or "").upper()
    if ap in ("下午", "PM") and h < 12:
        h += 12
    if ap in ("上午", "AM") and h == 12:
        h = 0
    try:
        return datetime(int(y), int(mo), int(d), h, int(mi or 0), int(ss or 0))
    except ValueError:
        return None


def read_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.reader(f, delimiter="|", quotechar='"'))
    if not rows:
        return [], []
    head = [h.strip() for h in rows[0]]
    body = [r for r in rows[1:] if any(c != "" for c in r)]
    bad = [i + 2 for i, r in enumerate(body) if len(r) != len(head)]
    if bad:
        raise ValueError(f"第 {bad[:5]} 列的欄數跟標題（{len(head)} 欄）不一樣")
    return head, body


# ---------- dbo 原表：判斷型別 ----------

def infer(name, values):
    vals = [v for v in values if v != ""]
    if not vals:
        return "NVARCHAR(255)"
    if not sapfields.is_code_field(name):
        dts = [to_dt(v) for v in vals]
        if all(dts):
            return "DATE" if all(d.time() == datetime.min.time() for d in dts) else "DATETIME2(0)"
        if all(NUM_RE.match(v) for v in vals) and not any(LEADING_ZERO.match(v) and "." not in v for v in vals) \
                and (sapfields.is_numeric_field(name) or any("." in v for v in vals)):
            scale = max((len(v.split(".")[1]) if "." in v else 0) for v in vals)
            whole = max(len(v.lstrip("-").split(".")[0]) for v in vals)
            return f"DECIMAL({max(18, whole + scale + 2)},{min(scale, 10)})" if scale else f"DECIMAL({max(18, whole + 2)},0)"
    longest = max(len(v) for v in vals)
    return "NVARCHAR(255)" if longest <= 255 else "NVARCHAR(4000)" if longest <= 4000 else "NVARCHAR(MAX)"


def convert(v, sqltype, not_null=False):
    if v == "":
        return "" if not_null and sqltype.startswith("NVARCHAR") else None
    t = sqltype.upper()
    if t.startswith("DATETIME"):
        return to_dt(v)
    if t == "DATE":
        d = to_dt(v)
        return d.date() if d else None
    if t == "TIME":
        d = to_dt("2000/01/01 " + v)
        return d.time() if d else None
    if t.startswith(("DECIMAL", "NUMERIC")):
        return Decimal(v)
    if t in ("INT", "BIGINT", "SMALLINT"):
        return int(Decimal(v))
    if t == "BIT":
        return v.strip().upper() in ("1", "X", "TRUE", "Y")
    return v


# ---------- 寫入 ----------

def run_script(cur, path):
    """執行有 GO 的 SQL 檔。"""
    text = path.read_text("utf-8-sig")
    for batch in re.split(r"^\s*GO\s*$", text, flags=re.M | re.I):
        if batch.strip():
            cur.execute(batch)


def business_tables():
    """01_create_tables.sql 裡的 schema.Table → {Table: schema}"""
    return {t: s for s, t in re.findall(r"CREATE TABLE (\w+)\.(\w+)", ddl_path().read_text("utf-8-sig"))}


def insert(cur, full, cols, rows):
    cur.fast_executemany = True
    sql = f"INSERT {full} ({', '.join(f'[{c}]' for c in cols)}) VALUES ({', '.join('?' * len(cols))})"
    for i in range(0, len(rows), 5000):
        cur.executemany(sql, rows[i:i + 5000])


def load(cur, path, biz):
    head, body = read_csv(path)
    name = path.stem
    if name in biz:
        full = f"[{biz[name]}].[{name}]"
        meta = {r.COLUMN_NAME: (r.DATA_TYPE.upper(), r.IS_NULLABLE == "NO") for r in cur.execute(
            "SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS "
            "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?", biz[name], name).fetchall()}
        extra = [c for c in head if c not in meta]
        if extra:
            raise ValueError(f"CSV 有規格上沒有的欄位：{', '.join(extra)}")
        types = [meta[c] for c in head]
    else:
        full = f"[dbo].[{name}]"
        specs = [infer(c, [r[i] for r in body]) for i, c in enumerate(head)]
        cur.execute(f"DROP TABLE IF EXISTS {full}")
        cur.execute(f"CREATE TABLE {full} (" + ", ".join(f"[{c}] {t} NULL" for c, t in zip(head, specs)) + ")")
        types = [(t, False) for t in specs]
    rows = [[convert(v, t, nn) for v, (t, nn) in zip(r, types)] for r in body]
    if rows:
        insert(cur, full, head, rows)
    return full, len(rows)


# ---------- 主程式 ----------

def run(a, console):
    env_path = Path(a.env) if a.env else HERE / ".env"
    if load_env(env_path):
        print(f"讀取設定：{env_path}")

    if a.conn:
        conn = a.conn
    else:
        s = settings_from(a)
        asked = s is None
        if asked:
            if not console:
                raise SystemExit("沒有連線設定：給 --server、--database，或在程式旁邊放 .env（範本見 .env.example）")
            s = interactive_settings()
        if s["auth"] in NEEDS_USER and not s.get("user"):
            if not console:
                raise SystemExit(f"驗證方式 {s['auth']} 要帳號：給 --user 或在 .env 設 SQL_USER")
            s["user"] = ask("帳號")
        if s["auth"] in NEEDS_PASSWORD and not s.get("password"):
            if not console:
                raise SystemExit("沒有密碼：不能互動時請用環境變數 SQL_PASSWORD（不要寫在命令列）")
            s["password"] = getpass.getpass(f"{s['user']} 的密碼（打字不會顯示）：")
        conn = build_conn(s)
        if a.save_env or (asked and ask("要把這組設定存成 .env，下次不用再打嗎？（不存密碼）y/n", "y").lower() in YES):
            save_env(s, env_path)
            print(f"已存到 {env_path}（不含密碼）")

    print(f"連線：{mask(conn)}")
    db = db_name(conn)
    if (a.create_db or "(localdb)" in conn.lower()) and db:
        master = re.sub(r"(?i)(database|initial catalog)=[^;]+", r"\1=master", conn)
        with pyodbc.connect(master, autocommit=True, timeout=30) as cn:
            if cn.execute("SELECT DB_ID(?)", db).fetchone()[0] is None:
                cn.execute(f"CREATE DATABASE [{db}] COLLATE {a.collation}")
                print(f"建立資料庫 {db}（定序 {a.collation}）")

    cn = pyodbc.connect(conn, autocommit=True, timeout=30)
    cur = cn.cursor()
    srv, dbn, coll, ver, who = cur.execute(
        "SELECT @@SERVERNAME, DB_NAME(), CONVERT(sysname, DATABASEPROPERTYEX(DB_NAME(), 'Collation')),"
        " CONVERT(nvarchar(30), SERVERPROPERTY('ProductVersion')), SUSER_SNAME()").fetchone()
    print(f"已連上：{srv} / {dbn}（SQL Server {ver}，登入 {who}，定序 {coll}）")
    if a.test:
        cn.close()
        print("連線測試成功，沒有匯入任何資料。")
        return 0

    folder = Path(a.folder) if a.folder else HERE / "Data"
    if console and not a.folder:
        folder = Path(ask("CSV 資料夾", str(folder)))
    files = sorted(folder.glob("*.csv"))
    if not files:
        raise SystemExit(f"{folder} 底下沒有 .csv")

    biz = business_tables()
    if console:
        print(f"\n要匯入 {len(files)} 個檔案到 {srv} / {dbn}：")
        print("  " + "、".join(f.stem for f in files))
        print("這些表會整張重建，原本的資料會不見" + ("；業務表會依 01_create_tables.sql 全部重建" if any(
            f.stem in biz for f in files) else "") + "。")
        if ask("確定匯入？y/n", "n").lower() not in YES:
            print("已取消，沒有動到資料庫。")
            return 0

    if any(f.stem in biz for f in files):
        run_script(cur, ddl_path())       # 建 schema 與業務表（會 DROP 重建）
        print("已依規格重建業務表（01_create_tables.sql）")

    failed = 0
    for f in files:
        try:
            full, n = load(cur, f, biz)
            print(f"  {full:<36} {n:>8,} 筆")
        except Exception as e:      # 一張失敗不影響其他張
            failed += 1
            print(f"  X {f.name}：{e}")
    cn.close()
    print(f"\n完成：{len(files) - failed} 張成功，{failed} 張失敗")
    return 1 if failed else 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    ap = argparse.ArgumentParser(description="把資料夾裡的 CSV 匯進 SQL Server（一個檔案一張表）。"
                                             "連線設定的優先順序：--conn > 參數 > .env > 互動詢問")
    ap.add_argument("--folder", help="CSV 資料夾（預設程式旁邊的 Data）")
    ap.add_argument("--conn", help="完整的 ODBC 連線字串；有給就不看其他連線參數")
    ap.add_argument("--server", help=r"伺服器，例如 SQL01,1433、xxx.database.windows.net、(localdb)\MSSQLLocalDB")
    ap.add_argument("--database", help="資料庫名稱")
    ap.add_argument("--auth", choices=list(AUTH), help="驗證方式（預設：有帳號 = sql，沒帳號 = windows）")
    ap.add_argument("--user", help="帳號（密碼不要放命令列：執行時會問，或用環境變數 SQL_PASSWORD）")
    ap.add_argument("--driver", help="ODBC 驅動名稱（預設自動挑機器上版本最高的）")
    ap.add_argument("--trust-cert", action="store_true", help="不驗證伺服器憑證（只有自簽憑證被擋時才用）")
    ap.add_argument("--env", help=".env 路徑（預設程式旁邊的 .env）")
    ap.add_argument("--save-env", action="store_true", help="把這次的連線設定存成 .env（不存密碼）")
    ap.add_argument("--test", action="store_true", help="只測連線、印出連到哪裡，不匯入")
    ap.add_argument("--create-db", action="store_true", help="資料庫不存在就先建（LocalDB 自動開；雲端通常要先在入口網站建好）")
    ap.add_argument("--collation", default="Chinese_Taiwan_Stroke_CI_AS_WS",
                    help="建資料庫時的定序（預設不分大小寫、分全形半形）")
    ap.add_argument("-y", "--yes", action="store_true", help="不詢問、不確認，直接匯入（排程用）")
    a = ap.parse_args(argv)

    # 導到檔案或給排程讀時一律輸出 UTF-8（打包版不吃 PYTHONIOENCODING，預設會是 cp950，
    # 罕用字會印不出來而中斷）。開在主控台視窗時不動，Windows 主控台本來就顯示得了中文。
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and not stream.isatty() and hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    console = sys.stdin is not None and sys.stdin.isatty() and not a.yes
    double_click = FROZEN and not argv          # 點兩下開的視窗，結束前停一下讓人看結果
    try:
        return run(a, console)
    except SystemExit as e:
        if e.code not in (None, 0) and not isinstance(e.code, int):
            print(f"\n{e.code}")
        return e.code if isinstance(e.code, int) else 1
    except pyodbc.Error as e:
        print(f"\n連線或執行失敗：{e}")
        print("可以先用 --test 只測連線；雲端記得確認防火牆已開放這台電腦的 IP。")
        return 1
    except KeyboardInterrupt:
        print("\n已中斷。")
        return 1
    finally:
        if double_click:
            input("\n按 Enter 關閉視窗…")


if __name__ == "__main__":
    sys.exit(main())
