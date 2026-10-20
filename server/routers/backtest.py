"""回测模块接口:/api/backtest/live(实盘台账)。
八年历史回测(runs/import+backtest_* 表)已随 015 迁移移除,数据备份在 ~/Documents/workbench_backup_20261008.db。"""
from fastapi import APIRouter

from .common import get_conn

router = APIRouter(prefix="/api/backtest", tags=["backtest"])

PRINCIPAL = 100000.0


def _equity_curve(ledger: list, principal: float = PRINCIPAL) -> list:
    """逐日净值:按 sell_date(未卖用 round_date)聚合已实现净额,同日并成一点。
    不再追加伪日期点(旧实现用"最新持仓 round_date + summary.assets"追加,
    会与当日已有点重复 → 曲线末两点相同 → 「最近一日」永远 0.00%)。"""
    by_day, cum = {}, principal
    for row in ledger:
        d = row.get("sell_date") or row.get("round_date")
        if not d:
            continue
        cum += row.get("realized_net") or 0
        by_day[d] = round(cum, 0)
    return [{"date": d, "equity": by_day[d]} for d in sorted(by_day)]


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
    curve = _equity_curve(ledger, principal)
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
