"""AI 只读问答引擎(GET /api/ai/ask 的业务层)。

LLM 把问题解析成查询 JSON → 本地进程内执行 → 返回 答案+表头+行。
写入/指令类返回 {"mode":"write"},由前端转调 /api/ledger/smart-any(保留其防重)。
"""
import json
import re
import time

from routers import chan as _chan
from routers import ledger as _ledger
from routers import market as _market
from routers import portfolio as _portfolio
from routers import goals as _goals
from routers import todo as _todo
from services.ui_snapshot import try_call


def ask(text: str) -> dict:
    """入口:问题文本 → 查询结果(不写库)。失败以 ValueError(文案) 抛给路由层。"""
    if not text:
        raise ValueError("问点什么")
    from services.llm_cfg import effective as _eff
    try:
        base, key, model, _e = _eff()
    except Exception:
        base = key = model = None
    if not (base and key):
        raise ValueError("未配置大模型(设置 · 大模型)")

    hold_ctx, wl_ctx = "无", "无"
    try:
        pf = try_call(_portfolio.portfolio) or {}
        hold_ctx = ", ".join(f"{h.get('code')} {h.get('name')}" for h in pf.get("holdings") or []) or "无"
    except Exception:
        pass
    try:
        q = try_call(_market.market_quotes) or {}
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

    from services import net as _net
    r = _net.session().post(f"{str(base).rstrip('/')}/chat/completions",
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
    ans, cols, rows = exec_query(str(spec.get("type") or ""), spec.get("params") or {})
    if ans is None:
        return {"mode": "none", "answer": "这类查询我还不支持,换个问法试试。"}
    return {"mode": "query", "type": spec.get("type"), "answer": ans, "cols": cols, "rows": rows}


# ---------- 本地查询执行 ----------

def exec_query(qtype, p):
    p = p or {}
    try:
        fn = {"ledger_sum": q_ledger_sum, "ledger_top": q_ledger_top, "ledger_list": q_ledger_list,
              "holdings": q_holdings, "rounds": q_rounds, "todos": q_todos,
              "watchlist": q_watchlist, "futures": q_futures, "push_today": q_push_today,
              "goals": q_goals}.get(qtype)
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


def q_ledger_sum(p):
    start, end, mkey = _month_range(p)
    cats = p.get("category")
    cats = [x.strip() for x in str(cats).split(",")] if isinstance(cats, str) and cats else (cats or [])
    entries = try_call(_ledger.ledger_entries, None, start, end, None, 1000) or []
    sel = [e for e in entries if (not cats or e.get("category") in cats
          or any(str(c) in (e.get("payee") or "") for c in cats))]
    out = sum(-e["amount"] for e in sel if e["amount"] < 0)
    inn = sum(e["amount"] for e in sel if e["amount"] > 0)
    label = "、".join(cats) if cats else "全部分类"
    ans = f"{mkey} {label}:支出 ¥{out:,.2f} · 收入 ¥{inn:,.2f} · {len(sel)} 笔"
    rows = [[e["date"], e.get("payee") or "—", e.get("category"), f"{e['amount']:,.2f}"] for e in sel[:15]]
    return ans, ["日期", "事由", "分类", "金额"], rows


def q_ledger_top(p):
    start, end, mkey = _month_range(p)
    n = int(p.get("n") or 5)
    entries = try_call(_ledger.ledger_entries, None, start, end, None, 2000) or []
    agg = {}
    for e in entries:
        if e["amount"] < 0:
            agg[e["category"]] = agg.get(e["category"], 0) + (-e["amount"])
    rows = sorted(agg.items(), key=lambda x: -x[1])[:n]
    total = sum(v for _, v in rows) or 1
    ans = f"{mkey} 支出 Top{len(rows)}:合计 ¥{total:,.2f}"
    return ans, ["分类", "支出", "占比"], [[c, f"¥{v:,.2f}", f"{v / total * 100:.0f}%"] for c, v in rows]


def q_ledger_list(p):
    start, end, mkey = _month_range(p)
    lim = int(p.get("limit") or 10)
    cat = p.get("category")
    entries = try_call(_ledger.ledger_entries, None, start, end, cat, 500) or []
    kw = str(p.get("keyword") or "")
    if kw:
        entries = [e for e in entries if kw in (e.get("payee") or "")]
    entries = entries[:lim]
    ans = f"{mkey} 流水 {len(entries)} 笔" + (f"(筛选:{kw or cat})" if (kw or cat) else "")
    return ans, ["日期", "事由", "分类", "金额"], \
        [[e["date"], e.get("payee") or "—", e.get("category"), f"{e['amount']:,.2f}"] for e in entries]


def q_holdings(p):
    pf = try_call(_portfolio.portfolio) or {}
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


def q_rounds(p):
    month = p.get("month") or time.strftime("%Y-%m")
    trades = try_call(_portfolio.portfolio_trades, 500) or []
    closed = [t for t in trades if t.get("sell_date") and str(t["sell_date"]).startswith(month)]
    wins = [t for t in closed if (t.get("net") or 0) > 0]
    net = sum(t.get("net") or 0 for t in closed)
    wr = (len(wins) / len(closed) * 100) if closed else 0.0
    ans = f"{month} 卖出 {len(closed)} 笔:盈利 {len(wins)} / 亏损 {len(closed) - len(wins)} · 胜率 {wr:.0f}% · 净盈亏 {net:+,.0f}"
    rows = [[t.get("sell_date"), t.get("name"), f"{(t.get('net') or 0):+,.0f}",
             f"{(t.get('pct') or 0):+.2f}%"] for t in closed]
    return ans, ["卖出日", "名称", "净盈亏", "收益率"], rows


def q_todos(p):
    st = p.get("status") or "open"
    ts = try_call(_todo.list_todos) or []
    if st == "open":
        ts = [t for t in ts if not t["done"]]
    elif st == "done":
        ts = [t for t in ts if t["done"]]
    od = sum(1 for t in ts if t.get("overdue"))
    ans = f"待办:{len(ts)} 条(逾期 {od})" if st == "open" else f"待办:{len(ts)} 条"
    rows = [[t["title"], t.get("due_date") or "—", "已完成" if t["done"] else
             ("逾期" if t.get("overdue") else "未完成")] for t in ts[:15]]
    return ans, ["标题", "截止", "状态"], rows


def q_watchlist(p):
    q = try_call(_market.market_quotes) or {}
    wl = q.get("watchlist") or []
    rows = [[w.get("name"), w.get("code"), f"{w.get('price'):,.2f}", f"{w.get('chg_pct'):+.2f}%"] for w in wl]
    return f"自选 {len(rows)} 只", ["名称", "代码", "现价", "涨跌%"], rows


def q_futures(p):
    f = try_call(_chan.chan_futures) or {}
    rows = [[x.get("name"), x.get("code"), f"{x.get('live_price'):,.2f}", f"{x.get('chg_pct'):+.2f}%",
             (x.get("chanpy") or {}).get("last_bi_dir", "—")] for x in f.get("stocks") or []]
    return f"期货监控 {len(rows)} 个品种(级别 {f.get('level')})", ["名称", "代码", "现价", "涨跌%", "笔方向"], rows


def q_push_today(p):
    from services.ui_snapshot import push_snapshot
    ps = push_snapshot()
    today = time.strftime("%Y-%m-%d")
    tds = [m for m in ps.get("recent") or [] if str(m.get("created_at", "")).startswith(today)]
    rows = [[str(m.get("created_at", ""))[11:16], m.get("kcn"), m.get("title"), m.get("status")] for m in tds]
    ans = f"今日推送 {len(tds)} 条(今日入箱 {ps['stats'].get('today', 0)})"
    return ans, ["时间", "类型", "标题", "状态"], rows


def q_goals(p):
    gs = try_call(_goals.list_goals) or {}
    rows = []
    for grp in gs.get("groups") or []:
        for it in grp.get("items") or []:
            rows.append([grp.get("label"), it.get("title"), it.get("review_date") or "—"])
    return f"目标 {len(rows)} 条", ["周期", "标题", "复盘日"], rows
