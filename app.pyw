"""Excel/CSV/SAP txt 匯入 SQL Server 的圖形介面。

副檔名用 .pyw，雙擊執行時不會跳出黑色命令列視窗。
所有匯入邏輯都在 core.py，這裡只處理畫面與執行緒。
"""
import queue
import threading
import traceback
from datetime import datetime
from pathlib import Path
from tkinter import StringVar, Tk, Toplevel, filedialog, messagebox, ttk

import core

LOG = Path("import.log")


def log(text):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}  {text}\n")


class App(Tk):
    def __init__(self):
        super().__init__()
        self.title("Excel/txt 匯入工具")
        self.geometry("980x680")
        self.minsize(820, 560)

        self.cfg = core.load_config()
        self.tables = []
        self.current = None          # 目前選中的 Table
        self.q = queue.Queue()       # 背景執行緒 -> UI

        self.root_var = StringVar(value=self.cfg["root"])
        self.mode_var = StringVar(value=self.cfg["write_mode"])
        self.status_var = StringVar(value="選擇資料夾後按「掃描」")
        self.type_var = StringVar()

        self._build()
        self.after(100, self._pump)

        if self.cfg["conn"].startswith("mssql"):
            missing = core.missing_driver()
            if missing:
                messagebox.showwarning("缺少 ODBC 驅動程式", missing)

    # --- 畫面 ----------------------------------------------------------

    def _build(self):
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)
        self.rowconfigure(2, weight=2)

        top = ttk.Frame(self, padding=8)
        top.grid(row=0, column=0, sticky="ew")
        top.columnconfigure(1, weight=1)
        ttk.Label(top, text="資料夾").grid(row=0, column=0, padx=(0, 6))
        ttk.Entry(top, textvariable=self.root_var).grid(row=0, column=1, sticky="ew")
        ttk.Button(top, text="瀏覽…", command=self.browse).grid(row=0, column=2, padx=4)
        ttk.Button(top, text="掃描", command=self.scan).grid(row=0, column=3)
        ttk.Button(top, text="連線設定…", command=self.edit_conn).grid(row=0, column=4, padx=(12, 0))

        # 上半：每張表一列
        mid = ttk.LabelFrame(self, text="要匯入的資料表", padding=6)
        mid.grid(row=1, column=0, sticky="nsew", padx=8)
        mid.columnconfigure(0, weight=1)
        mid.rowconfigure(0, weight=1)
        self.tv = ttk.Treeview(mid, columns=("name", "files", "rows", "status"),
                               show="headings", selectmode="browse")
        for col, width, text, anchor in [
            ("name", 200, "資料表", "w"), ("files", 70, "檔數", "e"),
            ("rows", 100, "列數", "e"), ("status", 420, "狀態", "w"),
        ]:
            self.tv.heading(col, text=text)
            self.tv.column(col, width=width, anchor=anchor)
        self.tv.tag_configure("err", foreground="#b00020")
        self.tv.tag_configure("warn", foreground="#a15c00")
        self.tv.grid(row=0, column=0, sticky="nsew")
        ttk.Scrollbar(mid, orient="vertical", command=self.tv.yview).grid(row=0, column=1, sticky="ns")
        self.tv.bind("<<TreeviewSelect>>", self.on_table)

        # 下半：選中那張表的欄位與型別
        low = ttk.LabelFrame(self, text="欄位預覽（選一列即可修改型別）", padding=6)
        low.grid(row=2, column=0, sticky="nsew", padx=8, pady=(6, 0))
        low.columnconfigure(0, weight=1)
        low.rowconfigure(0, weight=1)
        self.cv = ttk.Treeview(low, columns=("col", "type", "sample"),
                               show="headings", selectmode="browse")
        for col, width, text in [("col", 200, "欄位"), ("type", 180, "型別"), ("sample", 460, "範例值")]:
            self.cv.heading(col, text=text)
            self.cv.column(col, width=width, anchor="w")
        self.cv.grid(row=0, column=0, sticky="nsew")
        ttk.Scrollbar(low, orient="vertical", command=self.cv.yview).grid(row=0, column=1, sticky="ns")
        self.cv.bind("<<TreeviewSelect>>", self.on_column)
        self.cv.tag_configure("warn", foreground="#a15c00")

        edit = ttk.Frame(low)
        edit.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(6, 0))
        ttk.Label(edit, text="型別").pack(side="left")
        self.combo = ttk.Combobox(edit, textvariable=self.type_var,
                                  values=core.TYPE_CHOICES, width=22)
        self.combo.pack(side="left", padx=6)
        self.combo.bind("<<ComboboxSelected>>", self.apply_type)
        self.combo.bind("<Return>", self.apply_type)
        ttk.Label(edit, text="（也可直接輸入，例如 NVARCHAR(120)）",
                  foreground="#666").pack(side="left")

        bottom = ttk.Frame(self, padding=8)
        bottom.grid(row=3, column=0, sticky="ew")
        bottom.columnconfigure(3, weight=1)
        ttk.Label(bottom, text="寫入模式").grid(row=0, column=0)
        ttk.Radiobutton(bottom, text="replace（清空重建）", value="replace",
                        variable=self.mode_var).grid(row=0, column=1, padx=6)
        ttk.Radiobutton(bottom, text="append（接在後面）", value="append",
                        variable=self.mode_var).grid(row=0, column=2)
        self.bar = ttk.Progressbar(bottom, mode="determinate")
        self.bar.grid(row=0, column=3, sticky="ew", padx=12)
        ttk.Button(bottom, text="測試連線", command=self.test_conn).grid(row=0, column=4)
        self.import_btn = ttk.Button(bottom, text="開始匯入", command=self.do_import)
        self.import_btn.grid(row=0, column=5, padx=(6, 0))

        ttk.Label(self, textvariable=self.status_var, relief="sunken",
                  anchor="w", padding=4).grid(row=4, column=0, sticky="ew")

    # --- 動作 ----------------------------------------------------------

    def browse(self):
        chosen = filedialog.askdirectory(title="選擇要匯入的資料夾")
        if chosen:
            self.root_var.set(chosen)
            self.scan()

    def scan(self):
        root = Path(self.root_var.get())
        if not root.is_dir():
            messagebox.showerror("找不到資料夾", f"{root} 不存在")
            return
        self.status_var.set("掃描中…")
        self.bg(lambda: self.q.put(("tables", core.scan(root, self.cfg))))

    def show_tables(self, tables):
        self.tables = core.apply_overrides(tables, self.cfg)
        self.tv.delete(*self.tv.get_children())
        self.cv.delete(*self.cv.get_children())
        self.current = None
        for i, t in enumerate(tables):
            # 欄名不在 SAP 代碼欄位清單、又被推斷成整數的欄位要人看一眼，
            # 代碼被當數字是唯一會靜悄悄弄壞資料的情況。
            warn = core.suspects(t) if t.ok else []
            status = t.error or (f"可匯入（{len(warn)} 欄待確認）" if warn
                                 else "可匯入")
            self.tv.insert("", "end", iid=str(i),
                           values=(t.name, len(t.files), f"{t.rows:,}", status),
                           tags=("err",) if not t.ok else
                                ("warn",) if warn else ())
        bad = sum(1 for t in tables if not t.ok)
        warned = sum(1 for t in tables if t.ok and core.suspects(t))
        self.status_var.set(
            f"找到 {len(tables)} 張表"
            + (f"，其中 {bad} 張有問題，將略過" if bad else "")
            + (f"，{warned} 張有待確認的欄位" if warned else ""))

    def on_table(self, _=None):
        sel = self.tv.selection()
        if not sel:
            return
        self.current = self.tables[int(sel[0])]
        self.cv.delete(*self.cv.get_children())
        if not self.current.ok:
            self.cv.insert("", "end", values=("—", "—", self.current.error))
            return
        warn = set(core.suspects(self.current))
        for col in self.current.columns:
            sample = self.sample_of(col)
            if col in warn:
                sample = "← 整數但欄名不在 SAP 清單，是代碼的話請改 NVARCHAR｜" + sample
            self.cv.insert("", "end", iid=col,
                           values=(col, self.current.dtypes[col], sample),
                           tags=("warn",) if col in warn else ())

    def sample_of(self, col):
        values = self.current.sample[col].dropna().astype(str).head(3).tolist()
        return ", ".join(values) if values else "（整欄空白）"

    def on_column(self, _=None):
        sel = self.cv.selection()
        if sel and self.current and self.current.ok:
            self.type_var.set(self.current.dtypes[sel[0]])

    def apply_type(self, _=None):
        sel = self.cv.selection()
        if not (sel and self.current and self.current.ok):
            return
        col, spec = sel[0], self.type_var.get().strip()
        try:
            core.to_sa(spec)                   # 先驗證再存，免得匯入時才爆
        except ValueError as e:
            messagebox.showerror("型別無效", str(e))
            self.type_var.set(self.current.dtypes[col])
            return
        self.current.dtypes[col] = spec
        self.cv.item(col, values=(col, spec, self.sample_of(col)))
        self.cfg.setdefault("dtypes", {}).setdefault(self.current.name, {})[col] = spec
        self.save_cfg()
        self.status_var.set(f"{self.current.name}.{col} 型別改為 {spec}，已記住")

    def edit_conn(self):
        dialog = ConnDialog(self, self.cfg["conn"])
        self.wait_window(dialog)
        if dialog.result:
            self.cfg["conn"] = dialog.result
            self.save_cfg()
            self.status_var.set("連線字串已更新")

    def save_cfg(self):
        self.cfg["root"] = self.root_var.get()
        self.cfg["write_mode"] = self.mode_var.get()
        core.save_config(self.cfg)

    def test_conn(self):
        self.status_var.set("測試連線中…")

        def work():
            try:
                core.connect(self.cfg["conn"]).connect().close()
                self.q.put(("info", ("連線成功", "資料庫連線正常。")))
            except Exception as e:
                self.q.put(("error", ("連線失敗", str(e))))
        self.bg(work)

    def do_import(self):
        ready = [t for t in self.tables if t.ok]
        if not ready:
            messagebox.showwarning("沒有可匯入的資料表", "請先掃描資料夾。")
            return
        mode = self.mode_var.get()
        warning = ("\n\nreplace 會先刪除同名資料表再重建，"
                   "原有的索引與權限會一併消失。" if mode == "replace" else
                   "\n\nappend 會接在現有資料後面，重複執行會產生重複資料。")
        if not messagebox.askyesno(
                "確認匯入",
                f"即將以 {mode} 模式匯入 {len(ready)} 張資料表：\n"
                + "\n".join(f"  • {t.name}（{t.rows:,} 列）" for t in ready)
                + warning + "\n\n要繼續嗎？"):
            return
        self.save_cfg()
        self.import_btn.state(["disabled"])
        self.bar.configure(maximum=len(ready), value=0)
        self.bg(lambda: self.run_import(ready, mode))

    def run_import(self, tables, mode):
        """在背景執行緒跑。每張表獨立成敗，一張失敗不影響其他。"""
        engine, done, failed = None, [], []
        try:
            engine = core.connect(self.cfg["conn"])
        except Exception as e:
            self.q.put(("error", ("無法建立連線", str(e))))
            self.q.put(("finish", ([], [])))
            return
        for t in tables:
            self.q.put(("status", f"匯入 {t.name}…"))
            try:
                rows = core.import_table(engine, t, mode)
                done.append(f"{t.name}：{rows:,} 列")
                log(f"OK   {t.name} {rows} rows ({mode})")
            except Exception as e:
                failed.append(f"{t.name}：{str(e).splitlines()[0]}")
                log(f"FAIL {t.name} ({mode})\n{traceback.format_exc()}")
            self.q.put(("step", None))
        self.q.put(("finish", (done, failed)))

    # --- 執行緒橋接 -----------------------------------------------------

    def bg(self, fn):
        threading.Thread(target=fn, daemon=True).start()

    def _pump(self):
        """tkinter 不是執行緒安全的，背景結果一律經由佇列回到主執行緒。"""
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "tables":
                    self.show_tables(payload)
                elif kind == "status":
                    self.status_var.set(payload)
                elif kind == "step":
                    self.bar.step()
                elif kind == "info":
                    self.status_var.set(payload[1])
                    messagebox.showinfo(*payload)
                elif kind == "error":
                    self.status_var.set(payload[1].splitlines()[0])
                    messagebox.showerror(*payload)
                elif kind == "finish":
                    self.on_finish(*payload)
        except queue.Empty:
            pass
        self.after(100, self._pump)

    def on_finish(self, done, failed):
        self.import_btn.state(["!disabled"])
        self.bar.configure(value=0)
        self.status_var.set(f"完成 {len(done)} 張，失敗 {len(failed)} 張")
        report = ""
        if done:
            report += "成功：\n" + "\n".join(f"  • {x}" for x in done)
        if failed:
            report += ("\n\n" if report else "") + "失敗：\n" + \
                "\n".join(f"  • {x}" for x in failed)
            report += f"\n\n詳細錯誤已寫入 {LOG.resolve()}"
            messagebox.showwarning("匯入結束（有錯誤）", report)
        elif done:
            messagebox.showinfo("匯入完成", report)


