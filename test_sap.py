"""SAP 匯出檔的解析測試。

這裡的 fixture 都是照 SAP GUI「Export -> Spreadsheet / Unconverted」
實際吐出來的長相寫的：標題列、空白列、頁尾統計、尾綴負號、
德式小數點、前導零料號、DD.MM.YYYY 日期。

不需要連資料庫，最後一個測試用 sqlite 驗證整條路走得通。
"""
import sqlite3
from pathlib import Path

import pandas as pd
import pytest

import core

TAB_TXT = (
    "Dynamic List Display\n"
    "\n"
    "MATNR\tMAKTX\tMENGE\tWERT\tERDAT\n"
    "000000000010001234\tWAFER 12IN\t1.234\t1.234,56\t31.12.2026\n"
    "000000000010001235\tWAFER 8IN\t56\t1.000,00-\t01.01.2026\n"
    "000000000010001236\tWAFER 6IN\t0\t0,00\t00000000\n"
    "\n"
    "* 3 筆記錄\n"
)

PIPE_TXT = (
    "Dynamic List Display\n"
    "-------------------------------------\n"
    "|MATNR   |MAKTX      |MENGE|ERDAT     |\n"
    "|--------|-----------|-----|----------|\n"
    "|1000123 |WAFER 12IN |   12|31.12.2026|\n"
    "|1000124 |WAFER 8IN  |  34-|01.01.2026|\n"
    "-------------------------------------\n"
    "* 2 筆記錄\n"
)


def write(tmp_path, name, text, encoding="utf-8-sig"):
    p = tmp_path / name
    p.write_bytes(text.encode(encoding))
    return p


# --- 編碼 ---------------------------------------------------------------

@pytest.mark.parametrize("encoding", ["utf-8-sig", "utf-16", "utf-8", "cp950"])
def test_decode_handles_sap_encodings(encoding):
    raw = "料號\tMENGE\nA\t1\n".encode(encoding)
    assert core.decode(raw).splitlines()[0] == "料號\tMENGE"


# --- 版面 ---------------------------------------------------------------

def test_tab_export_drops_title_blank_and_footer(tmp_path):
    df = core.read(write(tmp_path, "ZMM001.txt", TAB_TXT))
    assert list(df.columns) == ["MATNR", "MAKTX", "MENGE", "WERT", "ERDAT"]
    assert len(df) == 3


def test_pipe_export_drops_rules_and_footer(tmp_path):
    df = core.read(write(tmp_path, "ZMM002.txt", PIPE_TXT))
    assert list(df.columns) == ["MATNR", "MAKTX", "MENGE", "ERDAT"]
    assert len(df) == 2
    assert df["MAKTX"].tolist() == ["WAFER 12IN", "WAFER 8IN"]


def test_count_rows_matches_read(tmp_path):
    p = write(tmp_path, "ZMM001.txt", TAB_TXT)
    assert core.count_rows(p) == len(core.read(p))


def test_config_can_override_autodetect(tmp_path):
    p = write(tmp_path, "ZMM001.txt", TAB_TXT)
    df = core.read(p, opts={"encoding": "utf-8-sig", "sep": "\t", "skiprows": 2})
    assert list(df.columns) == ["MATNR", "MAKTX", "MENGE", "WERT", "ERDAT"]


# --- 數值 ---------------------------------------------------------------

def test_trailing_minus_becomes_negative(tmp_path):
    df = core.read(write(tmp_path, "ZMM001.txt", TAB_TXT))
    assert df["WERT"].tolist() == [1234.56, -1000.0, 0.0]


def test_pipe_trailing_minus(tmp_path):
    df = core.read(write(tmp_path, "ZMM002.txt", PIPE_TXT))
    assert df["MENGE"].tolist() == [12, -34]


def test_ambiguous_single_dot_is_thousands(tmp_path):
    # 整欄只有 "1.234" / "56" / "0"，看不出是千分位還是小數點。
    # SAP 預設輸出千分位，所以當 1234 解讀。
    df = core.read(write(tmp_path, "ZMM001.txt", TAB_TXT))
    assert df["MENGE"].tolist() == [1234, 56, 0]


def test_leading_zero_code_stays_text(tmp_path):
    df = core.read(write(tmp_path, "ZMM001.txt", TAB_TXT))
    assert df["MATNR"].tolist() == [
        "000000000010001234", "000000000010001235", "000000000010001236"]


# --- 日期 ---------------------------------------------------------------

def test_ddmmyyyy_parsed_and_null_marker_is_nat(tmp_path):
    df = core.read(write(tmp_path, "ZMM001.txt", TAB_TXT))
    assert df["ERDAT"].tolist()[:2] == [
        pd.Timestamp("2026-12-31"), pd.Timestamp("2026-01-01")]
    assert pd.isna(df["ERDAT"].iloc[2])


