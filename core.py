"""掃描資料夾、推斷欄位型別、把 Excel/CSV/SAP txt 匯入資料庫。

這個模組不 import tkinter，所以可以單獨用 sqlite 測試，
也讓之後換 UI 或加命令列介面時不用動到匯入邏輯。

SAP 匯出的 txt 有自己的脾氣：檔頭有報表標題、檔尾有統計列、
負號掛在數字後面、千分位與小數點可能顛倒、料號有前導零不能當數字。
這些都在「SAP txt」那幾段處理掉，之後的流程跟 Excel 完全一樣。
"""
import codecs
import json
import os
import re
import xml.etree.ElementTree as ET
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote_plus

import openpyxl
import pandas as pd
import pyodbc
from pandas.errors import OutOfBoundsDatetime
from sqlalchemy import create_engine
from sqlalchemy.types import (
    NVARCHAR, BigInteger, Boolean, Date, DateTime, Float, Integer, Numeric,
)

EXTS = {".csv", ".xlsx", ".xls", ".txt", ".xml"}
PREVIEW_ROWS = 200
CONFIG = Path("config.json")

# UI 下拉選單的選項。順序即顯示順序。
TYPE_CHOICES = [
    "INT", "BIGINT", "DECIMAL(18,2)", "DECIMAL(18,3)", "DECIMAL(18,4)",
    "DECIMAL(18,5)", "FLOAT", "BIT",
    "DATE", "DATETIME",
    "NVARCHAR(50)", "NVARCHAR(255)", "NVARCHAR(4000)", "NVARCHAR(MAX)",
]


# --- SAP txt：編碼 ------------------------------------------------------

# SAP GUI 依版本與設定吐出不同編碼，先看 BOM，沒有 BOM 再逐個試。
BOMS = [
    (codecs.BOM_UTF8, "utf-8-sig"),
    (codecs.BOM_UTF16_LE, "utf-16"),
    (codecs.BOM_UTF16_BE, "utf-16"),
]
FALLBACKS = ("utf-8", "cp950", "cp1252")


def decode(raw, encoding=None):
    """把位元組解成文字。encoding 給了就照做，否則自己判斷。"""
    if encoding:
        return raw.decode(encoding)
    for bom, enc in BOMS:
        if raw.startswith(bom):
            return raw.decode(enc)
    for enc in FALLBACKS:
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1")     # 最後手段：不會失敗，但可能有亂碼


# --- SAP txt：版面 ------------------------------------------------------

PIPE_ROW = re.compile(r"^\s*\|.*\|\s*$")
RULE_ROW = re.compile(r"^[\s|+\-=_]*$")     # ALV 的 |-----| 框線
AUTO_SEPS = ("\t", ";", ",")


def split_pipe(lines):
    """ALV「Unconverted」格式：每列被 | 框起來，中間夾框線。"""
    return [[c.strip() for c in ln.strip().strip("|").split("|")]
            for ln in lines
            if PIPE_ROW.match(ln) and not RULE_ROW.match(ln)]


def split_char(lines, sep):
    """單一分隔符格式。出現次數最多的欄數當資料列的基準。

    用「大於等於」而不是「等於」：SAP 會把每一列結尾的空欄砍掉，
    所以最後一欄沒值的資料列會比標題列少一個分隔符。只收剛好相等的
    話，標題列會被排除，第一列資料就被當成欄名。
    比基準少的（報表標題、「* n 筆記錄」）分隔符不夠，照樣排除。
    """
    counts = Counter(ln.count(sep) for ln in lines if ln.strip())
    if not counts:
        return []
    n, hits = counts.most_common(1)[0]
    if n < 1 or hits < 2:           # 至少要有標題列加一筆資料
        return []
    return [[c.strip() for c in ln.split(sep)]
            for ln in lines if ln.strip() and ln.count(sep) >= n]


def widest(rows):
    """只留下欄數最常見的列。給管線格式用，那種每列寬度一致。"""
    if not rows:
        return []
    n = Counter(len(r) for r in rows).most_common(1)[0][0]
    return [r for r in rows if len(r) == n]


def squared(rows):
    """把各列補到一樣寬。SAP 砍掉列尾空欄之後，各列長度會不一致。"""
    if not rows:
        return []
    width = max(len(r) for r in rows)
    return [r + [""] * (width - len(r)) for r in rows]


def headers(names):
    """補空欄名、去重複，免得 DataFrame 建不起來。"""
    out, seen = [], Counter()
    for i, raw in enumerate(names):
        name = raw.strip() or f"COL{i + 1}"
        seen[name] += 1
        out.append(name if seen[name] == 1 else f"{name}_{seen[name]}")
    return out


def parse(text, sep=None, skiprows=0):
    """把 SAP txt 的文字切成 DataFrame（全部先當字串）。"""
    lines = text.splitlines()[skiprows:]
    piped = sep == "|"
    if piped:
        rows = split_pipe(lines)
    elif sep:
        rows = split_char(lines, sep)
    else:
        rows = split_pipe(lines)
        piped = len(rows) >= 2
        for cand in AUTO_SEPS:
            if len(rows) >= 2:
                break
            rows = split_char(lines, cand)

    rows = widest(rows) if piped else squared(rows)
    if len(rows) < 2:
        raise ValueError(
            "看不出欄位分隔方式。可能是固定寬度格式，或標題列之前的雜訊太多"
            "——請在 config.json 的 txt 區指定 sep 與 skiprows。")

    head, data = rows[0], rows[1:]
    data = [r for r in data if r != head]       # ALV 分頁會重印標題
    df = pd.DataFrame(data, columns=headers(head))
    # SAP 的管線格式常在左右各多一個空欄
    blank = [c for c in df.columns
             if c.startswith("COL") and df[c].str.strip().eq("").all()]
    return df.drop(columns=blank)


# --- SAP txt：值 --------------------------------------------------------

NULL_TOKENS = {"", "#", "-", "--", "n/a", "na", "null", "none",
               "00000000", "0000-00-00", "00.00.0000", "00/00/0000"}

