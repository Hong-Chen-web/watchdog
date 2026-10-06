"""装配模块接口:/api/modules(开关与排序,module_config 表)。"""
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .common import get_conn

router = APIRouter(prefix="/api/modules", tags=["modules"])

# 前端 i18n 负责名称;后端维护注册事实与图标名
MODULE_REGISTRY = [
    {"id": "portfolio", "icon": "chart-line-up"},
    {"id": "backtest",  "icon": "flask"},
    {"id": "todo",      "icon": "list-checks"},
    {"id": "ledger",    "icon": "wallet"},
    {"id": "market",    "icon": "chart-line"},
    {"id": "sysmon",    "icon": "stethoscope"},
    {"id": "disk",      "icon": "broom"},
    {"id": "strategy",  "icon": "lightning"},
    {"id": "futures",   "icon": "compass"},
    {"id": "calendar",  "icon": "calendar-blank"},
]


@router.get("")
def list_modules():
    conn = get_conn()
    try:
        rows = conn.execute("SELECT * FROM module_config ORDER BY sort").fetchall()
        return [
            {"id": r["module_id"], "enabled": bool(r["enabled"]), "sort": r["sort"],
             "icon": next((m["icon"] for m in MODULE_REGISTRY
                           if m["id"] == r["module_id"]), "")}
            for r in rows
        ]
    finally:
        conn.close()


class ModulePatch(BaseModel):
    enabled: bool


@router.put("/{module_id}")
def set_module(module_id: str, body: ModulePatch):
    conn = get_conn()
    try:
        cur = conn.execute(
            "UPDATE module_config SET enabled=?,"
            " updated_at=datetime('now','localtime') WHERE module_id=?",
            (int(body.enabled), module_id))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"unknown module {module_id}")
        return {"id": module_id, "enabled": body.enabled}
    finally:
        conn.close()


class ModuleOrder(BaseModel):
    order: list[str] = Field(min_length=1)


@router.put("/order")
def reorder_modules(body: ModuleOrder):
    conn = get_conn()
    try:
        known = {r["module_id"] for r in
                 conn.execute("SELECT module_id FROM module_config").fetchall()}
        unknown = [m for m in body.order if m not in known]
        if unknown:
            raise HTTPException(409, f"unknown modules: {unknown}")
        conn.executemany(
            "UPDATE module_config SET sort=?,"
            " updated_at=datetime('now','localtime') WHERE module_id=?",
            [(i, m) for i, m in enumerate(body.order)])
        conn.commit()
        return {"order": body.order}
    finally:
        conn.close()
