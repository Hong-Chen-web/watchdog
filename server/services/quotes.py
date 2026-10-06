"""行情快线:3 秒轮询腾讯批量行情(自选 + 三大指数),写库 + 内存缓存。
设计:单线程守护;失败退避(连续失败拉长间隔);指数与自选合并一次请求。"""
import json
import threading
import time
import urllib.request
from datetime import datetime

import db as dbm

INDICES = [("sh000001", "上证指数"), ("sz399001", "深证成指"), ("sz399006", "创业板指")]
INTERVAL_OK = 3.0
INTERVAL_FAIL = 10.0

_lock = threading.Lock()
_state = {"indices": {}, "updated_at": None, "fails": 0, "last_ok": 0.0}
_stop = threading.Event()


def _fetch(symbols):
    url = "https://qt.gtimg.cn/q=" + ",".join(symbols)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode("gbk", "ignore")


def _parse(text):
    """腾讯 v_szXXXXXX="51~名称~代码~现价~..." → {code: (name, price, chg_pct)};字段 3=现价 32=涨跌%。"""
    out = {}
    for line in text.strip().split(";"):
        if "~" not in line or "=" not in line:
            continue
        key, val = line.split("=", 1)
        code = key.split("_")[-1].replace("v_", "")   # sz002384
        p = val.split("~")
        if len(p) < 33 or not p[1]:
            continue
        try:
            out[code] = (p[1], float(p[3]), float(p[32]))
        except (ValueError, IndexError):
            continue
    return out


def _pref(c):
    """裸 6 位代码 → 腾讯带市场前缀(6/5→sh,4/8→bj,其余→sz);已带前缀的原样。"""
    if not c[:1].isdigit():
        return c
    return ("sh" if c[0] in "65" else "bj" if c[0] in "48" else "sz") + c


def _in_stock_hours() -> bool:
    """股票时段(8787 同款:9:25-11:35/12:55-15:05);休市慢轮 60s 省流量。"""
    from datetime import datetime
    now = datetime.now()
    if now.weekday() >= 5:
        return False
    hm = now.strftime("%H:%M")
    return "09:25" <= hm <= "11:35" or "12:55" <= hm <= "15:05"


def _tick():
    conn = dbm.connect()
    try:
        codes = [r["code"] for r in conn.execute("SELECT code FROM watchlist")]
        syms = [_pref(c) for c in codes] + [i for i, _ in INDICES]
        if not syms:
            return INTERVAL_OK
        text = _fetch(syms)
        data = _parse(text)
        by6 = {k[-6:]: v for k, v in data.items()}   # 回包键带前缀,按尾 6 位对齐
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with _lock:
            _state["fails"] = 0
            _state["last_ok"] = time.time()
        changed = False
        for c in codes:
            d = by6.get(c)
            if not d:
                continue
            conn.execute(
                "UPDATE watchlist SET name=?, price=?, chg_pct=?,"
                " quote_at=? WHERE code=?", (d[0], d[1], d[2], now, c))
            changed = True
        idx = {}
        for sym, label in INDICES:
            d = data.get(sym)
            if d:
                idx[label] = {"code": sym, "price": d[1], "chg_pct": d[2]}
        with _lock:
            _state["indices"] = idx
            _state["updated_at"] = now
        if changed:
            conn.commit()
        return INTERVAL_OK
    except Exception:
        with _lock:
            _state["fails"] += 1
        return INTERVAL_FAIL
    finally:
        conn.close()


def _notify(title: str, body: str):
    import subprocess
    try:
        subprocess.run(["osascript", "-e",
                        f'display notification "{body}" with title "{title}"'],
                       capture_output=True, timeout=5)
    except Exception:
        pass


_alerted = {}   # code → (day, 触发方向)


def _check_alerts(wl: list):
    """自选异动提醒:|涨跌|≥5% 当日首次触发(macOS 通知,无需盯盘)。"""
    from datetime import datetime as _dt
    today = _dt.now().strftime("%Y-%m-%d")
    for w in wl:
        code, chg = w.get("code"), w.get("chg_pct") or 0
        if not code:
            continue
        if abs(chg) >= 5:
            key = (code, "up" if chg > 0 else "down")
            if _alerted.get(code) == (today, key[1]):
                continue
            _alerted[code] = (today, key[1])
            name = w.get("name") or code
            _notify("看门狗 · 自选异动", f"{name} {chg:+.2f}%")
            break   # 单 tick 只发一条防轰炸


def _loop():
    while not _stop.is_set():
        try:
            wait = _tick()
            if _in_stock_hours():
                conn = dbm.connect()
                conn.row_factory = __import__("sqlite3").Row
                try:
                    wl = [dict(r) for r in conn.execute(
                        "SELECT code, name, chg_pct FROM watchlist WHERE chg_pct IS NOT NULL")]
                finally:
                    conn.close()
                _check_alerts(wl)
            else:
                wait = 60.0   # 休市慢轮:快线停刷,仅保活
        except Exception:
            wait = INTERVAL_FAIL
        _stop.wait(wait)


def start():
    threading.Thread(target=_loop, daemon=True, name="quotes-fastline").start()


def snapshot():
    """行情快照(供 /api/market/quotes)。"""
    with _lock:
        return {"indices": dict(_state["indices"]),
                "updated_at": _state["updated_at"],
                "fails": _state["fails"]}