def test_day_over_12_forces_day_first():
    s = pd.Series(["31/12/2026", "01/02/2026"])
    assert core.sap_dates(s).tolist() == [
        pd.Timestamp("2026-12-31"), pd.Timestamp("2026-02-01")]


def test_eight_digit_code_is_not_a_date():
    # 10001234 -> 年份 1000，不是合理日期，必須保持原樣。
    assert core.sap_dates(pd.Series(["10001234", "10001235"])) is None


# --- 型別推斷 -----------------------------------------------------------

def test_infer_sees_real_types_after_sap_conversion(tmp_path):
    df = core.read(write(tmp_path, "ZMM001.txt", TAB_TXT))
    assert core.infer(df["MENGE"]) == "INT"
    assert core.infer(df["WERT"]).startswith("DECIMAL")
    assert core.infer(df["ERDAT"]) == "DATE"
    assert core.infer(df["MATNR"]).startswith("NVARCHAR")


# --- 設定 ---------------------------------------------------------------

def test_env_builds_trusted_conn(monkeypatch):
    monkeypatch.setenv("SQL_SERVER", "SRV01")
    monkeypatch.setenv("SQL_DATABASE", "UMC")
    conn = core.conn_from_env()
    assert conn.startswith("mssql+pyodbc://@SRV01/UMC?")
    assert "trusted_connection=yes" in conn


def test_env_escapes_password(monkeypatch):
    monkeypatch.setenv("SQL_SERVER", "SRV01")
    monkeypatch.setenv("SQL_DATABASE", "UMC")
    monkeypatch.setenv("SQL_USER", "sa")
    monkeypatch.setenv("SQL_PASSWORD", "p@ss w/rd")
    assert "p%40ss+w%2Frd@SRV01" in core.conn_from_env()


def test_env_file_does_not_clobber_real_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("SQL_SERVER", "REAL")
    (tmp_path / ".env").write_text(
        "# 註解\nSQL_SERVER=FROMFILE\nSQL_DATABASE = UMC \n", encoding="utf-8")
    core.load_env(tmp_path / ".env")
    import os
    assert os.environ["SQL_SERVER"] == "REAL"
    assert os.environ["SQL_DATABASE"] == "UMC"


def test_config_prefers_env_over_json(tmp_path, monkeypatch):
    monkeypatch.setenv("SQL_SERVER", "SRV01")
    monkeypatch.setenv("SQL_DATABASE", "UMC")
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text('{"conn": "sqlite:///x.db"}', encoding="utf-8")
    assert core.load_config(cfg_path)["conn"].startswith("mssql+pyodbc://@SRV01")


# --- 端到端 -------------------------------------------------------------

def test_txt_and_excel_land_in_one_table(tmp_path):
    root = tmp_path / "data" / "ZMM001"
    root.mkdir(parents=True)
    write(root, "part1.txt", TAB_TXT)
    pd.DataFrame({
        "MATNR": ["000000000010009999"], "MAKTX": ["WAFER 4IN"],
        "MENGE": [7], "WERT": [12.5], "ERDAT": [pd.Timestamp("2026-06-01")],
    }).to_excel(root / "part2.xlsx", index=False)

    tables = core.scan(tmp_path / "data")
    assert len(tables) == 1 and tables[0].ok, tables[0].error
    assert tables[0].rows == 4

    db = tmp_path / "out.db"
    engine = core.connect(f"sqlite:///{db}")
    assert core.import_table(engine, tables[0]) == 4

    with sqlite3.connect(db) as c:
        rows = c.execute(
            "SELECT MATNR, WERT FROM ZMM001 ORDER BY MATNR").fetchall()
    assert rows[0] == ("000000000010001234", 1234.56)
    assert rows[1][1] == -1000.0


# --- SAP 代碼欄位清單 ---------------------------------------------------

SAP_FI_TXT = (
    "Dynamic List Display\n"
    "\n"
    "BUKRS\tBELNR\tGJAHR\tWRBTR\tZFBDT\tMENGE\n"
    "8104\t1449008934\t2026\t1.234,56\t31.12.2026\t12\n"
    "1763\t1597714383\t2026\t70.319,87-\t01.01.2026\t34\n"
)


def test_code_field_stays_text_even_when_it_looks_numeric(tmp_path):
    df = core.read(write(tmp_path, "BESG.txt", SAP_FI_TXT))
    assert df["BUKRS"].tolist() == ["8104", "1763"]
    assert df["BELNR"].tolist() == ["1449008934", "1597714383"]
    assert df["GJAHR"].tolist() == ["2026", "2026"]


