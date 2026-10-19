"""在 LocalDB 建暫存資料庫跑 01/10/11/12，塞會觸發與不該觸發的資料，驗證第一期 KRI。

    python etl/test_kri.py

只碰 (localdb)\\MSSQLLocalDB 上的 kri_test_scratch，跑完會刪掉。
資料直接塞進業務表（prc / mst），不經過 ETL，KRI 的邏輯才測得乾淨。
"""
import subprocess
import sys
from pathlib import Path

import pyodbc

SQL = Path(__file__).parent / "sql"
SERVER = r"(localdb)\MSSQLLocalDB"
DB = "kri_test_scratch"
AS_OF = "2025-12-31"


def sqlcmd(*args, db="master"):
    r = subprocess.run(["sqlcmd", "-S", SERVER, "-d", db, "-b", "-f", "65001", *args],
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode:
        sys.exit(f"sqlcmd 失敗：{args}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def run_file(name):
    sqlcmd("-i", str(SQL / name), db=DB)


sqlcmd("-Q", f"IF DB_ID('{DB}') IS NOT NULL BEGIN ALTER DATABASE {DB} SET SINGLE_USER "
             f"WITH ROLLBACK IMMEDIATE; DROP DATABASE {DB}; END; CREATE DATABASE {DB};")
cn = pyodbc.connect(f"Driver={{ODBC Driver 17 for SQL Server}};Server={SERVER};"
                    f"Database={DB};Trusted_Connection=yes", autocommit=True)
cur = cn.cursor()

cur.execute("CREATE TABLE dbo.T001 (BUKRS NVARCHAR(10), WAERS NVARCHAR(5))")
cur.execute("INSERT dbo.T001 VALUES ('1000','TWD'), ('2000','TWD'), ('3000','JPY')")
for f in ("01_create_tables.sql", "10_kri_framework.sql", "11_kri_procedures.sql", "12_kri_seed.sql"):
    run_file(f)


def ins(table, rows):
    for row in rows:
        cols = ", ".join(row)
        cur.execute(f"INSERT {table} ({cols}) VALUES ({', '.join('?' * len(row))})", *row.values())


def po(number, item="00010", **kw):
    base = dict(PoNumber=number, PoItem=item, CompanyCode="1000", PurchOrg="TW01", Plant="1100",
                Vendor="V1", OrderUom="EA", Currency="TWD", ExchangeRate=1, PriceUnit=1,
                PoDate="2025-03-01", OrderQty=100)
    base.update(kw)
    if "NetValue" not in base and "NetPrice" in base:
        base["NetValue"] = base["NetPrice"] * base["OrderQty"] / base["PriceUnit"]
    return base


def cond(**kw):
    base = dict(Vendor="V1", PurchOrg="TW01", InfoCategory="0", ConditionType="PB00",
                ValidFrom="2025-01-01", ValidTo="9999-12-31", Currency="TWD", PriceUnit=1,
                OrderUom="EA", CreatedOn="2024-12-01")
    base.update(kw)
    return base


# ---------------------------------------------------------------- K14
ins("prc.PurchaseOrderDetail", [
    po("4500000001", "00010", Material="M1", NetPrice=120),          # 高 20% → 標記
    po("4500000001", "00020", Material="M1", NetPrice=105),          # 剛好 5% → 不標記
    po("4500000002", Material="M2", Plant="1200", NetPrice=150, PriceUnit=100),  # A018，單價 1.5 vs 1
    po("4500000003", Material="M3", NetPrice=10),                    # 無主檔價
    po("4500000004", Material="M4", NetPrice=10, Currency="USD", ExchangeRate=31.5),  # 幣別不同
    po("4500000005", Material="M5", NetPrice=10, OrderUom="BOX"),    # 單位不同
    po("4500000006", Material="M6", NetPrice=12, OrderQty=10, Currency="USD", ExchangeRate=31.5),
    po("4500000007", Material="M7", NetPrice=11, OrderQty=10, Currency="EUR", ExchangeRate=-0.5),
    po("4500000008", Material="M1", NetPrice=999, DeletionInd="L"),  # 已刪除
    po("4500000009", Material="M1", NetPrice=999, Vendor="X00001"),  # 排除的供應商前綴
])
ins("mst.PurchasingCondA017", [
    cond(Material="M1", Plant="1100", ConditionRecord="0000500001", ConditionPrice=100),
    # 不在白名單的條件類型，而且生效日更近：不能被拿來用
    cond(Material="M1", Plant="1100", ConditionRecord="0000500002", ConditionType="ZPB0",
         ValidFrom="2025-02-01", ConditionPrice=50),
    cond(Material="M4", Plant="1100", ConditionRecord="0000500004", ConditionPrice=10),
    cond(Material="M5", Plant="1100", ConditionRecord="0000500005", ConditionPrice=10),
    cond(Material="M6", Plant="1100", ConditionRecord="0000500006", ConditionPrice=10, Currency="USD"),
    cond(Material="M7", Plant="1100", ConditionRecord="0000500007", ConditionPrice=10, Currency="EUR"),
])
ins("mst.PurchasingCondA018", [
    cond(Material="M2", ConditionRecord="0000510002", ConditionPrice=10, PriceUnit=10),
])
cur.execute("INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('K14', 'ExcludeVendorPrefix', 'X')")

# ---------------------------------------------------------------- K13
ins("prc.PurchaseOrderDetail", [
    po("4510000001", Material="M20", NetPrice=10, CompanyCode="1000", PoDate="2025-02-01"),
    po("4510000002", Material="M20", NetPrice=13, CompanyCode="2000", PoDate="2025-02-10"),  # 剛好 30%
    po("4510000003", Material="M20", NetPrice=14, CompanyCode="2000", PoDate="2025-03-10"),  # 40% → 標記
    po("4510000004", Material="M20", NetPrice=50, CompanyCode="2000", OrderQty=5),          # 不同數量級距
    po("4510000005", Material="M20", NetPrice=30, CompanyCode="1000", PoDate="2025-08-01"),  # 不同季度
])

# ---------------------------------------------------------------- K18
ins("prc.PurchaseOrderDetail", [
    po("4520000001", Material="M40", NetPrice=5, GrQty=20, DelivDate="2025-10-01"),   # 逾期 91 天、收 20% → 標記
    po("4520000002", Material="M40", NetPrice=5, GrQty=60, DelivDate="2025-10-01"),   # 收 60%
    po("4520000003", Material="M40", NetPrice=5, GrQty=0, DelivDate="2025-12-15"),    # 只逾期 16 天
    po("4520000004", Material="M40", NetPrice=5, GrQty=0, DelivDate="2025-01-01", DelivComplInd="X"),
    po("4520000005", Material="M40", NetPrice=5, GrQty=100, DelivDate="2025-01-01"),  # 已收齊
])

# ---------------------------------------------------------------- K08
ins("kri.ApprovalMatrix", [
    dict(DocType="PR", Currency="TWD", MinAmount=0, MaxAmount=10000, ApprovalLevel=1),
    dict(DocType="PR", Currency="TWD", MinAmount=10000, MaxAmount=100000, ApprovalLevel=2),
    dict(DocType="PR", Currency="TWD", MinAmount=100000, MaxAmount=999999999999, ApprovalLevel=3),
])


def pr(number, date, cc, vendor, amount, **kw):
    base = dict(PrNumber=number, PrItem="00010", PrDate=date, CostCenter=cc, Vendor=vendor,
                ReqQty=1, ValPrice=amount, Currency="TWD", Plant="1100", PurchOrg="TW01", Material="M50")
    base.update(kw)
    return base


ins("prc.PurchaseRequisition", [
    pr("1000000001", "2025-05-01", "CC1", "V1", 6000),
    pr("1000000002", "2025-05-10", "CC1", "V1", 6000),     # 30 天內合計 12000 → 第 2 層 → 標記
    pr("1000000003", "2025-07-01", "CC1", "V1", 6000),     # 前 30 天沒有別張
    pr("1000000006", "2025-05-05", "CC2", "V1", 6000),     # 不同成本中心
    pr("1000000004", "2025-08-01", "CC3", None, 9000, PoNumber="4500000001", PoItem="00010"),  # 供應商從 PO 帶
    pr("1000000005", "2025-08-15", "CC3", "V1", 9000),     # 合計 18000 → 標記
    pr("1000000007", "2025-05-09", "CC1", "V1", 6000, DeletionInd="X"),  # 已刪除
])

# ---------------------------------------------------------------- K21
ins("mst.PurchasingCondA017", [
    cond(Material="M30", Plant="1100", ConditionRecord="0000600001", ConditionPrice=10,
         ValidFrom="2025-03-01", CreatedOn="2025-05-01", CreatedBy="BUYER1"),     # 倒填 61 天 → 標記
    cond(Material="M31", Plant="1100", ConditionRecord="0000600002", ConditionPrice=10,
         ValidFrom="2025-03-01", CreatedOn="2025-03-11"),                         # 只倒填 10 天
    cond(Material="M32", Plant="1100", ConditionRecord="0000600004", ConditionPrice=10,
         ValidFrom="2024-01-01", CreatedOn="2024-06-01"),                         # 不在觀察期間建立
    cond(Material="M33", Plant="1100", ConditionRecord="0000600005", ConditionPrice=10, ConditionType="ZPB0",
         ValidFrom="2025-03-01", CreatedOn="2025-06-01"),                         # 不在白名單
])
ins("mst.PurchasingCondA018", [
    cond(Material="M34", ConditionRecord="0000600003", ConditionPrice=10,
         ValidFrom="2025-06-01", CreatedOn="2025-08-01"),                         # 倒填 61 天 → 標記
])
ins("prc.PurchaseOrderDetail", [
    po("4530000001", Material="M30", NetPrice=10, PoDate="2025-03-15"),           # 倒填期間內
    po("4530000002", Material="M30", NetPrice=5, PoDate="2025-04-20"),            # 倒填期間內
    po("4530000003", Material="M30", NetPrice=10, PoDate="2025-05-02"),           # 建立之後
    po("4530000004", Material="M30", NetPrice=10, PoDate="2025-04-01", Plant="1200"),  # A017 是分工廠的
    po("4530000005", Material="M34", NetPrice=10, PoDate="2025-06-10", Plant="1100"),
    po("4530000006", Material="M34", NetPrice=10, PoDate="2025-07-10", Plant="1200"),  # A018 不分工廠
])


# ---------------------------------------------------------------- 驗證
def one(sql, *a):
    return cur.execute(sql, *a).fetchall()


checks = []


def check(name, got, want):
    ok = got == want
    checks.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {got!r}" + ("" if ok else f"  (預期 {want!r})"))


def run(only=None):
    sql = "EXEC kri.RunAll @AsOfDate = ?" + (", @Only = ?" if only else "")
    rows = cur.execute(sql, AS_OF, *([only] if only else [])).fetchall()
    return {r[0]: r for r in rows}, one("SELECT MAX(RunId) FROM kri.Run")[0][0]


res, rid = run()
for code, r in res.items():
    print(f"  {code} {r[1]:<14} 明細 {r[4]}  標記 {r[5]}  {r[6]}  {r[7] or ''}")
check("五題都成功", sorted((c, r[6]) for c, r in res.items()),
      [(c, "OK") for c in ("K08", "K13", "K14", "K18", "K21")])

# K14
d = {(x.PoNumber, x.PoItem): x for x in one("SELECT * FROM kri.K14_Detail WHERE RunId = ?", rid)}
check("K14 高 20% 標記、影響 2000", (d[("4500000001", "00010")].IsFlagged,
                                    float(d[("4500000001", "00010")].EffectLocal)), (True, 2000.0))
check("K14 不在白名單的 ZPB0 不會被拿來比", float(d[("4500000001", "00010")].InfoUnitPrice), 100.0)
check("K14 剛好等於門檻不標記", d[("4500000001", "00020")].IsFlagged, False)
x = d[("4500000002", "00010")]
check("K14 找不到 A017 改用 A018、兩邊價格單位都換算", (x.InfoSource, float(x.PoUnitPrice),
                                                    float(x.InfoUnitPrice), x.IsFlagged), ("A018", 1.5, 1.0, True))
check("K14 比不了的列留在明細並註明原因",
      [d[(n, "00010")].MatchStatus for n in ("4500000003", "4500000004", "4500000005")],
      ["無主檔價", "幣別不同", "單位不同"])
check("K14 外幣換本幣（直接報價 ×31.5）", float(d[("4500000006", "00010")].EffectLocal), 630.0)
check("K14 外幣換本幣（間接報價 ÷0.5）", float(d[("4500000007", "00010")].EffectLocal), 20.0)
check("K14 已刪除、排除前綴的 PO 不在母體",
      [k for k in d if k[0] in ("4500000008", "4500000009")], [])
check("K14 備註列出比對覆蓋率", res["K14"][7].startswith("已比對 "), True)

# K13
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K13_Detail WHERE RunId = ?", rid)}
check("K13 只有同群組有兩個以上據點的進明細", sorted(d), ["4510000001", "4510000002", "4510000003"])
check("K13 高 40% 標記、跟其他據點最低價 10 比", (d["4510000003"].IsFlagged,
      d["4510000003"].OtherEntity, float(d["4510000003"].OtherMinPrice)), (True, "1000", 10.0))
check("K13 剛好 30% 不標記", d["4510000002"].IsFlagged, False)
check("K13 最便宜的據點跟第二便宜的比", (d["4510000001"].OtherEntity,
      float(d["4510000001"].OtherMinPrice), d["4510000001"].IsFlagged), ("2000", 13.0, False))
check("K13 影響金額 (14-10)×100", float(d["4510000003"].EffectLocal), 400.0)

# K18
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K18_Detail WHERE RunId = ?", rid)}
check("K18 只有未結案、已過交貨日的進明細", sorted(d), ["4520000001", "4520000002", "4520000003"])
check("K18 逾期 91 天收 20% 標記、影響 80×5", (d["4520000001"].IsFlagged, d["4520000001"].OverdueDays,
                                              float(d["4520000001"].EffectLocal)), (True, 91, 400.0))
check("K18 收 60%、逾期 16 天都不標記", (d["4520000002"].IsFlagged, d["4520000003"].IsFlagged), (False, False))

# K08
d = {x.PrNumber: x for x in one("SELECT * FROM kri.K08_Detail WHERE RunId = ?", rid)}
check("K08 候選：視窗內有兩張以上的", sorted(d), ["1000000002", "1000000005"])
check("K08 合計 12000 第 2 層 > 單筆第 1 層", (d["1000000002"].WindowLevel, d["1000000002"].OwnLevel,
                                             d["1000000002"].IsFlagged), (2, 1, True))
check("K08 PR 沒填供應商時用 PO 的供應商分群", (float(d["1000000005"].WindowAmount), d["1000000005"].IsFlagged),
      (18000.0, True))

# K21
d = {x.ConditionRecord: x for x in one("SELECT * FROM kri.K21_Detail WHERE RunId = ?", rid)}
check("K21 明細：觀察期間建立、倒填、在白名單", sorted(d), ["0000600001", "0000600002", "0000600003"])
check("K21 倒填 61 天標記、期間內 2 筆 PO 共 1500", (d["0000600001"].BackdateDays, d["0000600001"].IsFlagged,
      d["0000600001"].PoCount, float(d["0000600001"].PoAmountLocal)), (61, True, 2, 1500.0))
check("K21 倒填 10 天不標記", d["0000600002"].IsFlagged, False)
check("K21 A018 不分工廠，兩個工廠的 PO 都算", d["0000600003"].PoCount, 2)

# Flag 與 view
r = one("SELECT KriCode, COUNT(*) FROM kri.vFlagLatest GROUP BY KriCode ORDER BY KriCode")
check("vFlagLatest 各題標記數", [(x[0], x[1]) for x in r],
      [("K08", 2), ("K13", 1), ("K14", 4), ("K18", 1), ("K21", 2)])

# ---------------------------------------------------------------- 框架行為
cur.execute("UPDATE kri.Parameter SET ParamValue = 0.25 WHERE KriCode = 'K14' AND ParamName = 'PriceTolerance'")
res, rid2 = run("K14")
flagged = sorted(x.PoNumber for x in one("SELECT PoNumber FROM kri.K14_Detail WHERE RunId = ? AND IsFlagged = 1", rid2))
check("改門檻成 25%：高 20% 的不再標記", flagged, ["4500000002"])
check("vFlagLatest：K14 換成新的 Run，K13 還是上一次", (
    one("SELECT DISTINCT RunId FROM kri.vFlagLatest WHERE KriCode = 'K14'")[0][0],
    one("SELECT DISTINCT RunId FROM kri.vFlagLatest WHERE KriCode = 'K13'")[0][0]), (rid2, rid))

cur.execute("DELETE kri.Parameter WHERE KriCode = 'K18' AND ParamName = 'OverdueDays'")
res, _ = run()
check("缺參數：K18 失敗並指名缺哪個參數", (res["K18"][6], "K18.OverdueDays" in (res["K18"][7] or "")), ("FAILED", True))
check("缺參數：其他題照跑", sorted(c for c, r in res.items() if r[6] == "OK"), ["K08", "K13", "K14", "K21"])
check("Run 狀態為 PARTIAL", one("SELECT Status FROM kri.Run WHERE RunId = (SELECT MAX(RunId) FROM kri.Run)")[0][0], "PARTIAL")
run_file("12_kri_seed.sql")      # 重跑 seed 會把缺的參數補回來

cur.execute("EXEC sp_rename 'mst.PurchasingCondA018', 'PurchasingCondA018_x'")
res, _ = run()
check("A018 不見：用到它的 K14、K21 失敗，其他照跑",
      sorted((c, r[6]) for c, r in res.items()),
      [("K08", "OK"), ("K13", "OK"), ("K14", "FAILED"), ("K18", "OK"), ("K21", "FAILED")])
cur.execute("EXEC sp_rename 'mst.PurchasingCondA018_x', 'PurchasingCondA018'")

cur.execute("DELETE kri.ApprovalMatrix")
res, _ = run("K08")
check("核決權限表空的：K08 不標記並說明原因", (res["K08"][5], "ApprovalMatrix" in res["K08"][7]), (0, True))

cur.execute("UPDATE kri.Definition SET Enabled = 0 WHERE KriCode = 'K13'")
cur.execute("UPDATE kri.Parameter SET ParamValue = 0.99 WHERE KriCode = 'K13' AND ParamName = 'PriceTolerance'")
cur.execute("INSERT kri.ApprovalMatrix (DocType, Currency, MinAmount, MaxAmount, ApprovalLevel) VALUES ('PR','TWD',0,1,1)")
run_file("10_kri_framework.sql")
run_file("12_kri_seed.sql")
check("重跑 10、12 不動已調的門檻、啟用狀態、核決權限", (
    float(one("SELECT ParamValue FROM kri.Parameter WHERE KriCode='K13' AND ParamName='PriceTolerance'")[0][0]),
    one("SELECT Enabled FROM kri.Definition WHERE KriCode='K13'")[0][0],
    one("SELECT COUNT(*) FROM kri.ApprovalMatrix")[0][0]), (0.99, False, 1))
res, _ = run()
check("停用的 K13 不會跑", "K13" in res, False)

cur.execute("UPDATE kri.Parameter SET ParamValue = 2 WHERE KriCode = '*' AND ParamName = 'KeepRuns'")
run(); run()
keep = [x[0] for x in one("SELECT RunId FROM kri.Run ORDER BY RunId")]
check("KeepRuns = 2：只留最近兩次", len(keep), 2)
check("明細、標記跟著清掉", one("SELECT COUNT(*) FROM kri.K14_Detail WHERE RunId < ?", keep[0])[0][0]
      + one("SELECT COUNT(*) FROM kri.Flag WHERE RunId < ?", keep[0])[0][0], 0)

cn.close()
sqlcmd("-Q", f"ALTER DATABASE {DB} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE {DB};")
print(f"\n{sum(checks)}/{len(checks)} 通過")
sys.exit(0 if all(checks) else 1)
