"""期货缠论监控(内置:新浪K线 + czsc 结构计算;盘中自动轮询,无需人工关注)。"""
import json
import re
import threading
import time
import urllib.request
from datetime import datetime

STATE = {"stocks": [], "level": "5m", "quote_at": None, "scanning": False}
_lock = threading.Lock()
_stop = threading.Event()

# 原引擎同款 7 品种
FUTURES = ["JM0", "C0", "SC0", "JD0", "LC0", "MA0", "EG0"]
LEVELS = {"1m": 1, "5m": 5, "15m": 15, "30m": 30, "60m": 60}
# 原引擎中文级别兼容
_ALIAS = {"1分钟": "1m", "5分钟": "5m", "15分钟": "15m", "30分钟": "30m", "60分钟": "60m", "日线": "1d", "1d": 1440}

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}


def _sina_kline(symbol: str, minutes: int, limit: int = 300):
    """新浪期货分钟K(jsonp);日K用 getDailyKLine。"""
    import pandas as pd
    from czsc import RawBar, Freq
    svc = "getDailyKLine" if minutes == 1440 else "getFewMinLine"
    q = f"type={minutes}" if minutes != 1440 else ""
    url = (f"https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20_k=/InnerFuturesNewService.{svc}?symbol={symbol}"
           + (f"&{q}" if q else ""))
    try:
        raw = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=10).read().decode()
        rows = json.loads(re.search(r"\[.*\]", raw, re.S).group(0))
    except Exception:
        return [], None
    bars = []
    for r in rows[-limit:]:
        try:
            bars.append(RawBar(
                symbol=symbol, dt=pd.to_datetime(r["d"]), open=float(r["o"]),
                close=float(r["c"]), high=float(r["h"]), low=float(r["l"]),
                vol=float(r["v"]), amount=0,
                freq=Freq.D1 if minutes == 1440 else Freq.F5))
        except Exception:
            continue
    return bars, (rows[-1] if rows else None)


def scan(symbol: str, level: str) -> dict:
    """一个品种:K线→czsc→笔/中枢/最新价。"""
    from czsc import CZSC
    level = _ALIAS.get(level, level)
    minutes = _ALIAS.get(level, LEVELS.get(level, 5)) if level == "1d" else LEVELS.get(level, 5)
    bars, last_raw = _sina_kline(symbol, minutes)
    if len(bars) < 50:
        return {"code": symbol, "name": symbol, "close": None, "live_price": None,
                "chg_pct": None, "chanpy": None, "error": "kline不足"}
    c = CZSC(bars, max_bi_num=100)
    bis, zss = c.bi_list, (getattr(c, "zs_list", None) or [])
    last_bar = bars[-1]
    first_bar = bars[0]
    chg = (last_bar.close / first_bar.close - 1) * 100 if first_bar.close else 0
    return {
        "code": symbol, "name": symbol,
        "close": last_bar.close, "live_price": last_bar.close,
        "chg_pct": round(chg, 2),
        "chanpy": {
            "bi_count": len(bis), "seg_count": 0, "zs_count": len(zss),
            "last_bi_dir": str(bis[-1].direction) if bis else None,
            "last_bi_from": str(bis[-1].fx_a.dt) if bis else None,
            "last_zs": [zss[-1].zd, zss[-1].zg] if zss else None,   # ZS 属性=zd/zg(低/高)
        },
        "quote_dt": str(last_bar.dt),
    }


def rescan_all(level: str = None):
    """全品种重扫(轮询线程与手动共用)。"""
    lv = level or STATE["level"]
    with _lock:
        STATE["scanning"] = True
    out = []
    for sym in FUTURES:
        try:
            out.append(scan(sym, lv))
            time.sleep(0.4)   # 防限流
        except Exception as e:
            out.append({"code": sym, "name": sym, "error": str(e)[:80]})
    with _lock:
        STATE.update(stocks=out, level=lv, quote_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                     scanning=False)
    return out


def _fut_hours() -> bool:
    now = datetime.now()
    if now.weekday() >= 5:
        return False
    hm = now.strftime("%H:%M")
    return "09:00" <= hm <= "15:15" or hm >= "21:00" or hm <= "02:30"


def _loop():
    while not _stop.is_set():
        try:
            if _fut_hours():
                rescan_all()
                _stop.wait(30)   # 盘中 30s 重算结构
            else:
                _stop.wait(120)  # 休市 2 分钟探测
        except Exception as e:
            print("[watchdog] futures loop:", e)
            _stop.wait(60)


def start():
    threading.Thread(target=_loop, daemon=True, name="futures-monitor").start()


def snapshot(level: str = None):
    level = _ALIAS.get(level, level) or STATE.get("level")
    if level and level != STATE.get("level"):
        rescan_all(level)   # 级别切换:同步重扫
    return {"level": STATE.get("level"), "levels": list(LEVELS.keys()),
            "quote_at": STATE.get("quote_at"), "scanning": STATE.get("scanning", False),
            "stocks": STATE.get("stocks", [])}
