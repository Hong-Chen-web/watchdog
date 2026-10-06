"""缠论实盘台账镜像:拉 8787 /api/backtest 全量轮次+summary 落 SQLite。
持久化语义:成功一次后,8787 宕机也能从库出数(镜像新鲜度标注 synced_at)。"""
import json
import urllib.request
from datetime import datetime
from pathlib import Path

import db as dbm


def _conn():
    c = dbm.connect()
    c.row_factory = sqlite3.Row
    return c

import sqlite3

CHAN_API = "http://127.0.0.1:8787/api/backtest"
CHAN_FILE = Path("/Users/chenhong/github/personal-workbench/chan/data/backtest_tail_history.json")
CHAN_DATA = CHAN_FILE.parent


def _tencent_names(codes):
    """腾讯批量行情取名(sh.600519 → v[1] 名称)。失败返回空表。"""
    try:
        q = ",".join(c.replace(".", "") for c in codes)
        raw = urllib.request.urlopen(f"http://qt.gtimg.cn/q={q}", timeout=6).read().decode("gbk", "ignore")
        out = {}
        for line in raw.split(";"):
            if "~" not in line:
                continue
            parts = line.split("~")
            full = parts[0].split("=")[0].strip().lower()   # v_sh600519 → sh600519
            if len(full) >= 8:
                out[full[2:]] = parts[1]   # 裸代码 → 名称
        return out
    except Exception:
        return {}
PRINCIPAL = 100000.0


def _last_trade_date() -> str:
    """上证指数行情日期("YYYY-MM-DD");拉不到返回空(不过滤)。"""
    try:
        with urllib.request.urlopen("http://qt.gtimg.cn/q=sh000001", timeout=4) as f:
            raw = f.read().decode("gbk", "ignore")
        d = (raw.split("~")[30] or "")[:8]
        return f"{d[:4]}-{d[4:6]}-{d[6:8]}" if len(d) == 8 else ""
    except Exception:
        return ""


