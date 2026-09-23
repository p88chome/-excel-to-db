"""看一眼 SAP 匯出的 txt 到底長什麼樣，不連資料庫、不寫任何檔案。

這支刻意只用標準函式庫，沒有 pandas 也跑得動——目的就是讓遠端機器
只要複製這一個檔案就能診斷格式，不必先把整個專案裝起來。

用法：
    python sniff.py D:\\SAP\\ZMM001.txt          # 看單一檔案
    python sniff.py D:\\SAP                      # 看整個資料夾裡的 txt
    python sniff.py D:\\SAP --short              # 每個檔壓成兩行

完整輸出貼得回來的話，整段貼就好。遠端跟這邊沒連通、只能用手打的時候，
用 --short，一個檔兩行、六十幾個字，打得完。
"""
import codecs
import json
import re
import sys
from collections import Counter
from pathlib import Path

BOMS = [
    (codecs.BOM_UTF8, "utf-8-sig"),
    (codecs.BOM_UTF16_LE, "utf-16"),
    (codecs.BOM_UTF16_BE, "utf-16"),
]
FALLBACKS = ("utf-8", "cp950", "cp1252")

PIPE_ROW = re.compile(r"^\s*\|.*\|\s*$")
RULE_ROW = re.compile(r"^[\s|+\-=_]*$")
AUTO_SEPS = ("\t", ";", ",")
SEP_NAMES = {"\t": "Tab", ";": "分號 ;", ",": "逗號 ,", "|": "管線 |"}
# 短報告用 | 當欄位分界，分隔符名稱裡不能再有 |
SHORT_SEPS = {"\t": "TAB", ";": "SEMI", ",": "COMMA", "|": "PIPE"}

NUM_RE = re.compile(r"^[-+]?(?:\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d+)?|\d+(?:[.,]\d+)?)[-+]?$")
CODE_RE = re.compile(r"0\d+")
DATE_RES = [
    (re.compile(r"\d{4}-\d{1,2}-\d{1,2}"), "YYYY-MM-DD", "D:iso"),
    (re.compile(r"\d{1,2}\.\d{1,2}\.\d{4}"), "DD.MM.YYYY", "D:dot"),
    (re.compile(r"\d{1,2}/\d{1,2}/\d{4}"), "DD/MM/YYYY 或 MM/DD/YYYY", "D:slash?"),
    (re.compile(r"(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])"), "YYYYMMDD", "D:8"),
]
NULL_TOKENS = {"", "#", "-", "--", "n/a", "na", "null", "none",
               "00000000", "0000-00-00", "00.00.0000", "00/00/0000"}

SHORT_LEGEND = (
    "代碼：T=文字 T0=文字有前導零 T!=SAP代碼欄位強制文字 N=數字 "
    "N!=整數但欄名不在清單（請確認） N-=有尾綴負號 N?=千分位待確認 "
    "D:iso=YYYY-MM-DD D:dot=DD.MM.YYYY D:slash?=日月順序待確認 "
    "D:8=YYYYMMDD _=整欄空白")

# SAP 代碼欄位清單放在 core.py，這裡不複製一份，免得兩邊改到不一致。
# 只複製了 sniff.py 到遠端、或那台沒裝 pandas 時，清單就不套用——
# 版面與編碼的判斷不受影響，只是代碼欄位不會標成 T!。
try:
    from core import SAP_CODE_FIELDS, SAP_NUMERIC_FIELDS, is_code_field
except Exception:                                   # noqa: BLE001
    SAP_CODE_FIELDS = SAP_NUMERIC_FIELDS = frozenset()

    def is_code_field(name):
        return False


# 舊版 Windows 主控台是 cp950，印到不支援的符號會整支掛掉。
try:
    sys.stdout.reconfigure(errors="replace")
except (AttributeError, ValueError):
    pass


def sniff_encoding(raw):
    """回傳 (編碼, 怎麼判斷出來的)。"""
    for bom, enc in BOMS:
        if raw.startswith(bom):
            return enc, "檔頭有 BOM"
    for enc in FALLBACKS:
        try:
            raw.decode(enc)
            return enc, "沒有 BOM，試解成功"
        except UnicodeDecodeError:
            continue
    return "latin-1", "全部試過都失敗，硬解（可能有亂碼）"


