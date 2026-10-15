"""飞书推送(8787 卡片口径):interactive 卡片+markdown 表格+红涨绿跌。

防丢:ensure_push 先落 push_outbox(事务性发件箱)→发送线程逐目标投递
(push_delivery 目标级幂等)→失败退避重试(1m/5m/15m,>3次 failed)。
格式:带 rows 的消息渲染成卡片(header+表格+footer);纯文本走 text 兜底。
"""
import json
import threading
import time
import urllib.request
from datetime import datetime

import db as dbm

BACKOFF = [60, 300, 900]
# 永久性拒绝(webhook 失效/被删):静默该目标,不再拖累消息状态(用户修好 webhook 后需改配置重投)
_PERMANENT_ERR = ("19001", "19002", "token invalid", "webhook")

# 信号代码 → 人话(对齐 8787 卡片口径:B=买 S=卖)
KIND_CN = {
    "B1": "买① 趋势背驰", "B1P": "买①p 盘整背驰",
    "B2": "买② 回抽不破低", "B2S": "买②s 类二回抽",
    "B3": "买③ 中枢上沿回抽",
    "S1": "卖① 趋势背驰", "S1P": "卖①p 盘整背驰",
    "S2": "卖② 反抽不过高", "S2S": "卖②s 类二反抽",
    "S3": "卖③ 中枢下沿反抽",
}


def kind_cn(k: str) -> str:
    return KIND_CN.get(k, k)


def kind_dir(k: str) -> str:
    return "买点" if k.startswith("B") else ("卖点" if k.startswith("S") else "信号")


_lock = threading.Lock()


def _targets(kind: str, code: str = None):
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        rows = conn.execute("SELECT id, kind, name, webhook, codes FROM feishu").fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]      # 全员广播(用户 2026-10-09 口径)


_TEMPLATE = {"signal": "blue", "settle": "red", "selection": "orange",
             "plan": "green", "holding_daily": "turquoise", "test": "grey"}


def _fmt_cell(v) -> str:
    """单元格:剥 markdown 记号的数字→千分位去尾0(108240.0→108,240);其余原样。"""
    raw = str(v)
    probe = raw.replace("**", "").replace(",", "").strip()
    try:
        f = float(probe)
        if f == int(f):
            return f"{int(f):,}"
        return f"{f:,.2f}".rstrip("0").rstrip(".")
    except Exception:
        pass
    return raw


def _rows_to_columns(rows: list) -> list:
    """行数据→飞书原生 column_set(每行一组等分列;首列加粗,时间列窄)。"""
    cols = list(rows[0].keys())
    elems = []
    for r in rows:
        columns = []
        for i, c in enumerate(cols):
            v = _fmt_cell(r.get(c, ""))
            bold = (i == 0) or ("价" in c and "时间" not in c)
            content = f"**{v}**" if bold and not v.startswith("**") else v
            weight = 1 if ("时间" in c or c in ("时间", "名次")) else 2
            columns.append({
                "tag": "column", "width": "weighted", "weight": weight,
                "vertical_align": "center",
                "elements": [{"tag": "div", "text": {"tag": "lark_md", "content": content}}]})
        elems.append({"tag": "column_set", "flex_mode": "none",
                      "horizontal_spacing": "small", "columns": columns})
    return elems


