"""在 LocalDB 建暫存資料庫跑 00/01/02，塞會踩到陷阱的資料驗證結果。

    python etl/test_etl.py

只碰 (localdb)\\MSSQLLocalDB 上的 etl_test_scratch，跑完會刪掉。
stg 表照 00_check_staging.sql 的清單建，型別模仿 excel-to-db 匯入的結果。
"""
import re
import subprocess
import sys
from pathlib import Path

import pyodbc

SQL = Path(__file__).parent / "sql"
SERVER = r"(localdb)\MSSQLLocalDB"
DB = "etl_test_scratch"
DATES = {"BEDAT", "BUDAT", "BLDAT", "CPUDT", "EINDT", "BADAT", "LFDAT", "ERDAT", "ERSDA",
         "UDATE", "DATAB", "DATBI", "ZFBDT", "AUGDT"}
NUMS = {"MENGE", "DMBTR", "NETPR", "PEINH", "NETWR", "PREIS", "KBETR", "KPEIN",
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

# 00 在空資料庫上應該回報全部缺
out = sqlcmd("-i", str(SQL / "00_check_staging.sql"), "-h", "-1", "-W", "-s", "|", db=DB)
missing_before = [l for l in out.splitlines() if "|" in l]

# 依 00 的清單建 stg 表（型別模仿 excel-to-db 的結果）
need = re.findall(r"\('(\w+)','(\w+)'(,1)?\)", (SQL / "00_check_staging.sql").read_text("utf-8"))
tables = {}
for t, c, optional in need:
    if not optional:
        tables.setdefault(t, []).append(c)
assert len(missing_before) == len(need), (len(missing_before), len(need))
for t, cols in tables.items():
    # 匯率有 5 位小數，excel-to-db 會給 DECIMAL(18,5)
    defs = ", ".join(f"[{c}] {'DATE' if c in DATES else 'DECIMAL(18,5)' if c == 'WKURS' else 'DECIMAL(18,3)' if c in NUMS else 'NVARCHAR(100)'} NULL"
                     for c in cols)
    cur.execute(f"CREATE TABLE dbo.{t} ({defs})")

out = sqlcmd("-i", str(SQL / "00_check_staging.sql"), "-h", "-1", "-W", "-s", "|", db=DB)
left = [l for l in out.splitlines() if "|" in l]
assert left and all("選用" in l for l in left), out
# 先測有 T024E 的路線，後面再拿掉它測從 EKKO 推
cur.execute("CREATE TABLE dbo.T024E (EKORG NVARCHAR(100), BUKRS NVARCHAR(100))")
sqlcmd("-i", str(SQL / "01_create_tables.sql"), db=DB)
sqlcmd("-i", str(SQL / "02_load_procedures.sql"), db=DB)


def ins(table, rows):
    for row in rows:
        cols = ", ".join(row)
        cur.execute(f"INSERT dbo.{table} ({cols}) VALUES ({', '.join('?' * len(row))})",
                    *row.values())


# ---- 測試資料 ----
ins("LFA1", [dict(LIFNR="0000100001", NAME1="台灣測試股份有限公司", LAND1="TW", SPERR="X"),
             dict(LIFNR="0000100002", NAME1="日本テスト株式会社", LAND1="JP")])
ins("LFB1", [dict(LIFNR="0000100001", BUKRS=b, ZTERM="NT30", ZAHLS="A" if b == "1000" else None)
             for b in ("1000", "2000", "3000")])
ins("LFM1", [dict(LIFNR="0000100001", EKORG=e, ZTERM="NT60", VERKF="王小明") for e in ("TW01", "TW02")])
# TW01 屬於公司別 1000；TW02 是跨公司的採購組織，沒有公司別
ins("T024E", [dict(EKORG="TW01", BUKRS="1000"), dict(EKORG="TW02", BUKRS=None)])
ins("MAKT", [dict(MATNR="000000000000012345", SPRAS="ZF", MAKTX="晶圓載具"),
             dict(MATNR="000000000000012345", SPRAS="E", MAKTX="Wafer carrier")])
ins("MARA", [dict(MATNR="000000000000012345", MTART="ROH", MATKL="A01", MEINS="EA")])
ins("EKKO", [dict(EBELN="4500000001", BSTYP="F", BSART="NB", BUKRS="1000", LIFNR="0000100001",
                  BEDAT="2024-01-05", WAERS="JPY", WKURS=0.21345),
             dict(EBELN="4600000001", BSTYP="K", BSART="MK", BUKRS="1000", LIFNR="0000100001",
                  BEDAT="2024-01-05", WAERS="TWD")])
ins("EKPO", [dict(EBELN="4500000001", EBELP=p, MATNR="000000000000012345", MENGE=100, NETPR=250,
                  PEINH=100, BANFN="1000000001", BNFPO="00010") for p in ("00010", "00020")]
        + [dict(EBELN="4600000001", EBELP="00010", MATNR="000000000000012345")])
ins("EKKN", [dict(EBELN="4500000001", EBELP="00010", ZEKKN=z, KOSTL=k)
             for z, k in (("02", "CC_SECOND"), ("01", "CC_FIRST"))])
ins("EKET", [dict(EBELN="4500000001", EBELP="00010", EINDT=d) for d in ("2024-03-01", "2024-02-01")])
ins("EKBE", [dict(EBELN="4500000001", EBELP="00010", BEWTP="E", SHKZG="S", MENGE=100, DMBTR=250, BUDAT="2024-02-02"),
             dict(EBELN="4500000001", EBELP="00010", BEWTP="E", SHKZG="H", MENGE=30, DMBTR=75, BUDAT="2024-02-10"),
             dict(EBELN="4500000001", EBELP="00010", BEWTP="Q", SHKZG="S", MENGE=70, DMBTR=175, BUDAT="2024-02-15")])
ins("EBAN", [dict(BANFN="1000000001", BNFPO="00010", MATNR="000000000000012345", FLIEF="0000100001"),
             dict(BANFN="1000000002", BNFPO="00010", MATNR="000000000000012345")])
ins("EBKN", [dict(BANFN="1000000001", BNFPO="00010", ZEBKN=z, KOSTL=k)
             for z, k in (("02", "PR_SECOND"), ("01", "PR_FIRST"))])
ins("T001", [dict(BUKRS="1000", WAERS="TWD")])
ins("MKPF", [dict(MBLNR="5000000001", MJAHR="2024", BUDAT="2024-02-02")])
ins("MSEG", [dict(MBLNR="5000000001", MJAHR="2024", ZEILE="0001", BWART="101", SHKZG="S",
                  MATNR="000000000000012345", BUKRS="1000", MENGE=100, EBELN="4500000001", EBELP="00010"),
             dict(MBLNR="5000000001", MJAHR="2024", ZEILE="0002", BWART="102", SHKZG="H",
                  MATNR="000000000000012345", BUKRS="1000", MENGE=30, EBELN="4500000001", EBELP="00010"),
             dict(MBLNR="5000000001", MJAHR="2024", ZEILE="0003", BWART="261", SHKZG="H",
                  MATNR="000000000000012345", BUKRS="1000", MENGE=5)])
ins("CDHDR", [dict(OBJECTCLAS="KRED", OBJECTID="0000100001", CHANGENR="0000012345",
                   UDATE="2024-04-01", UTIME="134501", USERNAME="ADMIN", TCODE="XK05"),
              dict(OBJECTCLAS="MATERIAL", OBJECTID="000000000000012345", CHANGENR="0000012346",
                   UDATE="2024-04-01", UTIME="09:00:00")])
ins("CDPOS", [dict(OBJECTCLAS="KRED", OBJECTID="0000100001", CHANGENR="0000012345", TABNAME="LFB1",
                   TABKEY=f"8000000100001{b}", FNAME="SPERR", CHNGIND="U", VALUE_NEW="X")
              for b in ("1000", "2000")]
             + [dict(OBJECTCLAS="KRED", OBJECTID="0000100001", CHANGENR="0000012345", TABNAME="LFA1",
                     TABKEY="8000000100001", FNAME="NAME1", CHNGIND="U")])
ins("EINA", [dict(INFNR="5300000001", LIFNR="0000100001", MATNR="000000000000012345")])
ins("EINE", [dict(INFNR="5300000001", EKORG="TW01", ESOKZ="0", WERKS=None),
             dict(INFNR="5300000001", EKORG="TW01", ESOKZ="0", WERKS="1100")])
ins("KONP", [dict(KNUMH="0000500001", KOPOS=k, KBETR=p, KPEIN=1, LOEVM_KO=None)
             for k, p in (("02", 999), ("01", 120))])
ins("KONH", [dict(KNUMH="0000500001", ERDAT="2023-01-01", ERNAM="BUYER")])
ins("A017", [dict(LIFNR="0000100001", MATNR="000000000000012345", EKORG="TW01", WERKS="1100",
                  ESOKZ="0", KSCHL="PB00", DATAB="2023-01-01", DATBI="9999-12-31", KNUMH="0000500001")])
ins("A018", [dict(LIFNR="0000100001", MATNR="000000000000012345", EKORG="TW01",
                  ESOKZ="0", KSCHL="PB00", DATAB="2023-01-01", DATBI="9999-12-31", KNUMH="0000500001")])
ins("MARD", [dict(MATNR="000000000000012345", WERKS=w, LGORT=l, LABST=10)
             for w, l in (("1100", "0001"), ("1100", "0002"), ("1200", "0001"))])
ins("MARC", [dict(MATNR="000000000000012345", WERKS=w, DISPO="001") for w in ("1100", "1200")])
# 1100 有分割評價：總額列 10 個、每 100 個 10000 元 = 1000；子列 NEW 6 個 = 600
ins("MBEW", [dict(MATNR="000000000000012345", BWKEY="1100", BWTAR=None, SALK3=1000, LBKUM=10,
                  VERPR=10000, PEINH=100),
             dict(MATNR="000000000000012345", BWKEY="1100", BWTAR="NEW", SALK3=600, LBKUM=6,
                  VERPR=10000, PEINH=100),
             dict(MATNR="000000000000012345", BWKEY="1200", BWTAR=None, SALK3=2000)])
ins("BKPF", [dict(BUKRS="1000", BELNR="5100000001", GJAHR="2024", BLART="RE", WAERS="TWD")])
ins("BSEG", [dict(BUKRS="1000", BELNR="5100000001", GJAHR="2024", BUZEI="001", KOART="K",
                  LIFNR="0000100001", SHKZG="H", WRBTR=175),
             dict(BUKRS="1000", BELNR="5100000001", GJAHR="2024", BUZEI="002", KOART="S",
                  SHKZG="S", WRBTR=175, EBELN="4500000001", EBELP="00010")])

# ---- 第一次執行（沒有 T024D）----
res = cur.execute("EXEC etl.LoadAll").fetchall()
for r in res:
    print(f"  {r[0]:<28} {str(r[1]):>4}  {r[3]}")
assert all(r[3] == "OK" for r in res), "有表載入失敗"


def one(sql):
    return cur.execute(sql).fetchall()


checks = []


def check(name, got, want):
    ok = got == want
    checks.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {got!r}" + ("" if ok else f"  (預期 {want!r})"))


check("目標表沒有 VARCHAR（全部 NVARCHAR）",
      one("SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE DATA_TYPE = 'varchar' "
          "AND TABLE_SCHEMA IN ('prc','mst','inv','fin')")[0][0], 0)
check("ExchangeRate 5 位小數不被四捨五入",
      float(one("SELECT ExchangeRate FROM prc.PurchaseOrderDetail WHERE PoItem='00010'")[0][0]), 0.21345)
check("PO 只留 BSTYP=F，合約被排除", one("SELECT COUNT(*) FROM prc.PurchaseOrderDetail")[0][0], 2)
r = one("SELECT CostCenter, DelivDate, GrQty, GrAmount, IrQty, LastGrDate, MaterialDesc, VendorName, PriceUnit "
        "FROM prc.PurchaseOrderDetail WHERE PoItem='00010'")[0]
check("EKKN 兩筆分攤取 ZEKKN 最小", r.CostCenter, "CC_FIRST")
check("DelivDate 取 EKET 最早", str(r.DelivDate), "2024-02-01")
check("GrQty 100 收 - 30 沖銷", float(r.GrQty), 70.0)
check("GrAmount 250 - 75", float(r.GrAmount), 175.0)
check("IrQty", float(r.IrQty), 70.0)
check("LastGrDate", str(r.LastGrDate), "2024-02-10")
check("MAKT 取 ZF 中文", r.MaterialDesc, "晶圓載具")
check("NVARCHAR 中文供應商名", r.VendorName, "台灣測試股份有限公司")
check("PriceUnit", float(r.PriceUnit), 100.0)

r = one("SELECT PrNumber, PoNumber, PoItem, PoItemCount, CostCenter FROM prc.PurchaseRequisition ORDER BY PrNumber")
check("PR 不因多筆 PO 重複", len(r), 2)
check("PR 取最小 PO 項目", (r[0].PoItem, r[0].PoItemCount), ("00010", 2))
check("EBKN 取 ZEBKN 最小", r[0].CostCenter, "PR_FIRST")
check("沒轉 PO 的 PR PoItemCount=0", r[1].PoItemCount, 0)

r = one("SELECT MaterialDocItem, MovementType, DebitCreditInd, CostCenter, Currency FROM prc.GoodsReceipt ORDER BY 1")
check("GR 只留 101/102，261 排除", [x.MovementType for x in r], ["101", "102"])
check("GR 借貸別", [x.DebitCreditInd for x in r], ["S", "H"])
check("GR 幣別來自 T001", r[0].Currency, "TWD")
check("MaterialMovement 保留全部", one("SELECT COUNT(*) FROM inv.MaterialMovement")[0][0], 3)

r = one("SELECT Vendor, TableKey, FieldName, ChangeTime FROM mst.VendorChangeHistory ORDER BY TableKey")
check("異動：同一次改兩個公司別不撞鍵、NAME1 被篩掉、MATERIAL 類被篩掉", len(r), 2)
check("UTIME 134501 轉成時間", str(r[0].ChangeTime), "13:45:01")

r = one("SELECT Vendor, PurchOrg, CompanyCode, PaymentTerms, PurchOrgPaymentTerms, PaymentBlock, "
        "VendorRowNo, VendorName, SalesPerson, CentralPostingBlock FROM mst.Vendor ORDER BY Vendor, VendorRowNo")
check("Vendor 只留真實組合（不是 3×2 笛卡兒積）",
      [(x.Vendor[-1], x.PurchOrg, x.CompanyCode) for x in r],
      [("1", "", "2000"), ("1", "", "3000"), ("1", "TW01", "1000"), ("1", "TW02", ""), ("2", "", "")])
tw01 = next(x for x in r if x.PurchOrg == "TW01")
check("TW01 帶到公司別 1000 的 LFB1 付款條件與 ZAHLS",
      (tw01.PaymentTerms, tw01.PaymentBlock), ("NT30", "A"))
check("PurchOrgPaymentTerms 來自 LFM1", tw01.PurchOrgPaymentTerms, "NT60")
check("跨公司採購組織沒有 LFB1 資料", next(x for x in r if x.PurchOrg == "TW02").PaymentTerms, None)
check("VendorRowNo = 1 算家數", sum(x.VendorRowNo == 1 for x in r), 2)
check("沒有 LFB1/LFM1 的供應商也留著", r[-1].VendorName, "日本テスト株式会社")
check("CentralPostingBlock 來自 LFA1.SPERR", tw01.CentralPostingBlock, "X")
check("SalesPerson 中文", tw01.SalesPerson, "王小明")

r = one("SELECT Plant FROM mst.PurchasingInfoRecord ORDER BY Plant")
check("InfoRecord：空白工廠與 1100 各一列，不撞鍵", [x.Plant for x in r], ["", "1100"])

for t in ("A017", "A018"):
    r = one(f"SELECT ConditionPrice, ValidTo, CreatedBy FROM mst.PurchasingCond{t}")
    check(f"{t} 只一列、KONP 取 KOPOS 最小", (len(r), float(r[0].ConditionPrice)), (1, 120.0))
    check(f"{t} 9999-12-31", str(r[0].ValidTo), "9999-12-31")
check("A017 有 Plant", one("SELECT Plant FROM mst.PurchasingCondA017")[0][0], "1100")

r = one("SELECT Plant, StorLoc, StockValue, Planner FROM inv.InventoryBalance ORDER BY Plant, StorLoc")
check("庫存三個儲位各一列（分割評價子列沒有讓它變多）", len(r), 3)
check("StockValue 依工廠", [float(x.StockValue) for x in r], [1000.0, 1000.0, 2000.0])
check("沒有 T024D 時 Planner 是 NULL", r[0].Planner, None)

r = one("SELECT LineItem, PoNumber, PoItem, DebitCreditInd FROM fin.AccountsPayable")
check("AP 只留供應商行", len(r), 1)
check("AP 從 GR/IR 行帶 PO 號", (r[0].PoNumber, r[0].PoItem), ("4500000001", "00010"))

# ---- 補上 T024D 再跑一次 ----
cur.execute("CREATE TABLE dbo.T024D (WERKS NVARCHAR(4), DISPO NVARCHAR(3), DSNAM NVARCHAR(18))")
cur.execute("INSERT dbo.T024D VALUES ('1100', '001', N'陳控制員')")
cur.execute("EXEC etl.Load_InventoryBalance")
r = one("SELECT Plant, Planner FROM inv.InventoryBalance ORDER BY Plant, StorLoc")
check("有 T024D 時帶出 Planner", [x.Planner for x in r], ["陳控制員", "陳控制員", None])

# ---- 失敗時 LoadAll 不中斷 ----
cur.execute("EXEC sp_rename 'dbo.BSEG', 'BSEG_x'")
res = cur.execute("EXEC etl.LoadAll").fetchall()
bad = [r for r in res if r[3] != "OK"]
check("BSEG 不見時只有 AP 失敗、其他照跑", [r[0] for r in bad], ["fin.AccountsPayable"])
print("  錯誤訊息：", bad[0][3])
check("失敗的表沒有被清空成半套（交易回滾）",
      one("SELECT COUNT(*) FROM fin.AccountsPayable")[0][0], 1)

# ---- 沒有 T024E：從 EKKO 推採購組織的公司別 ----
cur.execute("DROP TABLE dbo.T024E")
ins("EKKO", [dict(EBELN="4500000002", BSTYP="F", BUKRS="1000", EKORG="TW01"),
             dict(EBELN="4500000003", BSTYP="F", BUKRS="1000", EKORG="TW02"),
             dict(EBELN="4500000004", BSTYP="F", BUKRS="2000", EKORG="TW02")])
cur.execute("EXEC etl.Load_Vendor")
r = one("SELECT PurchOrg, CompanyCode, PaymentTerms FROM mst.Vendor WHERE Vendor='0000100001' AND PurchOrg<>'' ORDER BY 1")
check("沒有 T024E：TW01 只跟 1000 出現過 → 1000；TW02 跟兩個公司別出現過 → 跨公司",
      [(x.PurchOrg, x.CompanyCode, x.PaymentTerms) for x in r], [("TW01", "1000", "NT30"), ("TW02", "", None)])

# ---- 欄位沒下載齊：BSEG 沒有 KOART/SHKZG、EBAN 少一堆，用 @fill = 1 補空欄先組起來 ----
cur.execute("EXEC sp_rename 'dbo.BSEG_x', 'BSEG'")
cur.execute("ALTER TABLE dbo.BSEG DROP COLUMN KOART, SHKZG")
cur.execute("UPDATE dbo.BSEG SET BSCHL = IIF(BUZEI = '001', '31', '86')")
cur.execute("ALTER TABLE dbo.EKPO DROP COLUMN PEINH")
cur.execute("ALTER TABLE dbo.MBEW DROP COLUMN BWTAR, PEINH")
cur.execute("ALTER TABLE dbo.EBKN DROP COLUMN ZEBKN")
cur.execute("UPDATE dbo.EKPO SET NETWR = MENGE * NETPR / 100")   # 價格單位 100
EBAN_GONE = ["BADAT", "EKORG", "FLIEF", "KNTTP", "LFDAT", "MEINS", "MENGE", "PREIS", "WAERS"]
cur.execute(f"ALTER TABLE dbo.EBAN DROP COLUMN {', '.join(EBAN_GONE)}")
cur.execute("DROP TABLE dbo.T024D")
fill = Path(__file__).with_name("_fill.sql")
fill.write_text((SQL / "00_check_staging.sql").read_text("utf-8-sig")
                .replace("DECLARE @fill bit = 0;", "DECLARE @fill bit = 1;"), "utf-8-sig")
try:
    out = sqlcmd("-i", str(fill), "-h", "-1", "-W", "-s", "|", db=DB)
finally:
    fill.unlink()
filled = sorted(l.split("|")[:2] for l in out.splitlines() if "已補成空欄" in l)
check("@fill 補上缺的欄位", filled,
      sorted([["BSEG", "KOART"], ["BSEG", "SHKZG"], ["EBKN", "ZEBKN"], ["EKPO", "PEINH"],
              ["MBEW", "BWTAR"], ["MBEW", "PEINH"]]
             + [["EBAN", c] for c in EBAN_GONE]))
check("補了之後只剩選用的 T024D/T024E", all("選用" in l for l in out.splitlines()
                                      if "|" in l and "已補成空欄" not in l), True)
sqlcmd("-i", str(SQL / "02_load_procedures.sql"), db=DB)      # 程序建得起來
res = cur.execute("EXEC etl.LoadAll").fetchall()
check("缺欄位時全部照樣載入", [r[0] for r in res if r[3] != "OK"], [])
r = one("SELECT LineItem, DebitCreditInd, PoNumber FROM fin.AccountsPayable")
check("沒有 KOART 時用 BSCHL 31 判定供應商行、推出貸方", [(x.LineItem, x.DebitCreditInd) for x in r],
      [("001", "H")])
cur.execute("UPDATE dbo.BSEG SET BSCHL = NULL")
cur.execute("EXEC etl.Load_AccountsPayable")
r = one("SELECT LineItem, DebitCreditInd FROM fin.AccountsPayable")
check("BSCHL 也沒有時用 LIFNR 判定，借貸別留 NULL", [(x.LineItem, x.DebitCreditInd) for x in r],
      [("001", None)])
r = one("SELECT Plant, StockValue, PriceUnit FROM inv.InventoryBalance ORDER BY Plant, StorLoc")
check("沒有 BWTAR 時分割評價不讓庫存重複、取總額列",
      [(x.Plant, float(x.StockValue)) for x in r], [("1100", 1000.0), ("1100", 1000.0), ("1200", 2000.0)])
check("沒有 MBEW.PEINH 時從 LBKUM、SALK3 反推", float(r[0].PriceUnit), 100.0)
check("沒有 PEINH 時從 NETWR 反推 PriceUnit",
      float(one("SELECT PriceUnit FROM prc.PurchaseOrderDetail WHERE PoItem='00010'")[0][0]), 100.0)
check("沒有 ZEBKN 時 EBKN 依成本中心排序，結果固定",
      one("SELECT CostCenter FROM prc.PurchaseRequisition WHERE PrNumber='1000000001'")[0][0], "PR_FIRST")
r = one("SELECT ReqQty, PrDate, Vendor FROM prc.PurchaseRequisition WHERE PrNumber='1000000001'")[0]
check("EBAN 缺的欄位是 NULL", (r.ReqQty, r.PrDate, r.Vendor), (None, None, None))

# ---- 90_diagnose.sql：三行代號=數字 ----
out = sqlcmd("-i", str(SQL / "90_diagnose.sql"), "-h", "-1", "-W", db=DB)
lines = [l for l in out.splitlines() if "=" in l]
for l in lines:
    print("  " + l)
got = dict(kv.split("=") for l in lines for kv in l.split())
check("診斷輸出三行", len(lines), 3)
check("診斷：AP 筆數、BSEG 無重複、MARA 無空白料號",
      (got["T10"], got["B2"], got["M2"]), ("1", "0", "0"))

cn.close()
sqlcmd("-Q", f"ALTER DATABASE {DB} SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE {DB};")
print(f"\n{sum(checks)}/{len(checks)} 通過")
sys.exit(0 if all(checks) else 1)
