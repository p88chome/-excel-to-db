"""命令列版匯入，沒有預覽。圖形介面版見 app.pyw。

連線字串與型別設定都讀 config.json 與 .env，跟 UI 共用同一份設定。

用法：
    python import_data.py                 # 用 config.json 裡的資料夾與模式
    python import_data.py data            # 指定資料夾
    python import_data.py data append     # 指定資料夾與寫入模式
    python import_data.py data --check    # 只檢查不寫入，也不連資料庫
    python import_data.py --conn          # 印出實際用的連線設定（密碼遮蔽）

--check 是給 Excel 用的：sniff.py 只看得懂 txt，Excel 要先跑這個
才知道欄位被判成什麼型別、有沒有代碼欄位被當成數字。
"""
import sys

import core


def check(root, cfg):
    """掃描並列出每張表的欄位型別與可疑欄位。不連資料庫、不寫任何東西。"""
    tables = core.apply_overrides(core.scan(root, cfg), cfg)
    if not tables:
        sys.exit(f"{root} 底下沒有 .csv/.xlsx/.xls/.txt 檔案")

    for t in tables:
        print()
        print(f"{t.name}（{len(t.files)} 個檔案，{t.rows:,} 列）")
        if not t.ok:
            print(f"  X {t.error}")
            continue
        for col, ty in t.dtypes.items():
            print(f"  {col:<20} {ty}")
        bad = core.suspects(t)
        if bad:
            print(f"  參考：{' '.join(bad)} 是整數、欄名不在 SAP 清單，"
                  f"已當成文字。")
            print(f"  真的要拿來計算，就在 config.json 的 dtypes 指定 "
                  f"INT/DECIMAL，或在 SQL 端 CAST。")
    return 0


def main(*argv):
    args = [a for a in argv if not a.startswith("-")]
    cfg = core.load_config()
    root = (args[0] if args else None) or cfg["root"]
    mode = (args[1] if len(args) > 1 else None) or cfg["write_mode"]

    if "--conn" in argv:
        print(core.conn_report())
        return 0

    if "--check" in argv or "-c" in argv:
        return check(root, cfg)

    if cfg["conn"].startswith("mssql"):
        missing = core.missing_driver()
        if missing:
            sys.exit(missing)

    engine = core.connect(cfg["conn"])
    try:
        engine.connect().close()          # 先確認連得上，免得掃完才失敗
    except Exception as e:
        sys.exit("連線失敗：" + core.explain_conn_error(e))

    tables = core.apply_overrides(core.scan(root, cfg), cfg)
    if not tables:
        sys.exit(f"{root} 底下沒有 .csv/.xlsx/.xls/.txt 檔案")

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
                print(f"  參考：{' '.join(bad)} 是整數、欄名不在 SAP 清單，"
                      f"已當成文字。")
                print(f"  真的要拿來計算，就在 config.json 的 dtypes 指定 "
                      f"INT/DECIMAL，或在 SQL 端 CAST。")
        except Exception as e:
            print(f"失敗 {t.name}：{str(e).splitlines()[0]}")
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