def test_field_not_in_list_still_converts(tmp_path):
    df = core.read(write(tmp_path, "BESG.txt", SAP_FI_TXT))
    assert df["WRBTR"].tolist() == [1234.56, -70319.87]
    assert df["MENGE"].tolist() == [12, 34]
    assert df["ZFBDT"].iloc[0] == pd.Timestamp("2026-12-31")


@pytest.mark.parametrize("name", ["bukrs", " BUKRS ", "Bukrs"])
def test_code_field_ignores_case_and_spaces(name):
    assert core.is_code_field(name)


def test_dtypes_override_can_force_a_code_field_back_to_number(tmp_path):
    t = core.scan(write(tmp_path, "BESG.txt", SAP_FI_TXT).parent)[0]
    assert t.dtypes["BUKRS"].startswith("NVARCHAR")
    df = core.coerce(core.load(t.files), {**t.dtypes, "BUKRS": "INT"})
    assert df["BUKRS"].tolist() == [8104, 1763]


def test_sniff_reuses_the_list_instead_of_copying_it():
    import sniff
    assert sniff.SAP_CODE_FIELDS is core.SAP_CODE_FIELDS


def test_sniff_marks_code_fields(tmp_path):
    import sniff
    p = write(tmp_path, "BESG.txt", SAP_FI_TXT)
    _, _, _, sep, header, data, _ = sniff.layout_of(p)
    codes = {name: sniff.guess_type([r[i] for r in data], name)[2]
             for i, name in enumerate(header)}
    assert codes["BUKRS"] == "T!" and codes["BELNR"] == "T!"
    assert codes["WRBTR"] == "N-" and codes["MENGE"] == "N"   # MENGE 是已知數字欄位


@pytest.mark.parametrize("name, why", [
    ("KNUMH", "條件記錄號"), ("KNUMV", "條件記錄號"),
    ("ORD41", "資產評估欄位"), ("ORD44", "資產評估欄位"),
    ("STJAH", "反轉年度"), ("URJHR", "原始年度"), ("LFGJA", "收貨年度"),
    ("INVNR", "庫存號碼"), ("SERNR", "序號"), ("ANLKL", "資產類別"),
    ("EAUFN", "投資訂單"), ("STBLG", "反轉憑證"), ("MONAT", "會計期間"),
])
def test_patterns_and_additions_catch_code_fields(name, why):
    assert core.is_code_field(name), why


@pytest.mark.parametrize("name, why", [
    ("WRBTR", "金額"), ("DMBTR", "金額"), ("KURSF", "匯率"),
    ("MENGE", "數量"), ("URWRT", "原始價值"),
    ("BUDAT", "過帳日"), ("BLDAT", "憑證日"), ("AEDAT", "異動日"),
    ("TXT50", "資產說明"), ("BKTXT", "憑證抬頭文字"),
])
def test_patterns_do_not_swallow_amounts_dates_or_text(name, why):
    assert not core.is_code_field(name), why


# --- 可疑欄位警示 -------------------------------------------------------

SUSPECT_TXT = (
    "Dynamic List Display\n"
    "\n"
    "BUKRS\tDOCTYPE\tMENGE\tWRBTR\tBUDAT\n"
    "8104\t4500000123\t12\t1.234,56\t31.12.2026\n"
    "1763\t4500000124\t34\t70.319,87-\t01.01.2026\n"
)


def test_suspects_flags_unknown_integer_columns(tmp_path):
    t = core.scan(write(tmp_path, "ZFI001.txt", SUSPECT_TXT).parent)[0]
    # DOCTYPE 是自訂欄名又是整數 -> 可疑。其餘都有憑有據。
    assert core.suspects(t) == ["DOCTYPE"]


def test_suspects_ignores_known_numeric_fields(tmp_path):
    t = core.scan(write(tmp_path, "ZFI001.txt", SUSPECT_TXT).parent)[0]
    assert t.dtypes["MENGE"] == "INT"
    assert "MENGE" not in core.suspects(t)


def test_sniff_marks_suspect_and_spares_quantities(tmp_path):
    import sniff
    p = write(tmp_path, "ZFI001.txt", SUSPECT_TXT)
    _, _, _, _, header, data, _ = sniff.layout_of(p)
    codes = {n: sniff.guess_type([r[i] for r in data], n)[2]
             for i, n in enumerate(header)}
    assert codes["DOCTYPE"] == "N!"
    assert codes["MENGE"] == "N"
    assert codes["WRBTR"] == "N-" and codes["BUKRS"] == "T!"