# SAP 標準的代碼欄位。這些在 SAP 裡本來就是 CHAR，只是長得像數字：
# 憑證號碼 1449008934、公司代碼 8104、年度 2026。當成數字會掉前導零
# （0000001000 變 1000），跟主檔 JOIN 就對不起來，而且同一欄位在不同
# 月份的檔案可能一次有前導零一次沒有，型別會跟著跳。
# 一律當文字，靠欄名判斷，不看值。
#
# 認不出來的情況：Z 開頭的自訂欄位、以及匯出時用中文/英文說明當欄名的
# 報表。那些欄位走原本的猜值邏輯，必要時用 config.json 的 dtypes 釘死。
# 反過來要把這裡的某一欄當數字，也是用 dtypes 指定 INT/DECIMAL。
SAP_CODE_FIELDS = frozenset("""
    MANDT BUKRS WERKS LGORT GSBER KOKRS PRCTR SEGMENT BUPLA VBUND
    VKORG VTWEG SPART EKORG EKGRP LAND1 WAERS SPRAS

    BELNR BUZEI BUZID DOCLN GJAHR BLART BSCHL SHKZG KOART UMSKZ MWSKZ
    HKONT SAKNR ALTKT KOSTL LSTAR KSTAR AUFNR ANLN1 ANLN2
    AUGBL AUGGJ ZUONR XBLNR XBLNR1 ZTERM ZLSCH ZLSPR ZLSCH RSTGR
    KTOSL FILKD HBKID HKTID BVTYP AWKEY AWTYP

    LIFNR KUNNR KUNAG KUNWE KTOKK KTOKD STCD1 STCD2 STCD3 STCEG
    PSTLZ TELF1 TELF2 TELFX

    MATNR MATKL MTART MEINS MSEHI CHARG BWTAR SOBKZ
    EBELN EBELP BANFN BNFPO BSART PSTYP KNTTP INFNR RESWK
    MBLNR MJAHR ZEILE BWART LFBNR LFGJA LFPOS

    VBELN POSNR AUART VBTYP FKART FKTYP LFART VGBEL VGPOS ANGNR

    PSPNR PSPID POSID PSPHI NPLNR VORNR ARBPL PLNBEZ PLNNR

    PERNR BNAME UNAME USNAM ERNAM AENAM

    KAPPL KSCHL ESOKZ KNUMH KNUMV KNUMA

    ANLKL ANLAR INVNR TYPBZ SERNR IZWEK KFZKZ LIEFE EAUFN GDLGRP
    AIBN1 AIBN2

    MONAT POPER BUPER PERIO SPMON TCODE BVORG DBBLG STBLG KZWRS BSTAT
    GLVOR GRPID FIKRS HWAER HWAE2 HWAE3 AUGLV PPNAM BRNCH RLDNR LDGRP
    IBLAR DOCCAT KTOPL VERSN ERGSL TXJCD XREF1 XREF2 XREF3
    FISTL FIPOS GEBER KDAUF KDPOS PROJK AUFPL APLZL PRODH

    AKONT ZWELS BUSAB QSSKZ MINDK KONZS BRSCH SPERR SPERM LOEVM LOEKZ
    BANKL BANKN BANKS BKONT IBAN SWIFT

    XBILK BILKT GVTYP MITKZ ZUMSK REBZG REBZJ REBZZ MANSP MSCHL MABER
    VERTN VERTT

    BISMT LABOR PRDHA MSTAE MSTAV DISPO DISMM BESKZ SOBSL LGPBE BKLAS
    VPRSV

    SMBLN SJAHR SMBLP KZBEW KZZUG KZVBR UMWRK UMLGO UMMAT UMCHA GRUND
    VGABE

    BSTYP BSAKZ STATU LPONR KONNR KTPNR ANFNR IHREZ VERKF

    AUGRU ABRVW VKBUR VKGRP PSTYV POSAR VGTYP UEPOS GRKOR

    OBJNR PAROB USPOB BEKNZ VRGNG WRTTP AFABE BWASL

    RBUKRS RACCT RCNTR RFAREA RBUSA RMVCT RTCUR RHCUR RKCUR RWCUR RUNIT

    # 逐一比對 A017 ANLA BKPF BSEG CDHDR CDPOS T001 EBAN EBKN EINA EINE
    # EKBE EKET EKKN EKKO EKPO KONH KONP LFA1 LFB1 LFBK LFM1 MAKT MARA
    # MARC MARD MBEW MBEWH MKPF MSEG T001W T001K 之後補上的。
    # 其中會出事的是長得像數字的：BWKEY 評價範圍、SAKTO 總帳科目、
    # ZEKKN/ZEBKN 科目分配序號、VBELP/POSN2 項次、PARGB 業務範圍、
    # PPRCT 夥伴利潤中心、EMPFB 收款人、ANBWA 資產交易類型、
    # PSTL2 郵遞區號、MANDANT 集團、LFMON 期間、LFBJA 年度。
    ABLAD ABSKZ ACT_CHNGNO AFNAM ALTKN ALTSL ANBWA ARSPS ATTYP AUREL
    AUSME AUTLF AWSYS BANPR BEDPL BEGRU BEHVO BEWTP BKREF BLA2D BLAUM
    BOIND BONUS BOSTA BPRME BSTAE BSTME BUALT BUSTW BUVAR BWKEY BWTTY
    CHANGE_IND CHAZV CHNGIND CITYC COUNC CUKY_NEW CUKY_OLD DISKZ DISLS
    DISPR DISST EAN11 EGLKZ EKWSL ELIKZ EMATN EMLIF EMPFB EREKZ ERFME
    ESTKZ ETEN2 EVERS EXNUM EXPVZ EXTWG FABKL FDBUK FDGRV FEVOR FLIEF
    FNAME FORMT FRATH FRGGR FRGKE FRGKZ FRGRL FRGST FRGSX FRGZU GEWEI
    IDNLF IMKEY INCO1 INCO2 INSMK KALSK KALSM KANBA KDEIN KFLAG KKBER
    KKOWK KMEIN KOINH KOKFI KONMS KONWA KONWS KOPOS KORDB KRECH KSTRG
    KUFIX KVEWE KZABS KZAUT KZBEH KZBZG KZDIE KZEAR KZKRI KZNEP KZSTR
    KZSTU LAGPR LANGU LBLIF LFABC LFBJA LFMON LIFAB LIFBI LIFRE LINE_ID
    LLIEF LMEIN LNRZA LNRZB LNRZE LOEVM_KO LOGSY LPEIN LSMEH LSOBS LVORM
    MAABC MAHN1 MAHNZ MANDANT MBRSH MEPRF MMSTA MRPPP MTPOS_MARA MTVFP
    NORMT OBJECTCLAS OBJECTID PACKNO PARENT_ID PARGB PERIV PERKZ PINCR
    POSN2 PPRCT PRCTL PROCSTAT PROJN PRSDR PSEGMENT PSTAT PSTL2 PSWSL
    QLAND RAUBE RCOMP REBZE REGIO REPOS REPRF RETPO REVLV RSNUM RSPOS
    RUECK SAKTO SBDKZ SCHPR SKTOF SPINF SSQSS STAFO STAPO STKZN STKZU
    STOFF STRGR SUBMI TABNAME TCODE2 TEMPB TEXT_CASE TOGRU TRAGR TWRKZ
    UEBPO UEBTK UMSKS UMZST UMZUS UNIT_NEW UNIT_OLD UNSEZ USERNAME VBEL2
    VBELP VERID VERSION VGART VMBKL VOLEH VPSTA VRTKZ VRTYP VSART VZSKZ
    WAABW WAKON WAS_PLANND WEAKT WEBRE WEMPF WEPOS WEUNB WEVER WFVAR
    WGLIF XABLN XANET XAUTO XBKNG XBKPF XBLNR_ALT XCHAR XCPDD XDEZV
    XERSY XEZER XFMCO XINVE XLOEV XMWST XNEGP XNETB XOPVW XPORE
    XREVERSAL XSKRL XSTOV XVERR ZAHLS ZBFIX ZEBKN ZEIAR ZEIFO ZEIVR
    ZEKKN ZGRUP ZGTYP ZINKZ ZINRT ZOLLA ZSABE ZUAWA ZUSCH ZUSTD
""".split())

