"""飞书通道配置(2026-10-18 自 chan.py 按域拆分):bot / 通知群 CRUD + 测试推送。

- 数据主存 workbench.db 的 feishu 表;chan-monitor data/ 目录存在时双写 *_json(兼容层)
- 对外路径保持 /api/chan/feishu*,拆分不改契约;与 chan.py 同属缠论域,不进 MODULE_ROUTERS
"""
import json
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from .common import get_conn
from .chan import CHAN_DATA, _read_json

router = APIRouter(prefix="/api/chan", tags=["feishu"])


def _mask(hook: str) -> str:
    """webhook 打码:只露最后 6 位。"""
    if not hook:
        return ""
    return "…" + hook[-6:]


def _db_bots(conn):
    import json as _j
    rows = conn.execute(
        "SELECT id,name,webhook,codes FROM feishu WHERE kind='bot' ORDER BY id").fetchall()
    out = []
    for r in rows:
        try:
            codes = _j.loads(r["codes"])
        except ValueError:
            codes = []
        out.append({"id": r["id"], "name": r["name"], "webhook": r["webhook"], "codes": codes})
    return out


def _db_notify(conn):
    return [{"name": r["name"], "webhook": r["webhook"]} for r in conn.execute(
        "SELECT name,webhook FROM feishu WHERE kind='notify' ORDER BY name").fetchall()]


def _sync_chan_json(conn):
    """表 → chan-monitor json(引擎已于 v57 移除,目录不存在时跳过双写)。"""
    if not CHAN_DATA.exists():
        return
    _save_json_atomic("feishu_bots.json", _db_bots(conn))
    _save_json_atomic("feishu_notify.json", _db_notify(conn))


def ensure_feishu_from_json(conn):
    """首启:表空则从 chan json 灌入(一次性)。"""
    if conn.execute("SELECT COUNT(*) c FROM feishu").fetchone()["c"]:
        return
    for b in _read_json("feishu_bots.json", []):
        conn.execute(
            "INSERT OR IGNORE INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
            (b.get("id") or "?", "bot", b.get("name") or "?", b.get("webhook") or "",
             json.dumps(b.get("codes") or [])))
    for g in _read_json("feishu_notify.json", []):
        conn.execute("INSERT OR IGNORE INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
                     (g.get("name") or "?", "notify", g.get("name") or "?",
                      g.get("webhook") or "", "[]"))
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
    """默认发通知群(走发件箱留档);指定 bot_id 时直发该机器人并同步返回结果。"""
    from services.feishu_push import ensure_push, flush_once
    bot_id = (body.bot_id if body else None) or None
    if bot_id:
        from services.feishu_push import _send_webhook
        conn = get_conn()
        try:
            row = conn.execute(
                "SELECT name,webhook FROM feishu WHERE id=? AND kind='bot'",
                (bot_id,)).fetchone()
        finally:
            conn.close()
        if not row:
            raise HTTPException(404, f"机器人 {bot_id} 不存在")
        try:
            _send_webhook(row["webhook"], "test", "看门狗 · 推送测试",
                          f"飞书通道正常 · {datetime.now().strftime('%H:%M:%S')}")
            return {"status": "sent", "target": row["name"]}
        except Exception as e:
            return {"status": "failed", "target": row["name"], "last_error": str(e)[:200]}
    ensure_push("test", "看门狗 · 推送测试",
                f"飞书通道正常 · {datetime.now().strftime('%H:%M:%S')}",
                f"test:{datetime.now().strftime('%Y-%m-%d %H:%M')}")
    flush_once()
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT status,last_error FROM push_outbox"
            " WHERE kind='test' ORDER BY id DESC LIMIT 1").fetchone()
        return dict(row) if row else {"status": "unknown"}
    finally:
        conn.close()


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
            "INSERT INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
            (uuid.uuid4().hex[:8], "bot", body.name.strip(), body.webhook.strip(),
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
            "UPDATE feishu SET name=?, webhook=?, codes=? WHERE id=? AND kind='bot'",
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
        cur = conn.execute("DELETE FROM feishu WHERE id=? AND kind='bot'", (bot_id,))
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
            conn.execute("INSERT INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
                         (body.name.strip(), "notify", body.name.strip(),
                          body.webhook.strip(), "[]"))
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
        cur = conn.execute("DELETE FROM feishu WHERE id=? AND kind='notify'", (name,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"通知群 {name} 不存在")
        _sync_chan_json(conn)
        return None
    finally:
        conn.close()
