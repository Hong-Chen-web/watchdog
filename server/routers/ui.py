"""Web UI 主界面:WKWebView 装载的静态壳 + 一次性数据快照 + UI 专用小接口。

- GET  /ui                 → server/static/watchdog_ui.html(无数据,运行时拉 bootstrap)
- GET  /api/ui/bootstrap   → 首屏数据快照(与原生卡同源:进程内直调各 router)
- PUT  /api/ui/push-master → 飞书总开关(settings.push_master,off=只入箱不发送)
"""
import glob
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from routers import chan as _chan
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
REPO = SERVER_DIR.parent                                  # 仓库根
DATA_DIR = REPO / "data"
WB_DB = Path.home() / "Library" / "Application Support" / "Workbench" / "workbench.db"
STATIC_HTML = SERVER_DIR / "static" / "watchdog_ui.html"

router = APIRouter(tags=["ui"])


def _html_path() -> Path:
    if STATIC_HTML.exists():
        return STATIC_HTML
    meipass = getattr(sys, "_MEIPASS", None)   # frozen(PyInstaller)解包目录
    if meipass:
        p = Path(meipass) / "static" / "watchdog_ui.html"
        if p.exists():
            return p
    return STATIC_HTML


def _try(fn, *a, **k):
    try:
        return fn(*a, **k)
    except Exception as e:   # 单项数据失败不拖垮整屏;前端按空态渲染
        print("[watchdog] ui bootstrap:", getattr(fn, "__name__", fn), "->", e)
        return None


def _fstat(p):
    try:
        st = os.stat(p)
        return {"exists": True, "mtime": time.strftime("%m-%d %H:%M", time.localtime(st.st_mtime)),
                "size": st.st_size}
    except Exception:
        return {"exists": False, "mtime": "—", "size": 0}


