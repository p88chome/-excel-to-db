"""命令列版匯入，沒有預覽。圖形介面版見 app.pyw。

連線字串與型別設定都讀 config.json，跟 UI 共用同一份設定。

用法：
    python import_data.py                 # 用 config.json 裡的資料夾與模式
    python import_data.py data            # 指定資料夾
    python import_data.py data append     # 指定資料夾與寫入模式
"""
import sys

import core


def main(root=None, mode=None):
    cfg = core.load_config()
    root = root or cfg["root"]
    mode = mode or cfg["write_mode"]

    if cfg["conn"].startswith("mssql"):
        missing = core.missing_driver()
        if missing:
            sys.exit(missing)

    engine = core.connect(cfg["conn"])
    tables = core.apply_overrides(core.scan(root), cfg)
    if not tables:
        sys.exit(f"{root} 底下沒有 .csv/.xlsx/.xls 檔案")

    failed = 0
    for t in tables:
        if not t.ok:
            print(f"略過 {t.name}：{t.error}")
            failed += 1
            continue
        try:
            rows = core.import_table(engine, t, mode)
            print(f"{t.name}：{rows:,} 列 <- {len(t.files)} 個檔案")
            bad = core.suspects(t)
            if bad:
                print(f"  注意：{' '.join(bad)} 被推斷成整數，"
                      f"但欄名不在 SAP 代碼欄位清單。")
                print(f"  如果是代碼欄位，請在 config.json 的 dtypes 改成 "
                      f"NVARCHAR，否則前導零會掉、JOIN 不到來源表。")
        except Exception as e:
            print(f"失敗 {t.name}：{str(e).splitlines()[0]}")
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