# 反過來：這些本來就是數字，就算沒小數也不要當成可疑欄位。
# 數量欄位（MENGE、LFIMG）匯出時剛好整數很常見，天期欄位（ZBD1T）更是。
SAP_NUMERIC_FIELDS = frozenset("""
    WRBTR DMBTR DMBE2 DMBE3 WRBTR2 NETWR BRTWR KZWRT KBETR KWERT
    MWSTS WMWST FWSTE HWSTE SKFBT WSKTO SKNTO
    MENGE BSTMG LFIMG FKIMG WEMNG PSMNG ERFMG BDMNG GSMNG LBKUM
    SALK3 SALKV VERPR STPRS PEINH UMREZ UMREN
    NTGEW BRGEW VOLUM
    KURSF KURRF KURS2 KURS3 ZBD1T ZBD2T ZBD3T ZBD1P ZBD2P
""".split())

# 標準欄位太多，列不完。這幾條欄名規則接住沒列到的，一樣只看名字不看值。
CODE_PATTERNS = re.compile(r"""
    ^KNUM                   # KNUMH KNUMV KNUMA 條件記錄號
  | ^ORD\d+$                # ORD41-44 資產評估欄位
  | (?:JHR|JAH|JAHR|GJA)$   # URJHR STJAH GJAHR MJAHR LFGJA 年度
  | NR\d?$                  # INVNR SERNR AUFNR PERNR 之類的號碼欄位
""", re.X)


def is_numeric_field(name):
    """欄名是不是已知的金額／數量／天期欄位。"""
    return str(name).strip().upper() in SAP_NUMERIC_FIELDS


def is_whole_number_column(s):
    """整欄都是沒有小數的整數（有空值時 pandas 會讓它變 float）。"""
    if s.dtype.kind in "iu":
        return True
    if s.dtype.kind != "f":
        return False
    kept = s.dropna()
    return not kept.empty and kept.mod(1).eq(0).all()


def is_code_field(name):
    """欄名是不是 SAP 的代碼欄位。大小寫與前後空白都不計。"""
    n = str(name).strip().upper()
    return n in SAP_CODE_FIELDS or bool(CODE_PATTERNS.search(n))

NUM_RE = re.compile(r"""^
    (?P<sign>[-+])?
    (?P<body>\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d+)?|\d+(?:[.,]\d+)?)
    (?P<trail>[-+])?
$""", re.X)
CODE_RE = re.compile(r"0\d+")               # 前導零 = 代碼，不是數字

D_ISO = re.compile(r"(\d{4})-(\d{1,2})-(\d{1,2})")
D_COMPACT = re.compile(r"(\d{4})(\d{2})(\d{2})")
D_DOT = re.compile(r"(\d{1,2})\.(\d{1,2})\.(\d{4})")
D_SLASH = re.compile(r"(\d{1,2})/(\d{1,2})/(\d{4})")
TIME_RE = re.compile(r"[ T](\d{1,2}:\d{2}(?::\d{2})?)$")


def cell(v):
    """全形空白也是空白。"""
    return v.replace("　", " ").strip()


def decimal_sep(values):
    """整欄一起判斷小數點是 . 還是 ,。判不出來回 None（全部當千分位）。"""
    for x in values:
        if "." in x and "," in x:            # 兩種都有，右邊那個是小數點
            return "." if x.rfind(".") > x.rfind(",") else ","
    for x in values:
        if x.count(".") > 1:                 # 出現兩次以上必是千分位
            return ","
        if x.count(",") > 1:
            return "."
    for x in values:                         # 後面不是剛好三位，就是小數點
        for ch in (".", ","):
            if x.count(ch) == 1 and len(x.split(ch)[1].rstrip("+-")) != 3:
                return ch
    return None                              # 例如整欄都是 "1.234"，當 1234


def to_number(v, dec):
    m = NUM_RE.match(v)
    if not m:
        return None
    body = m.group("body")
    if dec:
        body = body.replace("," if dec == "." else ".", "")
        body = body.replace(" ", "").replace(dec, ".")
    else:
        body = re.sub(r"[.,\s]", "", body)
    n = float(body)
    signs = (m.group("sign") or "") + (m.group("trail") or "")
    return -n if "-" in signs else n


def numeric_text(s):
    """帶千分位的文字轉成數字，不是文字的原樣留著。整欄一起判小數點。

    有一格文字轉不出來就回 None，讓呼叫端原本的錯誤照樣浮出來——
    安靜地把看不懂的值變成 NULL 比報錯更糟。
    """
    if s.dtype.kind != "O":         # 已經是數字/日期，幾十萬列不用白跑 map
        return None
    text = s.dropna().map(lambda x: x if isinstance(x, str) else None).dropna()
    if text.empty or not text.map(lambda x: bool(NUM_RE.match(x))).all():
        return None
    dec = decimal_sep(text)
    return s.map(lambda x: to_number(x, dec) if isinstance(x, str) else x)


def sap_numbers(s):
    """整欄都是 SAP 數字才轉換，否則回 None 讓它留著當文字。"""
    v = s.dropna()
    if v.map(lambda x: isinstance(x, str) and bool(CODE_RE.fullmatch(x))).any():
        return None
    converted = numeric_text(s)
    if converted is None:
        return None
    out = pd.to_numeric(converted)
    kept = out.dropna()
    if not kept.empty and kept.mod(1).eq(0).all() and kept.abs().lt(2**63).all():
        return out.astype("Int64")
    return out


# SAP 拿 9999-12-31 當「無限期」：EKKO 的有效期迄（KDATE）、合約、
# 主檔的失效日都常常是這個值。它不是髒資料，是有意義的日期。
SENTINEL_DATE = (9999, 12, 31)


def valid_date(y, mo, dy):
    return (y, mo, dy) == SENTINEL_DATE or (
        1900 <= y <= 2100 and 1 <= mo <= 12 and 1 <= dy <= 31)


def split_time(v):
    m = TIME_RE.search(v)
    return (v[:m.start()], m.group(1)) if m else (v, "")


def norm_date(v, rx, layout):
    """轉成 pandas 一定看得懂的 YYYY-MM-DD[ HH:MM:SS]，看不懂回 None。"""
    if not isinstance(v, str):
        return None
    d, t = split_time(cell(v))
    m = rx.fullmatch(d)
    if not m:
        return None
    a, b, c = (int(g) for g in m.groups())
    y, mo, dy = {"ymd": (a, b, c), "dmy": (c, b, a), "mdy": (c, a, b)}[layout]
    if not valid_date(y, mo, dy):
        return None
    return f"{y:04d}-{mo:02d}-{dy:02d}" + (f" {t}" if t else "")


# pandas 預設的 datetime64[ns] 最多只到 2262-04-11，整欄只要有一個
# 9999-12-31 就炸 Out of bounds nanosecond timestamp，而且訊息不會說是
# 哪一欄。降到秒精度放得下，SQL Server 的 DATE 與 DATETIME 上限也正好
# 是 9999-12-31，存得進去。
DT64 = "datetime64[s]"

# numpy 的字串轉日期只吃補零的 ISO，pd.to_datetime 寬鬆得多。
# 只有走到秒精度那條路才需要先補齊。
ISO_PARTS = re.compile(r"^\s*(\d{4})[-/](\d{1,2})[-/](\d{1,2})(.*?)\s*$")


def iso_pad(v):
    m = ISO_PARTS.match(v)
    if not m:
        return v
    return (f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
            f"{m.group(4)}")