# --- 欄位涵蓋率 ---------------------------------------------------------
#
# 實際要匯入的 34 張表（ZTM80／ZTM105 是自訂表，欄位未知所以不列）。
# 只列常被萃取的欄位，不是完整的 DDIC 定義。
# 這組測試鎖住兩個方向：代碼欄位不能漏，日期／金額／數量／文字說明
# 不能被誤抓成代碼。改 SAP_CODE_FIELDS 時這裡會擋下退步。

TABLES = {
"A017": "MANDT KAPPL KSCHL LIFNR MATNR EKORG WERKS ESOKZ DATBI DATAB KNUMH",

"ANLA": "MANDT BUKRS ANLN1 ANLN2 ANLKL GEGST ANLAR ERNAM ERDAT AENAM AEDAT "
        "XLOEV LVORM TXT50 TXA50 INVNR MENGE MEINS TYPBZ INVZU SERNR IZWEK "
        "WERKS LAND1 KFZKZ LIFNR LIEFE AKTIV DEAKT ABGDT ORD41 ORD42 ORD43 "
        "ORD44 EAUFN URJHR URWRT ZUJHR ZUGDT GDLGRP AIBN1 AIBN2 KOSTL PRCTR",

"BKPF": "MANDT BUKRS BELNR GJAHR BLART BLDAT BUDAT MONAT CPUDT CPUTM AEDAT "
        "UPDDT WWERT USNAM TCODE BVORG XBLNR DBBLG STBLG STJAH BKTXT WAERS "
        "KURSF KZWRS BSTAT XNETB GLVOR GRPID AWTYP AWKEY FIKRS HWAER HWAE2 "
        "HWAE3 KURS2 KURS3 XSTOV STODT XMWST AUGLV PPNAM BRNCH RLDNR LDGRP "
        "IBLAR DOCCAT XREVERSAL REINDAT VATDATE XBLNR_ALT",

"BSEG": "MANDT BUKRS BELNR GJAHR BUZEI BUZID AUGDT AUGCP AUGBL BSCHL KOART "
        "UMSKZ UMSKS ZUMSK SHKZG GSBER PARGB MWSKZ DMBTR WRBTR KZBTR PSWBT "
        "PSWSL TXBHW TXBFW MWSTS WMWST HWBAS FWBAS HWZUZ FWZUZ SKFBT SKNTO "
        "WSKTO ZTERM ZBD1T ZBD2T ZBD3T ZBD1P ZBD2P SKFBT ZLSCH ZLSPR ZBFIX "
        "HBKID BVTYP MANSP MSCHL MABER ZFBDT ZINKZ REBZG REBZE REBZJ REBZZ "
        "SGTXT ZUONR KOSTL AUFNR PROJK VBELN VBEL2 POSN2 ETEN2 FKART EBELN "
        "EBELP ZEKKN MATNR WERKS ANLN1 ANLN2 ANBWA BZDAT PERNR LIFNR KUNNR "
        "FILKD XCPDD SAKNR HKONT KTOSL XOPVW XANET XSKRL XINVE RSTGR PRCTR "
        "PPRCT XREF1 XREF2 XREF3 XNEGP MENGE MEINS VERTN VERTT VBUND KKBER "
        "EMPFB FIPOS FISTL GEBER SEGMENT PSEGMENT AUGGJ BUPLA TXJCD DOCLN",

"CDHDR": "MANDANT OBJECTCLAS OBJECTID CHANGENR USERNAME UDATE UTIME TCODE "
         "PLANCHNGNR ACT_CHNGNO WAS_PLANND CHANGE_IND LANGU VERSION",

"CDPOS": "MANDANT OBJECTCLAS OBJECTID CHANGENR TABNAME TABKEY FNAME CHNGIND "
         "TEXT_CASE UNIT_OLD UNIT_NEW CUKY_OLD CUKY_NEW VALUE_NEW VALUE_OLD",

"T001": "MANDT BUKRS BUTXT ORT01 LAND1 WAERS SPRAS KTOPL WAABW PERIV KOKFI "
        "RCOMP ADRNR STCEG FIKRS TXJCD BUVAR FDBUK KKBER WFVAR XFMCO",

"EBAN": "MANDT BANFN BNFPO BSART BSTYP BSAKZ LOEKZ STATU ESTKZ FRGKZ FRGZU "
        "FRGST EKGRP ERNAM ERDAT AFNAM TXZ01 MATNR EMATN WERKS LGORT BEDNR "
        "MATKL RESWK MENGE MEINS BUMNG BADAT LPEIN LFDAT FRGDT WEBAZ PREIS "
        "PEINH PSTYP KNTTP KFLAG VRTKZ TWRKZ WEPOS WEUNB REPOS LIFNR FLIEF "
        "EKORG VRTYP KONNR KTPNR INFNR EBELN EBELP BEDAT SPRAS BANPR",

"EBKN": "MANDT BANFN BNFPO ZEBKN LOEKZ AEDAT SAKTO GSBER KOSTL PROJN AUFNR "
        "VBELN VBELP ANLN1 ANLN2 WERKS KSTRG PAOBJNR PRCTR NPLNR AUFPL APLZL "
        "VPTNR FIPOS FISTL GEBER MENGE VPROZ NETWR",

"EINA": "MANDT INFNR LOEKZ ERDAT ERNAM MATNR MATKL LIFNR MEINS UMREZ UMREN "
        "IDNLF VERKF TELF1 MAHN1 URZNR URZDT LTSNR WGLIF LMEIN RUECK",

"EINE": "MANDT INFNR EKORG ESOKZ WERKS LOEKZ ERDAT ERNAM EKGRP WAERS MINBM "
        "NORBM APLFZ UEBTO UEBTK UNTTO ANGNR ANGDT MWSKZ REGIO INCO1 INCO2 "
        "VERID NETPR PEINH BPRME BPUMZ BPUMN EFFPR MEPRF SKTOF",

"EKBE": "MANDT EBELN EBELP ZEKKN VGABE GJAHR BELNR BUZEI BEWTP BWART BUDAT "
        "MENGE BPMNG DMBTR WRBTR WAERS AREWR WESBS BAMNG SHKZG BLDAT XBLNR "
        "LFGJA LFBNR LFPOS ELIKZ CPUDT CPUTM ERNAM MATNR WERKS LSMNG LSMEH",

"EKET": "MANDT EBELN EBELP ETENR EINDT SLFDT LPEIN MENGE AMENG WEMNG WAMNG "
        "MAHNZ BANFN BNFPO ESTKZ EGLKZ MNG02 DAT01 ALTDT AUREL",

"EKKN": "MANDT EBELN EBELP ZEKKN LOEKZ AEDAT SAKTO GSBER KOSTL PROJN AUFNR "
        "VBELN VBELP ANLN1 ANLN2 WERKS KSTRG PRCTR NPLNR AUFPL APLZL FIPOS "
        "FISTL GEBER MENGE VPROZ NETWR IMKEY PAOBJNR",

"EKKO": "MANDT EBELN BUKRS BSTYP BSART BSAKZ LOEKZ STATU AEDAT ERNAM PINCR "
        "LPONR LIFNR SPRAS ZTERM ZBD1T ZBD2T ZBD3T ZBD1P ZBD2P EKORG EKGRP "
        "WAERS WKURS KUFIX BEDAT KDATB KDATE BWBDT ANGDT BNDDT GWLDT AUSNR "
        "ANGNR IHREZ VERKF TELF1 LLIEF KUNNR KONNR AUTLF WEAKT RESWK LBLIF "
        "INCO1 INCO2 KTWRT SUBMI KNUMV KALSM STAFO LIFRE EXNUM UNSEZ LOGSY "
        "FRGGR FRGSX FRGKE FRGZU FRGRL PROCSTAT",

"EKPO": "MANDT EBELN EBELP LOEKZ STATU AEDAT TXZ01 MATNR EMATN BUKRS WERKS "
        "LGORT BEDNR MATKL INFNR IDNLF KTMNG MENGE MEINS BPRME BPUMZ BPUMN "
        "UMREZ UMREN NETPR PEINH NETWR BRTWR AGDT WEBAZ MWSKZ BONUS INSMK "
        "SPINF PRSDR SCHPR MAHNZ MAHN1 UEBTO UEBTK UNTTO BWTAR BWTTY ABSKZ "
        "ELIKZ EREKZ PSTYP KNTTP KZVBR VRTKZ TWRKZ WEPOS WEUNB REPOS WEBRE "
        "LABNR KONNR KTPNR ABDAT ETFZ1 ETFZ2 KZSTU LMEIN EVERS ZWERT ABMNG "
        "PRDAT EFFWR KUNNR ADRNR SKTOF STAFO PLIFZ NTGEW GEWEI TXJCD SOBKZ "
        "ARSNR ARSPS SSQSS ZGTYP EAN11 BSTAE REVLV GEBER FISTL FIPOS PRCTR "
        "MEPRF BRGEW VOLUM VOLEH INCO1 INCO2 LTSNR PACKNO FPLNR GNETWR STAPO "
        "UEBPO EMLIF SATNR ATTYP VSART KANBA RETPO",

"KONH": "MANDT KNUMH ERNAM ERDAM KVEWE KOTABNR KAPPL KSCHL KNUMH_REF DATAB "
        "DATBI VAKEY BOSTA KZNEP",

"KONP": "MANDT KNUMH KOPOS KAPPL KSCHL KRECH KZBZG KONMS KONWS KBETR KONWA "
        "KPEIN KMEIN KUMZA KUMNE MEINS MXWRT GKWRT LOEVM_KO VALTG VALDT",

"LFA1": "MANDT LIFNR LAND1 NAME1 NAME2 NAME3 NAME4 ORT01 ORT02 PFACH PSTL2 "
        "PSTLZ REGIO SORTL STRAS ADRNR MCOD1 KTOKK KONZS BRSCH STCD1 STCD2 "
        "STKZU STKZN SPERR SPERM LOEVM TELF1 TELF2 TELFX ERDAT ERNAM STCEG "
        "KUNNR LNRZA VBUND",

"LFB1": "MANDT LIFNR BUKRS SPERR LOEVM ERDAT ERNAM ZUAWA AKONT BEGRU VZSKZ "
        "ZWELS XVERR ZAHLS ZTERM WAKON FDGRV BUSAB LNRZE LNRZB ZINDT ZINRT "
        "DATLZ XDEZV WEBTR KULTG REPRF TOGRU HBKID XPORE QLAND MINDK ALTKN "
        "ZGRUP ZSABE",

"LFBK": "MANDT LIFNR BANKS BANKL BANKN BKONT BVTYP XEZER BKREF KOINH",

"LFM1": "MANDT LIFNR EKORG SPERM LOEVM ERDAT ERNAM LFABC WAERS VERKF TELF1 "
        "MINBW ZTERM INCO1 INCO2 WEBRE KZABS KALSK KZAUT EXPVZ ZOLLA MEPRF "
        "EKGRP XERSY PLIFZ MRPPP LIFAB LIFBI BOIND",

"MAKT": "MANDT MATNR SPRAS MAKTX MAKTG",

"MARA": "MANDT MATNR ERSDA ERNAM LAEDA AENAM VPSTA PSTAT LVORM MTART MBRSH "
        "MATKL BISMT MEINS BSTME ZEINR ZEIAR ZEIVR ZEIFO AESZN BLATT BLANZ "
        "FERTH FORMT GROES WRKST NORMT LABOR EKWSL BRGEW NTGEW GEWEI VOLUM "
        "VOLEH BEHVO RAUBE TEMPB DISST TRAGR STOFF SPART KUNNR EANNR PRDHA "
        "MSTAE MSTDE MTPOS_MARA EXTWG",

"MARC": "MANDT MATNR WERKS PSTAT LVORM BWTTY XCHAR MMSTA MMSTD MAABC KZKRI "
        "EKGRP AUSME DISPR DISMM DISPO KZDIE PLIFZ WEBAZ PERKZ AUSSS DISLS "
        "BESKZ SOBSL MINBE EISBE BSTFE BSTMI BSTMA BSTRF MABST LOSFX SBDKZ "
        "LAGPR ALTSL KZBEH STRGR PRCTR MTVFP PRFRQ FEVOR",

"MARD": "MANDT MATNR WERKS LGORT PSTAT LVORM LGPBE PRCTL LABST UMLME INSME "
        "EINME SPEME RETME VMLAB VMUML DISKZ LSOBS LMINB LBSTF",

"MBEW": "MANDT MATNR BWKEY BWTAR LVORM LBKUM SALK3 VPRSV VERPR STPRS PEINH "
        "BKLAS SALKV VMKUM VMSAL VMVPR VMVER VMSTP VMPEI VMBKL LFGJA LFMON "
        "BWPRS BWPRH ZKPRS ZKDAT TIMESTAMP",

"MBEWH": "MANDT MATNR BWKEY BWTAR LFGJA LFMON LBKUM SALK3 VPRSV VERPR STPRS "
         "PEINH BKLAS SALKV VMKUM VMSAL",

"MKPF": "MANDT MBLNR MJAHR VGART BLART BLAUM BLDAT BUDAT CPUDT CPUTM AEDAT "
        "USNAM XBLNR TCODE2 BKTXT FRATH FRBNR WEVER XABLN AWSYS VBUND BLA2D",

"MSEG": "MANDT MBLNR MJAHR ZEILE LINE_ID PARENT_ID BWART XAUTO MATNR WERKS "
        "LGORT CHARG INSMK ZUSCH ZUSTD SOBKZ LIFNR KUNNR KDAUF KDPOS KDEIN "
        "SHKZG WAERS DMBTR BNBTR BUALT SHKUM DMBUM BPMNG MENGE MEINS ERFMG "
        "ERFME BPRME EBELN EBELP LFBJA LFBNR LFPOS SJAHR SMBLN SMBLP ELIKZ "
        "SGTXT WEMPF ABLAD GSBER KOSTL AUFNR ANLN1 ANLN2 RSNUM RSPOS KZEAR "
        "PBAMG KZSTR UMMAT UMWRK UMLGO UMCHA UMZST UMZUS GRUND EVERS IMKEY "
        "KSTRG PAOBJNR PRCTR PS_PSP_PNR NPLNR AUFPL APLZL VPTNR FIPOS FISTL "
        "GEBER BUKRS XBLNR BUDAT CPUDT USNAM",

"T001W": "MANDT WERKS NAME1 BWKEY KUNNR LIFNR FABKL NAME2 STRAS PFACH PSTLZ "
         "ORT01 EKORG VKORG CHAZV KKOWK KORDB BEDPL LAND1 REGIO COUNC CITYC "
         "ADRNR TXJCD",

"T001K": "MANDT BWKEY BUKRS XBKNG BUSTW XBKPF",
}