class ConnDialog(Toplevel):
    def __init__(self, parent, conn):
        super().__init__(parent)
        self.title("連線設定")
        self.result = None
        self.transient(parent)
        self.grab_set()
        self.resizable(True, False)

        frame = ttk.Frame(self, padding=12)
        frame.pack(fill="both", expand=True)
        frame.columnconfigure(0, weight=1)
        ttk.Label(frame, text="SQLAlchemy 連線字串").grid(row=0, column=0, sticky="w")
        self.var = StringVar(value=conn)
        entry = ttk.Entry(frame, textvariable=self.var, width=90)
        entry.grid(row=1, column=0, sticky="ew", pady=6)
        entry.focus_set()
        ttk.Label(
            frame, foreground="#666", justify="left",
            text=("Windows 驗證：\n"
                  "  mssql+pyodbc://@主機/資料庫"
                  "?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes\n"
                  "帳號密碼：\n"
                  "  mssql+pyodbc://帳號:密碼@主機/資料庫"
                  "?driver=ODBC+Driver+17+for+SQL+Server"),
        ).grid(row=2, column=0, sticky="w")

        buttons = ttk.Frame(frame)
        buttons.grid(row=3, column=0, sticky="e", pady=(10, 0))
        ttk.Button(buttons, text="取消", command=self.destroy).pack(side="right")
        ttk.Button(buttons, text="確定", command=self.ok).pack(side="right", padx=6)
        self.bind("<Return>", lambda _: self.ok())
        self.bind("<Escape>", lambda _: self.destroy())

    def ok(self):
        self.result = self.var.get().strip()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
