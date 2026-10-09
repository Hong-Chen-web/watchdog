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
FUT_NAMES = {"JM0": "焦煤", "C0": "玉米", "SC0": "上海原油", "JD0": "鸡蛋",
             "LC0": "碳酸锂", "MA0": "甲醇", "EG0": "乙二醇"}
LEVELS = {"1m": 1, "5m": 5, "15m": 15, "30m": 30, "60m": 60}
# 原引擎中文级别兼容
_ALIAS = {"1分钟": "1m", "5分钟": "5m", "15分钟": "15m", "30分钟": "30m", "60分钟": "60m", "日线": "1d", "1d": 1440}

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}


def _sina_kline(symbol: str, minutes: int, limit: int = 300):
    """新浪期货分钟K(jsonp);日K用 getDailyKLine。"""
    from datetime import datetime as dtc
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
                symbol=symbol, dt=dtc.fromisoformat(r["d"]), open=float(r["o"]),
                close=float(r["c"]), high=float(r["h"]), low=float(r["l"]),
                vol=float(r["v"]), amount=0,
                freq=Freq.D if minutes == 1440 else Freq.F5))
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
        cb = _BAR_CACHE.get((symbol, minutes))
        if cb and len(cb) >= 50:
            bars = cb   # 新浪抖动,回退上一轮
    if len(bars) >= 50:
        _BAR_CACHE[(symbol, minutes)] = bars
    else:
        return {"code": symbol, "name": FUT_NAMES.get(symbol, symbol), "close": None, "live_price": None,
                "chg_pct": None, "chanpy": None, "error": "kline不足"}
    c = CZSC(bars, max_bi_num=100)
    bis, zss = c.bi_list, (getattr(c, "zs_list", None) or [])
    try:
        _push_futures_signals(symbol, c)
    except Exception:
        pass
    last_bar = bars[-1]
    first_bar = bars[0]
    chg = (last_bar.close / first_bar.close - 1) * 100 if first_bar.close else 0
    return {
        "code": symbol, "name": FUT_NAMES.get(symbol, symbol),
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


_BAR_CACHE = {}   # (symbol, minutes) -> bars,监控线程刷新,chart 端点兜底
_SIG_SEEN = {}    # (symbol, kind, 当日) -> True(信号去重,重启后首轮静默基线)
_SIG_PRIMED = {}  # symbol -> 是否已建基线


def _detect_signals(symbol: str, c) -> list:
    """从 CZSC 结构提取已确认买卖点(与股票监控同口径:B1/S1 背驰 + B3/S3 中枢回抽)。"""
    from datetime import datetime as _dt
    out = []
    bis = c.bi_list

    def dn(b):
        return "下" in str(b.direction)

    for i in range(2, len(bis)):
        b, pb = bis[i], bis[i-2]
        if dn(b) and b.low < pb.low:
            out.append((str(b.fx_b.dt)[:16], float(b.low), "B1"))
        if not dn(b) and b.high > pb.high:
            out.append((str(b.fx_b.dt)[:16], float(b.high), "S1"))
    for z in (getattr(c, "zs_list", None) or []):
        zg, zd, z_end = float(z.zg), float(z.zd), str(z.edt)[:16]
        for b in bis:
            if str(b.fx_b.dt)[:16] <= z_end:
                continue
            if dn(b) and b.low > zg:
                out.append((str(b.fx_b.dt)[:16], float(b.low), "B3")); break
            if not dn(b) and b.high < zd:
                out.append((str(b.fx_b.dt)[:16], float(b.high), "S3")); break
    # 只保留最近 2 根bar内确认的(稳定门≈前沿)
    if bis:
        fresh = str(bis[-1].fx_b.dt)[:16]
        out = [(t, p, k) for (t, p, k) in out if t >= fresh or
               (len(bis) > 1 and t >= str(bis[-2].fx_b.dt)[:16])]
    return out


def _push_futures_signals(symbol: str, c):
    """新确认信号→飞书发件箱(期货只走通知群/全局,不进专属bot)。"""
    today = time.strftime("%Y-%m-%d")
    marks = _detect_signals(symbol, c)
    if not _SIG_PRIMED.get(symbol):
        _SIG_PRIMED[symbol] = True          # 首轮=静默建基线
        for t, p, k in marks:
            _SIG_SEEN[(symbol, k, today)] = True
        return []
    fresh = []
    for t, p, k in marks:
        key = (symbol, k, today)
        if key in _SIG_SEEN:
            continue
        _SIG_SEEN[key] = True
        fresh.append((t, p, k))
    if fresh:
        try:
            from routers.pushscope import future_in_scope
            if not future_in_scope(symbol):
                return fresh                  # 范围外:不推
            from services.feishu_push import ensure_push, kind_cn, kind_dir
            rows = [{"品种": FUT_NAMES.get(symbol, symbol), "信号": kind_cn(k),
                     "价格": f"**{p}**", "时间": t[-5:]} for t, p, k in fresh]
            dirs = "".join(sorted({kind_dir(k) for t, p, k in fresh}))
            ensure_push("signal", f"📊 期货{dirs} · {FUT_NAMES.get(symbol, symbol)}", "",
                        f"fsig:{symbol}:{today}:{fresh[0][0]}",
                        rows=rows, footer=f"5分钟级 · 已确认 · {today}")
        except Exception:
            pass
    return fresh


def cached_bars(symbol: str, minutes: int):
    return _BAR_CACHE.get((symbol, minutes))


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
            out.append({"code": sym, "name": FUT_NAMES.get(sym, sym), "error": str(e)[:80]})
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
    # 启动先扫一轮(不论时段,展示最后数据),之后按时段轮询
    try:
        rescan_all()
    except Exception:
        pass
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
