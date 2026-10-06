"""缠论桥:chan-monitor(8787)只读代理 + 本地 data 文件读取(飞书配置/推送记录)。
原则:不改缠论服务,所有写入类操作(测试推送)仅原样转发其自身接口。"""
import json
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException

from .common import get_conn
from pydantic import BaseModel

router = APIRouter(prefix="/api/chan", tags=["chan"])

CHAN_BASE = "http://127.0.0.1:8787"
CHAN_DATA = Path("/Users/chenhong/github/personal-workbench/chan/data")


def _proxy(path: str, method: str = "GET", payload: dict = None):
    raise HTTPException(503, "缠论引擎已移除(2026-10-06),该实时能力下线")


def _read_json(name: str, default):
    try:
        return json.loads((CHAN_DATA / name).read_text(encoding="utf-8"))
    except Exception:
        return default


def _mask(hook: str) -> str:
    """webhook 打码:只露最后 6 位。"""
    if not hook:
        return ""
    return "…" + hook[-6:]


@router.get("/state")
def chan_state():
    """缠论引擎已移除:返回说明态(前端仅作存活展示)。"""
    return {"level": None, "levels": [], "watchlist": [], "scanning": False,
            "removed": True}



@router.get("/tail")
def chan_tail():
    """最近选股轮次:优先本地新生成(内置选股引擎),否则库内快照。"""
    import json as _json
    from datetime import datetime, timedelta
    from pathlib import Path as _P
    live = _P("/Users/chenhong/github/personal-workbench/data/recommended_tail.json")
    if live.exists():
        try:
            d = _json.loads(live.read_text(encoding="utf-8"))
            if d.get("stocks"):
                dd = datetime.now()
                while True:
                    dd += timedelta(days=1)
                    if dd.weekday() < 5:
                        break
                d.setdefault("next_run_day", dd.strftime("%Y-%m-%d"))
                return d
        except Exception:
            pass
    import db as dbm
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        row = conn.execute("SELECT v FROM chan_kv WHERE k='tail'").fetchone()
    finally:
        conn.close()
    snap = _json.loads(row["v"]) if row else {"date": None, "stocks": []}
    d = datetime.now()
    while True:
        d += timedelta(days=1)
        if d.weekday() < 5:
            break
    snap.setdefault("next_run_day", d.strftime("%Y-%m-%d"))
    return snap


@router.get("/futures")
def chan_futures(level: str = None):
    """期货缠论监控(内置引擎:新浪K线+czsc,盘中自动轮询)。"""
    from services import futures_monitor as fm
    return fm.snapshot(level)


@router.post("/futures-scan")
def chan_futures_scan(level: str = None):
    q = f"?level={urllib.parse.quote(level)}" if level else ""
    return _proxy(f"/api/futures/scan{q}", method="POST", payload={})


def _db_bots(conn):
    import json as _j
    rows = conn.execute("SELECT id,name,webhook,codes FROM feishu_bots ORDER BY id").fetchall()
    out = []
    for r in rows:
        try:
            codes = _j.loads(r["codes"])
        except ValueError:
            codes = []
        out.append({"id": r["id"], "name": r["name"], "webhook": r["webhook"], "codes": codes})
    return out


def _db_notify(conn):
    return [dict(r) for r in conn.execute(
        "SELECT name,webhook FROM feishu_notify ORDER BY name").fetchall()]


def _sync_chan_json(conn):
    """表 → chan-monitor json(推送引擎仍读它的 json 配置)。"""
    _save_json_atomic("feishu_bots.json", _db_bots(conn))
    _save_json_atomic("feishu_notify.json", _db_notify(conn))


def ensure_feishu_from_json(conn):
    """首启:表空则从 chan json 灌入(一次性)。"""
    n = conn.execute("SELECT COUNT(*) c FROM feishu_bots").fetchone()["c"] \
        + conn.execute("SELECT COUNT(*) c FROM feishu_notify").fetchone()["c"]
    if n:
        return
    for b in _read_json("feishu_bots.json", []):
        conn.execute(
            "INSERT OR IGNORE INTO feishu_bots(id,name,webhook,codes) VALUES(?,?,?,?)",
            (b.get("id") or "?", b.get("name") or "?", b.get("webhook") or "",
             json.dumps(b.get("codes") or [])))
    for g in _read_json("feishu_notify.json", []):
        conn.execute("INSERT OR IGNORE INTO feishu_notify(name,webhook) VALUES(?,?)",
                     (g.get("name") or "?", g.get("webhook") or ""))
    conn.commit()


@router.get("/feishu")
def chan_feishu():
    conn = get_conn()
    try:
        return {
            "bots": [{"id": b["id"], "name": b["name"],
                      "codes_n": len(b["codes"]), "codes": b["codes"],
                      "webhook": _mask(b["webhook"])} for b in _db_bots(conn)],
            "notify": [{"name": n["name"], "webhook": _mask(n["webhook"])}
                       for n in _db_notify(conn)],
        }
    finally:
        conn.close()


class FeishuTestIn(BaseModel):
    bot_id: Optional[str] = None   # 空=通知群


@router.post("/feishu/test")
def chan_feishu_test(body: FeishuTestIn = None):
    payload = {"bot_id": body.bot_id} if body and body.bot_id else {}
    return _proxy("/api/feishu/test", method="POST", payload=payload)


# ---------- 飞书配置维护(写 chan-monitor data/*.json,原子写+备份) ----------