# 這些本來就不是代碼欄位：日期、時間、金額、數量、重量、匯率、
# 文字說明、單一字元旗標。不該進代碼清單，也不該被警示。
NOT_CODES = set("""
 DATAB DATBI ERDAT ERDAM LAEDA AEDAT ERSDA AKTIV DEAKT ABGDT ZUGDT BLDAT
 BUDAT CPUDT CPUTM AEDAT UPDDT WWERT STODT REINDAT VATDATE BADAT LFDAT
 FRGDT BEDAT KDATB KDATE BWBDT ANGDT BNDDT GWLDT ABDAT PRDAT EINDT SLFDT
 URZDT ZINDT DATLZ AUGDT AUGCP ZFBDT BZDAT UDATE UTIME DAT01 ALTDT ZKDAT
 TIMESTAMP

 MENGE BUMNG KTMNG ABMNG AMENG WEMNG WAMNG MNG02 BPMNG ERFMG PBAMG LSMNG
 BAMNG WESBS MINBM NORBM MINBW LABST UMLME INSME EINME SPEME RETME VMLAB
 VMUML LBKUM VMKUM
 PREIS NETPR NETWR BRTWR EFFWR EFFPR ZWERT KTWRT GNETWR DMBTR WRBTR KZBTR
 PSWBT TXBHW TXBFW MWSTS WMWST HWBAS FWBAS HWZUZ FWZUZ SKFBT SKNTO WSKTO
 AREWR BNBTR DMBUM SHKUM SALK3 SALKV VMSAL STPRS VERPR BWPRS BWPRH ZKPRS
 VMVPR VMVER VMSTP KBETR GKWRT MXWRT WEBTR VPROZ
 PEINH KPEIN VMPEI BPUMZ BPUMN UMREZ UMREN KUMZA KUMNE
 BRGEW NTGEW VOLUM
 KURSF KURS2 KURS3 WKURS VALTG
 ZBD1T ZBD2T ZBD3T ZBD1P ZBD2P KULTG APLFZ PLIFZ WEBAZ ETFZ1 ETFZ2 UEBTO
 UNTTO AUSSS MINBE EISBE BSTFE BSTMI BSTMA BSTRF MABST LOSFX BLANZ
 LMINB LBSTF PRFRQ
 NAME1 NAME2 NAME3 NAME4 SORTL MCOD1 STRAS PFACH ORT01 ORT02 BUTXT TXZ01
 TXT50 TXA50 BKTXT SGTXT MAKTX MAKTG GEGST INVZU GROES WRKST FERTH BLATT
 AESZN VAKEY TABKEY VALUE_NEW VALUE_OLD
""".split())


