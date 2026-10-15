"""缠论持仓桥:读 chan-monitor data/backtest_tail_history.json 轮次历史,
同步持仓到 holdings 表(表结构 v8 后无外键)。规则:
- 取所有含 buy_price 的轮次;股票无 _exit_why → holding,有 → settled(带出场信息)
- 本地不再持有(轮次消失/已出场)的行标记 settled
- 资金口径:chan 未暴露现金,沿用 account_snapshots 最新 cash,仅市值实时"""
import json
from pathlib import Path
from datetime import datetime

import db as dbm

CHAN_DATA = Path("/Users/chenhong/github/personal-workbench/chan/data")


def _load_rounds():
    try:
        d = json.loads((CHAN_DATA / "backtest_tail_history.json").read_text(encoding="utf-8"))
        return d.get("rounds") or []
    except Exception:
        return []


def sync_holdings(conn) -> dict:
    rounds = _load_rounds()
    cur = conn.cursor()
    want = {}   # (round_id, code) → row
    for r in rounds:
        rid = str(r.get("date") or "")
        for s in (r.get("stocks") or []):
            if "buy_price" not in s:
                continue
            code = str(s.get("code") or "")       # sh.600812
            code6 = code.split(".")[-1] if "." in code else code
            exited = bool(s.get("_exit_why"))
            want[(rid, code6)] = {
                "name": s.get("name"), "buy_date": rid,
                "buy_price": s.get("buy_price"), "shares": s.get("shares") or 100,  # chan 不记股数,缺省 100 股口径
                "status": "settled" if exited else "holding",
                "exit_date": (s.get("_exit_why") or "")[5:-1] if exited else None,  # 括号内日期
                "exit_price": s.get("_exit_px"),
                "exit_why": s.get("_exit_why") if exited else None,
            }
    # 覆盖式同步:先清 holding 再落
    cur.execute("DELETE FROM holdings WHERE status='holding'")
    n_hold = 0
    for (rid, code6), row in want.items():
        exists = cur.execute(
            "SELECT status FROM holdings WHERE code=? AND round_id=?",
            (code6, rid)).fetchone()
        if row["status"] == "holding":
            cur.execute(
                "INSERT INTO holdings(code,round_id,name,buy_date,buy_price,shares,status)"
                " VALUES(?,?,?,?,?,?,'holding')"
                " ON CONFLICT(code,round_id) DO UPDATE SET name=excluded.name,"
                " buy_price=excluded.buy_price, shares=excluded.shares, status='holding'",
                (code6, rid, row["name"], row["buy_date"], row["buy_price"], row["shares"]))
            n_hold += 1
        elif not exists:
            cur.execute(
                "INSERT INTO holdings(code,round_id,name,buy_date,buy_price,shares,status,"
                "exit_date,exit_price,exit_why) VALUES(?,?,?,?,?,?,'settled',?,?,?)",
                (code6, rid, row["name"], row["buy_date"], row["buy_price"], row["shares"],
                 row["exit_date"], row["exit_price"], row["exit_why"]))
    # 历史里已全部出场的轮 → 其残留 holding 行改 settled
    live_keys = {(rid, c) for (rid, c), row in want.items() if row["status"] == "holding"}
    for r in cur.execute("SELECT code, round_id FROM holdings WHERE status='holding'").fetchall():
        if (r["round_id"], r["code"]) not in live_keys:
            cur.execute("UPDATE holdings SET status='settled', updated_at=datetime('now','localtime')"
                        " WHERE code=? AND round_id=?", (r["code"], r["round_id"]))
    # 持仓股自动入自选(快线才有它的价格)
    for (rid, code6), row in want.items():
        if row["status"] == "holding":
            cur.execute("INSERT OR IGNORE INTO watchlist(code,name,source) VALUES(?,?,'system')",
                        (code6, row["name"] or code6))
    cur.execute("INSERT INTO sync_log(source,status,message) VALUES(?,?,?)",
                ("chan", "ok", f"holdings={n_hold} rounds_seen={len(rounds)}"))
    cur.execute("DELETE FROM sync_log WHERE id NOT IN (SELECT id FROM sync_log ORDER BY id DESC LIMIT 200)")
    conn.commit()
    return {"holding": n_hold, "rounds": len(rounds)}


def snapshot_account(conn) -> dict:
    """每日快照:现金=镜像台账资产-持仓成本(自愈口径);镜像缺失才沿用上一快照。"""
    cash = None
    try:
        from services.chan_backtest_mirror import mirror_state
        m = mirror_state()
        assets = (m.get("summary") or {}).get("assets")
        if assets:
            cost = sum((h.get("price") or 0) * (h.get("shares") or 0)
                       for h in (m.get("holdings") or []))
            cash = assets - cost
    except Exception:
        pass
    if cash is None:
        snap = conn.execute("SELECT cash FROM account_snapshots ORDER BY date DESC LIMIT 1").fetchone()
        cash = snap["cash"] if snap else 0.0
    mv = conn.execute(
        "SELECT COALESCE(SUM(h.shares * COALESCE(w.price, h.buy_price)),0) mv FROM holdings h"
        " LEFT JOIN watchlist w ON w.code=h.code WHERE h.status='holding'").fetchone()["mv"]
    total = round(cash + mv, 2)
    today = datetime.now().strftime("%Y-%m-%d")
    conn.execute(
        "INSERT INTO account_snapshots(date,cash,market_value,total) VALUES(?,?,?,?)"
        " ON CONFLICT(date) DO UPDATE SET cash=excluded.cash,"
        " market_value=excluded.market_value, total=excluded.total",
        (today, cash, round(mv, 2), total))
    conn.commit()
    return {"date": today, "cash": cash, "market_value": round(mv, 2), "total": total}