def iso_text(v):
    """一格轉成 numpy 看得懂的 ISO 字串，空值回 None。

    這一欄不一定是字串：Excel 的日期儲存格讀進來是 datetime 物件，
    而整欄只要有一個 9999-12-31，pandas 就放不進 datetime64[ns]，
    整欄會留成 object。把非字串一律當空值會整欄變 NULL。
    """
    if v is None or v is pd.NaT:
        return None
    if isinstance(v, str):
        return iso_pad(v)
    if hasattr(v, "isoformat"):             # date / datetime / Timestamp
        return v.isoformat()
    return None if pd.isna(v) else str(v)


def parse_dates(s):
    """整欄轉成 datetime。放不進 ns 精度的才降到秒精度重試。"""
    try:
        return pd.to_datetime(s)
    except OutOfBoundsDatetime:
        return s.map(iso_text).astype(DT64)


def date_layout(values):
    """從整欄判斷日期格式，回 (regex, 排列)。判不出來回 None。"""
    candidates = [(D_ISO, "ymd"), (D_COMPACT, "ymd"), (D_DOT, "dmy")]
    if all(D_SLASH.fullmatch(split_time(x)[0]) for x in values):
        # MM/DD 還是 DD/MM？有人超過 12 就確定了；都沒有就照 SAP 歐規當 DD/MM。
        pairs = [D_SLASH.fullmatch(split_time(x)[0]).groups()[:2] for x in values]
        mdy = (not any(int(a) > 12 for a, _ in pairs)
               and any(int(b) > 12 for _, b in pairs))
        candidates.insert(0, (D_SLASH, "mdy" if mdy else "dmy"))
    for rx, layout in candidates:
        if all(norm_date(x, rx, layout) for x in values):
            return rx, layout
    return None


def sap_dates(s):
    """整欄都是日期才轉換，否則回 None。"""
    v = s.dropna()
    if v.empty:
        return None
    found = date_layout(list(v))
    if not found:
        return None
    rx, layout = found
    return parse_dates(s.map(lambda x: norm_date(x, rx, layout)))


def sap_convert(df, int_codes=True):
    """把字串欄位還原成數字/日期。先試日期再試數字——YYYYMMDD 兩邊都像。"""
    out = {}
    for col in df.columns:
        s = df[col].map(lambda x: cell(x) if isinstance(x, str) else x)
        s = s.mask(s.map(
            lambda x: isinstance(x, str) and x.lower() in NULL_TOKENS))
        if is_code_field(col):      # 欄名說了算，不看值
            out[col] = s
            continue
        converted = sap_dates(s)
        if converted is None:
            converted = sap_numbers(s)
        # 沒有小數的整數、欄名又不在已知數字清單裡，多半是代碼。
        # 標準欄位清單列不完（光 ANLA 就一百多欄），所以用這條補。
        # 猜錯成文字還能在 SQL 端 CAST 回來；猜錯成整數，前導零就永遠沒了。
        if (int_codes and converted is not None
                and converted.dtype.kind in "iu"
                and not is_numeric_field(col)):
            converted = None
        out[col] = s if converted is None else converted
    return pd.DataFrame(out, columns=df.columns)


INT_TEXT_RE = re.compile(r"-?\d+")


def suspects(table):
    """欄名不在 SAP 清單、內容卻全是整數的欄位。

    int_codes 開著時它們已經被當成文字，也就是救得回來的那一邊：
    真的是數字就在 SQL 端 CAST，或用 dtypes 指定成 INT 重匯一次。
    這裡列出來只是讓人知道哪幾欄是靠規則判的，不是非處理不可。

    有前導零的不列——那種百分之百是代碼，沒什麼好確認的。
    """
    found = []
    for col, spec in table.dtypes.items():
        if is_code_field(col) or is_numeric_field(col):
            continue
        if spec in ("INT", "BIGINT"):
            found.append(col)
            continue
        if not spec.startswith("NVARCHAR") or table.sample is None:
            continue
        values = table.sample[col].dropna().astype(str)
        if (not values.empty
                and values.str.fullmatch(INT_TEXT_RE).all()
                and not values.str.fullmatch(CODE_RE).any()):
            found.append(col)
    return found


def read_txt(path, encoding=None, sep=None, skiprows=0, int_codes=True):
    text = decode(Path(path).read_bytes(), encoding)
    return sap_convert(parse(text, sep=sep, skiprows=skiprows), int_codes)


# --- Excel 2003 XML（SpreadsheetML）------------------------------------

# SAP 的「匯出成試算表」在某些版本吐的是這種檔：副檔名 .xml，內容是
# <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet">。
# Excel 開得起來，但 pandas.read_excel 讀不了（它不是 zip 也不是 BIFF）。
SS = "{urn:schemas-microsoft-com:office:spreadsheet}"


def xml_cell(data):
    """一個 <Data> 的值。型別寫在 ss:Type，不用猜。"""
    if data is None or data.text is None:
        return None
    text = data.text
    kind = data.get(SS + "Type")
    if kind == "Number":
        number = float(text)
        return int(number) if number.is_integer() and abs(number) < 2**63 else number
    if kind == "DateTime":
        return pd.to_datetime(text, errors="coerce")
    if kind == "Boolean":
        return text.strip() in ("1", "true", "True")
    return text


def xml_row(el):
    """一列。空白儲存格會被省略，靠 ss:Index 跳位補回來。"""
    cells = []
    for cell in el.findall(SS + "Cell"):
        at = cell.get(SS + "Index")
        if at:
            while len(cells) < int(at) - 1:
                cells.append(None)
        cells.append(xml_cell(cell.find(SS + "Data")))
        across = cell.get(SS + "MergeAcross")
        if across:
            cells.extend([None] * int(across))
    return cells


def read_xml(path, nrows=None):
    """讀 SpreadsheetML，只取第一個有資料的工作表。"""
    rows = []
    limit = None if nrows is None else nrows + 1     # 加上標題列
    for _, el in ET.iterparse(str(path), events=("end",)):
        if el.tag == SS + "Row":
            rows.append(xml_row(el))
            el.clear()
            if limit and len(rows) >= limit:
                break
        elif el.tag == SS + "Worksheet" and rows:
            break                                    # 後面的工作表不碰

    if len(rows) < 2:
        raise ValueError(
            "SpreadsheetML 裡找不到標題列加資料列。"
            "確認這個 .xml 是 Excel 2003 XML，而不是 SAP 自訂的 XML 格式。")

    width = max(len(r) for r in rows)
    head = [str(h) if h is not None else "" for h in rows[0]]
    head += [""] * (width - len(head))
    data = [r + [None] * (width - len(r)) for r in rows[1:]]

    df = pd.DataFrame(data, columns=headers(head))
    blank = [c for c in df.columns if c.startswith("COL") and df[c].isna().all()]
    return df.drop(columns=blank)


# --- 讀檔 ---------------------------------------------------------------

def code_columns_to_text(df, int_codes=True):
    """代碼欄位一律轉回文字。

    Excel 與 CSV 走 pandas 自己的型別推斷，憑證號碼會被讀成 int64，
    所以 txt 之外的格式也要補這一刀，否則同一個 BELNR 在 txt 是文字、
    在 Excel 是整數，兩張表就 JOIN 不起來。

    這一刀只管型別一致，救不了前導零——到這裡零已經被 pandas 吃掉了。
    保零是 read_sheet() 的事，它在讀檔時就把代碼欄指定成 dtype=str。

    注意：Excel 儲存格如果本來就存成數字，前導零在 SAP 匯出那一刻
    就沒了，這裡救不回來——能保證的是型別每次都一致。
    """
    out = df.copy()
    for col in out.columns:
        s = out[col]
        forced = is_code_field(col) or (
            int_codes and not is_numeric_field(col) and is_whole_number_column(s))
        if not forced:
            continue
        if s.dtype.kind in "iu":
            out[col] = s.astype("string")
        elif s.dtype.kind == "f":
            whole = s.dropna()
            # 有空值時整數欄會變 float，直接轉字串會多一個 .0
            if whole.empty or whole.mod(1).eq(0).all():
                out[col] = s.astype("Int64").astype("string")
            else:
                out[col] = s.astype("string")
    return out


