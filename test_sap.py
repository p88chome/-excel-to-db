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
