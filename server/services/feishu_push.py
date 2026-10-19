"""飞书推送(8787 卡片口径):interactive 卡片+markdown 表格+红涨绿跌。

防丢:ensure_push 先落 push_outbox(事务性发件箱)→发送线程逐目标投递
(push_delivery 目标级幂等)→失败退避重试(1m/5m/15m,>3次 failed)。
格式:带 rows 的消息渲染成卡片(header+表格+footer);纯文本走 text 兜底。
"""
import json
import re
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


def _norm_code(c: str) -> str:
    """代码归一:sh.600001 / 600001 / sz.000002 → 6 位数字;C0 等期货品种原样小写。"""
    c = str(c or "").strip().lower()
    m = re.search(r"\d{6}", c)
    return m.group(0) if m else c


def _targets(kind: str, code: str = None):
    """通道定向:feishu.codes 为空=全员广播(收全部);非空=只投 code 命中订阅的通道。
    无 code 的账户级卡(卖出/选股/持仓/买入)进全员广播通道 + 勾了 account_cards 的专线。"""
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        rows = conn.execute(
            "SELECT id, kind, name, webhook, codes, account_cards FROM feishu").fetchall()
    finally:
        conn.close()
    out = []
    for r in rows:
        try:
            subs = [s for s in json.loads(r["codes"] or "[]") if s]
        except Exception:
            subs = []
        if not subs \
           or (code and _norm_code(code) in {_norm_code(s) for s in subs}) \
           or (not code and r["account_cards"]):
            out.append(dict(r))
    return out


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
                rows: list = None, footer: str = None, code: str = None):
    """入箱(去重键唯一)。rows 提供则渲染卡片表格;code=本卡标的(按通道订阅 codes 定向)。"""
    if rows is not None or footer is not None:
        body = json.dumps({"text": body, "rows": rows, "footer": footer}, ensure_ascii=False)
    conn = dbm.connect()
    try:
        conn.execute(
            "INSERT OR IGNORE INTO push_outbox(kind,title,body,dedup_key,code)"
            " VALUES(?,?,?,?,?)",
            (kind, title, body, dedup_key, code))
        conn.commit()
    finally:
        conn.close()


def record_direct_test(target_id: str, body_text: str, ok: bool, error: str = None):
    """直发测试卡(指定 bot,同步返回)后记账:落 kind='test' 发件箱 + 该目标投递记录,
    状态直接终态(不入 pending,不经过发送线程),让通道卡「状态/最近投递」立即反映结果。"""
    conn = dbm.connect()
    try:
        now = datetime.now()
        cur = conn.execute(
            "INSERT INTO push_outbox(kind,title,body,dedup_key,status,retries,last_error)"
            " VALUES('test','看门狗 · 推送测试',?,?,?,0,?)",
            (body_text, f"testbot:{target_id}:{now.strftime('%Y-%m-%d %H:%M:%S.%f')}",
             "sent" if ok else "failed", None if ok else (error or "")[:200]))
        oid = cur.lastrowid
        if ok:
            conn.execute("UPDATE push_outbox SET sent_at=datetime('now','localtime')"
                         " WHERE id=?", (oid,))
            conn.execute("INSERT OR REPLACE INTO push_delivery(outbox_id,target,ok)"
                         " VALUES(?,?,1)", (oid, target_id))
        else:
            es = error or ""
            permanent = any(pe in es.lower() or pe in es for pe in _PERMANENT_ERR)
            conn.execute("INSERT OR REPLACE INTO push_delivery(outbox_id,target,ok,error)"
                         " VALUES(?,?,?,?)", (oid, target_id, 2 if permanent else 0, es[:200]))
        conn.commit()
    finally:
        conn.close()


def repush_to_target(outbox_id: int, target_id: str):
    """按需补发:把历史消息原样直发到指定通道(不经订阅路由,不打扰其他通道)。
    落一条终态发件箱记录(kind/title/body 与原卡一致,dedup=repush:...)+该目标投递行,
    时间轴/通道卡「最近投递」随之刷新。返回 (ok, error)。"""
    conn = dbm.connect()
    try:
        src = conn.execute("SELECT kind,title,body FROM push_outbox WHERE id=?",
                           (outbox_id,)).fetchone()
        tgt = conn.execute("SELECT name,webhook FROM feishu WHERE id=?",
                           (target_id,)).fetchone()
    finally:
        conn.close()
    if not src:
        raise ValueError(f"消息 #{outbox_id} 不存在")
    if not tgt:
        raise ValueError(f"通道 {target_id} 不存在")
    try:
        _send_webhook(tgt["webhook"], src["kind"], src["title"], src["body"])
        ok, err = True, None
    except Exception as e:
        ok, err = False, str(e)[:200]
    conn = dbm.connect()
    try:
        now = datetime.now()
        cur = conn.execute(
            "INSERT INTO push_outbox(kind,title,body,dedup_key,status,retries,last_error,sent_at)"
            " VALUES(?,?,?,?,?,0,?,?)",
            (src["kind"], src["title"], src["body"],
             f"repush:{outbox_id}:{target_id}:{now.strftime('%Y-%m-%d %H:%M:%S.%f')}",
             "sent" if ok else "failed",
             None if ok else err,
             now.strftime("%Y-%m-%d %H:%M:%S") if ok else None))
        oid = cur.lastrowid
        if ok:
            conn.execute("INSERT OR REPLACE INTO push_delivery(outbox_id,target,ok)"
                         " VALUES(?,?,1)", (oid, target_id))
        else:
            permanent = any(pe in (err or "").lower() or pe in (err or "")
                            for pe in _PERMANENT_ERR)
            conn.execute("INSERT OR REPLACE INTO push_delivery(outbox_id,target,ok,error)"
                         " VALUES(?,?,?,?)", (oid, target_id, 2 if permanent else 0, err))
        conn.commit()
    finally:
        conn.close()
    return ok, err


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
        # 重试超限(4 次仍失败)→ failed 终态(可见、计入统计,不再僵尸 pending)
        conn.execute("UPDATE push_outbox SET status='failed',"
                     " last_error='重试超限(4次仍失败)'"
                     " WHERE status='pending' AND retries>=4")
        conn.commit()   # 立即落库:否则 pendings 为空时无后续提交,close 会回滚这条终态
        # 只处理退避到期的(1m/5m/15m;新建消息 next_try_at 为空=立即)
        pendings = conn.execute(
            "SELECT * FROM push_outbox WHERE status='pending' AND retries<=3"
            " AND (next_try_at IS NULL OR next_try_at<=datetime('now','localtime'))"
            " ORDER BY id LIMIT 20").fetchall()
        for m in pendings:
            targets = _targets(m["kind"], m["code"])
            if not targets:
                if conn.execute("SELECT 1 FROM feishu LIMIT 1").fetchone():
                    # 有通道但订阅过滤后无人收(如仅剩订阅通道且 code 不匹配)
                    conn.execute("UPDATE push_outbox SET status='skipped',"
                                 " last_error='订阅过滤后无匹配通道' WHERE id=?", (m["id"],))
                else:
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
                wait = BACKOFF[min(r, len(BACKOFF)) - 1]
                conn.execute(
                    "UPDATE push_outbox SET retries=?,"
                    " next_try_at=datetime('now','localtime','+'||?||' seconds'),"
                    " last_error='部分目标失败' WHERE id=?",
                    (r, wait, m["id"]))
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