def numbers_from_text(df):
    """讀成文字的數字欄還原成數字。

    千分位（"1,087.00"）會讓 pandas 把整欄留成字串，使用者在 UI 指定
    DECIMAL 就炸在 coerce：unable to parse string "1,087.00"。txt 走
    sap_convert 有處理，Excel、CSV、XML 沒有，跟代碼欄一樣要補這一刀，
    否則同一個 WRBTR 在 txt 是數字、在 Excel 是文字。

    代碼欄不碰——欄名說了算，跟 sap_convert 同一條規則。
    """
    out = df.copy()
    for col in out.columns:
        if out[col].dtype.kind != "O" or is_code_field(col):
            continue
        converted = sap_numbers(
            out[col].map(lambda x: cell(x) if isinstance(x, str) else x))
        if converted is not None:
            out[col] = converted
    return out


def sheet(path, ext, nrows=None, dtype=None, usecols=None):
    """讀 csv 或 excel，兩邊參數一致。"""
    if ext == ".csv":
        return pd.read_csv(path, nrows=nrows, dtype=dtype, usecols=usecols)
    return pd.read_excel(path, nrows=nrows, dtype=dtype, usecols=usecols)


def read_sheet(path, ext, nrows=None, int_codes=True):
    """讀 csv/excel，代碼欄一律當文字讀。

    pandas 在讀檔那一刻就把 0010001234 判成 int64，前導零當場沒了，
    之後 code_columns_to_text 再怎麼轉回字串都只剩 10001234。零明明
    好好地寫在檔案裡（CSV 是純文字，Excel 那格也真的是字串儲存格），
    是我們自己丟掉的。

    所以先只讀標題列，欄名認得出來是代碼的就指定 dtype=str。只讀標題
    很便宜（5 萬列的 xlsx 約 0.2 秒，整份要 0.8 秒），比讀完再重讀划算。
    """
    names = list(sheet(path, ext, nrows=0).columns)
    forced = {c: str for c in names if is_code_field(c)}
    df = sheet(path, ext, nrows, dtype=forced or None)

    # 欄名沒認出來、值又是整數的，code_columns_to_text 一樣會當代碼。
    # 那些欄的零已經被吃掉了，只能把它們重讀一次——多讀一趟不便宜，
    # 但單號少一個零是安靜的錯，比慢更糟。
    rest = [c for c in df.columns
            if c not in forced and df[c].dtype.kind in "iu"
            and int_codes and not is_numeric_field(c)]
    if rest:
        again = sheet(path, ext, nrows, dtype=dict.fromkeys(rest, str),
                      usecols=rest)
        for c in rest:
            df[c] = again[c]
    return df


def read(path, nrows=None, opts=None, int_codes=True):
    """讀一個檔案。nrows 只讀前幾列，給預覽用。opts 是 txt 的解析覆寫。"""
    ext = Path(path).suffix.lower()
    if ext == ".txt":
        df = read_txt(path, int_codes=int_codes, **(opts or {}))
        df = df.head(nrows) if nrows else df
    else:
        df = (read_xml(path, nrows) if ext == ".xml"
              else read_sheet(path, ext, nrows, int_codes))
        df = numbers_from_text(df)          # txt 已經在 sap_convert 做過了
    return code_columns_to_text(df, int_codes)


def count_rows(path, opts=None):
    """不把整個檔讀進記憶體的前提下數資料列（不含標題）。"""
    ext = Path(path).suffix.lower()
    if ext == ".txt":
        o = dict(opts or {})
        text = decode(Path(path).read_bytes(), o.pop("encoding", None))
        return len(parse(text, **o))
    if ext == ".xml":
        return len(read_xml(path))
    if ext == ".csv":
        with open(path, "rb") as f:
            return max(sum(1 for _ in f) - 1, 0)
    wb = openpyxl.load_workbook(path, read_only=True)
    try:
        return max((wb.active.max_row or 1) - 1, 0)
    finally:
        wb.close()


# --- 型別推斷 -----------------------------------------------------------

# 文字欄位最短給 255。量到 40 就宣告 40 的話，append 模式下個月來個
# 50 就爆了，而 NVARCHAR 是變動長度，宣告寬一點不佔空間。
# SAP 的標準文字欄位都不長（SGTXT 50、TXZ01 40、MAKTX 40），255 蓋得住；
# 真正的自由輸入欄位會超過 4000，那時才給 MAX。
TEXT_FLOOR = 255
TEXT_LIMIT = 4000


# 小數位超過這個數就不猜 DECIMAL 了。金額 2 位、數量 3 位、匯率 5 位
# 蓋得住 SAP 的常態欄位；再多的多半是算出來的，宣告幾位都會被 SQL Server
# 安靜地四捨五入掉。留成文字至少值是完整的，要算再在 SQL 端 CAST。
MAX_SCALE = 5


def scale_of(numbers):
    """整欄實際用到幾位小數。整欄都沒有小數點回 None。"""
    used = numbers.astype(str).str.extract(r"\.(\d+)$")[0].str.len().max()
    return None if pd.isna(used) else int(used)


def text_spec(longest):
    """依實際最長長度決定文字型別。留一倍成長空間。"""
    if longest > TEXT_LIMIT:
        return "NVARCHAR(MAX)"      # MAX 不能進索引鍵，所以不隨便用
    return f"NVARCHAR({min(max(longest * 2, TEXT_FLOOR), TEXT_LIMIT)})"


# 只有長得像日期的字串才嘗試轉換，免得 "1"、"2" 這種被 pandas 當成日期。
DATE_RE = re.compile(r"\s*\d{4}[-/]\d{1,2}[-/]\d{1,2}([ T]\d{1,2}:\d{2}(:\d{2})?)?\s*")


def as_datetime(s):
    """整欄都像日期就轉成 datetime，否則回 None。"""
    text = s.astype(str)
    if not text.str.fullmatch(DATE_RE).all():
        return None
    try:
        return parse_dates(text)
    except (ValueError, TypeError):
        return None


def infer(series):
    """從一個欄位的資料推斷 SQL Server 型別字串。"""
    s = series.dropna()
    if s.empty:
        return f"NVARCHAR({TEXT_FLOOR})"

    # CSV 讀進來的日期是字串，要先還原才推得出 DATE/DATETIME。
    if s.dtype.kind == "O":
        # 整欄都是 True/False 時 pandas 給 bool；只要有一格空白就退成
        # object，型別會因此從 BIT 變成 NVARCHAR。這裡補回來。
        # 用 is_bool 而不是 == True/False：Python 裡 1 == True，
        # 整數 0/1 的欄位會被誤判成布林。
        if all(pd.api.types.is_bool(v) for v in s.unique()):
            return "BIT"
        parsed = as_datetime(s)
        if parsed is not None:
            s = parsed

    kind = s.dtype.kind
    if kind == "b":
        return "BIT"
    if kind in "iu":
        return "INT" if s.min() >= -2**31 and s.max() < 2**31 else "BIGINT"
    if kind == "f":
        # 量實際用到幾位小數，避免金額被 DECIMAL(18,2) 截掉。
        used = scale_of(s)
        if used is None:
            return "DECIMAL(18,2)"
        if used > MAX_SCALE:
            return text_spec(int(s.astype(str).str.len().max()))
        return f"DECIMAL(18,{max(used, 2)})"
    if kind == "M":
        return "DATE" if (s.dt.normalize() == s).all() else "DATETIME"

    # 文字：量最大長度再留一倍成長空間，比預設的 NVARCHAR(MAX) 好用得多。
    return text_spec(int(s.astype(str).str.len().max()))