def rows_by_pipe(lines):
    return [[c.strip() for c in ln.strip().strip("|").split("|")]
            for ln in lines if PIPE_ROW.match(ln) and not RULE_ROW.match(ln)]


def rows_by_char(lines, sep):
    # 「大於等於」而不是「等於」：SAP 會砍掉每列結尾的空欄，
    # 最後一欄沒值的資料列會比標題列少一個分隔符。跟 core.py 同一條規則。
    counts = Counter(ln.count(sep) for ln in lines if ln.strip())
    if not counts:
        return []
    n, hits = counts.most_common(1)[0]
    if n < 1 or hits < 2:
        return []
    return [[c.strip() for c in ln.split(sep)]
            for ln in lines if ln.strip() and ln.count(sep) >= n]


def squared(rows):
    """把各列補到一樣寬。"""
    width = max(len(r) for r in rows)
    return [r + [""] * (width - len(r)) for r in rows]


def find_layout(lines):
    """回傳 (分隔符, 資料列, 是不是管線格式)。認不出來分隔符回 None。"""
    rows = rows_by_pipe(lines)
    if len(rows) >= 2:
        return "|", rows, True
    for sep in AUTO_SEPS:
        rows = rows_by_char(lines, sep)
        if len(rows) >= 2:
            return sep, squared(rows), False
    return None, [], False


def header_line_no(lines, sep, header):
    """標題列在原始檔的第幾行（1 起算）。"""
    for i, ln in enumerate(lines, 1):
        cells = ([c.strip() for c in ln.strip().strip("|").split("|")]
                 if sep == "|" else [c.strip() for c in ln.split(sep)])
        if cells == header[:len(cells)]:    # header 可能被補過寬
            return i
    return 1


def guess_type(values, name=""):
    """從一欄的值推斷型別，回 (說明, 提醒, 短代碼)。"""
    real = [v for v in values if v.lower() not in NULL_TOKENS]
    if not real:
        return "（整欄空白）", "", "_"
    if is_code_field(name):
        return "文字（SAP 代碼欄位）", "欄名在 SAP 代碼欄位清單，一律當文字", "T!"
    for rx, fmt, date_code in DATE_RES:      # 別用 name/code，會蓋掉參數
        if all(rx.fullmatch(v.split(" ")[0]) for v in real):
            note = "!! 日月順序看不出來，預設當 DD/MM" if "或" in fmt else ""
            return f"日期 {fmt}", note, date_code
    if any(CODE_RE.fullmatch(v) for v in real):
        return "文字（有前導零）", "保持文字，轉數字會掉開頭的 0", "T0"
    if all(NUM_RE.fullmatch(v) for v in real):
        note, code = "", "N"
        if any(v.endswith("-") for v in real):
            note, code = "尾綴負號已辨識", "N-"
        ambiguous = [v for v in real
                     if (v.count(".") == 1 and len(v.split(".")[1]) == 3
                         and "," not in v)]
        if ambiguous and not any("," in v for v in real):
            note = f"!! 像 {ambiguous[0]} 這種看不出是千分位還是小數點，預設當千分位"
            code = "N?"
        # 欄名不在清單、整欄又都是沒小數的整數——代碼被當數字的典型長相。
        # 金額有小數、日期有格式，都不會落到這裡。
        if (code == "N" and SAP_CODE_FIELDS
                and name.strip().upper() not in SAP_NUMERIC_FIELDS
                and not any(re.search(r"[.,]\d{1,2}$", v) for v in real)):
            note = "!! 欄名不在 SAP 代碼欄位清單，整欄都是整數——是代碼的話要改成文字"
            code = "N!"
        return "數字", note, code
    return f"文字（最長 {max(len(v) for v in real)} 字）", "", "T"


