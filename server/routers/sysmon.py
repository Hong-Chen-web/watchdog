"""系统监控模块接口:/api/sysmon(services/mole 桥)。"""
from fastapi import APIRouter, HTTPException

from services.mole import mole_metrics
from .common import get_conn

router = APIRouter(prefix="/api/sysmon", tags=["sysmon"])


@router.get("")
def sysmon():
    err, data = mole_metrics()
    if err:
        # 502 + 错误信封;前端可用上次页面快照降级
        raise HTTPException(502, f"Mole 采集失败: {err}")
    return data


@router.get("/history")
def sysmon_history(hours: int = 1):
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT * FROM sysmon_samples ORDER BY ts DESC LIMIT ?",
            (hours * 720,)).fetchall()  # 5s 采样密度上限
        return [dict(r) for r in reversed(rows)]
    finally:
        conn.close()
