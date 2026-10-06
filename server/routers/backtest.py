"""回测模块接口:/api/backtest(档案读取 + 报告 HTML 导入)。"""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from .common import get_conn

router = APIRouter(prefix="/api/backtest", tags=["backtest"])


def _portfolio_total():
    """当前总资产(与持仓卡同源:现金+浮动市值)。"""
    from .portfolio import portfolio as _pf
    try:
        return _pf().get("total") or 0.0
    except Exception:
        return None


@router.get("/live")
def backtest_live():
    """实盘台账统计(缠论 tail 轮次镜像):本金/已实现/轮次/胜轮/最好最差 + 逐轮曲线。"""
    from services.chan_backtest_mirror import mirror_state
    m = mirror_state()
    summary = m.get("summary") or {}
    ledger = m.get("ledger") or []
    nets = [row.get("realized_net") or 0 for row in ledger]
    principal = summary.get("principal") or 100000.0
    realized = sum(nets)
    curve, cum = [], principal
    for row in ledger:
        d = row.get("sell_date") or row.get("round_date")
        if not d:
            continue
        cum += row.get("realized_net") or 0
        curve.append({"date": d, "equity": round(cum, 0)})
    if summary.get("assets"):
        curve.append({"date": m.get("round_date") or "now",
                      "equity": summary["assets"]})
    return {
        "start_date": ledger[0].get("sell_date") or ledger[0].get("round_date") if ledger else None,
        "principal": principal,
        "realized_net": round(realized, 0),
        "ret_pct": round(realized / principal * 100, 2) if principal else 0,
        "rounds": len(nets),
        "win_rounds": sum(1 for n in nets if n > 0),
        "best": max(nets) if nets else 0,
        "worst": min(nets) if nets else 0,
        "total_now": _portfolio_total(),
        "curve": curve,
        "synced_at": m.get("synced_at"),
    }


@router.get("/runs")
def backtest_runs():
    conn = get_conn()
    try:
        return [dict(r) for r in conn.execute(
            "SELECT id, label, created_at, final_equity, total_return,"
            " trades, win_rate, pl_ratio, worst_hit FROM backtest_runs"
            " ORDER BY id DESC").fetchall()]
    finally:
        conn.close()


@router.get("/runs/{rid}")
def backtest_run(rid: int):
    conn = get_conn()
    try:
        run = conn.execute("SELECT * FROM backtest_runs WHERE id=?",
                           (rid,)).fetchone()
        if not run:
            raise HTTPException(404, f"run {rid} not found")
        yearly = conn.execute(
            "SELECT year, return_pct FROM backtest_yearly WHERE run_id=?"
            " ORDER BY year", (rid,)).fetchall()
        curve = conn.execute(
            "SELECT seq, date, equity FROM backtest_curve WHERE run_id=?"
            " ORDER BY seq", (rid,)).fetchall()
        out = dict(run)
        out["yearly"] = [dict(y) for y in yearly]
        out["curve"] = [dict(c) for c in curve]
        return out
    finally:
        conn.close()


@router.get("/runs/{rid}/trades")
def backtest_trades(rid: int, limit: int = 50, offset: int = 0):
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT * FROM backtest_trades WHERE run_id=?"
            " ORDER BY seq LIMIT ? OFFSET ?",
            (rid, min(limit, 500), offset)).fetchall()
        total = conn.execute(
            "SELECT COUNT(*) c FROM backtest_trades WHERE run_id=?",
            (rid,)).fetchone()["c"]
        return {"total": total, "trades": [dict(r) for r in rows]}
    finally:
        conn.close()


class BacktestImportIn(BaseModel):
    path: str = None
    label: str = None
    run_id: int = None


@router.post("/import")
def run_backtest_import(body: BacktestImportIn = None):
    from services.backtest_import import import_backtest, DEFAULT_PATH
    import os
    path = (body.path if body and body.path else DEFAULT_PATH)
    if not os.path.exists(path):
        raise HTTPException(400, f"报告文件不存在: {path}")
    conn = get_conn()
    try:
        return import_backtest(conn, path,
                               label=(body.label if body else None),
                               replace_run=(body.run_id if body else None))
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(502, f"导入失败: {e}")
    finally:
        conn.close()
