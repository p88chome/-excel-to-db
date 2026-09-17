"""Import CSV/Excel files under a root folder into SQL Server.

Layout rule:
    data/
      customers/          -> table "customers" (all files inside concatenated)
        cust_2024.xlsx
        cust_2025.csv
      orders.csv          -> table "orders"

Usage: python import_data.py [root]      (root defaults to "data")
Deps:  pip install pandas sqlalchemy pyodbc openpyxl
"""
import sys
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine

CONN = "mssql+pyodbc://@SERVER/DB?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes"
EXTS = {".csv", ".xlsx", ".xls"}


def read(path):
    return pd.read_csv(path) if path.suffix.lower() == ".csv" else pd.read_excel(path)


def groups(root):
    """Yield (table_name, [files]) for each subfolder and each loose file."""
    for p in sorted(Path(root).iterdir()):
        if p.is_dir():
            files = [f for f in sorted(p.iterdir()) if f.suffix.lower() in EXTS]
            if files:
                yield p.name, files
        elif p.suffix.lower() in EXTS:
            yield p.stem, [p]


def load(files):
    """Concatenate files, refusing to guess when their columns disagree."""
    frames = [read(f) for f in files]
    cols = list(frames[0].columns)
    for f, df in zip(files[1:], frames[1:]):
        if set(df.columns) != set(cols):
            raise SystemExit(
                f"column mismatch in {f}\n"
                f"  expected (from {files[0].name}): {cols}\n"
                f"  got: {list(df.columns)}"
            )
    return pd.concat([df[cols] for df in frames], ignore_index=True)


def main(root):
    engine = create_engine(CONN, fast_executemany=True)
    for table, files in groups(root):
        df = load(files)
        df.to_sql(table, engine, if_exists="replace", index=False, chunksize=1000)
        print(f"{table}: {len(df)} rows <- {len(files)} file(s)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data")