def sync_chan_backtest() -> dict:
    """全量刷新(幂等),真源=backtest_tail_history.json,整本账落三表:
    - 整轮结算(round.settled dict)→ 其 rows 逐笔入库(股数/买卖/净额用 chan 结算值)
    - 未结算轮 → stocks[] 逐笔:buy_price 非空=实际买入;_exit_why=部分出场
    - 股数模型(未结算轮):轮初资金/3 均分,quota//(buy×手)×手(688=200/手)
    - 资金按卖出日时序回笼(含部分出场);全部入 chan_trades/chan_round_ledger/chan_kv"""
    from datetime import datetime
    try:
        data = json.loads(CHAN_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        return {"ok": False, "error": str(e)}
    rounds = sorted(data.get("rounds") or [], key=lambda r: str(r.get("date") or ""))
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn = _conn()
    try:
        cur = conn.cursor()
        cur.execute("DELETE FROM chan_trades")
        cur.execute("DELETE FROM chan_round_ledger")
        capital = PRINCIPAL
        watch_upsert = []
        all_exits = []   # 全部出场记录(ledger 数据源)
        pending = []     # 尚未回笼的(按 sell_date 滚动)

        def record_exit(e):
            all_exits.append(e)
            pending.append(e)

        def absorb(upto: str):
            """把 sell_date<=upto 的出场净额回笼进 capital(时序滚动)。"""
            nonlocal capital, pending
            due = [e for e in pending if e[0] <= upto]
            if due:
                capital += sum(e[3] for e in due)
                pending = [e for e in pending if e[0] > upto]

        for r in rounds:
            rd = str(r.get("date") or "")
            absorb(rd)   # 本轮买入前:先回笼已到期的出场资金
            st = r.get("settled") if isinstance(r.get("settled"), dict) else None
            if st:
                # 整轮结算:rows 即逐笔真账
                for row in st.get("rows") or []:
                    if not isinstance(row, dict):
                        continue
                    code = str(row.get("code") or "")
                    code6 = code.split(".")[-1] if "." in code else code
                    net = row.get("net") or 0
                    sd = st.get("sell_date") or rd
                    cur.execute(
                        "INSERT OR REPLACE INTO chan_trades"
                        "(round_date,code,name,shares,buy,sell,sell_date,net,pct,synced_at)"
                        " VALUES(?,?,?,?,?,?,?,?,?,?)",
                        (rd, code6, row.get("name"), row.get("shares") or 0,
                         row.get("buy"), row.get("sell"), sd, net, row.get("pct"), now))
                    record_exit((sd, rd, code6, net))
                continue
            stocks = [x for x in (r.get("stocks") or [])
                      if isinstance(x, dict) and x.get("buy_price") is not None]
            if not stocks:
                continue
            quota = capital / 3
            for stock in stocks:
                code = str(stock.get("code") or "")
                code6 = code.split(".")[-1] if "." in code else code
                buy = float(stock.get("buy_price"))
                unit = 200 if code6.startswith("688") else 100
                shares = int(quota // (buy * unit)) * unit if buy > 0 else 0
                exit_why = stock.get("_exit_why")
                sell_px = stock.get("_exit_px")
                sell = net = pct = sell_date = None
                if exit_why and sell_px is not None:
                    sell = float(sell_px)
                    sell_date = exit_why[exit_why.find("(") + 1:-1] if "(" in exit_why else rd
                    net = round((sell - buy) * shares, 0)
                    pct = round((sell / buy - 1) * 100, 2) if buy else None
                    record_exit((sell_date, rd, code6, net))
                cur.execute(
                    "INSERT OR REPLACE INTO chan_trades"
                    "(round_date,code,name,shares,buy,sell,sell_date,net,pct,synced_at)"
                    " VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (rd, code6, stock.get("name"), shares, buy, sell,
                     sell_date, net, pct, now))
                if sell is None:
                    watch_upsert.append((code6, stock.get("name")))
        # 期末:剩余未回笼出场也计入已实现资金
        capital += sum(e[3] for e in pending)
        all_exits.sort(key=lambda x: (x[0], x[1]))
        for sd, rd, code6, net in all_exits:
            cur.execute(
                "INSERT OR REPLACE INTO chan_round_ledger"
                "(round_date,code,sell_date,realized_net,synced_at) VALUES(?,?,?,?,?)",
                (rd, code6, sd, net, now))
        # 最近真实轮候选快照(信号卡休市展示;归档轮 score/hits 已剥,带出场标记)
        last_td = _last_trade_date()
        snap_round = next((r for r in reversed(rounds)
                           if str(r.get("date") or "") <= (last_td or "9999")), None)
        if snap_round:
            stocks = []
            for x in snap_round.get("stocks") or []:
                if not isinstance(x, dict):
                    continue
                stocks.append({
                    "code": x.get("code"), "name": x.get("name"),
                    "price": x.get("price"), "score": x.get("score"),
                    "hits": x.get("hits"),
                    "exit_why": x.get("_exit_why") or x.get("exit_why"),
                })
            tail_snap = {"date": snap_round.get("date"), "stocks": stocks}
            cur.execute(
                "INSERT INTO chan_kv(k,v,synced_at) VALUES('tail',?,?)"
                " ON CONFLICT(k) DO UPDATE SET v=excluded.v, synced_at=excluded.synced_at",
                (json.dumps(tail_snap, ensure_ascii=False), now))
        summary = {"principal": PRINCIPAL,
                   "total_net": round(capital - PRINCIPAL, 2),
                   "assets": round(capital, 2),
                   "assets_pct": round((capital - PRINCIPAL) / PRINCIPAL * 100, 2)}
        cur.execute(
            "INSERT INTO chan_kv(k,v,synced_at) VALUES('summary',?,?)"
            " ON CONFLICT(k) DO UPDATE SET v=excluded.v, synced_at=excluded.synced_at",
            (json.dumps(summary, ensure_ascii=False), now))
        for code6, name in watch_upsert:
            cur.execute(
                "INSERT INTO watchlist(code,name) VALUES(?,?)"
                " ON CONFLICT(code) DO UPDATE SET name=COALESCE(excluded.name, watchlist.name)",
                (code6, name))
        # 缠论手动监控清单 → 自选(腾讯批量取名+现价)
        try:
            manual = json.loads(
                (CHAN_DATA / "watchlist_manual.json").read_text(encoding="utf-8"))
        except Exception:
            manual = []
        codes = [c for c in manual if isinstance(c, str) and c.strip()]
        if codes:
            names = _tencent_names(codes)
            keep = set()
            for c in codes:
                code6 = c.split(".")[-1] if "." in c else c
                keep.add(code6)
                cur.execute(
                    "INSERT INTO watchlist(code,name) VALUES(?,?)"
                    " ON CONFLICT(code) DO UPDATE SET name=COALESCE(NULLIF(excluded.name,''), watchlist.name)",
                    (code6, names.get(c) or names.get(code6) or ""))
            # 持仓也在监控范围(出场前要盯)
            for row in cur.execute(
                    "SELECT DISTINCT code FROM chan_trades WHERE sell IS NULL").fetchall():
                keep.add(row["code"])
            # 自选=缠论监控清单+当前持仓;其余(种子/历史出场)清除
            ph = ",".join("?" * len(keep)) or "''"
            cur.execute(f"DELETE FROM watchlist WHERE code NOT IN ({ph})", tuple(keep))
        conn.commit()
        n_hold = conn.execute(
            "SELECT COUNT(*) c FROM chan_trades WHERE sell IS NULL").fetchone()["c"]
        n_trades = conn.execute("SELECT COUNT(*) c FROM chan_trades").fetchone()["c"]
        return {"ok": True, "trades": n_trades, "holdings": n_hold, "synced_at": now}
    finally:
        conn.close()


def mirror_state() -> dict:
    """读镜像:{summary, holdings[], synced_at, fresh}。fresh=10 分钟内同步过。"""
    conn = _conn()
    try:
        kv = conn.execute("SELECT v, synced_at FROM chan_kv WHERE k='summary'").fetchone()
        if not kv:
            return {"fresh": False, "holdings": [], "summary": None, "synced_at": None}
        latest = conn.execute(
            "SELECT MAX(round_date) d FROM chan_trades WHERE sell IS NULL").fetchone()["d"]
        rows = conn.execute(
            "SELECT code, name, buy AS price, shares FROM chan_trades"
            " WHERE round_date=? AND sell IS NULL ORDER BY code", (latest,)).fetchall()
        synced = kv["synced_at"] or ""
        fresh = False
        try:
            fresh = (datetime.now() - datetime.strptime(synced, "%Y-%m-%d %H:%M:%S")
                     ).total_seconds() < 600
        except Exception:
            pass
        return {"fresh": fresh,
                "round_date": latest,
                "holdings": [dict(r) for r in rows],
                "summary": json.loads(kv["v"] or "{}"),
                "synced_at": synced,
                "ledger": [dict(r) for r in conn.execute(
                    "SELECT round_date, sell_date, realized_net FROM chan_round_ledger"
                    " ORDER BY COALESCE(sell_date, round_date)").fetchall()]}
    finally:
        conn.close()