def to_sa(spec):
    """把 "NVARCHAR(50)" 這種字串轉成 SQLAlchemy 型別物件。"""
    m = re.fullmatch(r"([A-Z]+)(?:\(\s*(\d+|MAX)\s*(?:,\s*(\d+)\s*)?\))?", spec.strip().upper())
    if not m:
        raise ValueError(f"看不懂的型別：{spec}")
    name, size, scale = m.group(1), m.group(2), m.group(3)

    if name == "NVARCHAR":
        return NVARCHAR(None if size in (None, "MAX") else int(size))
    if name in ("DECIMAL", "NUMERIC"):
        return Numeric(int(size or 18), int(scale or 2))
    simple = {
        "INT": Integer, "BIGINT": BigInteger, "FLOAT": Float,
        "BIT": Boolean, "DATE": Date, "DATETIME": DateTime,
    }
    if name in simple:
        return simple[name]()
    raise ValueError(f"不支援的型別：{spec}")


# --- 掃描 ---------------------------------------------------------------

@dataclass
class Table:
    name: str
    files: list
    columns: list = field(default_factory=list)
    dtypes: dict = field(default_factory=dict)
    rows: int = 0
    sample: object = None       # 預覽用的 DataFrame
    error: str = ""             # 非空代表這張表不能匯入
    opts: dict = field(default_factory=dict)    # txt 解析覆寫
    int_codes: bool = True      # 沒小數的整數欄位當文字
    pinned: set = field(default_factory=set)    # 使用者指定死的型別
    skipped: list = field(default_factory=list)  # 副檔名不支援、沒讀的檔
    widened: dict = field(default_factory=dict)  # 建表前放寬過的長度

    @property
    def ok(self):
        return not self.error


def groups(root):
    """列出 (表名, 檔案清單, 跳過的檔案)。子資料夾 = 一張表，散檔 = 一張表。

    跳過的檔案也要回報。整個資料夾只有不支援的副檔名時，原本會安靜地
    連表都不出現，人會以為匯過了。
    """
    for p in sorted(Path(root).iterdir()):
        if p.is_dir():
            inside = [f for f in sorted(p.iterdir()) if f.is_file()]
            files = [f for f in inside if f.suffix.lower() in EXTS]
            skipped = [f for f in inside if f.suffix.lower() not in EXTS]
            if files or skipped:
                yield p.name, files, skipped
        elif p.is_file() and p.suffix.lower() in EXTS:
            yield p.stem, [p], []


def scan(root, cfg=None):
    """掃描資料夾，每個檔只讀前 PREVIEW_ROWS 列，回傳每張表的預覽資訊。"""
    txt_opts = (cfg or {}).get("txt", {})
    int_codes = (cfg or {}).get("int_codes", True)
    tables = []
    for name, files, skipped in groups(root):
        t = Table(name=name, files=files, opts=dict(txt_opts.get(name, {})),
                  int_codes=int_codes, skipped=skipped)
        if not files:
            t.error = ("沒有支援的檔案，只有 "
                       + "、".join(f.name for f in skipped[:5])
                       + f"（支援 {' '.join(sorted(EXTS))}）")
            tables.append(t)
            continue
        try:
            samples = [read(f, nrows=PREVIEW_ROWS, opts=t.opts,
                            int_codes=int_codes) for f in files]
            cols = list(samples[0].columns)
            for f, df in zip(files[1:], samples[1:]):
                if set(df.columns) != set(cols):
                    extra = set(df.columns) - set(cols)
                    missing = set(cols) - set(df.columns)
                    t.error = f"{f.name} 欄位不一致" + (
                        f"，多了 {sorted(extra)}" if extra else "") + (
                        f"，少了 {sorted(missing)}" if missing else "")
                    break
            if t.ok:
                t.sample = pd.concat([d[cols] for d in samples], ignore_index=True)
                t.columns = cols
                t.dtypes = {c: infer(t.sample[c]) for c in cols}
                t.rows = sum(count_rows(f, t.opts) for f in files)
        except Exception as e:
            t.error = f"{type(e).__name__}: {e}"
        tables.append(t)
    return tables


def load(files, opts=None, int_codes=True, progress=None):
    """讀完整資料。欄位不一致就丟例外 —— 猜錯比不做更糟。"""
    say = progress or (lambda message: None)
    frames = []
    for i, f in enumerate(files, 1):
        say(f"讀取 {f.name}（{i}/{len(files)}）")
        frames.append(read(f, opts=opts, int_codes=int_codes))
    cols = list(frames[0].columns)
    for f, df in zip(files[1:], frames[1:]):
        if set(df.columns) != set(cols):
            raise ValueError(
                f"欄位不一致：{f.name}\n"
                f"  預期（來自 {files[0].name}）：{cols}\n"
                f"  實際：{list(df.columns)}"
            )
    return pd.concat([df[cols] for df in frames], ignore_index=True)


# --- 匯入 ---------------------------------------------------------------

TRUE_TOKENS = {"true", "t", "yes", "y", "x", "1", "1.0"}
FALSE_TOKENS = {"false", "f", "no", "n", "0", "0.0"}


def to_bool(s):
    """把各種寫法的是/否轉成布林。

    SAP 的旗標是 X 與空白，Excel 匯出可能變成 TRUE/FALSE 或 1/0，
    pandas 讀進來又可能是 bool、字串或數字——全部收斂成同一種。
    """
    if s.dtype.kind == "b":
        return s.astype("boolean")

    def one(v):
        if pd.isna(v):
            return pd.NA
        text = str(v).strip().lower()
        if text in TRUE_TOKENS:
            return True
        if text in FALSE_TOKENS:
            return False
        raise ValueError(f"看不懂的布林值 {v!r}")

    return s.map(one).astype("boolean")


def coerce(df, types):
    """把資料轉成宣告的型別。

    宣告了 DATE 卻塞字串進去，DB 端只能隱式轉換，很容易爆。
    這一步讓 UI 上改型別能真的生效，而不只是改掉建表語法。
    """
    out = df.copy()
    for col, spec in types.items():
        if col not in out.columns:
            continue
        name = spec.split("(")[0].strip().upper()
        if name in ("INT", "BIGINT", "DECIMAL", "NUMERIC", "FLOAT"):
            # 讀檔那一關 sap_numbers 不肯轉的欄（混著代碼、混著數字），
            # 使用者指定了數字型別還是要照做，那是他明確的選擇。
            cleaned = numeric_text(out[col])
            if cleaned is not None:
                out[col] = cleaned
        try:
            if name in ("DATE", "DATETIME"):
                out[col] = parse_dates(out[col])
                if name == "DATE":
                    out[col] = out[col].dt.normalize()
            elif name in ("INT", "BIGINT"):
                out[col] = pd.to_numeric(out[col]).astype("Int64")
            elif name in ("DECIMAL", "NUMERIC", "FLOAT"):
                out[col] = pd.to_numeric(out[col])
            elif name == "BIT":
                out[col] = to_bool(out[col])
            elif name == "NVARCHAR":
                out[col] = out[col].astype("string")
        except (ValueError, TypeError) as e:
            raise ValueError(f"欄位「{col}」無法轉成 {spec}：{e}") from e
    return out


