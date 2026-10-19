"""Web UI 路由(薄壳):静态资源 + 三个接口;业务在 services/ui_snapshot 与 services/ai_query。

- GET  /ui                    → server/static/index.html(无数据,运行时拉 bootstrap)
- GET  /ui-assets/{path}      → 拆分后的 css/js 静态资源(带目录穿越防护)
- GET  /api/ui/bootstrap      → 首屏数据快照(services/ui_snapshot.build_bootstrap)
- GET  /api/ui/live           → 盘中轻量切片(组合/明细/自选行情/推送;前端秒级轮询)
- POST /api/ai/ask            → AI 只读问答(services/ai_query.ask;写入类由前端转调 smart-any)
- PUT  /api/ui/push-master    → 飞书总开关(settings.push_master,off=只入箱不发送)
"""
import sys
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from services import ai_query, ui_snapshot

SERVER_DIR = Path(__file__).resolve().parent.parent      # server/
STATIC_DIR = SERVER_DIR / "static"

router = APIRouter(tags=["ui"])


def _static_root() -> Path:
    """源码开发用 server/static;frozen(PyInstaller)用解包目录里的 static/。"""
    if (STATIC_DIR / "index.html").exists():
        return STATIC_DIR
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        p = Path(meipass) / "static"
        if (p / "index.html").exists():
            return p
    return STATIC_DIR


@router.get("/ui")
def ui_page():
    p = _static_root() / "index.html"
    if not p.exists():
        raise HTTPException(500, "static/index.html 缺失(打包需含 static/ 整目录)")
    return FileResponse(p, media_type="text/html; charset=utf-8", headers={"Cache-Control": "no-store"})


@router.get("/ui-assets/{path:path}")
def ui_asset(path: str):
    root = _static_root().resolve()
    p = (root / path).resolve()
    if not p.is_relative_to(root) or not p.is_file():
        raise HTTPException(404, "asset not found")
    return FileResponse(p, headers={"Cache-Control": "no-store"})


@router.get("/api/ui/bootstrap")
def ui_bootstrap():
    return ui_snapshot.build_bootstrap()


@router.get("/api/ui/live")
def ui_live():
    """盘中轻量切片:总资产/今日盈亏/持仓/自选行情/明细/推送(前端轮询用)。"""
    return ui_snapshot.build_live()


@router.post("/api/ai/ask")
def ai_ask(body: dict = None):
    try:
        return ai_query.ask(str((body or {}).get("text") or "").strip())
    except ValueError as e:
        raise HTTPException(400, str(e))


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
