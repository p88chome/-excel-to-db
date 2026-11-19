"""把一個資料夾裡的 CSV 匯進 SQL Server，一個檔案一張表。

給 SSMS「匯出成 CSV」的檔案用：UTF-8、| 分隔、每格有雙引號、空值是 ""、
日期像 2023/09/06 上午 12:00:00。

    python load_csv.py                                  # Data 資料夾 → 本機 LocalDB 的 kri_sample
    python load_csv.py --folder D:\\sample              # 指定資料夾
    python load_csv.py --conn "Driver={ODBC Driver 17 for SQL Server};Server=xxx.database.windows.net;Database=kri_sample;Uid=...;Pwd=..."
    python load_csv.py --create-db                      # 資料庫不存在就先建（雲端通常要先在入口網站建好）
    python load_csv.py --collation Chinese_Taiwan_Stroke_CI_AS_WS   # 建資料庫時用的定序

定序要跟來源資料庫一樣：來源分全形半形（_WS）時，像 TI001 和 ＴI001 這種在不分的定序下
會被當成同一個鍵，業務表會撞主鍵。在來源跑 SELECT DATABASEPROPERTYEX(DB_NAME(), 'Collation') 查。

* 檔名是業務表（PurchaseOrderDetail、Vendor…）的，先跑 etl/sql/01_create_tables.sql 建好
  prc / mst / inv / fin 的表（型別、主鍵照規格），再把 CSV 轉成那個型別寫進去。
* 其他檔案（EKKO、Z 開頭的自訂表…）建在 dbo，表名 = 檔名，型別照 excel-to-db 的規則判斷：
  代碼欄位一律文字（前導零保留）、日期 DATE、有小數點或已知的金額數量欄位 DECIMAL、其餘 NVARCHAR。
* 空值存成 NULL；業務表的主鍵欄位（NOT NULL）存成空字串，跟 ETL 一樣。
* 每次執行都整張重建，原本的資料會不見。

連線字串會寫進 log 前先遮掉密碼。不要把含密碼的連線字串寫進版控。
"""
import argparse
import csv
import re
import sys
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import pyodbc

import core

HERE = Path(__file__).parent
DDL = HERE / "etl" / "sql" / "01_create_tables.sql"
DEFAULT_CONN = ("Driver={ODBC Driver 17 for SQL Server};Server=(localdb)\\MSSQLLocalDB;"
                "Database=kri_sample;Trusted_Connection=yes")

DATE_RE = re.compile(r"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})"
                     r"(?:\s+(上午|下午|AM|PM)?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(上午|下午|AM|PM)?)?$", re.I)
NUM_RE = re.compile(r"^-?\d+(\.\d+)?$")
LEADING_ZERO = re.compile(r"^-?0\d")


def mask(conn):
    return re.sub(r"(?i)(pwd|password)=[^;]*", r"\1=***", conn)


def db_name(conn):
    m = re.search(r"(?i)(?:database|initial catalog)=([^;]+)", conn)
    return m.group(1).strip() if m else None


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
    if not core.is_code_field(name):
        dts = [to_dt(v) for v in vals]
        if all(dts):
            return "DATE" if all(d.time() == datetime.min.time() for d in dts) else "DATETIME2(0)"
        if all(NUM_RE.match(v) for v in vals) and not any(LEADING_ZERO.match(v) and "." not in v for v in vals) \
                and (core.is_numeric_field(name) or any("." in v for v in vals)):
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
    return {t: s for s, t in re.findall(r"CREATE TABLE (\w+)\.(\w+)", DDL.read_text("utf-8-sig"))}


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


def main(argv=None):
    ap = argparse.ArgumentParser(description="把資料夾裡的 CSV 匯進 SQL Server（一個檔案一張表）")
    ap.add_argument("--folder", default=str(HERE / "Data"), help="CSV 資料夾（預設 Data）")
    ap.add_argument("--conn", default=DEFAULT_CONN, help="ODBC 連線字串（預設本機 LocalDB 的 kri_sample）")
    ap.add_argument("--create-db", action="store_true",
                    help="資料庫不存在就先建（用預設連線時自動開啟）")
    ap.add_argument("--collation", default="Chinese_Taiwan_Stroke_CI_AS_WS",
                    help="建資料庫時的定序（預設不分大小寫、分全形半形）")
    a = ap.parse_args(argv)

    folder = Path(a.folder)
    files = sorted(folder.glob("*.csv"))
    if not files:
        sys.exit(f"{folder} 底下沒有 .csv")

    db = db_name(a.conn)
    print(f"連線：{mask(a.conn)}")
    if (a.create_db or a.conn == DEFAULT_CONN) and db:
        master = re.sub(r"(?i)(database|initial catalog)=[^;]+", r"\1=master", a.conn)
        with pyodbc.connect(master, autocommit=True) as cn:
            if cn.execute("SELECT DB_ID(?)", db).fetchone()[0] is None:
                cn.execute(f"CREATE DATABASE [{db}] COLLATE {a.collation}")
                print(f"建立資料庫 {db}（定序 {a.collation}）")

    biz = business_tables()
    cn = pyodbc.connect(a.conn, autocommit=True)
    cur = cn.cursor()
    coll = cur.execute("SELECT CONVERT(sysname, DATABASEPROPERTYEX(DB_NAME(), 'Collation'))").fetchone()[0]
    print(f"資料庫定序：{coll}")
    if any(f.stem in biz for f in files):
        run_script(cur, DDL)          # 建 schema 與業務表（會 DROP 重建）
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


if __name__ == "__main__":
    sys.exit(main())