def layout_of(path):
    """回傳 (編碼, 怎麼判的, 原始行, 分隔符, 標題列, 資料列, 前面跳幾行)。"""
    raw = path.read_bytes()
    enc, why = sniff_encoding(raw)
    lines = raw.decode(enc, errors="replace").splitlines()
    sep, rows, piped = find_layout(lines)
    if not sep:
        return enc, why, lines, None, [], [], 0
    if piped:                       # 管線格式每列寬度一致，異常列丟掉
        n = Counter(len(r) for r in rows).most_common(1)[0][0]
        rows = [r for r in rows if len(r) == n]
    header = rows[0]
    data = [r for r in rows[1:] if r != header]     # ALV 分頁會重印標題
    skip = header_line_no(lines, sep, header) - 1
    return enc, why, lines, sep, header, data, skip


def short_report(path):
    """壓成兩行，給沒辦法複製檔案、只能用手打的情況。"""
    enc, _, _, sep, header, data, skip = layout_of(path)
    if not sep:
        print(f"{path.stem} | {enc} | 認不出分隔符（可能是固定寬度）")
        return
    print(f"{path.stem} | {enc} | {SHORT_SEPS.get(sep, sep)} | "
          f"{len(header)}col | skip{skip} | {len(data)}row")
    print(" ".join(
        f"{name or f'COL{i + 1}'}:{guess_type([r[i] for r in data[:200]], name)[2]}"
        for i, name in enumerate(header)))


def report(path):
    enc, why, lines, sep, header, data, skip = layout_of(path)

    print("=" * 70)
    print(f"檔案　　：{path}")
    print(f"大小　　：{path.stat().st_size:,} bytes，{len(lines):,} 行")
    print(f"編碼　　：{enc}（{why}）")

    print("\n--- 原始前 8 行（[TAB]）---")
    for i, ln in enumerate(lines[:8], 1):
        print(f"{i:>3} | {ln.replace(chr(9), '[TAB]')[:160]}")

    if not sep:
        print("\nX 認不出分隔符。可能是固定寬度格式，請把上面前 8 行貼回來。")
        return

    print("\n--- 版面 ---")
    print(f"分隔符　：{SEP_NAMES.get(sep, sep)}")
    print(f"欄位數　：{len(header)}")
    print(f"標題列　：第 {skip + 1} 行（前面 {skip} 行是報表標題/空行，跳過）")
    print(f"資料列　：{len(data):,} 筆"
          f"（檔尾另有 {len(lines) - skip - 1 - len(data):,} 行被當成統計列丟掉）")

    print("\n--- 欄位 ---")
    width = max((len(c) for c in header), default=6)
    print(f"{'欄名'.ljust(width)} | {'推斷型別'.ljust(18)} | 前 3 筆值")
    print("-" * 70)
    for i, name in enumerate(header):
        values = [r[i] for r in data[:200]]
        kind, note, _ = guess_type(values, name)
        shown = " / ".join(v[:18] or "(空)" for v in values[:3])
        print(f"{(name or f'COL{i + 1}').ljust(width)} | {kind.ljust(18)} | {shown}")
        if note:
            print(f"{' ' * width} | {note}")

    print("\n--- 貼進 config.json 的 txt 區（自動偵測不準時才需要）---")
    print(json.dumps(
        {"txt": {path.stem: {"encoding": enc, "sep": sep, "skiprows": 0}}},
        indent=2, ensure_ascii=False))
    print("（skiprows 只在標題列被認錯時才要調；sep 用 \\t 代表 Tab）")

    print("\n--- 沒辦法複製檔案時，手打這兩行就夠 ---")
    short_report(path)


def main(*argv):
    short = "--short" in argv or "-s" in argv
    args = [a for a in argv if not a.startswith("-")]
    p = Path(args[0] if args else ".")
    files = sorted(p.glob("*.txt")) if p.is_dir() else [p]
    if not files:
        sys.exit(f"{p} 底下沒有 .txt")
    if short:
        print(SHORT_LEGEND)
    if not SAP_CODE_FIELDS:
        print("注意：讀不到 core.py，SAP 代碼欄位清單這次沒套用。")
    for f in files:
        try:
            short_report(f) if short else report(f)
        except Exception as e:
            print(f"X {f}：{type(e).__name__}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