# 這五個長得像代碼但其實有型別：兩個金額、三個日期。
KEEP_TYPED = {"URWRT", "VALDT", "AGDT", "MSTDE", "MMSTD"}


@pytest.mark.parametrize("table", sorted(TABLES))
def test_every_code_field_is_in_the_list(table):
    missing = [c for c in sorted(set(TABLES[table].split()))
               if not core.is_code_field(c)
               and c not in NOT_CODES and c not in KEEP_TYPED]
    assert not missing, f"{table} 漏了：{' '.join(missing)}"


@pytest.mark.parametrize("table", sorted(TABLES))
def test_no_date_amount_or_text_is_treated_as_a_code(table):
    wrong = [c for c in sorted(set(TABLES[table].split()))
             if core.is_code_field(c) and (c in NOT_CODES or c in KEEP_TYPED)]
    assert not wrong, f"{table} 誤判成代碼：{' '.join(wrong)}"


# --- Excel 也要套代碼欄位清單 -------------------------------------------

def test_excel_code_columns_become_text(tmp_path):
    # Excel 存成數字的憑證號碼，pandas 會讀成 int64。清單要把它轉回文字，
    # 否則同一個 BELNR 在 txt 是文字、在 Excel 是整數，兩張表 JOIN 不起來。
    pd.DataFrame({
        "BELNR": [1449008934, 1597714383],
        "BUKRS": [8104, 1763],
        "MANDANT": [800, 800],
        "WRBTR": [1234.56, -1000.0],
        "MENGE": [12, 34],
    }).to_excel(tmp_path / "ZTM80.xlsx", index=False)

    df = core.read(tmp_path / "ZTM80.xlsx")
    assert df["BELNR"].tolist() == ["1449008934", "1597714383"]
    assert df["BUKRS"].tolist() == ["8104", "1763"]
    assert df["MANDANT"].tolist() == ["800", "800"]
    assert df["WRBTR"].tolist() == [1234.56, -1000.0]    # 金額不動
    assert df["MENGE"].tolist() == [12, 34]              # 已知數字欄位不動


