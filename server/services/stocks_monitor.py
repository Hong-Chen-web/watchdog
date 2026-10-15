"""盘中股票缠论监控(对齐 8787 的 9:30 盘中口径)。

交易时段(9:30-11:35/12:55-15:05)每 5 分钟:自选股 5 分钟K线→czsc 笔/中枢
→新确认的买卖点(B1/B2/B3/S1/S2/S3)→桌面通知+落库 chan_signals 表
(同票同类型同K线时间当日只报一次——当年『只推已确认』去重口径)。
"""
import json
import re
import subprocess
import threading
import time
import urllib.request
from datetime import datetime

DATA_DIR = None
_seen = {}          # (code, kind, bar_time) -> True(当日去重)
_lock = threading.Lock()
_stop = threading.Event()


def _in_stock_hours() -> bool:
    now = datetime.now()
    if now.weekday() >= 5:
        return False
    hm = now.strftime("%H:%M")
    return "09:30" <= hm <= "11:35" or "12:55" <= hm <= "15:05"


def _is_trade_day() -> bool:
    try:
        with urllib.request.urlopen("http://qt.gtimg.cn/q=sh000001", timeout=4) as f:
            raw = f.read().decode("gbk", "ignore")
        return raw.split("~")[30][:8] == datetime.now().strftime("%Y%m%d")
    except Exception:
        return datetime.now().weekday() < 5


def _notify(title: str, body: str):
    try:
        subprocess.run(["osascript", "-e",
                        f'display notification "{body}" with title "{title}"'],
                       timeout=5, capture_output=True)
    except Exception:
        pass


def _mkline(code6: str, minutes: int = 5, limit: int = 250):
    """腾讯股票分钟K(与图表端点同源)。"""
    pfx = "sh" if code6[0] == "6" else ("bj" if code6[0] in "48" else "sz")
    try:
        api = (f"https://ifzq.gtimg.cn/appstock/app/kline/mkline"
               f"?param={pfx}{code6},m{minutes},,{limit}")
        raw = urllib.request.urlopen(
            urllib.request.Request(api, headers={"User-Agent": "Mozilla/5.0"}), timeout=8
        ).read().decode()
        arr = (json.loads(raw).get("data") or {}).get(f"{pfx}{code6}") or {}
        mk = arr.get(f"m{minutes}") or []
        from datetime import datetime as dtc
        return [{"date": f"{s[0][:4]}-{s[0][4:6]}-{s[0][6:8]} {s[0][8:10]}:{s[0][10:12]}",
                 "open": float(s[1]), "close": float(s[2]), "high": float(s[3]),
                 "low": float(s[4]), "volume": float(s[5])} for s in mk if len(s) >= 6]
    except Exception:
        return []


def _detect_bsp(code6: str, name: str, level: str = "5m"):
    """K→CZSC→买卖点(与图表端点同口径:B/S 1/2/3);level=5m/4h。"""
    if level == "4h":
        from services.kline_store import merge_4h
        rows = merge_4h(_mkline(code6, 60, 320))
    else:
        rows = _mkline(code6, 5)
    if len(rows) < 30:
        return []
    try:
        from czsc import CZSC, RawBar, Freq
        from datetime import datetime as dtc
        raw = [RawBar(symbol=code6, dt=dtc.fromisoformat(r["date"]),
                      open=r["open"], close=r["close"], high=r["high"],
                      low=r["low"], vol=r["volume"], amount=0, freq=Freq.F5)
               for r in rows]
        c = CZSC(raw, max_bi_num=100)
        marks = []
        bis = c.bi_list

        def _dn(b):
            return "下" in str(b.direction)

        for i in range(2, len(bis)):
            b, pb = bis[i], bis[i-2]
            if _dn(b) and b.low < pb.low:
                marks.append((b.fx_b.dt, float(b.low), "B1"))
            if not _dn(b) and b.high > pb.high:
                marks.append((b.fx_b.dt, float(b.high), "S1"))
        lows = [(i, b.low) for i, b in enumerate(bis) if _dn(b)]
        if lows:
            p_min = min(x[1] for x in lows)
            i_min = min(lows, key=lambda x: x[1])[0]
            for j in range(i_min+1, min(i_min+6, len(bis))):
                if _dn(bis[j]) and bis[j].low > p_min:
                    marks.append((bis[j].fx_b.dt, float(bis[j].low), "B2"))
                    break
        for z in (getattr(c, "zs_list", None) or []):
            zg, zd, z_end = float(z.zg), float(z.zd), str(z.edt)[:16]
            for b in bis:
                if str(b.fx_b.dt)[:16] <= z_end:
                    continue
                if _dn(b) and b.low > zg:
                    marks.append((b.fx_b.dt, float(b.low), "B3")); break
                if not _dn(b) and b.high < zd:
                    marks.append((b.fx_b.dt, float(b.high), "S3")); break
        return marks
    except Exception:
        return []


_primed = {"4h": False}   # 每级别首轮=静默建基线


