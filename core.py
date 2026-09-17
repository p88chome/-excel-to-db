"""掃描資料夾、推斷欄位型別、把 Excel/CSV 匯入資料庫。

這個模組不 import tkinter，所以可以單獨用 sqlite 測試，
也讓之後換 UI 或加命令列介面時不用動到匯入邏輯。
"""
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import openpyxl
import pandas as pd
import pyodbc
from sqlalchemy import create_engine
from sqlalchemy.types import (
    NVARCHAR, BigInteger, Boolean, Date, DateTime, Float, Integer, Numeric,
)

EXTS = {".csv", ".xlsx", ".xls"}
PREVIEW_ROWS = 200
CONFIG = Path("config.json")

# UI 下拉選單的選項。順序即顯示順序。
TYPE_CHOICES = [
    "INT", "BIGINT", "DECIMAL(18,2)", "FLOAT", "BIT",
    "DATE", "DATETIME",
    "NVARCHAR(50)", "NVARCHAR(255)", "NVARCHAR(4000)", "NVARCHAR(MAX)",
]


# --- 讀檔 ---------------------------------------------------------------

def read(path, nrows=None):
    """讀一個檔案。nrows 只讀前幾列，給預覽用。"""
    if path.suffix.lower() == ".csv":
        return pd.read_csv(path, nrows=nrows)
    return pd.read_excel(path, nrows=nrows)


def count_rows(path):
    """不把整個檔讀進記憶體的前提下數資料列（不含標題）。"""
    if path.suffix.lower() == ".csv":
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


def scan(root):
    """掃描資料夾，每個檔只讀前 PREVIEW_ROWS 列，回傳每張表的預覽資訊。"""
    tables = []
    for name, files in groups(root):
        t = Table(name=name, files=files)
        try:
            samples = [read(f, nrows=PREVIEW_ROWS) for f in files]
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
                t.rows = sum(count_rows(f) for f in files)
        except Exception as e:
            t.error = f"{type(e).__name__}: {e}"
        tables.append(t)
    return tables


def load(files):
    """讀完整資料。欄位不一致就丟例外 —— 猜錯比不做更糟。"""
    frames = [read(f) for f in files]
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
    df = coerce(load(table.files), types)
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


# --- 設定檔 -------------------------------------------------------------

DEFAULTS = {
    "conn": "mssql+pyodbc://@SERVER/DB?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes",
    "root": "data",
    "write_mode": "replace",
    "dtypes": {},
}


def apply_overrides(tables, cfg):
    """把 config.json 裡存下來的型別覆寫套回掃描結果。"""
    saved = cfg.get("dtypes", {})
    for t in tables:
        t.dtypes.update({c: ty for c, ty in saved.get(t.name, {}).items()
                         if c in t.dtypes})
    return tables


def load_config(path=CONFIG):
    cfg = dict(DEFAULTS)
    p = Path(path)
    if p.exists():
        cfg.update(json.loads(p.read_text(encoding="utf-8")))
    return cfg


def save_config(cfg, path=CONFIG):
    Path(path).write_text(
        json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
