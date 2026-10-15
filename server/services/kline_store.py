"""A股K线底库:一次性建库(全历史)+ 每日增量 + 本地查询。

设计(用户口径):历史K线全部落本地库,盘中/盘后只拉增量拼接;
选股/结算/回测全部读本地库——不再每票现拉 120 根(那要 50+ 分钟)。
存储:data/klines.db(SQLite,主键 code+date,与主库隔离便于重建)。
"""
import json
import sqlite3
import threading
import time
import urllib.request
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent.parent / "data"
DB = DATA / "klines.db"
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"}
_write_lock = threading.Lock()


def _conn():
    c = sqlite3.connect(DB, timeout=30)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("""CREATE TABLE IF NOT EXISTS kline(
        code TEXT NOT NULL, date TEXT NOT NULL,
        open REAL, close REAL, high REAL, low REAL, volume REAL,
        PRIMARY KEY(code, date))""")
    return c


def _pref(code6: str) -> str:
    return ("sh" if code6[0] == "6" else "bj" if code6[0] in "48" else "sz") + code6


def stats():
    """库现状:(票数, 总行数, 最早日期, 最晚日期)。"""
    try:
        c = _conn()
        n, rows, d1, d2 = c.execute(
            "SELECT COUNT(DISTINCT code), COUNT(*), MIN(date), MAX(date) FROM kline"
        ).fetchone()
        c.close()
        return {"codes": n, "rows": rows, "first": d1, "last": d2}
    except Exception:
        return {"codes": 0, "rows": 0, "first": None, "last": None}


def get_daily(code6: str, days: int = 120):
    """从库读最近 days 根;不足 days 根返回 None(调用方决定网络补)。"""
    try:
        c = _conn()
        rows = c.execute(
            "SELECT date, open, close, high, low, volume FROM kline"
            " WHERE code=? ORDER BY date DESC LIMIT ?", (code6, days)).fetchall()
        c.close()
    except Exception:
        return None
    if len(rows) < days:
        return None
    return [{"date": r[0], "open": r[1], "close": r[2], "high": r[3], "low": r[4],
             "volume": r[5]} for r in reversed(rows)]


def upsert(code6: str, bars: list):
    if not bars:
        return
    with _write_lock:
        c = _conn()
        c.executemany(
            "INSERT OR REPLACE INTO kline(code,date,open,close,high,low,volume)"
            " VALUES(?,?,?,?,?,?,?)",
            [(code6, b["date"], b["open"], b["close"], b["high"], b["low"], b["volume"])
             for b in bars])
        c.commit()
        c.close()


def fetch_tencent(code6: str, days: int = 800):
    """腾讯前复权日K(网络)。建库拉 800,日常增量拉 5。失败返回 None。"""
    sym = _pref(code6)
    for attempt in range(2):
        try:
            url = (f"https://ifzq.gtimg.cn/appstock/app/fqkline/get?"
                   f"param={sym},day,,,{days},qfq")
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=12) as f:
                d = json.loads(f.read().decode())
            rows = d["data"][sym].get("qfqday") or d["data"][sym].get("day") or []
            if rows:
                return [{"date": r[0], "open": float(r[1]), "close": float(r[2]),
                         "high": float(r[3]), "low": float(r[4]), "volume": float(r[5])}
                        for r in rows]
        except Exception:
            pass
        if attempt == 0:
            time.sleep(1)
    return None


def fetch_sina(code6: str, days: int = 250):
    """新浪日K备用源(断板/涨跌幅判定对复权口径不敏感)。"""
    sym = _pref(code6)
    try:
        u2 = (f"https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData"
              f"?symbol={sym}&scale=240&ma=no&datalen={days}")
        req = urllib.request.Request(u2, headers={"User-Agent": UA["User-Agent"],
                                                  "Referer": "https://finance.sina.com.cn"})
        with urllib.request.urlopen(req, timeout=10) as f:
            rows = json.loads(f.read().decode())
        if rows:
            return [{"date": r["day"], "open": float(r["open"]), "close": float(r["close"]),
                     "high": float(r["high"]), "low": float(r["low"]), "volume": float(r["volume"])}
                    for r in rows]
    except Exception:
        pass
    return None


def build(codes, full: bool = True, workers: int = 6, progress_every: int = 200):
    """建库/增量:多线程拉取并入库。
    full=True:每只拉 800 根(建库);full=False:每只拉 5 根(每日增量,拼接去重)。
    返回 {"ok": n, "fail": n, "bars": n}。"""
    lock = threading.Lock()
    state = {"ok": 0, "fail": 0, "bars": 0, "done": 0}
    total = len(codes)

    def worker(chunk):
        for code6, _name in chunk:
            bars = fetch_tencent(code6, 800 if full else 5)
            if bars is None:
                bars = fetch_sina(code6, 250 if full else 5)
            if bars:
                upsert(code6, bars)
                with lock:
                    state["ok"] += 1
                    state["bars"] += len(bars)
            else:
                with lock:
                    state["fail"] += 1
            with lock:
                state["done"] += 1
                if state["done"] % progress_every == 0:
                    print(f"[kline] {state['done']}/{total} · ok={state['ok']}"
                          f" fail={state['fail']} bars={state['bars']}", flush=True)
            time.sleep(0.25)   # 节流纪律:腾讯密集拉会被限流

    chunks = [[] for _ in range(workers)]
    for i, item in enumerate(codes):
        chunks[i % workers].append(item)
    threads = [threading.Thread(target=worker, args=(ch,), daemon=True) for ch in chunks]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return state


