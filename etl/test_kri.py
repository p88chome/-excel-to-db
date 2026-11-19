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
    base = dict(PoNumber=number, PoItem=item, CompanyCode="1000", PurchOrg="P001", Plant="1100",
                Vendor="V1", OrderUom="EA", Currency="TWD", ExchangeRate=1, PriceUnit=1,
                PoDate="2025-03-01", OrderQty=100)
    base.update(kw)
    if "NetValue" not in base and "NetPrice" in base:
        base["NetValue"] = base["NetPrice"] * base["OrderQty"] / base["PriceUnit"]
    return base


def cond(**kw):
    base = dict(Vendor="V1", PurchOrg="P001", InfoCategory="0", ConditionType="PB00",
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
                ReqQty=1, ValPrice=amount, Currency="TWD", Plant="1100", PurchOrg="P001", Material="M50")
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
    cond(Material="M35", Plant="1100", ConditionRecord="0000600006", ConditionPrice=10,
         ValidFrom="2025-03-01", CreatedOn="2025-05-01"),                         # 倒填 61 天，但期間沒有 PO
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

# ---------------------------------------------------------------- K01
ins("ext.QualityIssue", [
    dict(IssueNo="Q1", Vendor="12345", Material="M60", Status="Open", IsClosed=0, OpenedOn="2025-06-01"),
    dict(IssueNo="Q2", Vendor="V9", Status="Closed", IsClosed=1, OpenedOn="2025-03-01", ClosedOn="2025-03-31"),
    dict(IssueNo="Q3", Vendor="V9", Status="Closed", IsClosed=1, OpenedOn="2025-01-01"),   # 結案沒結案日 → 略過
    dict(IssueNo="Q4", Vendor="777", Material="123", Status="Open", IsClosed=0, OpenedOn="2025-06-01"),  # 料號補零
    dict(IssueNo="Q5", Vendor="V10", Status="Closed", IsClosed=1, OpenedOn="2025-10-01",
         ClosedOn="2026-03-01"),                                                       # 基準日之後才結案
])
ins("prc.PurchaseOrderDetail", [
    po("4540000001", Vendor="0000012345", Material="M60", NetPrice=10, PoDate="2025-07-01"),  # 同料號 → 標記
    po("4540000002", Vendor="0000012345", Material="M61", NetPrice=10, PoDate="2025-05-01"),  # 開單前
    po("4540000003", Vendor="0000012345", Material="M62", NetPrice=10, PoDate="2025-08-01"),  # 不同料號 → 標記
    po("4540000004", Vendor="V9", Material="M63", NetPrice=10, PoDate="2025-03-15"),          # 結案前 → 標記
    po("4540000005", Vendor="V9", Material="M63", NetPrice=10, PoDate="2025-04-15"),          # 結案後
    po("4540000006", Vendor="0000000777", Material="000000000000000123", NetPrice=10, PoDate="2025-07-01"),
    po("4540000007", Vendor="V10", Material="M64", NetPrice=10, PoDate="2025-11-01"),
])

# ---------------------------------------------------------------- K03
def chg(vendor, no, date, table, key, field, old, new, by="U1"):
    return dict(Vendor=vendor, ChangeNumber=no, ChangeDate=date, ChangeTime="10:00", ChangedBy=by,
                TableName=table, TableKey=key, FieldName=field, OldValue=old, NewValue=new, ChangeInd="U")


ins("mst.VendorChangeHistory", [
    chg("0000000020", "C001", "2025-04-01", "LFA1", "1000000000020", "SPERM", "X", ""),
    chg("0000000020", "C002", "2025-04-10", "LFA1", "1000000000020", "SPERM", "", "X"),       # 9 天、有 PO → 標記
    chg("0000000021", "C003", "2025-05-01", "LFM1", "1000000000021P001", "SPERM", "X", ""),
    chg("0000000021", "C004", "2025-05-20", "LFM1", "1000000000021P001", "SPERM", "", "X"),   # PO 在別的採購組織
    chg("0000000022", "C005", "2025-06-01", "LFA1", "1000000000022", "SPERR", "X", ""),
    chg("0000000022", "C006", "2025-08-15", "LFA1", "1000000000022", "SPERR", "", "X"),       # 75 天，太久
    chg("0000000023", "C007", "2025-09-01", "LFA1", "1000000000023", "SPERM", "X", ""),       # 沒再凍結
    chg("0000000024", "C008", "2025-07-01", "LFB1", "10000000000241000", "SPERR", "X", ""),
    chg("0000000024", "C009", "2025-07-05", "LFB1", "10000000000241000", "SPERR", "", "X"),   # 只有傳票 → 標記
    chg("0000000025", "C010", "2025-04-01", "LFA1", "1000000000025", "NAME1", "A", ""),       # 不是凍結欄位
    chg("0000000026", "C011", "2025-12-01", "LFA1", "1000000000026", "SPERM", "X", ""),
    chg("0000000026", "C012", "2026-01-05", "LFA1", "1000000000026", "SPERM", "", "X"),       # 基準日之後才再凍結
    # 同一張異動單解凍兩個採購組織，只有 P001 有 PO
    chg("0000000027", "C013", "2025-03-01", "LFM1", "1000000000027P001", "SPERM", "X", ""),
    chg("0000000027", "C013", "2025-03-01", "LFM1", "1000000000027TW02", "SPERM", "X", ""),
    chg("0000000027", "C014", "2025-03-10", "LFM1", "1000000000027P001", "SPERM", "", "X"),
    chg("0000000027", "C014", "2025-03-10", "LFM1", "1000000000027TW02", "SPERM", "", "X"),
    chg("0000000028", "C015", "2025-03-01", "LFA1", "1000000000028", "SPERM", "X", ""),
    chg("0000000028", "C016", "2025-03-05", "LFA1", "1000000000028", "SPERM", "", "X"),       # 採購凍結只有傳票
    dict(chg("0000000029", "C017", "2025-03-01", "LFA1", "1000000000029", "SPERM", "X", ""), ChangeTime=None),
    dict(chg("0000000029", "C018", "2025-03-01", "LFA1", "1000000000029", "SPERM", "", "X"), ChangeTime=None),
    chg("0000000030", "C019", "2025-03-01", "LFA1", "1000000000030", "SPERR", "X", ""),
    chg("0000000030", "C020", "2025-03-05", "LFA1", "1000000000030", "SPERR", "", "X"),       # 傳票在解凍期間輸入
    chg("0000000031", "C021", "2025-03-01", "LFA1", "1000000000031", "SPERR", "X", ""),
    chg("0000000031", "C022", "2025-03-05", "LFA1", "1000000000031", "SPERR", "", "X"),       # 再凍結後才輸入
])
ins("prc.PurchaseOrderDetail", [
    po("4570000001", Vendor="0000000020", NetPrice=10, PoDate="2025-04-05"),
    po("4570000002", Vendor="0000000021", PurchOrg="TW02", NetPrice=10, PoDate="2025-05-10"),
    po("4570000003", Vendor="0000000022", NetPrice=10, PoDate="2025-06-10"),
    po("4570000004", Vendor="0000000023", NetPrice=10, PoDate="2025-09-10"),
    po("4570000005", Vendor="0000000026", NetPrice=10, PoDate="2025-12-10"),
    po("4570000006", Vendor="0000000027", NetPrice=10, PoDate="2025-03-05"),
    po("4570000007", Vendor="0000000029", NetPrice=10, PoDate="2025-03-01"),
])
ins("fin.AccountsPayable", [
    dict(CompanyCode="1000", AccountingDoc="5100000001", FiscalYear="2025", LineItem="001",
         Vendor="0000000024", PostingDate="2025-07-03"),
    dict(CompanyCode="1000", AccountingDoc="5100000003", FiscalYear="2025", LineItem="001",
         Vendor="0000000024", PostingDate="2025-07-04", EntryDate="2026-02-01"),   # 基準日之後才入帳
    dict(CompanyCode="1000", AccountingDoc="5100000004", FiscalYear="2025", LineItem="001",
         Vendor="0000000028", PostingDate="2025-03-03"),
    dict(CompanyCode="1000", AccountingDoc="5100000006", FiscalYear="2025", LineItem="001",
         Vendor="0000000030", PostingDate="2025-02-20", EntryDate="2025-03-02"),   # 過帳日倒填到解凍前
    dict(CompanyCode="1000", AccountingDoc="5100000011", FiscalYear="2025", LineItem="001",
         Vendor="0000000031", PostingDate="2025-03-03", EntryDate="2025-03-10"),   # 過帳日在期間、輸入在再凍結後
])