def _push_snapshot():
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
        for c in pq("SELECT id, kind, name, codes FROM feishu ORDER BY rowid"):
            try:
                n = len(json.loads(c["codes"] or "[]"))
            except Exception:
                n = 0
            ld = last.get(c["id"]) or {}
            err = ld.get("error") or ""
            m = re.search(r"code=(\d+)", err)
            push["channels"].append({"id": c["id"], "name": c["name"], "codes": n,
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
        ids = [r["id"] for r in recent]
        dv = pq("SELECT outbox_id,target,ok,error FROM push_delivery WHERE outbox_id>=?",
                (min(ids) if ids else 0,))
        bydv = {}
        for d in dv:
            bydv.setdefault(d["outbox_id"], []).append(d)
        for r in recent:
            r["kcn"] = KIND_CN.get(r["kind"], r["kind"])
            r["body"] = (r["body"] or "")[:4000]
            r["deliveries"] = bydv.get(r["id"], [])
        push["recent"] = recent
    finally:
        pc.close()
    return push


def _files_snapshot():
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
    trash = None
    return {"klines": {"info": k_info, "mtime": st["mtime"]},
            "fflow": {"kb": round(ff["size"] / 1024), "mtime": ff["mtime"]},
            "industry": {"name": ind_name, "mtime": ind["mtime"]},
            "limitRoll": {"n": lr_n, "mtime": lr["mtime"]},
            "frozen": {"exists": fz["exists"], "mtime": fz["mtime"]},
            "trash": trash}



@router.post("/api/ai/ask")
def ai_ask(body: dict = None):
    """只读问答:LLM 把问题解析成查询 → 本地执行 → 返回答案+数据表。
    写入/指令类返回 {"mode":"write"},由前端转调 /api/ledger/smart-any(保留其防重)。"""
    text = str((body or {}).get("text") or "").strip()
    if not text:
        raise HTTPException(400, "问点什么")
    from services.llm_cfg import effective as _eff
    try:
        base, key, model, _e = _eff()
    except Exception:
        base = key = model = None
    if not (base and key):
        raise HTTPException(400, "未配置大模型(设置 · 大模型)")
    hold_ctx, wl_ctx = "无", "无"
    try:
        pf = _try(_portfolio.portfolio) or {}
        hold_ctx = ", ".join(f"{h.get('code')} {h.get('name')}" for h in pf.get("holdings") or []) or "无"
    except Exception:
        pass
    try:
        q = _try(_market.market_quotes) or {}
        wl_ctx = ", ".join(f"{w.get('code')} {w.get('name')}" for w in (q.get("watchlist") or [])) or "无"
    except Exception:
        pass
    from datetime import date as _ddate
    td = _ddate.today()
    sys_prompt = (
        f"今天是{td.year}年{td.month}月{td.day}日。你是个人工作台的只读查询引擎。"
        "把用户的问题解析成一个 JSON 对象,只输出 JSON,不要多余文字:"
        '{"mode":"query","type":"…","params":{…}}'
        ' 或 {"mode":"write"}(用户要改数据/下指令时)'
        ' 或 {"mode":"none","answer":"简短回答"}(无关闲聊)。可用 query type:'
        '- ledger_sum {month:"YYYY-MM" 或 start/end:"YYYY-MM-DD", category?:字符串或数组} 统计花费/收入/笔数;category 优先用账本大类(食物/交通/人情/医疗/其他/购物/娱乐/房屋/投资),不确定就给大类;'
        "- ledger_top {month?} 支出分类排行;"
        "- ledger_list {month?, category?, keyword?, limit?} 流水明细;"
        "- holdings {name?:名称或代码} 持仓盈亏(不填=全部);"
        '- rounds {month:"YYYY-MM"?} 交易回合统计(按卖出日,含胜率/净盈亏);'
        '- todos {status:"open|done|all"} 待办;'
        "- watchlist {} 自选行情; - futures {} 期货监控; - push_today {} 今日飞书推送; - goals {} 目标。"
        "相对时间按今天换算。当前持仓:" + hold_ctx + "。当前自选:" + wl_ctx + "。只输出 JSON。")
    import requests as _rq2
    r = _rq2.post(f"{str(base).rstrip('/')}/chat/completions",
                  headers={"Authorization": f"Bearer {key}"},
                  json={"model": model or "deepseek-chat",
                        "messages": [{"role": "system", "content": sys_prompt},
                                     {"role": "user", "content": text}],
                        "temperature": 0}, timeout=30)
    content = r.json()["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", content, re.S)
    if not m:
        return {"mode": "none", "answer": "没看懂这个问题,换个问法试试。"}
    spec = json.loads(m.group(0))
    mode = spec.get("mode")
    if mode == "write":
        return {"mode": "write"}
    if mode == "none":
        return {"mode": "none", "answer": str(spec.get("answer") or "…")}
    ans, cols, rows = _exec_query(str(spec.get("type") or ""), spec.get("params") or {})
    if ans is None:
        return {"mode": "none", "answer": "这类查询我还不支持,换个问法试试。"}
    return {"mode": "query", "type": spec.get("type"), "answer": ans, "cols": cols, "rows": rows}


def _exec_query(qtype, p):
    p = p or {}
    try:
        fn = {"ledger_sum": _q_ledger_sum, "ledger_top": _q_ledger_top, "ledger_list": _q_ledger_list,
              "holdings": _q_holdings, "rounds": _q_rounds, "todos": _q_todos,
              "watchlist": _q_watchlist, "futures": _q_futures, "push_today": _q_push_today,
              "goals": _q_goals}.get(qtype)
        if not fn:
            return None, [], []
        return fn(p)
    except Exception as e:
        print("[watchdog] ai ask query:", qtype, "->", e)
        return f"查询执行失败:{e}", [], []


def _month_range(p):
    import calendar as _cal
    month = p.get("month")
    if month:
        y, mth = int(month[:4]), int(month[5:7])
        last = _cal.monthrange(y, mth)[1]
        return f"{month}-01", f"{month}-{last:02d}", month
    start = p.get("start") or "2000-01-01"
    end = p.get("end") or str(time.strftime("%Y-%m-%d"))
    return str(start), str(end), str(p.get("month") or start[:7])


def _q_ledger_sum(p):
    start, end, mkey = _month_range(p)
    cats = p.get("category")
    cats = [x.strip() for x in str(cats).split(",")] if isinstance(cats, str) and cats else (cats or [])
    entries = _try(_ledger.ledger_entries, None, start, end, None, 1000) or []
    sel = [e for e in entries if (not cats or e.get("category") in cats
          or any(str(c) in (e.get("payee") or "") for c in cats))]
    out = sum(-e["amount"] for e in sel if e["amount"] < 0)
    inn = sum(e["amount"] for e in sel if e["amount"] > 0)
    label = "、".join(cats) if cats else "全部分类"
    ans = f"{mkey} {label}:支出 ¥{out:,.2f} · 收入 ¥{inn:,.2f} · {len(sel)} 笔"
    rows = [[e["date"], e.get("payee") or "—", e.get("category"), f"{e['amount']:,.2f}"] for e in sel[:15]]
    return ans, ["日期", "事由", "分类", "金额"], rows


def _q_ledger_top(p):
    start, end, mkey = _month_range(p)
    n = int(p.get("n") or 5)
    entries = _try(_ledger.ledger_entries, None, start, end, None, 2000) or []
    agg = {}
    for e in entries:
        if e["amount"] < 0:
            agg[e["category"]] = agg.get(e["category"], 0) + (-e["amount"])
    rows = sorted(agg.items(), key=lambda x: -x[1])[:n]
    total = sum(v for _, v in rows) or 1
    ans = f"{mkey} 支出 Top{len(rows)}:合计 ¥{total:,.2f}"
    return ans, ["分类", "支出", "占比"], [[c, f"¥{v:,.2f}", f"{v / total * 100:.0f}%"] for c, v in rows]


def _q_ledger_list(p):
    start, end, mkey = _month_range(p)
    lim = int(p.get("limit") or 10)
    cat = p.get("category")
    entries = _try(_ledger.ledger_entries, None, start, end, cat, 500) or []
    kw = str(p.get("keyword") or "")
    if kw:
        entries = [e for e in entries if kw in (e.get("payee") or "")]
    entries = entries[:lim]
    ans = f"{mkey} 流水 {len(entries)} 笔" + (f"(筛选:{kw or cat})" if (kw or cat) else "")
    return ans, ["日期", "事由", "分类", "金额"], \
        [[e["date"], e.get("payee") or "—", e.get("category"), f"{e['amount']:,.2f}"] for e in entries]


def _q_holdings(p):
    pf = _try(_portfolio.portfolio) or {}
    hs = pf.get("holdings") or []
    key = str(p.get("name") or "").strip()
    if key:
        hs = [h for h in hs if key in str(h.get("name", "")) or key in str(h.get("code", ""))]
    if not hs:
        return "当前没有匹配的持仓", [], []
    rows = [[h.get("name"), h.get("code"), f"{h.get('last'):,.2f}",
             f"{h.get('pnl_pct'):+.2f}%", f"{h.get('value'):,.0f}"] for h in hs]
    tot = sum(h.get("value") or 0 for h in hs)
    return f"持仓 {len(hs)} 只 · 市值合计 ¥{tot:,.0f}", ["名称", "代码", "现价", "浮盈%", "市值"], rows


def _q_rounds(p):
    month = p.get("month") or time.strftime("%Y-%m")
    trades = _try(_portfolio.portfolio_trades, 500) or []
    closed = [t for t in trades if t.get("sell_date") and str(t["sell_date"]).startswith(month)]
    wins = [t for t in closed if (t.get("net") or 0) > 0]
    net = sum(t.get("net") or 0 for t in closed)
    wr = (len(wins) / len(closed) * 100) if closed else 0.0
    ans = f"{month} 卖出 {len(closed)} 笔:盈利 {len(wins)} / 亏损 {len(closed) - len(wins)} · 胜率 {wr:.0f}% · 净盈亏 {net:+,.0f}"
    rows = [[t.get("sell_date"), t.get("name"), f"{(t.get('net') or 0):+,.0f}",
             f"{(t.get('pct') or 0):+.2f}%"] for t in closed]
    return ans, ["卖出日", "名称", "净盈亏", "收益率"], rows


def _q_todos(p):
    st = p.get("status") or "open"
    ts = _try(_todo.list_todos) or []
    if st == "open":
        ts = [t for t in ts if not t["done"]]
    elif st == "done":
        ts = [t for t in ts if t["done"]]
    od = sum(1 for t in ts if t.get("overdue"))
    ans = f"待办:{len(ts)} 条(逾期 {od})" if st == "open" else f"待办:{len(ts)} 条"
    rows = [[t["title"], t.get("due_date") or "—", "已完成" if t["done"] else
             ("逾期" if t.get("overdue") else "未完成")] for t in ts[:15]]
    return ans, ["标题", "截止", "状态"], rows


def _q_watchlist(p):
    q = _try(_market.market_quotes) or {}
    wl = q.get("watchlist") or []
    rows = [[w.get("name"), w.get("code"), f"{w.get('price'):,.2f}", f"{w.get('chg_pct'):+.2f}%"] for w in wl]
    return f"自选 {len(rows)} 只", ["名称", "代码", "现价", "涨跌%"], rows


def _q_futures(p):
    f = _try(_chan.chan_futures) or {}
    rows = [[x.get("name"), x.get("code"), f"{x.get('live_price'):,.2f}", f"{x.get('chg_pct'):+.2f}%",
             (x.get("chanpy") or {}).get("last_bi_dir", "—")] for x in f.get("stocks") or []]
    return f"期货监控 {len(rows)} 个品种(级别 {f.get('level')})", ["名称", "代码", "现价", "涨跌%", "笔方向"], rows


def _q_push_today(p):
    ps = _push_snapshot()
    today = time.strftime("%Y-%m-%d")
    tds = [m for m in ps.get("recent") or [] if str(m.get("created_at", "")).startswith(today)]
    rows = [[str(m.get("created_at", ""))[11:16], m.get("kcn"), m.get("title"), m.get("status")] for m in tds]
    ans = f"今日推送 {len(tds)} 条(今日入箱 {ps['stats'].get('today', 0)})"
    return ans, ["时间", "类型", "标题", "状态"], rows


def _q_goals(p):
    gs = _try(_goals.list_goals) or {}
    rows = []
    for grp in gs.get("groups") or []:
        for it in grp.get("items") or []:
            rows.append([grp.get("label"), it.get("title"), it.get("review_date") or "—"])
    return f"目标 {len(rows)} 条", ["周期", "标题", "复盘日"], rows


def _pool_snapshot():
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


@router.get("/api/ui/bootstrap")
def ui_bootstrap():
    portfolio = _try(_portfolio.portfolio) or {}
    trades = _try(_portfolio.portfolio_trades, 500) or []
    todos = _try(_todo.list_todos) or []
    months = _try(_ledger.ledger_months) or []
    summaries = {}
    for m in months:
        mm = _try(_ledger.ledger_summary, m["month"])
        summaries[m["month"]] = mm or {
            "month": m["month"], "income": m.get("income", 0), "expense": m.get("expense", 0),
            "net": m.get("income", 0) - m.get("expense", 0),
            "entries": m.get("entries", 0), "categories": []}
    entries = _try(_ledger.ledger_entries, None, "2015-01-01", "2035-01-01", None, 500) or []
    quotes = _try(_market.market_quotes) or {"watchlist": [], "indices": {}, "updated_at": None, "fails": 0}
    sysm = _try(_sysmon.sysmon) or {}
    jrn = _try(_journal.journal_list) or {}
    sldrun = _try(_disk.disk_clean_status) or {}
    live = _try(_backtest.backtest_live) or {}
    selst = _try(_chan.chan_selection_status) or {}
    tail = _try(_chan.chan_tail) or {"date": None, "stocks": []}
    stocklv = _try(_chan.chan_monitor_level) or {"level": "4h", "choices": ["5m", "15m", "30m", "60m", "4h", "day"]}
    futlv = _try(_chan.chan_futures_level) or {"level": "4h", "choices": ["5m", "15m", "30m", "60m", "4h", "day"]}
    signals = _try(_chan.chan_signals) or {}
    mods = _try(_modules.list_modules) or []
    try:
        fcfg = _try(_chan.feishu_config) or {}
        bots = fcfg.get("bots") or []
        feishu_bots = len(bots) if isinstance(bots, list) else 0
    except Exception:
        feishu_bots = 0
    try:
        push = _push_snapshot()
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
    files = _files_snapshot()
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
        "pool": _pool_snapshot(),
    }


@router.get("/ui")
def ui_page():
    p = _html_path()
    if not p.exists():
        raise HTTPException(500, "watchdog_ui.html 缺失(打包需含 static/)")
    return FileResponse(p, media_type="text/html; charset=utf-8", headers={"Cache-Control": "no-store"})


@router.put("/api/ui/push-master")
def ui_push_master(body: dict = None):
    on = bool((body or {}).get("on", True))
    import db as dbm
    conn = dbm.connect()
    try:
        cur = conn.execute("UPDATE settings SET value=? WHERE key='push_master'",
                           ("on" if on else "off",))
        if cur.rowcount == 0:
            conn.execute("INSERT INTO settings(key, value) VALUES('push_master', ?)",
                         ("on" if on else "off",))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "master": "on" if on else "off"}