_SNAP = {"bars": {}, "at": 0.0}


def snapshot_today_bars(codes6, force: bool = False, ttl: int = 300):
    """腾讯批量快照→合成当日K线 {code: bar}(量×100:手→股,与库口径一致)。
    14:55 选股/结算用:库里 K 线至昨天,当日实时数据靠快照拼接(8787 同款口径)。"""
    # 缓存需覆盖全部请求 codes(逐票调用时首只缓存不能顶替其余票);新拉取合并入缓存
    if (not force and _SNAP["bars"] and time.time() - _SNAP["at"] < ttl
            and all(c in _SNAP["bars"] for c in codes6)):
        return _SNAP["bars"]
    import urllib.request as _ur
    bars = {}
    uniq = list(dict.fromkeys(codes6))
    B = 400
    for i in range(0, len(uniq), B):
        chunk = uniq[i:i+B]
        q = ",".join(_pref(c) for c in chunk)
        try:
            raw = _ur.urlopen(_ur.Request(f"http://qt.gtimg.cn/q={q}", headers=UA),
                              timeout=10).read().decode("gbk", "ignore")
        except Exception:
            continue
        for seg in raw.split(";"):
            pp = seg.split('"')
            if len(pp) < 2:
                continue
            f = pp[1].split("~")
            if len(f) < 35:
                continue
            try:
                ts = f[30]
                d = f"{ts[:4]}-{ts[4:6]}-{ts[6:8]}"
                close = float(f[3]); op = float(f[5]); pv = float(f[4])
                vol_shares = float(f[6]) * 100   # 快照=手 → 股(库同口径)
                high = float(f[33]); low = float(f[34])
                if close <= 0 or vol_shares <= 0:
                    continue
                bars[f[2]] = {"date": d, "open": op, "close": close, "prev_close": pv,
                              "high": high, "low": low, "volume": vol_shares}
            except Exception:
                continue
        time.sleep(0.08)
    if bars:
        if time.time() - _SNAP["at"] < ttl:
            _SNAP["bars"].update(bars)   # 合并(逐票调用累积)
        else:
            _SNAP["bars"] = bars
        _SNAP["at"] = time.time()
        return _SNAP["bars"]
    return bars


def daily_increment(codes=None):
    """每日增量:库内票拉最近 5 根拼接;池内新票(库外)首次全量 800 根。
    codes 缺省=当前 universe(全池);返回统计。"""
    if codes is None:
        try:
            from services.selection import universe
            codes = universe()
        except Exception:
            c = _conn()
            codes = [(r[0], "") for r in c.execute("SELECT DISTINCT code FROM kline").fetchall()]
            c.close()
    c = _conn()
    have = {r[0] for r in c.execute("SELECT DISTINCT code FROM kline").fetchall()}
    c.close()
    inc = [(code, n) for code, n in codes if code in have]
    new = [(code, n) for code, n in codes if code not in have]
    r1 = build(inc, full=False) if inc else {"ok": 0, "fail": 0}
    r2 = build(new, full=True) if new else {"ok": 0, "fail": 0}
    return {"increment": r1, "new_full": r2,
            "ok": r1.get("ok", 0) + r2.get("ok", 0),
            "fail": r1.get("fail", 0) + r2.get("fail", 0)}


def merge_4h(bars):
    """60 分钟 K → 4 小时 K(连续 4 根合一)。兼容 dict 与 czsc RawBar 两种元素。"""
    if not bars:
        return []
    out = []
    n = len(bars) - len(bars) % 4
    for i in range(0, n, 4):
        g = bars[i:i + 4]
        if hasattr(g[0], "open"):   # RawBar
            out.append(type(g[0])(
                symbol=g[0].symbol, dt=g[-1].dt,
                open=g[0].open, close=g[-1].close,
                high=max(b.high for b in g), low=min(b.low for b in g),
                vol=sum(b.vol for b in g), amount=sum(getattr(b, "amount", 0) or 0 for b in g),
                freq=g[0].freq))
        else:
            out.append({"date": g[-1]["date"], "open": g[0]["open"], "close": g[-1]["close"],
                        "high": max(b["high"] for b in g), "low": min(b["low"] for b in g),
                        "volume": sum(b["volume"] for b in g)})
    return out
