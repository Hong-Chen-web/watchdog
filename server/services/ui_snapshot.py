"""Web 工作台首屏快照(与原生卡同源:进程内直调各 router,单项失败不拖垮整屏)。

被 routers/ui.py 的 GET /api/ui/bootstrap 调用;push_today 查询也复用 push_snapshot。
"""
import glob
import json
import os
import re
import sqlite3
import time
from datetime import date
from pathlib import Path

from routers import chan as _chan
from routers import feishu as _feishu
from routers import backtest as _backtest
from routers import disk as _disk
from routers import journal as _journal
from routers import ledger as _ledger
from routers import market as _market
from routers import modules as _modules
from routers import portfolio as _portfolio
from routers import sysmon as _sysmon
from routers import goals as _goals
from routers import todo as _todo

SERVER_DIR = Path(__file__).resolve().parent.parent      # server/
REPO = SERVER_DIR.parent                                 # 仓库根
DATA_DIR = REPO / "data"
WB_DB = Path.home() / "Library" / "Application Support" / "Workbench" / "workbench.db"


def try_call(fn, *a, **k):
    """单项数据失败不拖垮整屏;前端按空态渲染。"""
    try:
        return fn(*a, **k)
    except Exception as e:
        print("[watchdog] ui bootstrap:", getattr(fn, "__name__", fn), "->", e)
        return None


def push_snapshot():
    """飞书推送(主库只读):通道 / 发件箱统计 / 最近记录 + 逐目标投递。"""
    KIND_CN = {"signal": "信号卡", "settle": "卖出卡", "selection": "选股卡",
               "holding_daily": "持仓卡", "plan": "计划卡", "test": "测试"}
    push = {"master": "on", "channels": [], "stats": {}, "recent": []}
    pc = sqlite3.connect(str(WB_DB), timeout=3)
    pc.row_factory = sqlite3.Row
    try:
        def pq(sql, args=()):
            return [dict(r) for r in pc.execute(sql, args).fetchall()]
        row = pq("SELECT value FROM settings WHERE key='push_master'")
        push["master"] = row[0]["value"] if row else "on"
        last = {}
        for d in pq("SELECT target, ok, error, outbox_id FROM push_delivery ORDER BY outbox_id DESC LIMIT 400"):
            last.setdefault(d["target"], d)
        for c in pq("SELECT id, kind, name, codes, account_cards FROM feishu ORDER BY rowid"):
            try:
                n = len(json.loads(c["codes"] or "[]"))
            except Exception:
                n = 0
            ld = last.get(c["id"]) or {}
            err = ld.get("error") or ""
            m = re.search(r"code=(\d+)", err)
            push["channels"].append({"id": c["id"], "name": c["name"], "codes": n,
                                     "account_cards": int(c["account_cards"] or 0),
                                     "ok": ld.get("ok") == 1, "err_code": (m.group(1) if m else None),
                                     "last_id": ld.get("outbox_id")})
        st = {r["status"]: r["n"] for r in pq("SELECT status, count(*) n FROM push_outbox GROUP BY status")}
        push["stats"] = {
            "sent": st.get("sent", 0), "pending": st.get("pending", 0),
            "skipped": st.get("skipped", 0), "failed": st.get("failed", 0),
            "signal": pq("SELECT count(*) n FROM push_outbox WHERE kind='signal'")[0]["n"],
            "today": pq("SELECT count(*) n FROM push_outbox WHERE created_at LIKE ?",
                        (time.strftime("%Y-%m-%d") + "%",))[0]["n"],
        }
        recent = pq("SELECT id,kind,title,status,retries,created_at,sent_at,dedup_key,body"
                    " FROM push_outbox ORDER BY id DESC LIMIT 16")
        # 今日全部记录(时间轴事件流用;面板仍只显示 recent 16 条)
        today_rows = pq("SELECT id,kind,title,status,retries,created_at,sent_at,dedup_key,body"
                        " FROM push_outbox WHERE created_at LIKE ? ORDER BY id DESC LIMIT 200",
                        (time.strftime("%Y-%m-%d") + "%",))
        ids = [r["id"] for r in recent + today_rows]
        dv = pq("SELECT outbox_id,target,ok,error FROM push_delivery WHERE outbox_id>=?",
                (min(ids) if ids else 0,))
        bydv = {}
        for d in dv:
            bydv.setdefault(d["outbox_id"], []).append(d)
        for r in recent + today_rows:
            r["kcn"] = KIND_CN.get(r["kind"], r["kind"])
            r["body"] = (r["body"] or "")[:4000]
            r["deliveries"] = bydv.get(r["id"], [])
        push["recent"] = recent
        push["today"] = today_rows
    finally:
        pc.close()
    return push


