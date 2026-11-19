"""把 etl/sql/kri_procs/ 底下每一題的檔案合併成 etl/sql/11_kri_procedures.sql。

    python etl/build_kri_sql.py           # 重新產生
    python etl/build_kri_sql.py --check   # 只檢查 11 是不是最新的（測試用），不是就回傳 1

改 KRI 時改 kri_procs/ 底下那一題的檔，再跑這支。只改一題時，也可以直接在 SSMS 開那一題的檔按 F5。
"""
import sys
from pathlib import Path

SQL = Path(__file__).resolve().parent / "sql"
OUT = SQL / "11_kri_procedures.sql"

HEADER = """\
-- 由 etl/build_kri_sql.py 把 etl/sql/kri_procs/ 底下每一題的檔合併產生，不要手改這個檔。
-- 要改某一題：改 kri_procs/ 底下那一題的檔，再跑 python etl/build_kri_sql.py。
--
-- 每題一張明細表 kri.Kxx_Detail（每次執行一個 RunId），被標記的列另外寫一列到 kri.Flag。
-- 程序由 kri.RunAll 呼叫；交易與執行紀錄由 RunAll 處理，程序本身不開交易。
-- 明細表只在不存在時建立；改了欄位要先手動 DROP 那張明細表再跑。
--
-- 目錄：
"""


def files():
    return sorted(SQL.glob("kri_procs/K*.sql"))


def build():
    toc, parts = [], []
    for f in files():
        code, _, name = f.stem.partition("_")
        toc.append(f"--   {code}  {name}")
        body = f.read_text("utf-8-sig").rstrip("\n")
        parts.append(f"-- {'#' * 70}\n-- 檔案：kri_procs/{f.name}\n-- {'#' * 70}\n{body}\n")
    return "﻿" + HEADER + "\n".join(toc) + "\n\n" + "\n".join(parts)


if __name__ == "__main__":
    text = build()
    if "--check" in sys.argv:
        same = OUT.exists() and OUT.read_text("utf-8") == text
        print("11_kri_procedures.sql 是最新的" if same else
              "11_kri_procedures.sql 不是最新的：請跑 python etl/build_kri_sql.py")
        sys.exit(0 if same else 1)
    OUT.write_text(text, "utf-8", newline="\n")
    print(f"已產生 {OUT.name}（{len(files())} 題）")