def connect(conn_str):
    is_mssql = conn_str.startswith("mssql")
    return create_engine(conn_str, fast_executemany=True) if is_mssql \
        else create_engine(conn_str)


def as_numbers(values):
    """轉成數字好量範圍與小數位；帶千分位的文字欄也要量得出來。"""
    cleaned = numeric_text(values)          # 不是文字欄會直接回 None
    return pd.to_numeric(values if cleaned is None else cleaned,
                         errors="coerce").dropna()


NVARCHAR_RE = re.compile(r"NVARCHAR\((\d+)\)")
DECIMAL_RE = re.compile(r"(?:DECIMAL|NUMERIC)\((\d+),\s*(\d+)\)")


def better_spec(series, spec):
    """宣告的型別放不下這一欄時回傳放得下的，放得下就回 None。

    掃描為了快只看前 PREVIEW_ROWS 列，之後才出現的值可能放不進去：
    文字更長、整數欄冒出小數、金額多一位小數。這些在 INSERT 時才會
    爆，而且訊息很難看懂（「cannot safely cast non-equivalent float64
    to int64」、「String data, right truncation」），還不會說是哪一欄。
    """
    values = series.dropna()
    if values.empty:
        return None
    name = spec.split("(")[0].strip().upper()

    if name == "NVARCHAR":
        m = NVARCHAR_RE.fullmatch(spec.strip().upper())
        if not m:
            return None                     # 已經是 NVARCHAR(MAX)
        longest = int(values.astype(str).str.len().max())
        return text_spec(longest) if longest > int(m.group(1)) else None

    if name in ("INT", "BIGINT"):
        numbers = as_numbers(values)
        if numbers.empty:
            return None
        if not numbers.mod(1).eq(0).all():
            # 數量欄位常常是 12.500 這種，前 200 列剛好都整數就會判成 INT
            return infer(as_numbers(series))
        if name == "INT" and (numbers.min() < -2**31 or numbers.max() >= 2**31):
            return "BIGINT"
        return None

    if name in ("DECIMAL", "NUMERIC"):
        m = DECIMAL_RE.fullmatch(spec.strip().upper())
        if not m:
            return None
        numbers = as_numbers(values)
        if numbers.empty:
            return None
        used = scale_of(numbers)
        if used is None or used <= int(m.group(2)):
            return None
        # 小數位不夠不會報錯，SQL Server 會安靜地四捨五入掉
        if used > MAX_SCALE:
            return text_spec(int(values.astype(str).str.len().max()))
        return f"DECIMAL(18,{used})"

    return None


def fit_types(df, types, pinned=()):
    """用完整資料校正型別，回 (型別, 調整過的, 衝突的)。

    自己推斷出來的放寬就好；使用者在 config.json 指定死的不動它，
    改成報錯並指名欄位——那是他明確的選擇，不該被偷偷改掉。
    """
    fitted, changed, conflicts = dict(types), {}, {}
    for col, spec in types.items():
        if col not in df.columns:
            continue
        better = better_spec(df[col], spec)
        if better is None or better == spec:
            continue
        if col in pinned:
            conflicts[col] = (spec, better)
            continue
        fitted[col] = better
        changed[col] = better
    return fitted, changed, conflicts


# 每寫入這麼多列回報一次。太小的話光是回報就拖慢速度。
PROGRESS_ROWS = 50_000


def import_table(engine, table, mode="replace", overrides=None, progress=None):
    """匯入一張表。整個動作包在交易裡，失敗會回滾，不影響其他表。

    progress 是一個接收字串的函式。幾十萬列要跑好幾分鐘，沒有回報的話
    沒辦法分辨是卡住還是在跑。
    """
    say = progress or (lambda message: None)
    if not table.ok:
        raise ValueError(table.error)
    types = {**table.dtypes, **(overrides or {})}
    pinned = set(table.pinned) | set(overrides or {})

    # 先用完整資料校正型別再轉換：掃描是抽樣的，直接拿去 coerce 會在
    # 「無法轉成 INT」或 INSERT 的截斷錯誤上炸掉。
    raw = load(table.files, table.opts, table.int_codes, say)
    say("校正型別…")
    types, table.widened, conflicts = fit_types(raw, types, pinned)
    if conflicts:
        detail = "、".join(f"{c} 指定 {old}，但實際資料需要 {new}"
                           for c, (old, new) in conflicts.items())
        # 小數位太多而被推去 NVARCHAR 的，改成文字不是唯一的解法——
        # 訊息只寫「需要 NVARCHAR」會害人以為不能留成數字。
        rounded = any(old.upper().startswith(("DECIMAL", "NUMERIC"))
                      and new.upper().startswith("NVARCHAR")
                      for old, new in conflicts.values())
        hint = (f"小數位超過 {MAX_SCALE} 位就不自動給 DECIMAL 了；"
                f"要留成數字就自己指定夠用的位數，例如 "
                f"DECIMAL(18,{MAX_SCALE + 1})。" if rounded else "")
        raise ValueError(
            f"指定的型別放不下：{detail}。"
            "請在 config.json 的 dtypes 調整，或把該欄的指定拿掉讓程式自己判斷。"
            + hint)
    table.dtypes.update(table.widened)

    say("轉換型別…")
    df = coerce(raw, types)
    dtype = {c: to_sa(t) for c, t in types.items() if c in df.columns}

    total = len(df)
    with engine.begin() as conn:
        if not total:                       # 空表也要建出來
            df.to_sql(table.name, conn, if_exists=mode, index=False,
                      dtype=dtype)
        for start in range(0, total, PROGRESS_ROWS):
            part = df.iloc[start:start + PROGRESS_ROWS]
            part.to_sql(table.name, conn, index=False, dtype=dtype,
                        if_exists=mode if start == 0 else "append",
                        chunksize=1000)
            say(f"寫入 {min(start + PROGRESS_ROWS, total):,} / {total:,} 列")
    return total


DEFAULT_DRIVER = "ODBC Driver 17 for SQL Server"


def installed_drivers():
    """機器上裝的 SQL Server ODBC 驅動，版本高的排前面。"""
    found = [d for d in pyodbc.drivers()
             if "ODBC Driver" in d and "SQL Server" in d]
    return sorted(found, key=lambda d: int(re.search(r"\d+", d).group())
                  if re.search(r"\d+", d) else 0, reverse=True)


def best_driver():
    """挑機器上實際裝的驅動。

    連線字串寫死 17、機器上裝的卻是 18，ODBC 會回 IM002
    「找不到資料來源名稱且未指定預設的驅動程式」——名字差一個字就連不上，
    而且錯誤訊息完全看不出是版本號的問題。
    """
    found = installed_drivers()
    return found[0] if found else DEFAULT_DRIVER


