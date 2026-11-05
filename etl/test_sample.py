"""在 LocalDB 測 20_sample_exp.sql：抽出來的資料要串得起來、同一個 seed 抽同一批。

    python etl/test_sample.py

只碰 (localdb)\\MSSQLLocalDB 上的 etl_sample_scratch，跑完會刪掉。
"""
import re
import subprocess
import sys
from pathlib import Path

import pyodbc

SQL = Path(__file__).parent / "sql"
SERVER = r"(localdb)\MSSQLLocalDB"
DB = "etl_sample_scratch"
DATES = {"BEDAT", "BUDAT", "BLDAT", "CPUDT", "EINDT", "BADAT", "LFDAT", "ERDAT", "ERSDA",
         "UDATE", "DATAB", "DATBI", "ZFBDT", "AUGDT"}
NUMS = {"MENGE", "DMBTR", "NETPR", "PEINH", "NETWR", "PREIS", "KBETR", "KPEIN", "WKURS",
        "LABST", "INSME", "SPEME", "UMLME", "SALK3", "STPRS", "VERPR", "EISBE", "MINBE",
        "MABST", "LBKUM", "BRGEW", "NTGEW", "VOLUM", "WRBTR", "NORBM", "APLFZ"}


def sqlcmd(*args, db="master"):
    r = subprocess.run(["sqlcmd", "-S", SERVER, "-d", db, "-b", "-f", "65001", *args],
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode:
        sys.exit(f"sqlcmd 失敗：{args}\n{r.stdout}\n{r.stderr}")
    return r.stdout


sqlcmd("-Q", f"IF DB_ID('{DB}') IS NOT NULL BEGIN ALTER DATABASE {DB} SET SINGLE_USER "
             f"WITH ROLLBACK IMMEDIATE; DROP DATABASE {DB}; END; CREATE DATABASE {DB};")
cn = pyodbc.connect(f"Driver={{ODBC Driver 17 for SQL Server}};Server={SERVER};"
                    f"Database={DB};Trusted_Connection=yes", autocommit=True)
cur = cn.cursor()

# stg 表照 00 的清單建；T024D、T024E 不建，測「來源表不存在」
need = re.findall(r"\('(\w+)','(\w+)'(,1)?\)", (SQL / "00_check_staging.sql").read_text("utf-8"))
tables = {}
for t, c, optional in need:
    if not optional:
        tables.setdefault(t, []).append(c)
for t, cols in tables.items():
    defs = ", ".join(f"[{c}] {'DATE' if c in DATES else 'DECIMAL(18,5)' if c in NUMS else 'NVARCHAR(100)'} NULL"
                     for c in cols)
    cur.execute(f"CREATE TABLE dbo.{t} ({defs})")


def ins(table, rows):
    for r in rows:
        cols = ", ".join(f"[{k}]" for k in r)
        cur.execute(f"INSERT dbo.{table} ({cols}) VALUES ({', '.join('?' * len(r))})", *r.values())


V = [f"V{i:04d}" for i in range(6)]
M = [f"M{i:05d}" for i in range(8)]
N = 30
po = lambda i: f"45{i:08d}"
pr = lambda i: f"10{i:08d}"

ins("T001", [{"BUKRS": "1000", "WAERS": "TWD"}])
for i in range(N):
    v, m = V[i % 6], M[i % 8]
    ins("EKKO", [{"EBELN": po(i), "BSTYP": "F", "BSART": "NB", "BUKRS": "1000", "EKORG": "TW01",
                  "BEDAT": "2025-03-01", "LIFNR": v, "WAERS": "TWD", "WKURS": 1}])
    for item in ("00010", "00020"):
        # 前一半的 PO 由 PR 轉來
        ins("EKPO", [{"EBELN": po(i), "EBELP": item, "MATNR": m, "WERKS": "1100", "MENGE": 10,
                      "MEINS": "EA", "NETPR": 5, "PEINH": 1, "NETWR": 50,
                      "BANFN": pr(i) if i < N // 2 else None, "BNFPO": item if i < N // 2 else None}])
        ins("EKET", [{"EBELN": po(i), "EBELP": item, "EINDT": "2025-04-01"}])
        ins("EKKN", [{"EBELN": po(i), "EBELP": item, "ZEKKN": "01", "KOSTL": "CC1"}])
    ins("EKBE", [{"EBELN": po(i), "EBELP": "00010", "BEWTP": "E", "SHKZG": "S", "MENGE": 10,
                  "DMBTR": 50, "BUDAT": "2025-04-02"}])
    # 收貨憑證連到 PO；另外 N 張沒有 PO 的物料憑證
    ins("MKPF", [{"MBLNR": f"49{i:08d}", "MJAHR": "2025", "BUDAT": "2025-04-02"},
                 {"MBLNR": f"48{i:08d}", "MJAHR": "2025", "BUDAT": "2025-04-02"}])
    ins("MSEG", [{"MBLNR": f"49{i:08d}", "MJAHR": "2025", "ZEILE": "0001", "BWART": "101",
                  "MATNR": m, "WERKS": "1100", "BUKRS": "1000", "MENGE": 10, "EBELN": po(i),
                  "EBELP": "00010"},
                 {"MBLNR": f"48{i:08d}", "MJAHR": "2025", "ZEILE": "0001", "BWART": "261",
                  "MATNR": m, "WERKS": "1100", "BUKRS": "1000", "MENGE": 1}])
    # 發票傳票：供應商行 + 費用行；另外有沒有供應商行的總帳傳票
    ins("BKPF", [{"BUKRS": "1000", "BELNR": f"51{i:08d}", "GJAHR": "2025", "BLART": "RE"},
                 {"BUKRS": "1000", "BELNR": f"10{i:08d}", "GJAHR": "2025", "BLART": "SA"}])
    ins("BSEG", [{"BUKRS": "1000", "BELNR": f"51{i:08d}", "GJAHR": "2025", "BUZEI": "001",
                  "KOART": "K", "SHKZG": "H", "LIFNR": v, "DMBTR": 50, "WRBTR": 50},
                 {"BUKRS": "1000", "BELNR": f"51{i:08d}", "GJAHR": "2025", "BUZEI": "002",
                  "KOART": "S", "SHKZG": "S", "DMBTR": 50, "WRBTR": 50, "EBELN": po(i), "EBELP": "00010"},
                 {"BUKRS": "1000", "BELNR": f"10{i:08d}", "GJAHR": "2025", "BUZEI": "001",
                  "KOART": "S", "SHKZG": "S", "DMBTR": 1}])
for i in range(N + 10):         # PR 比 PO 多：後 10 張沒有轉 PO
    for item in ("00010", "00020"):
        ins("EBAN", [{"BANFN": pr(i), "BNFPO": item, "MATNR": M[i % 8], "FLIEF": V[i % 6],
                      "MENGE": 10, "PREIS": 5, "WAERS": "TWD"}])
        ins("EBKN", [{"BANFN": pr(i), "BNFPO": item, "ZEBKN": "01", "KOSTL": "CC1"}])
for v in V + ["V9999"]:         # V9999 沒有任何單據用到
    ins("LFA1", [{"LIFNR": v, "NAME1": f"供應商{v}"}])
    ins("LFB1", [{"LIFNR": v, "BUKRS": "1000"}])
    ins("LFM1", [{"LIFNR": v, "EKORG": "TW01"}])
    ins("CDHDR", [{"OBJECTCLAS": "KRED", "OBJECTID": v, "CHANGENR": f"C{v}", "UDATE": "2025-01-01"},
                  {"OBJECTCLAS": "MATERIAL", "OBJECTID": v, "CHANGENR": f"X{v}", "UDATE": "2025-01-01"}])
    ins("CDPOS", [{"OBJECTCLAS": "KRED", "OBJECTID": v, "CHANGENR": f"C{v}", "TABNAME": "LFA1",
                   "TABKEY": v, "FNAME": "SPERR", "CHNGIND": "U"},
                  {"OBJECTCLAS": "MATERIAL", "OBJECTID": v, "CHANGENR": f"X{v}", "TABNAME": "MARA",
                   "TABKEY": v, "FNAME": "MSTAE", "CHNGIND": "U"}])
for m in M + ["M99999"]:
    ins("MARA", [{"MATNR": m, "MTART": "ROH", "MEINS": "EA"}])
    ins("MAKT", [{"MATNR": m, "SPRAS": "M", "MAKTX": f"物料{m}"}])
    ins("MARC", [{"MATNR": m, "WERKS": "1100"}])
    ins("MARD", [{"MATNR": m, "WERKS": "1100", "LGORT": "0001", "LABST": 1}])
    ins("MBEW", [{"MATNR": m, "BWKEY": "1100", "BWTAR": "", "SALK3": 10, "PEINH": 1, "LBKUM": 1}])
k = 0
for v in V + ["V9999"]:
    for m in M + ["M99999"]:
        k += 1
        ins("EINA", [{"INFNR": f"53{k:08d}", "LIFNR": v, "MATNR": m}])
        ins("EINE", [{"INFNR": f"53{k:08d}", "EKORG": "TW01", "ESOKZ": "0", "WERKS": ""}])
        ins("A017", [{"LIFNR": v, "MATNR": m, "EKORG": "TW01", "WERKS": "1100", "ESOKZ": "0",
                      "KSCHL": "PB00", "DATAB": "2025-01-01", "DATBI": "9999-12-31", "KNUMH": f"K{k:09d}"}])
        ins("KONP", [{"KNUMH": f"K{k:09d}", "KOPOS": "01", "KBETR": 5, "KONWA": "TWD", "KPEIN": 1}])
        ins("KONH", [{"KNUMH": f"K{k:09d}", "ERDAT": "2025-01-01"}])

# 其他表：LFBK 有 LIFNR、MBEWH 沒有 MATNR（測退回隨機）、ADT_ECAR 欄位隨便、ZTM80 不存在
cur.execute("CREATE TABLE dbo.LFBK (LIFNR NVARCHAR(100), BANKN NVARCHAR(100))")
for v in V + ["V9999"]:
    ins("LFBK", [{"LIFNR": v, "BANKN": "123"}])
cur.execute("CREATE TABLE dbo.MBEWH (MATERIAL NVARCHAR(100), LFGJA NVARCHAR(4))")
# ANLA：EKKN 有 ANLN1/ANLN2、BSEG 沒有（測只用 EKKN 串）
cur.execute("ALTER TABLE dbo.EKKN ADD ANLN1 NVARCHAR(100), ANLN2 NVARCHAR(100)")
cur.execute("CREATE TABLE dbo.ANLA (BUKRS NVARCHAR(100), ANLN1 NVARCHAR(100), ANLN2 NVARCHAR(100), TXT50 NVARCHAR(100))")
for i in range(N):
    ins("ANLA", [{"BUKRS": "1000", "ANLN1": f"3{i:011d}", "ANLN2": "0000", "TXT50": f"資產{i}"},
                 {"BUKRS": "1000", "ANLN1": f"3{i:011d}", "ANLN2": "0001", "TXT50": f"子資產{i}"}])
cur.execute("UPDATE dbo.EKKN SET ANLN1 = '3' + RIGHT('00000000000' + CAST(CAST(RIGHT(EBELN, 8) AS INT) AS VARCHAR), 11),"
            " ANLN2 = '0000' WHERE EBELP = '00010'")
cur.execute("CREATE TABLE dbo.T001W (WERKS NVARCHAR(100), NAME1 NVARCHAR(100))")
ins("T001W", [{"WERKS": "1100", "NAME1": "一廠"}, {"WERKS": "1200", "NAME1": "二廠"}])
cur.execute("CREATE TABLE dbo.ADT_ECAR (Id INT, Amount DECIMAL(18,2), Memo NVARCHAR(MAX), Dt DATETIME2)")
for i in range(50):
    ins("ADT_ECAR", [{"Id": i, "Amount": i * 1.5, "Memo": f"備註{i}", "Dt": "2025-01-01"}])
    ins("MBEWH", [{"MATERIAL": f"X{i}", "LFGJA": "2024"}])

for i in range(40):           # A018 都跟抽到的單據無關，測補到 @Rows
    ins("A018", [{"LIFNR": "V9999", "MATNR": "M99999", "EKORG": "TW01", "ESOKZ": "0", "KSCHL": "PB00",
                  "DATAB": f"20{i:02d}-01-01", "DATBI": f"20{i:02d}-12-31", "KNUMH": f"Q{i:09d}"}])
    ins("KONP", [{"KNUMH": f"Q{i:09d}", "KOPOS": "01", "KBETR": 5, "KONWA": "TWD", "KPEIN": 1}])

for f in ("01_create_tables.sql", "02_load_procedures.sql", "20_sample_exp.sql"):
    sqlcmd("-i", str(SQL / f), db=DB)
cur.execute("EXEC etl.LoadAll").fetchall()

checks = []


def one(sql):
    return cur.execute(sql).fetchall()


def check(name, got, want):
    ok = got == want
    checks.append(ok)
    print(f"{'OK ' if ok else 'NG '} {name}" + ("" if ok else f"\n     得到 {got!r}\n     預期 {want!r}"))


def sample(rows, seed):
    res = one(f"EXEC exp.SampleAll @Rows = {rows}, @Seed = {seed}")
    return {r[0]: (r[2], r[3], r[4]) for r in res}


def keys(sql):
    return sorted(r[0] for r in one(sql))


res = sample(5, 42)
check("結果列出這次的 seed", {v[2] for v in res.values()}, {42})
check("沒有 T024E 的話跳過並註明", res["dbo.T024E"][:2], (None, "來源表不存在，跳過"))

po_set = keys("SELECT EBELN FROM exp.EKKO")
# 隨機 5 張 PO + 隨機 5 張 PR 中有轉 PO 的那幾張
pr_rand = keys("SELECT DISTINCT BANFN FROM exp.EBAN")
check("PO 至少有隨機抽的 5 張", len(po_set) >= 5, True)
check("隨機抽到的 PR 轉出的 PO 都在",
      one("""SELECT COUNT(*) FROM dbo.EKPO p WHERE p.BANFN IN (SELECT BANFN FROM exp.EBAN)
             AND p.EBELN NOT IN (SELECT EBELN FROM exp.EKKO)""")[0][0], 0)
check("PO 的來源 PR 都在",
      one("""SELECT COUNT(*) FROM exp.EKPO p WHERE ISNULL(p.BANFN, '') <> ''
             AND p.BANFN NOT IN (SELECT BANFN FROM exp.EBAN)""")[0][0], 0)
for t, n in (("EKPO", 2), ("EKET", 2), ("EKKN", 2), ("EKBE", 1)):
    check(f"{t} 帶出抽到 PO 的全部明細", one(f"SELECT COUNT(*) FROM exp.{t}")[0][0], n * len(po_set))
check("EBKN 跟 EBAN 同一批 PR", keys("SELECT DISTINCT BANFN FROM exp.EBKN"), pr_rand)
check("PO 的收貨憑證都在",
      one("""SELECT COUNT(*) FROM dbo.MSEG s WHERE s.EBELN IN (SELECT EBELN FROM exp.EKKO)
             AND s.MBLNR NOT IN (SELECT MBLNR FROM exp.MKPF)""")[0][0], 0)
check("MSEG 跟 MKPF 同一批", keys("SELECT DISTINCT MBLNR FROM exp.MSEG"), keys("SELECT MBLNR FROM exp.MKPF"))
check("隨機抽的會計傳票都有供應商行（沒有的總帳傳票不抽）",
      one("SELECT COUNT(*) FROM exp.BKPF WHERE BELNR LIKE '10%'")[0][0], 0)
check("PO 的發票傳票都在",
      one("""SELECT COUNT(*) FROM dbo.BSEG s WHERE s.EBELN IN (SELECT EBELN FROM exp.EKKO)
             AND s.BELNR NOT IN (SELECT BELNR FROM exp.BKPF)""")[0][0], 0)
check("BSEG 帶出傳票的全部行", one("SELECT COUNT(*) FROM exp.BSEG")[0][0],
      2 * one("SELECT COUNT(*) FROM exp.BKPF")[0][0])

used_v = keys("""SELECT LIFNR FROM exp.EKKO UNION SELECT FLIEF FROM exp.EBAN
                 UNION SELECT LIFNR FROM exp.BSEG WHERE LIFNR IS NOT NULL""")
used_m = keys("""SELECT MATNR FROM exp.EKPO UNION SELECT MATNR FROM exp.EBAN
                 UNION SELECT MATNR FROM exp.MSEG""")
for t in ("LFA1", "LFB1", "LFM1"):
    check(f"{t} 只帶用到的供應商", keys(f"SELECT LIFNR FROM exp.{t}"), used_v)
for t in ("MARA", "MAKT", "MARC", "MARD", "MBEW"):
    check(f"{t} 只帶用到的物料", keys(f"SELECT MATNR FROM exp.{t}"), used_m)
check("CDHDR 只帶 KRED、用到的供應商", keys("SELECT OBJECTID FROM exp.CDHDR"), used_v)
check("CDPOS 跟 CDHDR 同一批", keys("SELECT CHANGENR FROM exp.CDPOS"), keys("SELECT CHANGENR FROM exp.CDHDR"))
pairs = one("""SELECT COUNT(*) FROM dbo.A017 a WHERE EXISTS (
                   SELECT 1 FROM exp.EKKO k JOIN exp.EKPO p ON p.EBELN = k.EBELN
                   WHERE k.LIFNR = a.LIFNR AND p.MATNR = a.MATNR
                   UNION ALL SELECT 1 FROM exp.EBAN r WHERE r.FLIEF = a.LIFNR AND r.MATNR = a.MATNR)""")[0][0]
check("A017 只帶同一張單據上一起出現的組合（不是供應商 × 物料）",
      one("""SELECT COUNT(*) FROM exp.A017 a WHERE NOT EXISTS (
               SELECT 1 FROM exp.EKKO k JOIN exp.EKPO p ON p.EBELN = k.EBELN
               WHERE k.LIFNR = a.LIFNR AND p.MATNR = a.MATNR
               UNION ALL SELECT 1 FROM exp.EBAN r WHERE r.FLIEF = a.LIFNR AND r.MATNR = a.MATNR)""")[0][0], 0)
check("A017 比供應商 × 物料少", pairs < len(used_v) * len(used_m), True)
check("A017 筆數 = 用到的組合（已超過 @Rows 不補）", one("SELECT COUNT(*) FROM exp.A017")[0][0], pairs)
check("KONP 跟 A017 + A018 同一批、KONH 只有 A017 的（測試資料 A018 沒建 KONH）",
      (keys("SELECT KNUMH FROM exp.KONP"), keys("SELECT KNUMH FROM exp.KONH")),
      (keys("SELECT KNUMH FROM exp.A017 UNION SELECT KNUMH FROM exp.A018"), keys("SELECT KNUMH FROM exp.A017")))
check("A018 沒有用到的組合時隨機補到 @Rows 筆", (res["dbo.A018"][0], res["dbo.A018"][1]),
      (5, "用到的 0 筆 + 隨機補 5 筆"))
check("KONP 跟著補進來的 A018", one("SELECT COUNT(*) FROM exp.KONP WHERE KNUMH LIKE 'Q%'")[0][0], 5)
check("EINE 跟 EINA 同一批", keys("SELECT INFNR FROM exp.EINE"), keys("SELECT INFNR FROM exp.EINA"))
check("T001 整張", one("SELECT COUNT(*) FROM exp.T001")[0][0], 1)

check("業務表 PO 跟 exp.EKKO 同一批", keys("SELECT DISTINCT PoNumber FROM exp.PurchaseOrderDetail"), po_set)
check("業務表 PR 跟 exp.EBAN 同一批", keys("SELECT DISTINCT PrNumber FROM exp.PurchaseRequisition"), pr_rand)
check("業務表收貨的 PO 都在 exp.EKKO",
      keys("SELECT DISTINCT PoNumber FROM exp.GoodsReceipt"), po_set)
check("物料憑證、傳票引用的 PO 都在 exp.EKKO",
      one("""SELECT COUNT(*) FROM (SELECT EBELN FROM exp.MSEG UNION SELECT EBELN FROM exp.BSEG
                                   UNION SELECT EBELN FROM exp.EKPO) x
             WHERE x.EBELN IS NOT NULL AND x.EBELN NOT IN (SELECT EBELN FROM exp.EKKO)""")[0][0], 0)
check("業務表物料異動跟 exp.MKPF 同一批",
      keys("SELECT DISTINCT MaterialDoc FROM exp.MaterialMovement"), keys("SELECT MBLNR FROM exp.MKPF"))
check("業務表 AP 跟 exp.BKPF 同一批",
      keys("SELECT DISTINCT AccountingDoc FROM exp.AccountsPayable"), keys("SELECT BELNR FROM exp.BKPF"))
check("業務表 Vendor", keys("SELECT DISTINCT Vendor FROM exp.Vendor"), used_v)
check("業務表 VendorChangeHistory", keys("SELECT DISTINCT Vendor FROM exp.VendorChangeHistory"), used_v)
check("業務表 Material、InventoryBalance",
      (keys("SELECT Material FROM exp.Material"), keys("SELECT Material FROM exp.InventoryBalance")),
      (used_m, used_m))
check("業務表條件 A017 跟 exp.A017 同一批",
      keys("SELECT ConditionRecord FROM exp.PurchasingCondA017"), keys("SELECT KNUMH FROM exp.A017"))
check("業務表資訊記錄跟 exp.EINA 同一批",
      keys("SELECT InfoRecord FROM exp.PurchasingInfoRecord"), keys("SELECT INFNR FROM exp.EINA"))

# 同一個 seed 抽同一批；換 seed 換一批；不給 seed 會自己產生
before = (po_set, keys("SELECT MBLNR FROM exp.MKPF"), keys("SELECT BELNR FROM exp.BKPF"))
sample(5, 42)
check("同一個 seed 抽同一批",
      (keys("SELECT EBELN FROM exp.EKKO"), keys("SELECT MBLNR FROM exp.MKPF"), keys("SELECT BELNR FROM exp.BKPF")),
      before)
sample(5, 7)
check("換 seed 換一批", keys("SELECT EBELN FROM exp.EKKO") != po_set, True)
seed = {r[4] for r in one("EXEC exp.SampleAll @Rows = 5")}
check("不給 seed 也會列出用的是哪一個", len(seed) == 1 and None not in seed, True)
res = sample(40, 3)
used_a = keys("SELECT DISTINCT ANLN1 + '-' + ANLN2 FROM exp.EKKN WHERE ANLN1 IS NOT NULL")
check("ANLA 補到 40 筆，說明列出用到幾筆、補幾筆",
      (res["dbo.ANLA"][0], res["dbo.ANLA"][1]),
      (40, f"用到的 {len(used_a)} 筆 + 隨機補 {40 - len(used_a)} 筆"))
res = sample(2, 3)
used_a = keys("SELECT DISTINCT ANLN1 + '-' + ANLN2 FROM exp.EKKN WHERE ANLN1 IS NOT NULL")
check("ANLA 用到的已經夠 @Rows 時全留、不補不砍",
      (one("SELECT COUNT(*) FROM exp.ANLA")[0][0], res["dbo.ANLA"][1]), (len(used_a), None))
sample(1000, 1)
check("@Rows 比資料多時整張都抽", one("SELECT COUNT(*) FROM exp.EKKO")[0][0], N)
check("只動 exp，原表沒變", one("SELECT COUNT(*) FROM dbo.EKKO")[0][0], N)

# 其他表
sample(5, 42)
check("LFBK 只帶用到的供應商", keys("SELECT LIFNR FROM exp.LFBK"),
      keys("SELECT LIFNR FROM exp.LFA1"))
check("MBEWH 沒有 MATNR 時退回隨機 5 筆", one("SELECT COUNT(*) FROM exp.MBEWH")[0][0], 5)
used_a = keys("SELECT DISTINCT ANLN1 + '-' + ANLN2 FROM exp.EKKN WHERE ANLN1 IS NOT NULL")
got_a = keys("SELECT ANLN1 + '-' + ANLN2 FROM exp.ANLA")
check("ANLA 用到的資產都在（子編號也比對）", set(used_a) <= set(got_a), True)
check("ANLA 用到的不足 5 筆時補到 5 筆、不重複",
      (len(got_a), len(set(got_a))), (max(5, len(used_a)),) * 2)
check("T001W 整張", one("SELECT COUNT(*) FROM exp.T001W")[0][0], 2)
check("ADT_ECAR 隨機 5 筆、欄位全帶",
      (one("SELECT COUNT(*) FROM exp.ADT_ECAR")[0][0],
       one("SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('exp.ADT_ECAR')")[0][0]), (5, 4))
ecar = keys("SELECT Id FROM exp.ADT_ECAR")
res = sample(5, 42)
check("ADT_ECAR 同一個 seed 抽同一批", keys("SELECT Id FROM exp.ADT_ECAR"), ecar)
check("不存在的 ZTM80 跳過", res["dbo.ZTM80"][:2], (None, "來源表不存在，跳過"))
sample(5, 7)
check("ADT_ECAR 換 seed 換一批", keys("SELECT Id FROM exp.ADT_ECAR") != ecar, True)

cn.close()
sqlcmd("-Q", f"ALTER DATABASE {DB} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE {DB};")
print(f"\n{sum(checks)}/{len(checks)} 通過")
sys.exit(0 if all(checks) else 1)