def _fstat(p):
    try:
        st = os.stat(p)
        return {"exists": True, "mtime": time.strftime("%m-%d %H:%M", time.localtime(st.st_mtime)),
                "size": st.st_size}
    except Exception:
        return {"exists": False, "mtime": "—", "size": 0}


def files_snapshot():
    """磁盘与产物实测状态(K线底库/fflow 缓存/行业图/滚动集/frozen 包)。"""
    st = _fstat(DATA_DIR / "klines.db")
    k_info = (f"{st['size']/1048576:.1f}MB" if st["exists"] else "缺失") + \
             (" · 更新 " + st["mtime"] if st["exists"] else "")
    try:
        conn = sqlite3.connect(f"file:{DATA_DIR/'klines.db'}?mode=ro&immutable=1", uri=True, timeout=2)
        tbs = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
        tbl = next((t for t in tbs if "bar" in t.lower() or "kline" in t.lower()), None)
        if tbl:
            n = conn.execute(f"SELECT COUNT(*) FROM [{tbl}]").fetchone()[0]
            k_info = f"{st['size']/1048576:.1f}MB · {n/10000:.1f}万行 · 更新 {st['mtime']}"
        conn.close()
    except Exception:
        pass
    ff = _fstat(DATA_DIR / "fflow_cache.json")
    cand = sorted(glob.glob(str(DATA_DIR / "*industry*")) + glob.glob(str(DATA_DIR / "*sina*")))
    ind = _fstat(cand[-1]) if cand else {"mtime": "—"}
    ind_name = os.path.basename(cand[-1]) if cand else "industry.json"
    lr = _fstat(DATA_DIR / "limit_roll.json")
    lr_n = 0
    try:
        r = json.load(open(DATA_DIR / "limit_roll.json", encoding="utf-8"))
        if isinstance(r, list):
            lr_n = len(r)
        elif isinstance(r, dict):
            codes = r.get("codes")
            if isinstance(codes, dict):
                lr_n = len(codes)
            elif isinstance(codes, list):
                lr_n = len(codes)
            else:
                vals = [v for v in r.values() if isinstance(v, (list, dict))]
                lr_n = sum(len(v) for v in vals) if vals else len(r)
    except Exception:
        pass
    fz = _fstat(SERVER_DIR / "dist" / "watchdog-server")
    return {"klines": {"info": k_info, "mtime": st["mtime"]},
            "fflow": {"kb": round(ff["size"] / 1024), "mtime": ff["mtime"]},
            "industry": {"name": ind_name, "mtime": ind["mtime"]},
            "limitRoll": {"n": lr_n, "mtime": lr["mtime"]},
            "frozen": {"exists": fz["exists"], "mtime": fz["mtime"]},
            "trash": None}


def pool_snapshot():
    """候选池(近10交易日涨停滚动集)+ 冷却簿(同票卖出后5交易日)。"""
    try:
        lr = json.loads((DATA_DIR / "limit_roll.json").read_text(encoding="utf-8"))
    except Exception:
        lr = {}
    try:
        cd = json.loads((DATA_DIR / "trade_cooldown.json").read_text(encoding="utf-8"))
    except Exception:
        cd = {}
    return {"through": lr.get("through"), "codes": lr.get("codes") or {}, "cooldown": cd}