class BotIn(BaseModel):
    name: str
    webhook: str
    codes: list[str] = []


def _save_json_atomic(name: str, data):
    p = CHAN_DATA / name
    bak = CHAN_DATA / (name + ".bak")
    if p.exists():
        bak.write_text(p.read_text(encoding="utf-8"), encoding="utf-8")
    tmp = CHAN_DATA / (name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(p)


@router.get("/feishu/config")
def feishu_config():
    """完整配置(表主存,webhook 明文供编辑)。"""
    conn = get_conn()
    try:
        return {"bots": _db_bots(conn), "notify": _db_notify(conn)}
    finally:
        conn.close()


@router.post("/feishu/bots", status_code=201)
def feishu_bot_create(body: BotIn):
    import uuid
    if not body.webhook.startswith("https://open.feishu.cn/"):
        raise HTTPException(400, "webhook 需为飞书 open API 地址")
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO feishu_bots(id,name,webhook,codes) VALUES(?,?,?,?)",
            (uuid.uuid4().hex[:8], body.name.strip(), body.webhook.strip(),
             json.dumps([c.strip() for c in body.codes if c.strip()])))
        conn.commit()
        _sync_chan_json(conn)
        return {"ok": True}
    finally:
        conn.close()


@router.put("/feishu/bots/{bot_id}")
def feishu_bot_update(bot_id: str, body: BotIn):
    if not body.webhook.startswith("https://open.feishu.cn/"):
        raise HTTPException(400, "webhook 需为飞书 open API 地址")
    conn = get_conn()
    try:
        cur = conn.execute(
            "UPDATE feishu_bots SET name=?, webhook=?, codes=? WHERE id=?",
            (body.name.strip(), body.webhook.strip(),
             json.dumps([c.strip() for c in body.codes if c.strip()]), bot_id))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"bot {bot_id} 不存在")
        _sync_chan_json(conn)
        return {"ok": True}
    finally:
        conn.close()


@router.delete("/feishu/bots/{bot_id}", status_code=204)
def feishu_bot_delete(bot_id: str):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM feishu_bots WHERE id=?", (bot_id,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"bot {bot_id} 不存在")
        _sync_chan_json(conn)
        return None
    finally:
        conn.close()


class NotifyIn(BaseModel):
    name: str
    webhook: str


@router.post("/feishu/notify", status_code=201)
def feishu_notify_create(body: NotifyIn):
    conn = get_conn()
    try:
        try:
            conn.execute("INSERT INTO feishu_notify(name,webhook) VALUES(?,?)",
                         (body.name.strip(), body.webhook.strip()))
            conn.commit()
        except Exception:
            raise HTTPException(409, f"通知群 {body.name} 已存在")
        _sync_chan_json(conn)
        return {"ok": True}
    finally:
        conn.close()


@router.delete("/feishu/notify/{name}", status_code=204)
def feishu_notify_delete(name: str):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM feishu_notify WHERE name=?", (name,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"通知群 {name} 不存在")
        _sync_chan_json(conn)
        return None
    finally:
        conn.close()


@router.get("/signals")
def chan_signals(limit: int = 12):
    """最近推送的信号(缠论 pushed_signals 去重簿)。"""
    rows = _read_json("pushed_signals.json", [])
    if isinstance(rows, list):
        rows = [r for r in rows if isinstance(r, str)][-limit:]
    return {"recent": list(reversed(rows)), "total": len(rows)}


CHART_DIR = CHAN_DATA / "charts"
_LEVELS = ["5m", "30m", "60m", "120m", "day"]
_ENGINES = ["chanpy", "czsc"]


@router.get("/chart-levels")
def chart_levels(code: str):
    """某股可用的图级别/引擎(扫 charts 目录)。"""
    import re as _re
    code = _re.sub(r"[^0-9a-zA-Z.]", "", code)
    out = []
    for lv in _LEVELS:
        for eng in _ENGINES:
            if (CHART_DIR / f"{code}_{lv}_{eng}.html").exists():
                out.append({"level": lv, "engine": eng})
    return {"code": code, "charts": out}


@router.get("/chart")
def chan_chart(code: str, level: str = "day", engine: str = "chanpy"):
    """返回缠论生成的 K 线图 HTML(笔/中枢标注,lightweight-charts 交互图)。
    原 HTML 引用绝对路径 /lightweight-charts.js(挂在缠论根下),本域下重写为代理端点。"""
    import re as _re
    from fastapi.responses import HTMLResponse
    code = _re.sub(r"[^0-9a-zA-Z.]", "", code)
    level = level if level in _LEVELS else "day"
    engine = engine if engine in _ENGINES else "chanpy"
    path = CHART_DIR / f"{code}_{level}_{engine}.html"
    if not path.exists():
        raise HTTPException(404, f"无图表: {code} {level} {engine}")
    html = path.read_text(encoding="utf-8")
    html = html.replace('src="/lightweight-charts.js"',
                        'src="/api/chan/static/lightweight-charts.js"')
    return HTMLResponse(html)


from fastapi.responses import FileResponse  # noqa: E402


@router.get("/static/lightweight-charts.js")
def chan_static_js():
    js = CHAN_DATA.parent / "static" / "lightweight-charts.js"
    if not js.exists():
        raise HTTPException(404, "lightweight-charts.js missing")
    return FileResponse(js, media_type="application/javascript")