def test_excel_code_column_with_blanks_has_no_float_tail(tmp_path):
    # 有空值時整數欄會變 float64，直接轉字串會變成 "1449008934.0"
    pd.DataFrame({"BELNR": [1449008934, None], "SGTXT": ["A", "B"]}).to_excel(
        tmp_path / "ZTM80.xlsx", index=False)
    df = core.read(tmp_path / "ZTM80.xlsx")
    assert df["BELNR"].iloc[0] == "1449008934"      # 不是 "1449008934.0"
    assert pd.isna(df["BELNR"].iloc[1])


def test_excel_and_txt_agree_on_code_column_type(tmp_path):
    root = tmp_path / "data" / "BKPF"
    root.mkdir(parents=True)
    write(root, "jan.txt",
          "Dynamic List Display\n\nBUKRS\tBELNR\tWRBTR\n"
          "8104\t1449008934\t1.234,56\n")
    pd.DataFrame({"BUKRS": [1763], "BELNR": [1597714383],
                  "WRBTR": [99.0]}).to_excel(root / "feb.xlsx", index=False)

    t = core.scan(tmp_path / "data")[0]
    assert t.ok, t.error
    assert t.dtypes["BELNR"].startswith("NVARCHAR")
    assert t.dtypes["BUKRS"].startswith("NVARCHAR")
    df = core.load(t.files)                     # 檔案依檔名排序，feb 在 jan 前
    assert sorted(df["BELNR"]) == ["1449008934", "1597714383"]


