"""持仓模块接口:/api/portfolio(holdings+quotes_cache+account_snapshots)。
M3-lite:库内底档;chan-monitor 在线时由 services/chan_bridge 代理覆盖(待接)。"""
from fastapi import APIRouter

from .common import get_conn

router = APIRouter(prefix="/api/portfolio", tags=["portfolio"])


@router.get("")
def portfolio():
    # 镜像新鲜(≤10min)直接用;否则尝试同步一次;8787 挂了用库内陈旧镜像(持久化意义)
    from services.chan_backtest_mirror import mirror_state, sync_chan_backtest
    m = mirror_state()
    if not m.get("fresh"):
        sync_chan_backtest()
        m = mirror_state()
    conn = get_conn()
    try:
        if (m.get("summary") or {}).get("assets"):   # 镜像有汇总就走台账口径(空仓 cash=assets)
            # 策略口径:当日收盘买入评分前三(seq 0-2)
            # 股数模型=chan holdings_snapshot 同款:买入前资金(本金+已实现盈亏)三份均分,
            # 按手取整(科创板 688 开头 200 股/手,其余 100)
            hrows = [
                {"code": h["code"], "name": h["name"], "buy_date": m.get("round_date"),
                 "buy_price": h["price"], "shares": h.get("shares") or 0, "status": "holding",
                 "last": None, "chg_pct": None}
                for h in (m["holdings"] or [])]
            for r in hrows:   # 行情从自选表补
                q = conn.execute(
                    "SELECT price, chg_pct FROM watchlist WHERE code=?",
                    (r["code"],)).fetchone()
                if q:
                    r["last"] = q["price"]
                    r["chg_pct"] = q["chg_pct"]
            summary = m.get("summary") or {}
            assets_total = summary.get("assets")
            src = "chan-db"
        else:
            hrows = conn.execute(
                "SELECT h.code, h.name, h.buy_date, h.buy_price, h.shares, h.status,"
                " w.price last, w.chg_pct FROM holdings h"
                " LEFT JOIN watchlist w ON w.code=h.code"
                " WHERE h.status='holding'").fetchall()
            assets_total = None
            src = "local"
        snap = conn.execute(
            "SELECT * FROM account_snapshots ORDER BY date DESC LIMIT 1").fetchone()
        # 实际口径校准(先读:股数覆盖要进循环)
        calib = {r["code"]: r["shares"] for r in conn.execute(
            "SELECT code, shares FROM portfolio_calib").fetchall()}
        holdings = []
        mv = 0.0
        for r in hrows:
            shares = calib.get(r["code"], r["shares"])   # 用户校准股数优先
            last = r["last"] or r["buy_price"]
            value = round(last * shares, 0)
            mv += value
            pnl = round((last / r["buy_price"] - 1) * 100, 2) if r["buy_price"] else 0
            holdings.append({"code": r["code"], "name": r["name"],
                             "buy_price": r["buy_price"], "last": last,
                             "shares": shares, "value": value,
                             "pnl_pct": pnl, "chg_pct": r["chg_pct"] or 0,
                             "status": r["status"]})
        # 现金可整体覆盖;镜像口径 total=缠论台账资产,cash=资产-市值;本地口径沿用快照
        cash_override = calib.get("__cash__")
        if cash_override is not None:
            cash = cash_override
            total = cash + mv
        elif assets_total:
            # summary.assets=已实现口径(买入前资金);现金=实现资产-持仓成本,总资产=现金+浮动市值
            cost = sum((h["buy_price"] or 0) * h["shares"] for h in holdings)
            cash = assets_total - cost
            total = cash + mv
        else:
            cash = snap["cash"] if snap else 0.0
            total = (snap["total"] if snap and snap["total"] else cash + mv)
        day_pnl = round(sum(h["value"] * h["chg_pct"] / 100 for h in holdings), 0)
        calibrated = any(h["code"] in calib for h in holdings) or cash_override is not None
        return {"total": round(total, 0), "cash": round(cash, 0), "market_value": round(mv, 0),
                "day_pnl": day_pnl,
                "day_pnl_pct": round(day_pnl / total * 100, 2) if total else 0,
                "as_of": m.get("round_date") or (snap["date"] if snap else None),
                "calibrated": calibrated, "source": src,
                "synced_at": m.get("synced_at"), "holdings": holdings}
    finally:
        conn.close()


@router.post("/sync-chan")
def sync_chan():
    from services.chan_backtest_mirror import sync_chan_backtest
    return sync_chan_backtest()


@router.get("/trades")
def portfolio_trades(limit: int = 200):
    """全部买卖明细:已结算轮逐笔(含卖出)+当前持仓轮买入(卖出为空)。倒序。"""
    from services.chan_backtest_mirror import mirror_state
    m = mirror_state()
    conn = get_conn()
    try:
        rows = [dict(r) for r in conn.execute(
            "SELECT round_date, code, name, shares, buy, sell, sell_date, net, pct"
            " FROM chan_trades ORDER BY round_date DESC, code LIMIT ?", (min(limit, 500),)).fetchall()]
    finally:
        conn.close()
    return rows


@router.get("/calib")
def get_calib():
    conn = get_conn()
    try:
        rows = conn.execute("SELECT code, shares FROM portfolio_calib").fetchall()
        return {"shares": {r["code"]: r["shares"] for r in rows if r["code"] != "__cash__"},
                "cash": next((r["shares"] for r in rows if r["code"] == "__cash__"), None)}
    finally:
        conn.close()


@router.put("/calib")
def put_calib(body: dict):
    """body: {"shares": {code: 股数}, "cash": 金额|null}——增量合并。"""
    from pydantic import BaseModel
    shares = body.get("shares") or {}
    cash = body.get("cash", None)
    conn = get_conn()
    try:
        for code, n in shares.items():
            if not isinstance(n, (int, float)) or n < 0:
                continue
            conn.execute(
                "INSERT INTO portfolio_calib(code, shares) VALUES(?,?)"
                " ON CONFLICT(code) DO UPDATE SET shares=excluded.shares,"
                " updated_at=datetime('now','localtime')", (code, float(n)))
        if cash is not None:
            conn.execute(
                "INSERT INTO portfolio_calib(code, shares) VALUES('__cash__',?)"
                " ON CONFLICT(code) DO UPDATE SET shares=excluded.shares,"
                " updated_at=datetime('now','localtime')", (float(cash),))
        conn.commit()
        return get_calib()
    finally:
        conn.close()


@router.delete("/calib")
def reset_calib():
    conn = get_conn()
    try:
        conn.execute("DELETE FROM portfolio_calib")
        conn.commit()
        return {"ok": True}
    finally:
        conn.close()


@router.get("/history")
def portfolio_history(days: int = 120):
    """资产曲线(真实口径):本金 + 逐轮已实现盈亏累计(按卖出日),末端=当前台账资产。"""
    from services.chan_backtest_mirror import mirror_state
    m = mirror_state()
    summary = m.get("summary") or {}
    principal = summary.get("principal") or 100000.0
    by_day, cum = {}, principal
    for row in m.get("ledger") or []:
        d = row.get("sell_date") or row.get("round_date")
        if not d:
            continue
        cum += row.get("realized_net") or 0
        by_day[d] = round(cum, 0)
    points = [{"date": d, "total": by_day[d]} for d in sorted(by_day)]
    if summary.get("assets"):
        points.append({"date": m.get("round_date") or "now",
                       "total": summary["assets"]})
    return points[-min(days, len(points)):] if points else []
