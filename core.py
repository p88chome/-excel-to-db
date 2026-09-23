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
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote_plus

import openpyxl
import pandas as pd
import pyodbc
from sqlalchemy import create_engine
from sqlalchemy.types import (
    NVARCHAR, BigInteger, Boolean, Date, DateTime, Float, Integer, Numeric,
)

EXTS = {".csv", ".xlsx", ".xls", ".txt"}
PREVIEW_ROWS = 200
CONFIG = Path("config.json")

# UI 下拉選單的選項。順序即顯示順序。
TYPE_CHOICES = [
    "INT", "BIGINT", "DECIMAL(18,2)", "FLOAT", "BIT",
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
    """單一分隔符格式。出現次數最多的欄數才算資料，其餘是標題與頁尾。"""
    counts = Counter(ln.count(sep) for ln in lines if ln.strip())
    if not counts:
        return []
    n, hits = counts.most_common(1)[0]
    if n < 1 or hits < 2:           # 至少要有標題列加一筆資料
        return []
    return [[c.strip() for c in ln.split(sep)]
            for ln in lines if ln.strip() and ln.count(sep) == n]


def widest(rows):
    """只留下欄數最常見的列，順手丟掉 SAP 檔尾的「* n 筆記錄」。"""
    if not rows:
        return []
    n = Counter(len(r) for r in rows).most_common(1)[0][0]
    return [r for r in rows if len(r) == n]


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
    if sep == "|":
        rows = split_pipe(lines)
    elif sep:
        rows = split_char(lines, sep)
    else:
        rows = split_pipe(lines)
        for cand in AUTO_SEPS:
            if len(rows) >= 2:
                break
            rows = split_char(lines, cand)

    rows = widest(rows)
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
""".split())


def is_code_field(name):
    """欄名是不是 SAP 的代碼欄位。大小寫與前後空白都不計。"""
    return str(name).strip().upper() in SAP_CODE_FIELDS

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


def sap_numbers(s):
    """整欄都是 SAP 數字才轉換，否則回 None 讓它留著當文字。"""
    v = s.dropna()
    if v.empty or v.map(lambda x: bool(CODE_RE.fullmatch(x))).any():
        return None
    if not v.map(lambda x: bool(NUM_RE.match(x))).all():
        return None
    dec = decimal_sep(v)
    out = pd.to_numeric(
        s.map(lambda x: to_number(x, dec) if isinstance(x, str) else None))
    kept = out.dropna()
    if not kept.empty and kept.mod(1).eq(0).all() and kept.abs().lt(2**63).all():
        return out.astype("Int64")
    return out


def valid_date(y, mo, dy):
    return 1900 <= y <= 2100 and 1 <= mo <= 12 and 1 <= dy <= 31


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
    return pd.to_datetime(s.map(lambda x: norm_date(x, rx, layout)))


def sap_convert(df):
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
        out[col] = s if converted is None else converted
    return pd.DataFrame(out, columns=df.columns)


def read_txt(path, encoding=None, sep=None, skiprows=0):
    text = decode(Path(path).read_bytes(), encoding)
    return sap_convert(parse(text, sep=sep, skiprows=skiprows))


# --- 讀檔 ---------------------------------------------------------------

def read(path, nrows=None, opts=None):
    """讀一個檔案。nrows 只讀前幾列，給預覽用。opts 是 txt 的解析覆寫。"""
    ext = Path(path).suffix.lower()
    if ext == ".txt":
        df = read_txt(path, **(opts or {}))
        return df.head(nrows) if nrows else df
    if ext == ".csv":
        return pd.read_csv(path, nrows=nrows)
    return pd.read_excel(path, nrows=nrows)


def count_rows(path, opts=None):
    """不把整個檔讀進記憶體的前提下數資料列（不含標題）。"""
    ext = Path(path).suffix.lower()
    if ext == ".txt":
        o = dict(opts or {})
        text = decode(Path(path).read_bytes(), o.pop("encoding", None))
        return len(parse(text, **o))
    if ext == ".csv":
        with open(path, "rb") as f:
            return max(sum(1 for _ in f) - 1, 0)
    wb = openpyxl.load_workbook(path, read_only=True)
    try:
        return max((wb.active.max_row or 1) - 1, 0)
    finally:
        wb.close()


# --- 型別推斷 -----------------------------------------------------------

# 只有長得像日期的字串才嘗試轉換，免得 "1"、"2" 這種被 pandas 當成日期。
DATE_RE = re.compile(r"\s*\d{4}[-/]\d{1,2}[-/]\d{1,2}([ T]\d{1,2}:\d{2}(:\d{2})?)?\s*")


def as_datetime(s):
    """整欄都像日期就轉成 datetime，否則回 None。"""
    text = s.astype(str)
    if not text.str.fullmatch(DATE_RE).all():
        return None
    try:
        return pd.to_datetime(text)
    except (ValueError, TypeError):
        return None


def infer(series):
    """從一個欄位的資料推斷 SQL Server 型別字串。"""
    s = series.dropna()
    if s.empty:
        return "NVARCHAR(255)"

    # CSV 讀進來的日期是字串，要先還原才推得出 DATE/DATETIME。
    if s.dtype.kind == "O":
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
        decimals = s.astype(str).str.extract(r"\.(\d+)$")[0].str.len().max()
        if pd.isna(decimals):
            return "DECIMAL(18,2)"
        if decimals > 6:
            return "FLOAT"
        return f"DECIMAL(18,{max(int(decimals), 2)})"
    if kind == "M":
        return "DATE" if (s.dt.normalize() == s).all() else "DATETIME"

    # 文字：量最大長度再留一倍成長空間，比預設的 NVARCHAR(MAX) 好用得多。
    longest = int(s.astype(str).str.len().max())
    return f"NVARCHAR({min(max(longest * 2, 20), 4000)})"


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

    @property
    def ok(self):
        return not self.error


def groups(root):
    """列出 (表名, 檔案清單)。子資料夾 = 一張表，散檔 = 一張表。"""
    for p in sorted(Path(root).iterdir()):
        if p.is_dir():
            files = [f for f in sorted(p.iterdir()) if f.suffix.lower() in EXTS]
            if files:
                yield p.name, files
        elif p.suffix.lower() in EXTS:
            yield p.stem, [p]


def scan(root, cfg=None):
    """掃描資料夾，每個檔只讀前 PREVIEW_ROWS 列，回傳每張表的預覽資訊。"""
    txt_opts = (cfg or {}).get("txt", {})
    tables = []
    for name, files in groups(root):
        t = Table(name=name, files=files, opts=dict(txt_opts.get(name, {})))
        try:
            samples = [read(f, nrows=PREVIEW_ROWS, opts=t.opts) for f in files]
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


def load(files, opts=None):
    """讀完整資料。欄位不一致就丟例外 —— 猜錯比不做更糟。"""
    frames = [read(f, opts=opts) for f in files]
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
        try:
            if name in ("DATE", "DATETIME"):
                out[col] = pd.to_datetime(out[col])
                if name == "DATE":
                    out[col] = out[col].dt.normalize()
            elif name in ("INT", "BIGINT"):
                out[col] = pd.to_numeric(out[col]).astype("Int64")
            elif name in ("DECIMAL", "NUMERIC", "FLOAT"):
                out[col] = pd.to_numeric(out[col])
            elif name == "BIT":
                out[col] = out[col].astype("boolean")
            elif name == "NVARCHAR":
                out[col] = out[col].astype("string")
        except (ValueError, TypeError) as e:
            raise ValueError(f"欄位「{col}」無法轉成 {spec}：{e}") from e
    return out


def connect(conn_str):
    is_mssql = conn_str.startswith("mssql")
    return create_engine(conn_str, fast_executemany=True) if is_mssql \
        else create_engine(conn_str)


def import_table(engine, table, mode="replace", overrides=None):
    """匯入一張表。整個動作包在交易裡，失敗會回滾，不影響其他表。"""
    if not table.ok:
        raise ValueError(table.error)
    types = {**table.dtypes, **(overrides or {})}
    df = coerce(load(table.files, table.opts), types)
    dtype = {c: to_sa(t) for c, t in types.items() if c in df.columns}
    with engine.begin() as conn:
        df.to_sql(table.name, conn, if_exists=mode, index=False,
                  chunksize=1000, dtype=dtype)
    return len(df)


def missing_driver():
    """回傳提示字串；沒問題就回傳空字串。"""
    if any("ODBC Driver" in d and "SQL Server" in d for d in pyodbc.drivers()):
        return ""
    return ("找不到 ODBC Driver for SQL Server。\n"
            "請先安裝「ODBC Driver 17 for SQL Server」再使用本程式。\n"
            "檢查指令：reg query "
            '"HKLM\\SOFTWARE\\ODBC\\ODBCINST.INI\\ODBC Drivers"')


# --- 設定 ---------------------------------------------------------------

DEFAULTS = {
    "conn": "mssql+pyodbc://@SERVER/DB?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes",
    "root": "data",
    "write_mode": "replace",
    "dtypes": {},
    "txt": {},
}

DEFAULT_DRIVER = "ODBC Driver 17 for SQL Server"


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
    driver = os.environ.get("SQL_DRIVER", DEFAULT_DRIVER)
    query = f"driver={quote_plus(driver)}"
    user = os.environ.get("SQL_USER")
    if user:
        # 密碼裡的 @ 或 : 會把 URL 拆壞，一律編碼。
        password = quote_plus(os.environ.get("SQL_PASSWORD", ""))
        auth = f"{quote_plus(user)}:{password}@"
    else:
        auth = "@"
        query += "&trusted_connection=yes"
    return f"mssql+pyodbc://{auth}{server}/{database}?{query}"


def apply_overrides(tables, cfg):
    """把 config.json 裡存下來的型別與 txt 解析設定套回掃描結果。"""
    saved = cfg.get("dtypes", {})
    txt = cfg.get("txt", {})
    for t in tables:
        t.opts = {**txt.get(t.name, {}), **t.opts}
        t.dtypes.update({c: ty for c, ty in saved.get(t.name, {}).items()
                         if c in t.dtypes})
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