def build_bootstrap() -> dict:
    """一次性首屏快照:前端 GET /api/ui/bootstrap 后全量渲染,不再逐卡请求。"""
    portfolio = try_call(_portfolio.portfolio) or {}
    trades = try_call(_portfolio.portfolio_trades, 500) or []
    todos = try_call(_todo.list_todos) or []
    months = try_call(_ledger.ledger_months) or []
    summaries = {}
    for m in months:
        mm = try_call(_ledger.ledger_summary, m["month"])
        summaries[m["month"]] = mm or {
            "month": m["month"], "income": m.get("income", 0), "expense": m.get("expense", 0),
            "net": m.get("income", 0) - m.get("expense", 0),
            "entries": m.get("entries", 0), "categories": []}
    entries = try_call(_ledger.ledger_entries, None, "2015-01-01", "2035-01-01", None, 500) or []
    quotes = try_call(_market.market_quotes) or {"watchlist": [], "indices": {}, "updated_at": None, "fails": 0}
    sysm = try_call(_sysmon.sysmon) or {}
    jrn = try_call(_journal.journal_list) or {}
    sldrun = try_call(_disk.disk_clean_status) or {}
    live = try_call(_backtest.backtest_live) or {}
    selst = try_call(_chan.chan_selection_status) or {}
    tail = try_call(_chan.chan_tail) or {"date": None, "stocks": []}
    stocklv = try_call(_chan.chan_monitor_level) or {"level": "4h", "choices": ["5m", "15m", "30m", "60m", "4h", "day"]}
    futlv = try_call(_chan.chan_futures_level) or {"level": "4h", "choices": ["5m", "15m", "30m", "60m", "4h", "day"]}
    signals = try_call(_chan.chan_signals) or {}
    mods = try_call(_modules.list_modules) or []
    try:
        fcfg = try_call(_feishu.feishu_config) or {}
        bots = fcfg.get("bots") or []
        feishu_bots = len(bots) if isinstance(bots, list) else 0
    except Exception:
        feishu_bots = 0
    try:
        push = push_snapshot()
    except Exception as e:
        print("[watchdog] ui bootstrap: push ->", e)
        push = {"master": "on", "channels": [], "stats": {}, "recent": []}
    feishu = {"bots": feishu_bots, "master": (push.get("master") == "on")}

    sysmon = {
        "collected_at": sysm.get("collected_at"), "host": sysm.get("host"), "uptime": sysm.get("uptime"),
        "procs": sysm.get("procs"), "hardware": sysm.get("hardware") or {},
        "health_score": sysm.get("health_score"), "health_score_msg": sysm.get("health_score_msg"),
        "cpu": {k: (sysm.get("cpu") or {}).get(k) for k in ("usage", "per_core", "load1")},
        "memory": {k: (sysm.get("memory") or {}).get(k)
                   for k in ("used", "total", "used_percent", "swap_used", "swap_total")},
    }
    trash = sysm.get("trash_approx") or (f"{sysm.get('trash_size', 0)/1073741824:.1f}GB" if sysm.get("trash_size") else "—")
    files = files_snapshot()
    files["trash"] = trash
    import db as dbm
    conn = dbm.connect()
    try:
        ver = conn.execute("PRAGMA user_version").fetchone()[0]
    except Exception:
        ver = "?"
    finally:
        conn.close()

    return {
        "portfolio": portfolio, "trades": trades, "todos": todos,
        "today": date.today().isoformat(),
        "months": months, "summaries": summaries, "entries": entries,
        "live": live, "selst": selst, "tail": tail,
        "stocklv": stocklv, "futlv": futlv, "signals": signals,
        "watch": quotes.get("watchlist") or [],
        "quotes": {"indices": quotes.get("indices") or {}, "updated_at": quotes.get("updated_at"),
                   "fails": quotes.get("fails", 0)},
        "journal": jrn, "sysmon": sysmon, "files": files,
        "health": {"status": "ok", "schema_version": ver},
        "clean": {k: (sldrun or {}).get(k) for k in ("running", "current", "finished_at")},
        "feishu": feishu, "push": push, "modules": mods,
        "pool": pool_snapshot(),
    }


def build_live() -> dict:
    """盘中轻量切片(前端秒级轮询):组合口径 / 买卖明细 / 自选行情 / 推送面板。

    与 build_bootstrap 同形同源,只取分钟级会变的部分;账本/待办/系统/文件等
    低频数据留给首屏快照与 60s 兜底全量刷新。"""
    portfolio = try_call(_portfolio.portfolio) or {}
    trades = try_call(_portfolio.portfolio_trades, 500) or []
    quotes = try_call(_market.market_quotes) or {"watchlist": [], "indices": {}, "updated_at": None, "fails": 0}
    try:
        push = push_snapshot()
    except Exception as e:
        print("[watchdog] ui live: push ->", e)
        push = None
    return {"portfolio": portfolio, "trades": trades,
            "today": date.today().isoformat(),
            "watch": quotes.get("watchlist") or [],
            "quotes": {"indices": quotes.get("indices") or {}, "updated_at": quotes.get("updated_at"),
                       "fails": quotes.get("fails", 0)},
            "push": push}