def _send_webhook(webhook: str, kind: str, title: str, body: str):
    """body 兼容两种:json 信封({text,rows,footer})渲染卡片;裸文本发 text。"""
    text, rows, footer = body, None, None
    try:
        env = json.loads(body)
        if isinstance(env, dict) and "text" in env:
            text, rows, footer = env.get("text") or "", env.get("rows"), env.get("footer")
    except Exception:
        pass
    if rows:
        elems = []
        if text:
            elems.append({"tag": "div", "text": {"tag": "lark_md", "content": text}})
        # 飞书卡片 lark_md 不渲染 markdown 表格(裸竖线外露)——改用原生 column_set
        elems += _rows_to_columns(rows)
        if footer:
            elems.append({"tag": "hr"})
            elems.append({"tag": "div", "text": {
                "tag": "lark_md", "content": f"<font color='grey'>{footer}</font>"}})
        payload = {"msg_type": "interactive", "card": {
            "config": {"wide_text_mode": True},
            "header": {"title": {"tag": "plain_text", "content": title},
                       "template": _TEMPLATE.get(kind, "blue")},
            "elements": elems}}
    else:
        payload = {"msg_type": "text", "content": {"text": f"【{title}】\n{text}"}}
    req = urllib.request.Request(
        webhook, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as f:
        d = json.loads(f.read().decode())
    if d.get("code") not in (0, None):
        raise RuntimeError(f"feishu code={d.get('code')} {d.get('msg')}")


def ensure_push(kind: str, title: str, body: str, dedup_key: str,
                rows: list = None, footer: str = None):
    """入箱(去重键唯一)。rows 提供则渲染卡片表格。"""
    if rows is not None or footer is not None:
        body = json.dumps({"text": body, "rows": rows, "footer": footer}, ensure_ascii=False)
    conn = dbm.connect()
    try:
        conn.execute(
            "INSERT OR IGNORE INTO push_outbox(kind,title,body,dedup_key) VALUES(?,?,?,?)",
            (kind, title, body, dedup_key))
        conn.commit()
    finally:
        conn.close()


def _push_enabled() -> bool:
    """总开关:settings.push_master=='off' 时暂停一切飞书发送(消息入箱留档不发送)。"""
    try:
        conn = dbm.connect()
        row = conn.execute("SELECT value FROM settings WHERE key='push_master'").fetchone()
        conn.close()
        return (not row) or row["value"] != "off"
    except Exception:
        return True


def flush_once():
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        if not _push_enabled():
            # 停发模式:pending 一律标 skipped(留档不堆积,重开只推新消息)
            conn.execute("UPDATE push_outbox SET status='skipped'"
                         " WHERE status='pending'")
            conn.commit()
            return
    finally:
        pass
    conn.close()
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        pendings = conn.execute(
            "SELECT * FROM push_outbox WHERE status='pending' AND retries<=3"
            " ORDER BY id LIMIT 20").fetchall()
        for m in pendings:
            targets = _targets(m["kind"])
            if not targets:
                conn.execute("UPDATE push_outbox SET status='failed',"
                             " last_error='无飞书配置(设置里配机器人)' WHERE id=?", (m["id"],))
                conn.commit()
                continue
            all_ok = True
            for t in targets:
                done = conn.execute(
                    "SELECT ok FROM push_delivery WHERE outbox_id=? AND target=?",
                    (m["id"], t["id"])).fetchone()
                if done and done["ok"] in (1, 2):
                    continue   # 1=已送达 2=永久拒绝(webhook 失效,静默)
                try:
                    _send_webhook(t["webhook"], m["kind"], m["title"], m["body"] or "")
                    conn.execute(
                        "INSERT OR REPLACE INTO push_delivery(outbox_id,target,ok) VALUES(?,?,1)",
                        (m["id"], t["id"]))
                except Exception as e:
                    es = str(e)
                    permanent = any(pe in es.lower() or pe in es for pe in _PERMANENT_ERR)
                    conn.execute(
                        "INSERT OR REPLACE INTO push_delivery(outbox_id,target,ok,error)"
                        " VALUES(?,?,?,?)", (m["id"], t["id"], 2 if permanent else 0, es[:200]))
                    if not permanent:
                        all_ok = False
            if all_ok:
                conn.execute(
                    "UPDATE push_outbox SET status='sent',"
                    " sent_at=datetime('now','localtime') WHERE id=?", (m["id"],))
            else:
                r = m["retries"] + 1
                conn.execute(
                    "UPDATE push_outbox SET retries=?, last_error='部分目标失败' WHERE id=?",
                    (r, m["id"]))
            conn.commit()
    finally:
        conn.close()


def _loop():
    while True:
        try:
            flush_once()
        except Exception as e:
            print("[watchdog] push:", e)
        time.sleep(30)


def start():
    threading.Thread(target=_loop, daemon=True, name="feishu-push").start()