def missing_driver():
    """回傳提示字串；沒問題就回傳空字串。"""
    if installed_drivers():
        return ""
    return ("找不到 ODBC Driver for SQL Server。\n"
            "請先安裝「ODBC Driver 17 for SQL Server」再使用本程式。\n"
            "檢查指令：reg query "
            '"HKLM\\SOFTWARE\\ODBC\\ODBCINST.INI\\ODBC Drivers"')


def driver_hint():
    """連線失敗時附在錯誤訊息後面的提示。"""
    found = installed_drivers()
    if not found:
        return missing_driver()
    using = os.environ.get("SQL_DRIVER") or best_driver()
    return ("這台機器上裝的驅動：\n  " + "\n  ".join(found)
            + f"\n目前使用：{using}"
            + "\n名字要一字不差；要指定別的就在 .env 設 SQL_DRIVER。"
            + "\nDriver 18 預設強制加密，憑證不受信任時連線字串要補上"
            " TrustServerCertificate=yes。")


CERT_KEYWORDS = ("SSL Provider", "certificate", "憑證", "SSL 提供者")


def explain_conn_error(err):
    """把連線例外變成人看得懂的訊息。

    兩種錯誤的原始訊息都看不出真正的原因：
    IM002 其實是驅動名稱對不上，憑證錯誤其實是 Driver 18 的強制加密。
    """
    msg = str(err)
    if any(k in msg for k in ("IM002", "資料來源名稱", "Data source name")):
        return msg + "\n\n" + driver_hint()
    if any(k in msg for k in CERT_KEYWORDS):
        return msg + "\n\n" + cert_hint()
    return msg


def cert_hint():
    """Driver 18 強制加密、憑證不受信任時的提示。"""
    return ("ODBC Driver 18 起預設強制加密，且會驗證伺服器憑證。"
            "內部的 SQL Server 多半用自簽憑證，就會被擋在這裡。\n"
            "\n"
            "兩條路：\n"
            "  1. 請 DBA 裝上受信任的憑證（正解，連線與身分驗證都成立）\n"
            "  2. 在 .env 加 SQL_TRUST_CERT=yes 跳過憑證驗證\n"
            "\n"
            "選 2 的話，連線仍然是加密的，但不再驗證對方是不是真的那台"
            "伺服器——也就是擋不住中間人。內網用通常可接受，對外連線不要這樣設。")


# --- 設定 ---------------------------------------------------------------

DEFAULTS = {
    "conn": "mssql+pyodbc://@SERVER/DB?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes",
    "root": "data",
    "write_mode": "replace",
    "dtypes": {},
    "txt": {},
    # 沒有小數的整數欄位一律當文字。SAP 的標準欄位清單列不完，
    # 而猜錯成文字可以在 SQL 端 CAST 救回來，猜錯成整數前導零就沒了。
    # 要讓某一欄當數字，用 dtypes 指定 INT/DECIMAL。
    "int_codes": True,
}


# 連線相關的環境變數，診斷時要逐一印出來對照。
CONN_KEYS = ("SQL_CONN", "SQL_SERVER", "SQL_DATABASE", "SQL_USER",
             "SQL_PASSWORD", "SQL_DRIVER", "SQL_TRUST_CERT")


def load_env(path=".env"):
    """讀 .env。已存在的環境變數優先，所以臨時用 set 蓋掉也有效。"""
    p = Path(path)
    if not p.exists():
        return
    for line in p.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def conn_from_env():
    """用環境變數組連線字串。資訊不足就回空字串，改用 config.json。"""
    if os.environ.get("SQL_CONN"):
        return os.environ["SQL_CONN"]
    server = os.environ.get("SQL_SERVER")
    database = os.environ.get("SQL_DATABASE")
    if not (server and database):
        return ""
    # 沒指定就用機器上實際裝的，免得寫死 17 卻裝了 18
    driver = os.environ.get("SQL_DRIVER") or best_driver()
    query = f"driver={quote_plus(driver)}"
    user = os.environ.get("SQL_USER")
    if user:
        # 密碼裡的 @ 或 : 會把 URL 拆壞，一律編碼。
        password = quote_plus(os.environ.get("SQL_PASSWORD", ""))
        auth = f"{quote_plus(user)}:{password}@"
    else:
        auth = "@"
        query += "&trusted_connection=yes"
    # Driver 18 起預設強制加密並驗證憑證，內部的自簽憑證會被擋。
    # 跳過驗證是明確的選擇，不自動開。
    if os.environ.get("SQL_TRUST_CERT", "").strip().lower() in ("1", "y", "yes", "true"):
        query += "&TrustServerCertificate=yes"
    return f"mssql+pyodbc://{auth}{server}/{database}?{query}"


def apply_overrides(tables, cfg):
    """把 config.json 裡存下來的型別與 txt 解析設定套回掃描結果。"""
    saved = cfg.get("dtypes", {})
    txt = cfg.get("txt", {})
    for t in tables:
        t.opts = {**txt.get(t.name, {}), **t.opts}
        mine = {c: ty for c, ty in saved.get(t.name, {}).items()
                if c in t.dtypes}
        t.dtypes.update(mine)
        t.pinned |= set(mine)       # 指定死的不讓程式自己放寬
    return tables


def load_config(path=CONFIG):
    cfg = dict(DEFAULTS)
    p = Path(path)
    if p.exists():
        cfg.update(json.loads(p.read_text(encoding="utf-8")))
    load_env(p.parent / ".env")
    env_conn = conn_from_env()          # .env 的連線資訊優先於 config.json
    if env_conn:
        cfg["conn"] = env_conn
    return cfg


def save_config(cfg, path=CONFIG):
    Path(path).write_text(
        json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")



def mask(conn):
    """把連線字串裡的密碼遮掉，方便貼給別人看。"""
    return re.sub(r"://([^:/@]+):([^@]*)@", r"://\1:***@", conn)


def conn_report(path=CONFIG):
    """印出實際會用的連線設定，給連不上的時候對照用。

    「我明明改了 .env」最常見的原因是那份 .env 根本沒被讀到，
    或是程式還是舊版、根本不認得新的設定。直接把讀到什麼印出來。
    """
    env = Path(path).parent / ".env"
    out = [f"程式版本　：{'認得 SQL_TRUST_CERT' if 'SQL_TRUST_CERT' in CONN_KEYS else '舊版，不認得 SQL_TRUST_CERT'}",
           f".env 路徑 ：{env.resolve()}",
           f".env 存在 ：{'是' if env.exists() else '否 —— 沒讀到任何設定'}"]

    load_env(env)
    out.append("")
    out.append("讀到的環境變數：")
    for key in CONN_KEYS:
        value = os.environ.get(key)
        if key == "SQL_PASSWORD" and value:
            value = "***"
        out.append(f"  {key:<16} {value if value else '（未設定）'}")

    out.append("")
    out.append(f"裝的 ODBC 驅動：{', '.join(installed_drivers()) or '（一個都沒有）'}")
    out.append(f"實際使用驅動　：{os.environ.get('SQL_DRIVER') or best_driver()}")

    cfg = load_config(path)
    out.append("")
    out.append(f"最終連線字串　：{mask(cfg['conn'])}")
    if "TrustServerCertificate" not in cfg["conn"]:
        out.append("  （沒有 TrustServerCertificate —— Driver 18 會驗證憑證）")
    return "\n".join(out)