# ---------------------------------------------------------------- K04
ins("mst.Vendor", [
    dict(Vendor="V30", CompanyCode="1000", PurchOrg="P001", PurchOrgPaymentTerms="T045", PaymentTerms="T060"),
    dict(Vendor="V32", CompanyCode="1000", PurchOrg="P001", PurchOrgPaymentTerms="T045"),   # 公司別層空白
])
ins("prc.PurchaseOrderDetail", [
    po("4550000001", Vendor="V30", PaymentTerm="T030", NetPrice=3650),   # 提早 15 天 → 標記
    po("4550000002", Vendor="V30", PaymentTerm="T060", NetPrice=10),     # 比主檔好
    po("4550000003", Vendor="V30", PaymentTerm="T045", NetPrice=10),     # 跟主檔一樣，但傳票 T010 → 標記
    po("4550000004", Vendor="V31", PaymentTerm="T030", NetPrice=10),     # 沒有主檔
    po("4550000005", Vendor="V30", PaymentTerm="IMMD", NetPrice=10),     # 推不出天數
    po("4550000006", Vendor="V30", PaymentTerm="T050", NetPrice=10),     # 兩層主檔都不同，但比 LFM1 好
    po("4550000007", Vendor="V30", PaymentTerm="T045", NetPrice=10),     # 傳票在基準日之後才入帳
    po("4550000008", Vendor="V32", PaymentTerm="T030", NetPrice=10),     # LFB1 空白，照樣跟 LFM1 比
    po("4550000009", Vendor="V30", PaymentTerm="", NetPrice=10),         # PO 條件空白 = 立即付款
    po("4550000010", Vendor="V30", PaymentTerm="", NetPrice=10),         # PO 空白，但發票照主檔 T045
    po("4550000011", Vendor="V30", PaymentTerm="", NetPrice=10),         # PO 空白，發票有主檔條件和推不出天數的
    po("4550000012", Vendor="V30", PaymentTerm="", NetPrice=3650),       # PO 空白，發票 T030 比主檔早 15 天
])
ins("fin.AccountsPayable", [
    dict(CompanyCode="1000", AccountingDoc="5100000002", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000003", PoItem="00010", PaymentTerms="T010", DebitCreditInd="H"),
    dict(CompanyCode="1000", AccountingDoc="5100000005", FiscalYear="2026", LineItem="001", Vendor="V30",
         PostingDate="2026-01-10", PoNumber="4550000007", PoItem="00010", PaymentTerms="T010", DebitCreditInd="H"),
    dict(CompanyCode="1000", AccountingDoc="5100000007", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000002", PoItem="00010", PaymentTerms="T001",
         DebitCreditInd="S"),                                              # 貸項通知單（借方）不比
    dict(CompanyCode="1000", AccountingDoc="5100000008", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000001", PoItem="00010", PaymentTerms="T030", DebitCreditInd="H"),
    dict(CompanyCode="1000", AccountingDoc="5100000009", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000001", PoItem="00010", PaymentTerms="ZZZZ",
         DebitCreditInd="H"),                                              # 兩種條件：一樣的、推不出天數的
    dict(CompanyCode="1000", AccountingDoc="5100000010", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000010", PoItem="00010", PaymentTerms="T045", DebitCreditInd="H"),
    dict(CompanyCode="1000", AccountingDoc="5100000012", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000011", PoItem="00010", PaymentTerms="T045", DebitCreditInd="H"),
    dict(CompanyCode="1000", AccountingDoc="5100000013", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000011", PoItem="00010", PaymentTerms="ZZZZ", DebitCreditInd="H"),
    dict(CompanyCode="1000", AccountingDoc="5100000014", FiscalYear="2025", LineItem="001", Vendor="V30",
         PostingDate="2025-04-01", PoNumber="4550000012", PoItem="00010", PaymentTerms="T030", DebitCreditInd="H"),
])

# ---------------------------------------------------------------- K10 / K19
def gr(doc, po_no, date, entry=None, mvt="101", dc="S", text=None, item="0001"):
    return dict(MaterialDoc=doc, MaterialDocYear="2025", MaterialDocItem=item, PostingDate=date,
                EntryDate=entry or date, MovementType=mvt, DebitCreditInd=dc, PoNumber=po_no, PoItem="00010",
                ItemText=text)


ins("prc.PurchaseOrderDetail", [
    po("4560000001", NetPrice=100, PoDate="2025-04-10"),
    po("4560000002", NetPrice=100, PoDate="2025-04-10"),
    po("4560000003", NetPrice=100, PoDate="2025-04-10", PrNumber="1100000001", PrItem="00010"),
    po("4560000004", NetPrice=100, PoDate="2025-04-10"),
    po("4560000005", NetPrice=6000, PoDate="2025-04-10"),                                   # 60 萬
    po("4560000006", NetPrice=10000, PoDate="2025-04-10", CompanyCode="3000", Currency="JPY"),
    po("4560000007", NetPrice=100, PoDate="2025-04-10"),
    po("4560000008", NetPrice=100, PoDate="2025-04-10"),                                    # 收了 1 萬
    po("4560000008", "00020", NetPrice=5000, PoDate="2025-04-10"),                          # 沒收的 50 萬
    po("4560000009", NetPrice=100, PoDate="2025-04-10"),
    po("4560000010", NetPrice=100, PoDate="2025-04-10", PrNumber="1100000099", PrItem="00010"),  # PR 不在資料裡
    po("4560000011", NetPrice=100, PoDate="2025-04-10"),
])
ins("prc.PurchaseRequisition", [dict(PrNumber="1100000001", PrItem="00010", PrDate="2025-03-01")])
ins("prc.GoodsReceipt", [
    gr("5000000001", "4560000001", "2025-04-08"),                   # 早於 PO 2 天
    gr("5000000001", "4560000001", "2025-05-01", item="0002"),
    gr("5000000002", "4560000002", "2025-04-20", entry="2025-04-11"),  # 過帳日晚，輸入日 PO 後 1 天
    gr("5000000003", "4560000003", "2025-04-12"),                   # PO 後 2 天；PR 後 42 天
    gr("5000000004", "4560000004", "2025-04-10", text="URGENT repair"),
    gr("5000000005", "4560000005", "2025-04-10"),
    gr("5000000006", "4560000006", "2025-04-10"),
    gr("5000000007", "4560000007", "2025-04-10", mvt="102", dc="H"),   # 不是收貨
    gr("5000000008", "4560000008", "2025-04-10"),
    gr("5000000009", "4560000009", "2025-04-10", entry="2026-02-01"),  # 基準日之後才補的收貨
    gr("5000000010", "4560000010", "2025-04-10"),
    dict(gr("5000000011", "4560000011", "2025-04-20"), DocumentDate="2025-04-05"),  # 送貨單早於 PO 5 天
])
cur.execute("INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('*', 'ExcludeTextPattern', '%URGENT%')")

# ---------------------------------------------------------------- K09
cur.execute("INSERT kri.ApprovalMatrix (DocType, Currency, MinAmount, MaxAmount, ApprovalLevel) "
            "VALUES ('AP','TWD',0,10000,1), ('AP','TWD',10000,999999999,2)")
def ap(doc, vendor, date, amount, dc="H", cc=None):
    return dict(CompanyCode="1000", AccountingDoc=doc, FiscalYear="2025", LineItem="001", Vendor=vendor,
                PostingDate=date, LocalAmount=amount, DocAmount=amount, Currency="TWD", DebitCreditInd=dc, CostCenter=cc)


ins("fin.AccountsPayable", [
    ap("5200000001", "V40", "2025-05-01", 6000),
    ap("5200000002", "V40", "2025-05-15", 6000),                 # 15 天內合計 12000 → 第 2 層 → 標記
    ap("5200000003", "V41", "2025-05-01", 6000),
    ap("5200000004", "V41", "2025-06-15", 6000),                 # 隔 45 天
    ap("5200000005", "V42", "2025-05-01", 6000, dc="S"),         # 借方不算
    ap("5200000006", "V42", "2025-05-10", 6000),
    ap("5200000007", "V43", "2025-05-01", 6000, cc="CC1"),
    ap("5200000008", "V43", "2025-05-10", 6000, cc="CC2"),       # 不同成本中心
    dict(ap("5200000009", "V44", "2025-05-01", 6000), DocumentType="KZ"),            # 付款傳票類型
    dict(ap("5200000010", "V44", "2025-05-10", 6000), ClearingDoc="5200000010"),     # 自己清自己 = 付款
    ap("5200000011", "V44", "2025-05-12", 6000),
])

# ---------------------------------------------------------------- K12
def k12(no, material, vendor, prior, cur_price, group="G1"):
    return [po(no + "1", Material=material, Vendor=vendor, MaterialGroup=group, NetPrice=prior, PoDate="2024-04-01"),
            po(no + "2", Material=material, Vendor=vendor, MaterialGroup=group, NetPrice=cur_price, PoDate="2025-03-01")]


ins("prc.PurchaseOrderDetail",
    k12("462000001", "M70", "V50", 100, 130)                     # 獨家漲 30%，群組其他平均 5% → 標記
    + k12("462000002", "M71", "V51", 100, 105) + k12("462000003", "M71", "V52", 100, 105)   # 兩家
    + k12("462000004", "M72", "V53", 100, 105) + k12("462000005", "M73", "V54", 100, 105)
    + k12("462000006", "M74", "V55", 100, 115, "G2")             # 群組沒得比，基準 0 → 漲 15% 標記
    + k12("462000007", "M75", "V56", 100, 200, "G2"))            # 合理獨家白名單
cur.execute("INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('K12', 'AllowedSingleSource', 'M75')")

# ---------------------------------------------------------------- K22 / K23
ins("mst.PurchasingCondA017", [
    cond(Vendor="V60", Material="M80", Plant="1100", ConditionRecord="0000700001", ConditionPrice=10,
         ValidFrom="2025-01-01", CreatedOn="2025-01-01"),
    cond(Vendor="V60", Material="M80", Plant="1100", ConditionRecord="0000700002", ConditionPrice=13,
         ValidFrom="2025-06-01", CreatedOn="2025-06-01"),                       # 漲 30% → 標記
    cond(Vendor="V60", Material="M81", Plant="1100", ConditionRecord="0000700003", ConditionPrice=10,
         ValidFrom="2025-01-01", CreatedOn="2025-01-01"),
    cond(Vendor="V60", Material="M81", Plant="1100", ConditionRecord="0000700004", ConditionPrice=11,
         ValidFrom="2025-06-01", CreatedOn="2025-06-01"),                       # 漲 10%
    cond(Vendor="V61", Material="M85", Plant="1100", ConditionRecord="0000700010", ConditionPrice=20,
         ValidFrom="2024-01-01", CreatedOn="2024-01-01"),
    cond(Vendor="V61", Material="M85", Plant="1100", ConditionRecord="0000700011", ConditionPrice=15,
         ValidFrom="2025-08-01", CreatedOn="2025-08-01"),                       # 降價
])
ins("prc.PurchaseOrderDetail", [
    po("4630000001", Vendor="V60", Material="M80", NetPrice=13, PoDate="2025-07-01"),   # 多付 3 × 100
    po("4600000001", Vendor="V61", Material="M85", NetPrice=20, PoDate="2025-05-01", GrQty=100),  # 基準日時未收 60 → 標記
    po("4600000002", Vendor="V61", Material="M85", NetPrice=20, PoDate="2025-05-02", DelivComplInd="X"),
    po("4600000003", Vendor="V61", Material="M85", NetPrice=15, PoDate="2025-09-01"),   # 降價後才下單
])
ins("prc.GoodsReceipt", [
    dict(gr("5000000020", "4600000001", "2025-06-01"), Quantity=40),
    dict(gr("5000000021", "4600000001", "2026-01-05"), Quantity=60),   # 基準日之後才收，不算
])

# ---------------------------------------------------------------- K24
ins("prc.PurchaseOrderDetail", [
    po("4610000001", Vendor="V70", Material="M90", NetPrice=10, PoDate="2023-06-01"),
    po("4610000002", Vendor="V70", Material="M90", NetPrice=13, PoDate="2025-03-01"),   # 休眠後重新下單、高 30%
    po("4610000003", Vendor="V71", Material="M90", NetPrice=10, PoDate="2024-09-01"),
    po("4610000004", Vendor="V70", Material="M91", NetPrice=10, PoDate="2025-04-01"),   # 沒有別家可比
    po("4610000005", Vendor="V70", Material="M90", NetPrice=13, PoDate="2025-08-01"),   # 超過 90 天
    po("4610000009", Vendor="V72", Material="M90", NetPrice=10, PoDate="2024-10-01"),
    po("4610000010", Vendor="V70", Material="M94", NetPrice=20, PoDate="2025-03-20"),   # 參考 PO 只有 1 筆
    po("4610000011", Vendor="V76", Material="M94", NetPrice=10, PoDate="2024-10-01"),
    po("4610000006", Vendor="V70", Material="M93", NetPrice=50, PoDate="2025-03-15"),   # 參考價 10～60 太分散
    po("4610000007", Vendor="V74", Material="M93", NetPrice=10, PoDate="2024-10-01"),
    po("4610000008", Vendor="V75", Material="M93", NetPrice=60, PoDate="2024-10-01"),
])
ins("mst.PurchasingCondA017", [
    cond(Vendor="V62", Material="M83", Plant="1100", ConditionRecord="0000700020", ConditionPrice=10,
         ValidFrom="2025-01-01", CreatedOn=None),
    cond(Vendor="V62", Material="M83", Plant="1100", ConditionRecord="0000700021", ConditionPrice=20,
         ValidFrom="2025-07-01", CreatedOn=None),                               # 建立日空白，用生效日
])
ins("mst.PurchasingCondA018", [
    cond(Vendor="V62", Material="M84", InfoCategory="2", ConditionRecord="0000700030", ConditionPrice=10,
         ValidFrom="2025-01-01", CreatedOn="2025-01-01"),
    cond(Vendor="V62", Material="M84", InfoCategory="2", ConditionRecord="0000700031", ConditionPrice=15,
         ValidFrom="2025-07-01", CreatedOn="2025-07-01"),                       # 寄售類別也比（同類別）
])


# ---------------------------------------------------------------- K02
def vend(v, **kw):
    return dict(dict(Vendor=v, CompanyCode="1000", PurchOrg="P001"), **kw)


ins("mst.Vendor", [
    vend("V80", TaxNumber="12345678", CentralPurchBlock="X"),        # 凍結
    vend("V81", TaxNumber="12345678"),                               # 同統編、期間內有 PO → 標記
    vend("V82", Phone="02-1234-5678"), vend("V83", Phone="0212345678"),   # 同電話、買同料號 → 標記
    vend("V84", Address="No. 1, Test Rd."), vend("V85", Address="NO1 TEST RD"),   # 同地址、沒交易
    vend("V86", TaxNumber="11112222", CentralPurchBlock="X"),        # 基準日之後才凍結 → 基準日當時沒凍結
    vend("V88", TaxNumber="NANANANANA", Phone="0000000000"),         # 填充值：不配對
    vend("V89", TaxNumber="NANANANANA", Phone="0000000000"),
    vend("V87", TaxNumber="11112222"),
])
ins("mst.VendorChangeHistory", [chg("V86", "C086", "2026-02-01", "LFA1", "100V86", "SPERM", "", "X")])
ins("ext.VendorRelation", [dict(VendorA="V85", VendorB="V84", RelationType="同代表人"),
                           dict(VendorA="V84", VendorB="V85", RelationType="同代表人", Note="反向"),
                           dict(VendorA="V84", VendorB="V85", RelationType="同地址")])
ins("prc.PurchaseOrderDetail", [
    po("4670000001", Vendor="V81", NetPrice=10, PoDate="2025-04-01"),
    po("4670000002", Vendor="V82", Material="M100", NetPrice=10, PoDate="2025-04-01"),
    po("4670000003", Vendor="V83", Material="M100", NetPrice=10, PoDate="2025-05-01"),
    po("4670000004", Vendor="V87", NetPrice=10, PoDate="2025-05-01"),
])

# ---------------------------------------------------------------- K05
ins("mst.Vendor", [vend("V91", TaxNumber="87654321")])
ins("ext.VendorCapital", [dict(Vendor="V90", Capital=1000000, Currency="TWD"),
                          dict(TaxNumber="87654321", Capital=10000000, Currency="TWD")])
ins("prc.PurchaseOrderDetail", [
    po("4680000001", Vendor="V90", NetPrice=15000, PoDate="2025-06-01"),   # 未收 150 萬 / 資本 100 萬 → 標記
    po("4680000002", Vendor="V91", NetPrice=15000, PoDate="2025-06-01"),   # 用統編對到資本 1000 萬
    po("4680000003", Vendor="V92", NetPrice=15000, PoDate="2025-06-01"),   # 查不到資本額
])

# ---------------------------------------------------------------- 庫存、異動（K06、K11、K15、K16、K20）
def mm(doc, date, mvt, mat, qty, dc, sloc="0001", item="0001"):
    return dict(MaterialDoc=doc, MaterialDocYear=date[:4], MaterialDocItem=item, PostingDate=date, MovementType=mvt,
                Material=mat, Plant="1100", StorLoc=sloc, Quantity=qty, DebitCreditInd=dc, BaseUom="EA")


def ib(mat, qty, value=None):
    return dict(Material=mat, Plant="1100", StorLoc="0001", StockQty=qty, StockValue=value, SnapshotDate="2025-12-31")


ins("inv.InventoryBalance", [ib("M110", 1000), ib("M111", 50), ib("M112", 0), ib("M130", 20), ib("M131", 0),
                             ib("M132", 0), ib("M140", 10, 500), ib("M142", 10, 300)])
months = [f"{y}-{m:02d}-01" for y in (2024, 2025) for m in range(1, 13)][6:]          # 2024-07 ～ 2025-12
ins("inv.MaterialMovement",
    [mm(f"49100{i:05d}", d, "261", "M110", 100, "H") for i, d in enumerate(months)]           # 每月耗用 100
    + [mm(f"49200{i:05d}", d, "261", "M112", 200, "H") for i, d in enumerate(months[:12])]    # 耗用到 2025-06
    + [mm("4930000001", "2025-01-10", "101", "M140", 10, "S"),     # 最後異動 → 2026-01-10 呆滯
       mm("4930000002", "2024-01-05", "101", "M142", 10, "S")])    # 2025-01-04 起呆滯
ins("prc.PurchaseRequisition", [
    dict(PrNumber="1000000101", PrItem="00010", PrDate="2025-06-15", Material="M110", Plant="1100", ReqQty=500, ValPrice=1, Currency="TWD"),
    dict(PrNumber="1000000102", PrItem="00010", PrDate="2025-06-15", Material="M111", Plant="1100", ReqQty=10, ValPrice=1, Currency="TWD"),
    dict(PrNumber="1000000103", PrItem="00010", PrDate="2025-06-20", Material="M112", Plant="1100", ReqQty=10, ValPrice=1, Currency="TWD"),
])
ins("prc.PurchaseOrderDetail", [
    po("4690000001", Material="M110", NetPrice=1, OrderQty=500, PoDate="2025-06-15", PrNumber="1000000101", PrItem="00010"),  # PR 自己轉的
    po("4690000002", Material="M112", NetPrice=1, PoDate="2025-02-01", GrQty=5, DelivComplInd="X"),      # 收 5 就結案
    po("4690000003", Material="M112", NetPrice=1, OrderQty=10, OrderUom="BOX", PoDate="2025-02-01", GrQty=4),   # 收 4 BOX（48 EA）
])
ins("prc.GoodsReceipt", [dict(gr("5000000090", "4690000002", "2025-03-01"), Quantity=5),
                         dict(gr("5000000091", "4690000003", "2025-03-01"), Quantity=48)])

# ---------------------------------------------------------------- K07
ins("prc.PurchaseRequisition",
    [dict(PrNumber=f"10000002{m:02d}", PrItem="00010", PrDate=f"2025-{m:02d}-05", Material="M120", Plant="1100",
          ReqQty=10 if m < 7 else 100, Uom="EA") for m in range(1, 8)]                        # 7 月暴增 10 倍
    + [dict(PrNumber="1000000301", PrItem="00010", PrDate="2025-08-05", Material="M121", Plant="1100", ReqQty=100, Uom="EA")])
ins("ext.ExpectedDemand", [dict(Material="M121", Plant="1100", Month="2025-08-01", Qty=1000)])

# ---------------------------------------------------------------- 通用料號（GenericMaterial）
# M125 跟 M120 一樣 7 月暴增，但列為通用料號 → K07 不看；5 家供應商單價差 100 倍 → 建議清單會列出來
cur.execute("INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('*', 'GenericMaterial', 'M125')")
ins("prc.PurchaseRequisition",
    [dict(PrNumber=f"10000004{m:02d}", PrItem="00010", PrDate=f"2025-{m:02d}-05", Material="M125", Plant="1100",
          ReqQty=10 if m < 7 else 100, Uom="EA") for m in range(1, 8)])
ins("prc.PurchaseOrderDetail", [po(f"47000000{i:02d}", Vendor=f"VG{i}", Material=f"M12{6 if i < 6 else 5}", NetPrice=p,
                                  PoDate="2025-04-01") for i, p in zip(range(1, 11), [1, 5, 20, 50, 100] * 2)])

# ---------------------------------------------------------------- K11
cur.execute("INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('K11', 'EmergencyPoType', 'ZEM')")
ins("ext.PartUsage", [dict(Material="M131", Plant="1100", SnapshotDate="2025-01-01", Mou=5, WaitingForUse=0),
                      dict(Material="M132", Plant="1100", SnapshotDate="2025-01-01", Mou=1, WaitingForUse=0)])
ins("prc.PurchaseOrderDetail", [
    po("4640000001", PoType="ZEM", Material="M130", NetPrice=10, PoDate="2025-05-01"),   # 有庫存 20 → 標記
    po("4640000002", PoType="ZEM", Material="M131", NetPrice=10, PoDate="2025-05-01"),   # MOU 5 → 標記
    po("4640000003", PoType="ZEM", Material="M132", NetPrice=10, PoDate="2025-05-01"),   # 真的急
    po("4640000004", Material="M130", NetPrice=10, PoDate="2025-05-01"),                 # 不是緊急採購
])

# ---------------------------------------------------------------- K16
ins("prc.PurchaseOrderDetail", [
    po("4650000001", Material="M142", NetPrice=10, PoDate="2025-06-01"),   # 呆滯、有庫存仍下單 → 標記
    po("4650000002", Material="M140", NetPrice=10, PoDate="2025-06-01"),   # 還沒呆滯
])

# ---------------------------------------------------------------- K17
cur.execute("INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('K17', 'ConstructionPoType', 'ZCON')")
ins("prc.PurchaseOrderDetail", [
    po("4660000001", PoType="ZCON", Vendor="V95", NetPrice=200000, PoDate="2025-03-01"),   # 2000 萬、沒合約 → 標記
    po("4660000002", PoType="ZCON", Vendor="V96", NetPrice=200000, PoDate="2025-03-01"),   # 合約對 PO
    po("4660000003", PoType="ZCON", Vendor="V97", NetPrice=200000, PoDate="2025-03-01"),   # 合約晚於 PO → 標記
    po("4660000004", PoType="ZCON", Vendor="V95", NetPrice=10, PoDate="2025-03-01"),       # 金額小
    po("4660000005", PoType="ZCON", Vendor="V98", NetPrice=200000, PoDate="2025-03-01", Contract="4600000099"),
])
ins("ext.Contract", [
    dict(ContractNo="C-1", PoNumber="4660000002", Vendor="V96", SignedOn="2025-01-01"),
    dict(ContractNo="C-2", Vendor="V97", SignedOn="2025-05-01", ValidFrom="2025-01-01", ValidTo="2025-12-31"),
])

# ---------------------------------------------------------------- K20
cur.execute("INSERT kri.ValueList (KriCode, ListName, ListValue) VALUES ('K20', 'ReturnStorLoc', 'R001')")
ins("inv.MaterialMovement", [
    mm("4940000001", "2025-03-01", "311", "M150", 10, "S", "R001"), mm("4940000001", "2025-03-01", "311", "M150", 10, "H", item="0002"),
    mm("4940000002", "2025-03-10", "122", "M150", 10, "H", "R001"),          # 9 天處理完
    mm("4940000003", "2025-05-01", "311", "M151", 10, "S", "R001"),
    mm("4940000004", "2025-05-20", "122", "M151", 4, "H", "R001"),
    mm("4940000005", "2025-07-15", "551", "M151", 6, "H", "R001"),           # 75 天才處理完 → 標記
    mm("4940000006", "2025-11-01", "311", "M152", 5, "S", "R001"),           # 到基準日 60 天還沒處理 → 標記
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
ALL = ("K01", "K02", "K03", "K04", "K05", "K06", "K07", "K08", "K09", "K10", "K11", "K12", "K13", "K14", "K15",
       "K16", "K17", "K18", "K19", "K20", "K21", "K22", "K23", "K24")
check("每題都成功", sorted((c, r[6]) for c, r in res.items()), [(c, "OK") for c in ALL])

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
check("K21 明細：觀察期間建立、倒填、在白名單", sorted(d), ["0000600001", "0000600002", "0000600003", "0000600006"])
check("K21 倒填但期間沒有 PO 不標記（RequirePo = 1）", (d["0000600006"].BackdateDays, d["0000600006"].IsFlagged),
      (61, False))
check("K21 倒填 61 天標記、期間內 2 筆 PO 共 1500", (d["0000600001"].BackdateDays, d["0000600001"].IsFlagged,
      d["0000600001"].PoCount, float(d["0000600001"].PoAmountLocal)), (61, True, 2, 1500.0))
check("K21 倒填 10 天不標記", d["0000600002"].IsFlagged, False)
check("K21 A018 不分工廠，兩個工廠的 PO 都算", d["0000600003"].PoCount, 2)

# K01
d = {(x.IssueNo, x.PoNumber): x for x in one("SELECT * FROM kri.K01_Detail WHERE RunId = ?", rid)}
check("K01 明細：異常單期間內同供應商的 PO（數字代碼補零比對）", sorted(d),
      [("Q1", "4540000001"), ("Q1", "4540000003"), ("Q2", "4540000004"), ("Q4", "4540000006"),
       ("Q5", "4540000007")])
check("K01 同料號註明（數字料號補零）、全部標記",
      ([d[k].SameMaterial for k in sorted(d)], all(x.IsFlagged for x in d.values())),
      ([True, False, False, True, False], True))
check("K01 基準日之後才結案：期間算到基準日", str(d[("Q5", "4540000007")].WindowEnd), AS_OF)
check("K01 備註：結案沒結案日的略過 1 張", "略過 1" in res["K01"][7], True)

# K03
d = {x.Vendor: x for x in one("SELECT * FROM kri.K03_Detail WHERE RunId = ?", rid)}
check("K03 明細：只有凍結欄位的解凍事件", sorted(d),
      ["0000000020", "0000000021", "0000000022", "0000000023", "0000000024", "0000000026",
       "0000000027", "0000000028", "0000000029", "0000000030", "0000000031"])
check("K03 基準日之後的再凍結看不到", (d["0000000026"].ReblockDate, d["0000000026"].OpenDays, d["0000000026"].IsFlagged),
      (None, 30, False))
check("K03 解凍 9 天、期間有 PO → 標記", (d["0000000020"].OpenDays, d["0000000020"].PoCount, d["0000000020"].IsFlagged),
      (9, 1, True))
check("K03 LFM1 只算該採購組織的 PO", (d["0000000021"].Scope, d["0000000021"].PoCount, d["0000000021"].IsFlagged),
      ("P001", 0, False))
check("K03 解凍太久、沒再凍結都不標記", (d["0000000022"].IsFlagged, d["0000000023"].ReblockDate, d["0000000023"].IsFlagged),
      (False, None, False))
check("K03 LFB1 期間內有應付傳票 → 標記", (d["0000000024"].Scope, d["0000000024"].ApCount, d["0000000024"].IsFlagged),
      ("1000", 1, True))
x = one("SELECT Scope, IsFlagged FROM kri.K03_Detail WHERE RunId = ? AND Vendor = '0000000027' ORDER BY Scope", rid)
check("K03 同一張異動單解凍兩個採購組織：各一筆、只標有 PO 的", [(r.Scope, r.IsFlagged) for r in x],
      [("P001", True), ("TW02", False)])
check("K03 採購凍結只算 PO、過帳凍結只算傳票", (d["0000000028"].ApCount, d["0000000028"].IsFlagged,
      d["0000000022"].PoCount), (0, False, 0))
check("K03 同一天、沒有時間：用異動單號排先後", (d["0000000029"].ReblockDate is not None, d["0000000029"].OpenDays,
      d["0000000029"].IsFlagged), (True, 0, True))
check("K03 過帳凍結：解凍期間輸入、過帳日倒填的傳票也算", (d["0000000030"].ApCount, d["0000000030"].IsFlagged), (1, True))
check("K03 過帳凍結：再凍結後才輸入的不算（過帳日在期間內也一樣）",
      (d["0000000031"].ApCount, d["0000000031"].IsFlagged), (0, False))

# K04
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K04_Detail WHERE RunId = ?", rid)}
check("K04 母體：有供應商的 PO（含條件空白）", sorted(k for k in d if k.startswith("455")),
      [f"455000000{i}" for i in range(1, 10)] + ["4550000010", "4550000011", "4550000012"])
check("K04 其他題的 PO 沒主檔：缺主檔、不標記", {d[k].Status for k in d if not k.startswith("455")}, {"缺主檔"})
check("K04 比主檔好不標記", (d["4550000006"].Status, d["4550000006"].WorseDays, d["4550000006"].IsFlagged),
      ("PO與主檔不同", -5, False))
x = d["4550000001"]
check("K04 PO 比主檔提早 15 天 → 標記、資金成本 300", (x.Status, x.WorseDays, x.IsFlagged, float(x.EffectLocal)),
      ("都不同", 15, True, 300.0))
check("K04 應付有好幾種條件：和 PO 不同的優先（推不出天數的也要列出）", x.ApTerm, "ZZZZ")
check("K04 和 LFM1 不同但和 LFB1 一樣：算一致（MasterLevel = 2）",
      (d["4550000002"].Status, d["4550000002"].WorseDays, d["4550000002"].IsFlagged), ("同公司別主檔", None, False))
check("K04 應付傳票比 PO 短 35 天 → 標記", (d["4550000003"].Status, d["4550000003"].ApTerm,
      d["4550000003"].WorseDays, d["4550000003"].IsFlagged), ("AP與PO不同", "T010", 35, True))
check("K04 沒主檔、推不出天數都不標記", (d["4550000004"].Status, d["4550000004"].IsFlagged,
      d["4550000005"].PoDays, d["4550000005"].IsFlagged), ("缺主檔", False, None, False))
check("K04 基準日之後的應付傳票不看", (d["4550000007"].ApTerm, d["4550000007"].Status), (None, "一致"))
check("K04 LFB1 空白：照樣跟 LFM1 比 → 標記", (d["4550000008"].Status, d["4550000008"].WorseDays,
      d["4550000008"].IsFlagged), ("PO與主檔不同", 15, True))
check("K04 天數從代碼推估的註明", d["4550000001"].DaysEstimated, True)
check("K04 貸項通知單不跟 PO 比", (d["4550000002"].ApTerm, d["4550000002"].Status), (None, "同公司別主檔"))
check("K04 PO 條件空白算立即付款 → 提早 45 天", (d["4550000009"].PoDays, d["4550000009"].WorseDays,
      d["4550000009"].IsFlagged), (0, 45, True))
check("K04 PO 空白但發票照主檔付：一致、不標記", (d["4550000010"].Status, d["4550000010"].PoDays,
      d["4550000010"].IsFlagged), ("一致", 45, False))
check("K04 PO 空白、發票有推不出天數的條件：列出來、算推不出天數",
      (d["4550000011"].ApTerm, d["4550000011"].WorseDays, d["4550000011"].IsFlagged), ("ZZZZ", None, False))
check("K04 PO 空白、發票比主檔早 15 天 → 標記", (d["4550000012"].ApTerm, d["4550000012"].WorseDays,
      d["4550000012"].IsFlagged, float(d["4550000012"].EffectLocal)), ("T030", 15, True, 300.0))

# K10
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K10_Detail WHERE RunId = ?", rid)}
check("K10 明細：有收貨（101 借方）、基準日當時已存在的 PO", sorted(d),
      ["4560000001", "4560000002", "4560000003", "4560000004", "4560000005", "4560000006", "4560000008",
       "4560000010", "4560000011", "4600000001", "4690000002", "4690000003"])
check("K10 送貨單日早於 PO：照樣標記", (d["4560000011"].GapDays, d["4560000011"].DocGapDays, d["4560000011"].IsFlagged),
      (10, -5, True))
x = one("SELECT MetricValue, ThresholdValue, Reason FROM kri.Flag WHERE RunId = ? AND KriCode = 'K10' "
        "AND DocNumber = '4560000011'", rid)[0]
check("K10 只因送貨單日標記：指標用送貨單日", (float(x.MetricValue), float(x.ThresholdValue), x.Reason.startswith("送貨單")),
      (-5.0, 0.0, True))
check("K10 備註列出送貨單早於 PO 的筆數", "送貨單早於 PO 1" in res["K10"][7], True)
check("K10 整張 PO 金額含沒收貨的項目：超過上限不標記",
      (float(d["4560000008"].PoAmountLocal), d["4560000008"].AmountCheck, d["4560000008"].IsFlagged),
      (510000.0, "超過上限", False))
check("K10 收貨早於 PO 2 天（取第一次收貨）", (d["4560000001"].GapDays, d["4560000001"].IsFlagged), (-2, True))
check("K10 輸入日比過帳日早時用輸入日", (d["4560000002"].GapDays, d["4560000002"].IsFlagged), (1, True))
check("K10 間隔 2 天不標記", d["4560000003"].IsFlagged, False)
check("K10 排除關鍵字、超過 50 萬不標記", (d["4560000004"].HasExcludedText, d["4560000004"].IsFlagged,
      d["4560000005"].AmountCheck, d["4560000005"].IsFlagged), (True, False, "超過上限", False))
check("K10 本幣不是 TWD：金額未判斷、照樣標記", (d["4560000006"].AmountCheck, d["4560000006"].IsFlagged),
      ("未判斷", True))

# K19
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K19_Detail WHERE RunId = ?", rid)}
check("K19 有 PR 用 PR 日：42 天不標記", (d["4560000003"].RefType, d["4560000003"].GapDays, d["4560000003"].IsFlagged),
      ("PR", 42, False))
check("K19 沒有 PR 用 PO 日、不限金額", sorted(k for k, x in d.items() if x.IsFlagged),
      ["4560000001", "4560000002", "4560000005", "4560000006", "4560000008"])
check("K19 有 PR 號碼但 PR 找不到：不退回 PO 日、不標記",
      (d["4560000010"].RefType, d["4560000010"].RefDate, d["4560000010"].IsFlagged), ("PR", None, False))
check("K19 備註列出 PR 找不到的筆數", "PR 找不到 1" in res["K19"][7], True)

# K09
d = {x.AccountingDoc: x for x in one("SELECT * FROM kri.K09_Detail WHERE RunId = ?", rid)}
check("K09 候選：同供應商、同成本中心、視窗內兩張以上（借方、付款傳票不算）", sorted(d), ["5200000002"])
x = d["5200000002"]
check("K09 合計 12000 第 2 層 > 單張第 1 層 → 標記", (float(x.WindowAmount), x.WindowLevel, x.OwnLevel, x.IsFlagged),
      (12000.0, 2, 1, True))

# K12
d = {x.Material: x for x in one("SELECT * FROM kri.K12_Detail WHERE RunId = ?", rid) if x.Vendor != "V52"}
check("K12 獨家漲 30%、群組平均 5% → 標記、影響 2500",
      (round(float(d["M70"].PriceChange), 4), round(float(d["M70"].GroupChange), 4), d["M70"].IsFlagged,
       float(d["M70"].EffectLocal)), (0.3, 0.05, True, 2500.0))
check("K12 兩家供應商、漲幅正常都不標記", (d["M71"].VendorCount, d["M71"].IsFlagged, d["M72"].IsFlagged), (2, False, False))
check("K12 群組沒得比：基準以 0 計 → 漲 15% 標記", (d["M74"].GroupChange, d["M74"].IsFlagged), (None, True))
check("K12 合理獨家白名單不標記", d["M75"].IsFlagged, False)

# K22
d = {x.ConditionRecord: x for x in one("SELECT * FROM kri.K22_Detail WHERE RunId = ?", rid)}
check("K22 漲 30% → 標記、生效後 PO 多付 300", (d["0000700002"].PrevRecord, round(float(d["0000700002"].IncreaseRatio), 4),
      d["0000700002"].IsFlagged, d["0000700002"].PoCount, float(d["0000700002"].EffectLocal)),
      ("0000700001", 0.3, True, 1, 300.0))
check("K22 建立日空白用生效日、不限資訊記錄類別", (d["0000700021"].IsFlagged, d["0000700031"].IsFlagged), (True, True))
check("K22 漲 10%、降價、沒有前一筆都不標記",
      (d["0000700004"].IsFlagged, d["0000700011"].IsFlagged, d["0000700001"].CompareStatus), (False, False, "無前一筆"))

# K23
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K23_Detail WHERE RunId = ?", rid)}
check("K23 只有下單後主檔價變便宜、還沒收完的 PO", sorted(d), ["4600000001"])
x = d["4600000001"]
check("K23 主檔 15、PO 20 → 標記，未收 60 多付 300", (float(x.InfoUnitPrice), float(x.OpenQty), x.IsFlagged,
      float(x.EffectLocal)), (15.0, 60.0, True, 300.0))

# K24
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K24_Detail WHERE RunId = ?", rid)}
check("K24 明細：休眠後重新下單 90 天內的 PO", sorted(k for k in d if k.startswith("461")),
      ["4610000002", "4610000004", "4610000006", "4610000010"])
check("K24 參考 PO 只有 1 筆：不標記", (d["4610000010"].RefPoCount, d["4610000010"].IsFlagged), (1, False))
check("K24 參考價太分散：不標記", (float(d["4610000006"].RefSpread), d["4610000006"].IsFlagged), (6.0, False))
x = d["4610000002"]
check("K24 比別家均價高 30% → 標記", (x.DormantDays, float(x.RefUnitPrice), x.IsFlagged, float(x.EffectLocal)),
      (639, 10.0, True, 300.0))
check("K24 沒有別家可比：留在明細、不標記", (d["4610000004"].RefUnitPrice, d["4610000004"].IsFlagged), (None, False))

# K02
d = {(x.VendorA, x.VendorB, x.MatchType): x for x in one("SELECT * FROM kri.K02_Detail WHERE RunId = ?", rid)}
check("K02 配對：統編、電話（去符號）、地址（去空白標點）、商工登記", sorted(d),
      [("V80", "V81", "TaxNumber"), ("V82", "V83", "Phone"), ("V84", "V85", "Address"), ("V84", "V85", "商工登記"),
       ("V86", "V87", "TaxNumber")])
check("K02 填充值（NANANA、0000000000）不配對", [k for k in d if "V88" in k], [])
check("K02 基準日之後才凍結的不算凍結；商工登記正反、多種關係併成一筆",
      (d[("V86", "V87", "TaxNumber")].ABlocked, d[("V86", "V87", "TaxNumber")].IsFlagged,
       d[("V84", "V85", "商工登記")].MatchValue), (False, False, "同代表人；同代表人（反向）；同地址"))
check("K02 凍結廠商的關聯廠商仍交易、關聯廠商買同料號 → 標記",
      (d[("V80", "V81", "TaxNumber")].Scenario, d[("V82", "V83", "Phone")].Scenario, d[("V84", "V85", "Address")].IsFlagged),
      ("凍結廠商關聯交易", "關聯廠商同料號", False))

# K05
d = {x.Vendor: x for x in one("SELECT * FROM kri.K05_Detail WHERE RunId = ?", rid)}
check("K05 未收 150 萬 / 資本 100 萬 → 標記", (float(d["V90"].Ratio), d["V90"].IsFlagged), (1.5, True))
check("K05 用統編對到資本額、沒超過；查不到的列無資本額",
      (float(d["V91"].Capital), d["V91"].IsFlagged, d["V92"].Status), (10000000.0, False, "無資本額"))

# K06
d = {x.PrNumber: x for x in one("SELECT * FROM kri.K06_Detail WHERE RunId = ?", rid)}
x = d["1000000101"]
check("K06 回推請購當天庫存 1600、月耗用 100 → 可用 16 個月 → 標記",
      (float(x.StockAtPr), float(x.AvgMonthlyUse), float(x.CoverageMonths), x.IsFlagged), (1600.0, 100.0, 16.0, True))
check("K06 沒有耗用但有庫存 → 標記；庫存用完的不標", (d["1000000102"].Status, d["1000000102"].IsFlagged,
      float(d["1000000103"].StockAtPr), d["1000000103"].IsFlagged), ("無耗用", True, 0.0, False))
check("K06 在途不含 PR 自己轉的 PO、已結案的 PO；6 BOX 換成 72 EA",
      (float(d["1000000101"].OpenPoQty), float(d["1000000103"].OpenPoQty)), (0.0, 72.0))

# K07
d = {(x.Material, str(x.Month)): x for x in one("SELECT * FROM kri.K07_Detail WHERE RunId = ?", rid)}
check("K07 只有 7 月暴增被標記", [k[1] for k in sorted(d) if k[0] == "M120" and d[k].IsFlagged], ["2025-07-01"])
check("K07 有預期量表用表：100 / 1000 不標記", (d[("M121", "2025-08-01")].ExpectedSource, d[("M121", "2025-08-01")].IsFlagged),
      ("預期量表", False))

# 通用料號
check("通用料號 K07 不看", [k for k in d if k[0] == "M125"], [])
check("PoBase 標出通用料號", sorted(set((r.Material, r.IsGeneric) for r in one(
      "SELECT Material, IsGeneric FROM kri.PoBase('K13', '2025-04-01', '2025-04-01') WHERE Material IN ('M125', 'M126')"))),
      [("M125", True), ("M126", False)])
check("建議清單：多家供應商、單價差很大的料號（已列入的有註明）",
      sorted((r.Material, r.Vendors, float(r.Spread), r.Listed) for r in one(
          "EXEC kri.SuggestGenericMaterial @From = '2025-04-01', @To = '2025-04-01'")),
      [("M125", 5, 100.0, "已列入"), ("M126", 5, 100.0, "")])

# K11
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K11_Detail WHERE RunId = ?", rid)}
check("K11 只看緊急採購；有庫存或 MOU 高 → 標記", sorted((k, x.IsFlagged) for k, x in d.items()),
      [("4640000001", True), ("4640000002", True), ("4640000003", False)])

# K15
d = {x.Material: x for x in one("SELECT * FROM kri.K15_Detail WHERE RunId = ?", rid)}
check("K15 沒有呆滯報表：最後異動推估，10 天內呆滯 → 標記", (d["M140"].Source, d["M140"].DaysToSlow, d["M140"].IsFlagged),
      ("SAP推估", 10, True))
check("K15 已呆滯、還早的不標記", (d["M142"].IsFlagged, d["M110"].IsFlagged), (False, False))

# K16
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K16_Detail WHERE RunId = ?", rid)}
check("K16 呆滯、有庫存仍下單 → 標記", sorted((k, x.IsFlagged) for k, x in d.items()), [("4650000001", True)])

# K17
d = {x.PoNumber: x for x in one("SELECT * FROM kri.K17_Detail WHERE RunId = ?", rid)}
check("K17 重大工程 PO 的合約狀態", sorted((k, x.Status, x.IsFlagged) for k, x in d.items()),
      [("4660000001", "無合約", True), ("4660000002", "有合約", False), ("4660000003", "合約晚於PO", True),
       ("4660000005", "有合約", False)])

# K20
d = {x.Material: x for x in one("SELECT * FROM kri.K20_Detail WHERE RunId = ?", rid)}
check("K20 先進先出：9 天處理完、75 天才處理完、60 天還沒處理",
      [(m, d[m].OpenDays, d[m].IsFlagged) for m in ("M150", "M151", "M152")],
      [("M150", 9, False), ("M151", 75, True), ("M152", 60, True)])

# Flag 與 view
r = one("SELECT KriCode, COUNT(*) FROM kri.vFlagLatest GROUP BY KriCode ORDER BY KriCode")
check("vFlagLatest 各題標記數", [(x[0], x[1]) for x in r],
      [("K01", 5), ("K02", 2), ("K03", 5), ("K04", 5), ("K05", 1), ("K06", 2), ("K07", 1), ("K08", 2), ("K09", 1),
       ("K10", 5), ("K11", 2), ("K12", 2), ("K13", 1), ("K14", 4), ("K15", 1), ("K16", 1), ("K17", 2), ("K18", 1),
       ("K19", 5), ("K20", 2), ("K21", 2), ("K22", 3), ("K23", 1), ("K24", 1)])

# 參數與對照表改了，結果跟著變
cur.execute("UPDATE kri.Parameter SET ParamValue = 1 WHERE KriCode = 'K01' AND ParamName = 'RequireSameMaterial'")
cur.execute("INSERT kri.PaymentTerm (Code, Days) VALUES ('IMMD', 0), ('T045', 45)")
res, rid1 = run("K01,K04")
check("K01 只看同料號：剩 2 筆", sorted(x.PoNumber for x in one("SELECT PoNumber FROM kri.K01_Detail WHERE RunId = ?", rid1)),
      ["4540000001", "4540000006"])
cur.execute("UPDATE kri.Parameter SET ParamValue = 0 WHERE KriCode = 'K01' AND ParamName = 'RequireSameMaterial'")
cur.execute("UPDATE kri.Parameter SET ParamValue = 2 WHERE KriCode = 'K01' AND ParamName = 'MinPoCount'")
res, rid1b = run("K01")
check("K01 MinPoCount = 2：只標期間內有 2 筆以上的單（Q1）",
      sorted(x.IssueNo for x in one("SELECT IssueNo FROM kri.K01_Detail WHERE RunId = ? AND IsFlagged = 1", rid1b)),
      ["Q1", "Q1"])
x = one("SELECT PoDays, WorseDays, IsFlagged FROM kri.K04_Detail WHERE RunId = ? AND PoNumber = '4550000005'", rid1)[0]
check("K04 kri.PaymentTerm 有值時用對照表的天數", (x.PoDays, x.WorseDays, x.IsFlagged), (0, 45, True))
x = one("SELECT DaysEstimated FROM kri.K04_Detail WHERE RunId = ? AND PoNumber = '4550000009'", rid1)[0]
check("K04 PO 條件空白的 0 天是規則、不算推估（主檔天數查得到時）", x.DaysEstimated, False)

ins("ext.SlowMoving", [dict(SnapshotDate="2025-12-31", Material="M141", Plant="1100", Status="A", SlowOn="2026-01-05",
                           StockQty=5, StockValue=999)])
res, rid3 = run("K15")
check("K15 有呆滯報表就只用報表", [(x.Material, x.Source, x.IsFlagged) for x in
      one("SELECT Material, Source, IsFlagged FROM kri.K15_Detail WHERE RunId = ?", rid3)], [("M141", "呆滯報表", True)])

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
check("缺參數：其他題照跑", sorted(c for c, r in res.items() if r[6] == "OK"), [c for c in ALL if c != "K18"])
check("Run 狀態為 PARTIAL", one("SELECT Status FROM kri.Run WHERE RunId = (SELECT MAX(RunId) FROM kri.Run)")[0][0], "PARTIAL")
run_file("12_kri_seed.sql")      # 重跑 seed 會把缺的參數補回來

cur.execute("EXEC sp_rename 'mst.PurchasingCondA018', 'PurchasingCondA018_x'")
res, _ = run()
check("A018 不見：用到它的 K14、K21、K22、K23 失敗，其他照跑",
      sorted((c, r[6]) for c, r in res.items()),
      [(c, "FAILED" if c in ("K14", "K21", "K22", "K23") else "OK") for c in ALL])
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