LEVEL_CHOICES = ["5m", "15m", "30m", "60m", "4h", "day"]
_LEVEL_SUB = {"5m": "5分钟", "15m": "15分钟", "30m": "30分钟", "60m": "60分钟",
              "4h": "4小时", "day": "日线"}
MON_LEVEL_KEY = "stocks_monitor_level"


def get_level() -> str:
    """当前监控级别(设置表持久化,默认 4h)。"""
    import db as dbm
    try:
        conn = dbm.connect()
        row = conn.execute("SELECT value FROM settings WHERE key=?", (MON_LEVEL_KEY,)).fetchone()
        conn.close()
        v = (row["value"] if hasattr(row, "keys") else row[0]) if row else "4h"
        return v if v in LEVEL_CHOICES else "4h"
    except Exception:
        return "4h"


def set_level(level: str):
    """选完即生效:落库 + 新级别重置基线 + 立即后台扫一轮。"""
    if level not in LEVEL_CHOICES:
        return False
    import db as dbm
    conn = dbm.connect()
    try:
        conn.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
                     (MON_LEVEL_KEY, level))
        conn.commit()
    finally:
        conn.close()
    with _lock:
        for k in [k for k in list(_primed) if k != level]:
            _primed.pop(k, None)
        _primed[level] = False       # 新级别首轮=静默基线,不轰炸历史
    import threading
    threading.Thread(target=scan_once, daemon=True, name="monitor-level-kick").start()
    return True


def scan_once():
    """全自选扫一轮(按当前监控级别,什么级别就推什么级别)。"""
    level = get_level()
    import db as dbm
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        rows = conn.execute("SELECT code, name FROM watchlist").fetchall()
        out = []
        today = datetime.now().strftime("%Y-%m-%d")
        from routers.pushscope import stock_in_scope
        out += _scan_level(level, rows, conn, today, stock_in_scope)
        conn.commit()
        push_out(out)
        return out
    finally:
        conn.close()


def push_out(out):
    """一个股票一个信号 = 一条独立消息;标题带级别(5分钟/4小时)。"""
    if not out:
        return
    try:
        from services.feishu_push import ensure_push, kind_cn, kind_dir
        day = datetime.now().strftime("%Y-%m-%d")
        for s in out:
            lvl = s.get("level", "4h")
            tag = _LEVEL_SUB.get(lvl, lvl)
            ensure_push(
                "signal",
                f"📈 {s['name']} · {kind_dir(s['kind'])} · {tag}", "",
                f"signal:{day}:{lvl}:{s['code']}:{s['kind']}:{s['bar_time']}",
                rows=[{"股票": f"{s['name']} {s['code']}",
                       "信号": kind_cn(s["kind"]),
                       "价格": f"**{s['price']}**",
                       "时间": s["bar_time"][-5:]}],
                footer=f"{tag}级 · 已确认 · {day}")
    except Exception:
        pass


def _scan_level(level, rows, conn, today, stock_in_scope):
    """单级别扫一轮。"""
    global _primed
    out = []
    for r in rows:
        code6 = (r["code"] or "").split(".")[-1]
        if not stock_in_scope(code6):
            continue                      # 推送范围外:不算不推
        if level == "day":
            from services.selection import tencent_daily
            k = tencent_daily(code6, 120)
        else:
            k = _mkline(code6, {"4h": 60}.get(level, int(level.rstrip("m")) or 5), 320)
            if level == "4h":
                from services.kline_store import merge_4h
                k = merge_4h(k)
        fresh_from = str(k[-3]["date"])[:16] if len(k) >= 3 else ""   # 稳定门
        for dt, px, kind in _detect_bsp(code6, r["name"], level):
            bar = str(dt)[:16]
            notify_this = (_primed.get(level) and bar >= fresh_from)
            with _lock:
                # 首轮静默也要占住当日键,防止下轮把同一信号当"新"误报
                if bar >= fresh_from and _seen.get((code6, level, kind, today)):
                    continue
                if _seen.get((code6, level, kind, bar)):
                    continue
                _seen[(code6, level, kind, bar)] = True
                if bar >= fresh_from:
                    _seen[(code6, level, kind, today)] = True
            conn.execute(
                "INSERT OR IGNORE INTO chan_signals(code,name,kind,price,bar_time,notified_at,level)"
                " VALUES(?,?,?,?,?,datetime('now','localtime'),?)",
                (code6, r["name"], kind, px, bar, level))
            if notify_this:
                out.append({"code": code6, "name": r["name"], "kind": kind,
                            "price": px, "bar_time": bar, "level": level})
        time.sleep(0.3)
    _primed[level] = True
    return out


def _loop():
    while not _stop.is_set():
        try:
            if _in_stock_hours() and _is_trade_day():
                scan_once()
                _stop.wait(300)          # 5 分钟一轮(当年口径)
            else:
                _stop.wait(120)
        except Exception as e:
            print("[watchdog] stocks monitor:", e)
            _stop.wait(60)


def start():
    threading.Thread(target=_loop, daemon=True, name="stocks-monitor").start()