# --- ODBC 驅動 ----------------------------------------------------------

def fake_drivers(monkeypatch, names):
    monkeypatch.setattr(core.pyodbc, "drivers", lambda: names)


def test_best_driver_prefers_the_highest_version(monkeypatch):
    fake_drivers(monkeypatch, [
        "SQL Server", "ODBC Driver 11 for SQL Server",
        "ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server"])
    assert core.best_driver() == "ODBC Driver 18 for SQL Server"


def test_best_driver_falls_back_when_none_installed(monkeypatch):
    fake_drivers(monkeypatch, ["SQL Server Native Client 11.0"])
    assert core.best_driver() == core.DEFAULT_DRIVER
    assert core.missing_driver()          # 應該要提醒去安裝


def test_env_uses_the_installed_driver_not_a_hardcoded_17(monkeypatch):
    # 寫死 17 但機器上只有 18，就是使用者遇到的 IM002 成因
    fake_drivers(monkeypatch, ["ODBC Driver 18 for SQL Server"])
    monkeypatch.setenv("SQL_SERVER", "SRV01")
    monkeypatch.setenv("SQL_DATABASE", "UMC")
    monkeypatch.delenv("SQL_DRIVER", raising=False)
    assert "ODBC+Driver+18+for+SQL+Server" in core.conn_from_env()


def test_env_driver_still_wins(monkeypatch):
    fake_drivers(monkeypatch, ["ODBC Driver 18 for SQL Server"])
    monkeypatch.setenv("SQL_SERVER", "SRV01")
    monkeypatch.setenv("SQL_DATABASE", "UMC")
    monkeypatch.setenv("SQL_DRIVER", "ODBC Driver 17 for SQL Server")
    assert "ODBC+Driver+17+for+SQL+Server" in core.conn_from_env()


def test_im002_error_gets_the_driver_list_appended(monkeypatch):
    fake_drivers(monkeypatch, ["ODBC Driver 17 for SQL Server"])
    err = Exception("('IM002', '[IM002] 找不到資料來源名稱且未指定預設的驅動程式')")
    out = core.explain_conn_error(err)
    assert "ODBC Driver 17 for SQL Server" in out
    assert "SQL_DRIVER" in out


def test_other_errors_are_left_alone(monkeypatch):
    fake_drivers(monkeypatch, ["ODBC Driver 17 for SQL Server"])
    out = core.explain_conn_error(Exception("('08001', '登入逾時終止')"))
    assert out == "('08001', '登入逾時終止')"
