"""在 LocalDB 測 20_sample_exp.sql：業務表各抽 N 筆、原表從業務表回推，同一個 seed 抽同一批。

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
        # 兩筆排程：測一對多的原表
        ins("EKET", [{"EBELN": po(i), "EBELP": item, "EINDT": "2025-04-01"},
                     {"EBELN": po(i), "EBELP": item, "EINDT": "2025-05-01"}])
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
cur.execute("CREATE TABLE dbo.ADT_ECAR (Id INT, Amount DECIMAL(18,2), Memo NVARCHAR(MAX), Dt DATETIME2, Extra NVARCHAR(10))")
for i in range(50):
    # 只有 10 筆是完整的，其他缺 Memo：測空欄位少的優先
    ins("ADT_ECAR", [{"Id": i, "Amount": i * 1.5, "Memo": f"備註{i}" if i % 5 == 0 else None, "Dt": "2025-01-01"}])
# 這 10 筆 Memo、Dt 都有，只缺 Amount：沒設重要欄位時最完整，設了 Amount 重要就排後面
for i in range(100, 110):
    ins("ADT_ECAR", [{"Id": i, "Amount": None, "Memo": f"完整{i}", "Dt": "2025-01-01", "Extra": "x"}])
cur.execute("UPDATE dbo.ADT_ECAR SET Dt = NULL WHERE Id < 100")
for i in range(50):
    ins("MBEWH", [{"MATERIAL": f"X{i}", "LFGJA": "2024"}])

for i in range(40):           # A018 都跟抽到的單據無關，測補到 @Rows
    ins("A018", [{"LIFNR": "V9999", "MATNR": "M99999", "EKORG": "TW01", "ESOKZ": "0", "KSCHL": "PB00",
                  "DATAB": f"20{i:02d}-01-01", "DATBI": f"20{i:02d}-12-31", "KNUMH": f"Q{i:09d}"}])
    ins("KONP", [{"KNUMH": f"Q{i:09d}", "KOPOS": "01", "KBETR": 5, "KONWA": "TWD", "KPEIN": 1}])

for f in ("01_create_tables.sql", "02_load_procedures.sql", "20_sample_exp.sql"):
    sqlcmd("-i", str(SQL / f), db=DB)
cur.execute("EXEC etl.LoadAll").fetchall()
# 後 20 張 PO 缺匯率：測業務表空欄位少的優先
cur.execute("UPDATE prc.PurchaseOrderDetail SET ExchangeRate = NULL WHERE PoNumber > '4500000009'")

checks = []


def one(sql, *params):
    return cur.execute(sql, *params).fetchall()


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


def cnt(sql, *p):
    return one(sql, *p)[0][0]


def pairs(sql):
    return sorted(tuple(r) for r in one(sql))


# ---- 1. 業務表：剛好 min(5, 整張) 筆；跟 PO 有關的優先 ----
LINK = {
    "prc.PurchaseRequisition": "EXISTS (SELECT 1 FROM exp.PurchaseOrderDetail k WHERE k.PrNumber = t.PrNumber AND k.PrItem = t.PrItem)",
    "prc.GoodsReceipt": "EXISTS (SELECT 1 FROM exp.PurchaseOrderDetail k WHERE k.PoNumber = t.PoNumber AND k.PoItem = t.PoItem)",
    "fin.AccountsPayable": "t.PoNumber IN (SELECT PoNumber FROM exp.PurchaseOrderDetail)",
    "inv.MaterialMovement": "EXISTS (SELECT 1 FROM exp.GoodsReceipt k WHERE k.MaterialDoc = t.MaterialDoc AND k.MaterialDocItem = t.MaterialDocItem)",
    "mst.Vendor": "t.Vendor IN (SELECT Vendor FROM exp.PurchaseOrderDetail UNION SELECT Vendor FROM exp.PurchaseRequisition"
                  " UNION SELECT Vendor FROM exp.GoodsReceipt UNION SELECT Vendor FROM exp.AccountsPayable)",
    "mst.VendorChangeHistory": "t.Vendor IN (SELECT Vendor FROM exp.Vendor)",
    "mst.Material": "t.Material IN (SELECT Material FROM exp.PurchaseOrderDetail UNION SELECT Material FROM exp.PurchaseRequisition"
                    " UNION SELECT Material FROM exp.MaterialMovement)",
    "inv.InventoryBalance": "t.Material IN (SELECT Material FROM exp.Material)",
}
PAIR = ("EXISTS (SELECT 1 FROM (SELECT Vendor, Material FROM exp.PurchaseOrderDetail"
        " UNION SELECT Vendor, Material FROM exp.PurchaseRequisition) k WHERE k.Vendor = t.Vendor AND k.Material = t.Material)")
for t in ("mst.PurchasingInfoRecord", "mst.PurchasingCondA017", "mst.PurchasingCondA018"):
    LINK[t] = PAIR

check("PO 明細剛好 5 筆", cnt("SELECT COUNT(*) FROM exp.PurchaseOrderDetail"), 5)
check("PO 明細空欄位少的優先（5 筆都有匯率）",
      cnt("SELECT COUNT(*) FROM exp.PurchaseOrderDetail WHERE ExchangeRate IS NOT NULL"), 5)
for t, cond in LINK.items():
    name = t.split(".")[1]
    total = cnt(f"SELECT COUNT(*) FROM {t}")
    linked = cnt(f"SELECT COUNT(*) FROM {t} t WHERE {cond}")
    got = cnt(f"SELECT COUNT(*) FROM exp.{name}")
    # exp 裡的列對回業務表，看有幾筆符合關聯
    got_linked = cnt(f"SELECT COUNT(*) FROM exp.{name} t WHERE {cond}")
    check(f"業務表 {name}：{min(5, total)} 筆、有關聯的 {min(5, linked)} 筆優先", (got, got_linked),
          (min(5, total), min(5, linked)))

# ---- 2. 原表從業務表回推 ----
po_keys = pairs("SELECT PoNumber, PoItem FROM exp.PurchaseOrderDetail")
check("EKKO = 業務表 PO 的表頭", keys("SELECT EBELN FROM exp.EKKO"), sorted({k[0] for k in po_keys}))
check("EKPO = 業務表 PO 的項目（一對一）", pairs("SELECT EBELN, EBELP FROM exp.EKPO"), po_keys)
check("EKKN 一個項目一筆", pairs("SELECT EBELN, EBELP FROM exp.EKKN"), po_keys)
check("EKET 一對多照實際帶（一個項目兩筆排程）", cnt("SELECT COUNT(*) FROM exp.EKET"), 2 * len(po_keys))
check("EKBE 只有 00010 有收貨", pairs("SELECT EBELN, EBELP FROM exp.EKBE"), [k for k in po_keys if k[1] == "00010"])
check("EBAN = 業務表 PR", pairs("SELECT BANFN, BNFPO FROM exp.EBAN"),
      pairs("SELECT PrNumber, PrItem FROM exp.PurchaseRequisition"))
check("EBKN = 業務表 PR", pairs("SELECT BANFN, BNFPO FROM exp.EBKN"),
      pairs("SELECT PrNumber, PrItem FROM exp.PurchaseRequisition"))
mdi = pairs("SELECT MaterialDoc, MaterialDocItem FROM exp.GoodsReceipt UNION SELECT MaterialDoc, MaterialDocItem FROM exp.MaterialMovement")
check("MSEG = 收貨 + 物料異動的項目", pairs("SELECT MBLNR, ZEILE FROM exp.MSEG"), mdi)
check("MKPF = 這些物料憑證", keys("SELECT MBLNR FROM exp.MKPF"), sorted({k[0] for k in mdi}))
check("MSEG 不超過 5 筆（物料異動先帶收貨那幾筆）", cnt("SELECT COUNT(*) FROM exp.MSEG") <= 5, True)
ap_docs = keys("SELECT DISTINCT AccountingDoc FROM exp.AccountsPayable")
check("BKPF = 業務表應付的傳票", keys("SELECT BELNR FROM exp.BKPF"), ap_docs)
check("BSEG 帶整張傳票（供應商行 + 費用行）", cnt("SELECT COUNT(*) FROM exp.BSEG"), 2 * len(ap_docs))
vend = keys("SELECT DISTINCT Vendor FROM exp.Vendor")
for t in ("LFA1", "LFB1", "LFM1"):
    check(f"{t} = 業務表 Vendor", keys(f"SELECT LIFNR FROM exp.{t}"), vend)
check("CDHDR = 業務表異動紀錄", keys("SELECT CHANGENR FROM exp.CDHDR"),
      keys("SELECT ChangeNumber FROM exp.VendorChangeHistory"))
check("CDPOS 只帶異動紀錄那幾筆（MATERIAL 類不帶）", keys("SELECT CHANGENR FROM exp.CDPOS"),
      keys("SELECT ChangeNumber FROM exp.VendorChangeHistory"))
mat = keys("SELECT Material FROM exp.Material")
check("MARA、MAKT = 業務表 Material", (keys("SELECT MATNR FROM exp.MARA"), keys("SELECT MATNR FROM exp.MAKT")), (mat, mat))
inv = keys("SELECT Material FROM exp.InventoryBalance")
for t in ("MARC", "MARD", "MBEW"):
    check(f"{t} = 業務表 InventoryBalance", keys(f"SELECT MATNR FROM exp.{t}"), inv)
check("EINA、EINE = 業務表資訊記錄",
      (keys("SELECT INFNR FROM exp.EINA"), keys("SELECT INFNR FROM exp.EINE")),
      (keys("SELECT InfoRecord FROM exp.PurchasingInfoRecord"),) * 2)
check("A017 = 業務表條件 A017", keys("SELECT KNUMH FROM exp.A017"),
      keys("SELECT ConditionRecord FROM exp.PurchasingCondA017"))
check("A018 = 業務表條件 A018", keys("SELECT KNUMH FROM exp.A018"),
      keys("SELECT ConditionRecord FROM exp.PurchasingCondA018"))
check("KONP = A017 + A018", keys("SELECT KNUMH FROM exp.KONP"),
      keys("SELECT KNUMH FROM exp.A017 UNION SELECT KNUMH FROM exp.A018"))
check("T001、T001W 整張", (cnt("SELECT COUNT(*) FROM exp.T001"), cnt("SELECT COUNT(*) FROM exp.T001W")), (1, 2))
for t in ("EKKO", "EKPO", "EBAN", "MSEG", "MKPF", "BKPF", "LFA1", "LFB1", "LFM1", "CDHDR", "CDPOS",
          "MARA", "MARC", "MARD", "EINA", "EINE", "A017", "A018"):
    check(f"一對一的 {t} 不超過 5 筆", cnt(f"SELECT COUNT(*) FROM exp.{t}") <= 5, True)

# ---- 3. 沒組進業務表的 ----
check("LFBK 先帶 exp.LFA1 的供應商，再補到 5 筆",
      (set(keys("SELECT LIFNR FROM exp.LFA1")) <= set(keys("SELECT LIFNR FROM exp.LFBK")),
       cnt("SELECT COUNT(*) FROM exp.LFBK")), (True, 5))
check("MBEWH 沒有 MATNR 時退回隨機 5 筆", cnt("SELECT COUNT(*) FROM exp.MBEWH"), 5)
used_a = keys("SELECT DISTINCT ANLN1 + '-' + ANLN2 FROM exp.EKKN WHERE ANLN1 IS NOT NULL")
got_a = keys("SELECT ANLN1 + '-' + ANLN2 FROM exp.ANLA")
check("ANLA 剛好 5 筆、不重複、EKKN 用到的都在",
      (len(got_a), len(set(got_a)), set(used_a) <= set(got_a)), (5, 5, True))
check("ADT_ECAR 隨機 5 筆、欄位全帶",
      (cnt("SELECT COUNT(*) FROM exp.ADT_ECAR"),
       cnt("SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('exp.ADT_ECAR')")), (5, 5))
check("不存在的 ZTM80 跳過", res["dbo.ZTM80"][:2], (None, "來源表不存在，跳過"))

# ---- 重要欄位 ----
ecar = keys("SELECT Id FROM exp.ADT_ECAR")
check("沒設重要欄位時只看全部欄位：挑到只缺 Amount 的", all(i >= 100 for i in ecar), True)
cur.execute("INSERT exp.ImportantColumn VALUES ('ADT_ECAR', 'Amount')")
sample(5, 42)
ecar = keys("SELECT Id FROM exp.ADT_ECAR")
check("設了重要欄位：重要欄位有值的優先，再看全部欄位", all(i < 100 and i % 5 == 0 for i in ecar), True)
check("重要欄位預設帶入 ETL 用到的欄位",
      cnt("SELECT COUNT(*) FROM exp.ImportantColumn WHERE TableName = 'EKKO' AND ColumnName = 'WKURS'"), 1)
sqlcmd("-i", str(SQL / "20_sample_exp.sql"), db=DB)
check("重跑 20 不會蓋掉自己加的重要欄位",
      cnt("SELECT COUNT(*) FROM exp.ImportantColumn WHERE TableName = 'ADT_ECAR'"), 1)

# ---- seed ----
po_before = pairs("SELECT PoNumber, PoItem FROM exp.PurchaseOrderDetail")
sample(5, 42)
check("同一個 seed 抽同一批（PO、ADT）",
      (pairs("SELECT PoNumber, PoItem FROM exp.PurchaseOrderDetail"), keys("SELECT Id FROM exp.ADT_ECAR")),
      (po_before, ecar))
sample(5, 7)
check("換 seed 換一批", (pairs("SELECT PoNumber, PoItem FROM exp.PurchaseOrderDetail") != po_before,
                       keys("SELECT Id FROM exp.ADT_ECAR") != ecar), (True, True))
seed = {r[4] for r in one("EXEC exp.SampleAll @Rows = 5")}
check("不給 seed 也會列出用的是哪一個", len(seed) == 1 and None not in seed, True)

# ---- @CapRaw ----
res = {r[0]: r for r in one("EXEC exp.SampleAll @Rows = 5, @Seed = 42, @CapRaw = 1")}
check("@CapRaw = 1 一對多的 EKET 也砍到 5 筆", (cnt("SELECT COUNT(*) FROM exp.EKET"), res["dbo.EKET"][3]),
      (5, "用到的 10 筆，隨機留 5 筆"))
check("@CapRaw = 1 不足的不補（EKBE）", cnt("SELECT COUNT(*) FROM exp.EKBE") <= 5, True)

# ---- @PreferFilled = 0 ----
res = {r[0]: r for r in one("EXEC exp.SampleAll @Rows = 5, @Seed = 42, @PreferFilled = 0")}
check("@PreferFilled = 0 不挑，抽得到缺 Memo 的",
      any(i % 5 and i < 100 for i in keys("SELECT Id FROM exp.ADT_ECAR")), True)
check("@PreferFilled = 0 說明只寫隨機", res["dbo.ADT_ECAR"][3], "隨機")

sample(1000, 1)
check("@Rows 比資料多時整張都抽", (cnt("SELECT COUNT(*) FROM exp.PurchaseOrderDetail"),
                                cnt("SELECT COUNT(*) FROM exp.EKKO")), (2 * N, N))
check("只動 exp，原表沒變", cnt("SELECT COUNT(*) FROM dbo.EKKO"), N)

cn.close()
sqlcmd("-Q", f"ALTER DATABASE {DB} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE {DB};")
print(f"\n{sum(checks)}/{len(checks)} 通過")
sys.exit(0 if all(checks) else 1)
