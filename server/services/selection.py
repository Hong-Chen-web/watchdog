"""涨停缩量二波策略(2026-09 定版,与 8787 年度回测口径对齐;2026-10-13 出场规则修订)。

六条件:①近10交易日涨停过 ②趋势(收盘>MA20且MA20向上) ③剔ST/退
④当日量≤涨停日量50%且≥15% ⑤所属行业当日涨停≥3家(本地行业图+全池快照,不逐票联网)
⑥涨停日主力净占比≥15%(东财fflow f57主力净占比,永久缓存,失败不拦)。
数据源:清单/K线/快照=腾讯,行业分类=新浪(腾讯无公开成员接口),东财仅保留⑥这一项原始数据。
排序=缩量30+梯队25+主力20+新鲜度10+趋势10+卫生5(4日前涨停最佳)。
同票冷却5个交易日(以卖出日计,trade_cooldown.json)。
买入=评分前三(受持仓上限3只约束:当日可买=3-当前持仓数,空位为0则不买),选股日14:57按收盘价,buy_price锁定;一字涨停买不进顺延次名。
候选预筛=近10交易日涨停滚动集(limit_roll.json),只对涨停过的票做完整评估。
出场(次一交易日起逐票):跌停→跌停价跑(一字跌停封死顺延次日)
>炸板累计>3→走 >收盘涨停→续命 >无涨停无跌停:持仓满3个交易日(含买入日)尾盘走,未满继续持有。
"""
import json
import re
import time
import urllib.request
from datetime import date, datetime
import db as dbm2
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent.parent / "data"
DATA.mkdir(exist_ok=True)
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
      "Referer": "https://quote.eastmoney.com/"}
HIST = DATA / "backtest_tail_history.json"
COOLDOWN = DATA / "trade_cooldown.json"   # {code6: 卖出日}(以实盘卖出日为准)


def _pref(code6: str) -> str:
    return ("sh" if code6[0] == "6" else "bj" if code6[0] in "48" else "sz") + code6


def _secid(code6: str) -> str:
    return ("1." if code6[0] == "6" else "0.") + code6


# ---------- 行情/K线 ----------

def tencent_daily(code6: str, days: int = 120):
    """日K(库优先+当日快照):库命中←毫秒级,并拼接当日快照K线(盘中实时);
    不足才网络补(腾讯→新浪)并入库。调用方不得把 None 当"无数据/无票"静默吞。"""
    try:
        from services import kline_store
        bars = kline_store.get_daily(code6, days)
        if bars:
            today = kline_store.snapshot_today_bars([code6]).get(code6)
            if today and bars[-1]["date"] < today["date"]:
                bars = (bars + [today])[-days:]
            return bars
    except Exception:
        pass
    bars = _net_daily(code6, days)
    if bars:
        try:
            from services import kline_store
            kline_store.upsert(code6, bars)
        except Exception:
            pass
    return bars


def _net_daily(code6: str, days: int = 120):
    """网络源(库未命中时):腾讯主源(前复权)→重试→新浪备用。"""
    sym = _pref(code6)
    for attempt in range(2):
        url = (f"https://ifzq.gtimg.cn/appstock/app/fqkline/get?"
               f"param={sym},day,,,{days},qfq")
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=8) as f:
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
    try:
        u2 = (f"https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData"
              f"?symbol={sym}&scale=240&ma=no&datalen={days}")
        req = urllib.request.Request(u2, headers={"User-Agent": UA["User-Agent"],
                                                  "Referer": "https://finance.sina.com.cn"})
        with urllib.request.urlopen(req, timeout=8) as f:
            rows = json.loads(f.read().decode())
        if rows:
            return [{"date": r["day"], "open": float(r["open"]), "close": float(r["close"]),
                     "high": float(r["high"]), "low": float(r["low"]), "volume": float(r["volume"])}
                    for r in rows]
    except Exception:
        pass
    return None


# ---------- 候选池(全A;剔ST/退/N/C) ----------

UNIVERSE_CACHE = DATA / "universe_cache.json"


def _universe_tencent():
    """腾讯批量行情探测全A(代码段扫描):10 秒级重建,东财/交易所都不可用时的可靠源。"""
    import urllib.parse

    def probe(codes):
        q = ",".join(codes)
        try:
            raw = urllib.request.urlopen(urllib.request.Request(
                f"http://qt.gtimg.cn/q={q}", headers={"User-Agent": UA["User-Agent"]}),
                timeout=10).read().decode("gbk", "ignore")
        except Exception:
            return []
        out = []
        for seg in raw.split(";"):
            pp = seg.split('"')
            if len(pp) < 2:
                continue
            f = pp[1].split("~")
            if len(f) > 3 and f[1] and f[2]:
                out.append((f[2], f[1]))
        return out

    spaces = ([f"sh{600000+i}" for i in range(6000)] +
              [f"sh{688000+i}" for i in range(2000)] +
              [f"sz{1+i:06d}" for i in range(3999)] +
              [f"sz{300000+i}" for i in range(2000)])
    found = {}
    B = 400
    for i in range(0, len(spaces), B):
        for code, name in probe(spaces[i:i+B]):
            found[code] = name.replace(" ", "")
        time.sleep(0.12)
    out = [(c, n) for c, n in found.items()
           if not any(t in n for t in ("ST", "退", "N", "C"))]
    out.sort(key=lambda x: x[0])
    if len(out) > 1000:
        try:
            UNIVERSE_CACHE.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
            print(f"[watchdog] universe 腾讯探测重建: {len(out)} 只")
        except Exception:
            pass
    return out if len(out) > 1000 else []


def _pool_clean(lst):
    """池清洗:剔北交/退/B(4/8/9开头);按代码升序(评分并列时的顺延口径,可复现)。"""
    out = [(c, n or "") for c, n in lst if not str(c).startswith(("4", "8", "9"))]
    out.sort(key=lambda x: x[0])
    return out


def universe():
    """全A候选(腾讯优先):当日缓存→腾讯批量探测→新浪hs_a清单→旧缓存→库内兜底。"""
    # 当日缓存直接复用(池子天级稳定;腾讯重建≈10秒,重建即落盘)
    try:
        st = UNIVERSE_CACHE.stat()
        if datetime.fromtimestamp(st.st_mtime).date() == date.today():
            cached = json.loads(UNIVERSE_CACHE.read_text(encoding="utf-8"))
            if len(cached) > 1000:
                out = _pool_clean(cached)
                if len(out) != len(cached):
                    try:
                        UNIVERSE_CACHE.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
                    except Exception:
                        pass
                return out
    except Exception:
        pass
    tw = _universe_tencent()
    if tw:
        return tw
    # 旧缓存(前日全A)
    try:
        cached = json.loads(UNIVERSE_CACHE.read_text(encoding="utf-8"))
        if len(cached) > 1000:
            print(f"[watchdog] universe 用缓存池: {len(cached)} 只")
            return _pool_clean(cached)
    except Exception:
        pass
    # 新浪 hs_a 清单(仅代码)
    try:
        rs = urllib.request.urlopen(urllib.request.Request(
            "https://vip.stock.finance.sina.com.cn/hs_a/dividend",
            headers={"User-Agent": UA["User-Agent"]}), timeout=10)
        codes = re.findall(r'symbol=(?:sh|sz)(\d{6})', rs.read().decode("gbk", "ignore"))
        seen, lst = set(), []
        for c in codes:
            if c not in seen and not c.startswith(("8", "4", "9")):
                seen.add(c)
                lst.append((c, ""))
        if len(lst) > 100:
            lst.sort(key=lambda x: x[0])
            try:
                UNIVERSE_CACHE.write_text(json.dumps(lst, ensure_ascii=False), encoding="utf-8")
            except Exception:
                pass
            return lst
    except Exception:
        pass
    # 最后兜底:库内(自选+历史)
    import db as dbm
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        rows = conn.execute(
            "SELECT DISTINCT w.code, COALESCE(w.name,'') name FROM watchlist w"
            " UNION SELECT DISTINCT t.code, COALESCE(t.name,'') FROM chan_trades t").fetchall()
        return [(r["code"], r["name"]) for r in rows]
    finally:
        conn.close()


# ---------- 条件⑤梯队(本地行业图+当日涨停集,不逐票联网) ----------

IND_MAP = DATA / "industry_map.json"      # {code6: 新浪行业节点}(7天重建一次)
_IND = None
_ZT_TODAY = set()                          # run_selection 每次刷新:当日涨幅≥9.9%代码集


def _industry_map():
    """{code6: 行业节点}: 新浪行业板块成员全量建图(缓存7天;失败返空→梯队不拦)。"""
    global _IND
    if _IND is not None:
        return _IND
    try:
        if time.time() - IND_MAP.stat().st_mtime < 7 * 86400:
            _IND = json.loads(IND_MAP.read_text(encoding="utf-8"))
            return _IND
    except Exception:
        pass
    out = {}
    try:
        raw = urllib.request.urlopen(urllib.request.Request(
            "http://vip.stock.finance.sina.com.cn/q/view/newSinaHy.php",
            headers={"User-Agent": UA["User-Agent"], "Referer": "https://finance.sina.com.cn"}),
            timeout=10).read().decode("gbk", "ignore")
        for node in re.findall(r'"(new_\w+)":"', raw):
            page = 1
            while page <= 12:
                try:
                    u = ("https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/"
                         f"Market_Center.getHQNodeData?page={page}&num=80&sort=symbol&asc=1&node={node}")
                    arr = json.loads(urllib.request.urlopen(urllib.request.Request(
                        u, headers={"User-Agent": UA["User-Agent"],
                                    "Referer": "https://finance.sina.com.cn"}), timeout=10)
                        .read().decode("utf-8", "ignore"))
                except Exception:
                    break
                if not arr:
                    break
                for x in arr:
                    c = str(x.get("code") or "")
                    if len(c) == 6 and not c.startswith(("8", "4", "9")):
                        out[c] = node
                page += 1
                time.sleep(0.05)
    except Exception:
        pass
    _IND = out
    if len(out) > 4000:      # 半截图不落盘(避免残缺缓存污染7天);进程内仍用本次结果
        try:
            IND_MAP.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass
    print(f"[watchdog] 行业图重建: {len(out)} 只", flush=True)
    return out


def _echelon_count(code6: str):
    """条件⑤:所属行业当日涨停家数(本地行业图+快照集;None=数据缺,不拦)。"""
    m = _industry_map()
    ind = m.get(code6)
    if not ind or not _ZT_TODAY:
        return None
    return sum(1 for c in _ZT_TODAY if m.get(c) == ind)


FFLOW_CACHE = DATA / "fflow_cache.json"   # {code: {date: 主力净占比%}}


def _mainforce_pct(code6: str, zt_date: str):
    """条件⑥:涨停日主力净占比%(东财fflow f57=主力净额/成交额;永久缓存,同票同日只拉一次)。
    腾讯该接口已下线,此为本策略仅存的一处东财原始数据;失败=None(不拦)。"""
    try:
        cache = json.loads(FFLOW_CACHE.read_text())
    except Exception:
        cache = {}
    row = cache.get(code6) or {}
    if zt_date in row:
        return row[zt_date]
    pct = None
    try:
        import requests
        sess = requests.Session()
        sess.trust_env = False
        for host in ("push2his.eastmoney.com", "push2.eastmoney.com"):
            try:
                r = sess.get(
                    f"https://{host}/api/qt/stock/fflow/daykline/get",
                    params={"lmt": 15, "klt": 101, "secid": _secid(code6),
                            "fields1": "f1,f2,f3,f7",
                            "fields2": "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63,f64,f65"},
                    headers=UA, timeout=5)
                rows = (r.json().get("data") or {}).get("klines") or []
                for line in rows:
                    p = line.split(",")
                    if len(p) > 6:
                        try:
                            cache.setdefault(code6, {})[p[0]] = round(float(p[6]), 2)
                        except Exception:
                            continue
                pct = (cache.get(code6) or {}).get(zt_date)
                break
            except Exception:
                continue
    except Exception:
        pass
    try:
        FFLOW_CACHE.write_text(json.dumps(cache, ensure_ascii=False))
    except Exception:
        pass
    return pct


# ---------- 六条件打分 ----------

def score_stock(code6: str, k, name: str = ""):
    """六条件+六因子加权(缩量30/梯队25/主力20/新鲜度10/趋势10/卫生5)。
    硬条件不满足返回 None;梯队/主力网络失败不扣分不拦(原版容灾口径)。"""
    if not k or len(k) < 30:
        return None
    if name and any(t in name for t in ("ST", "退", "N", "C")):
        return None
    closes = [x["close"] for x in k]
    vols = [x["volume"] for x in k]

    # ① 近10交易日涨停过(主板10%/双创20%);新鲜度只进排序,不做硬门槛
    lim_days = []
    for i in range(max(1, len(k) - 10), len(k)):
        prev = closes[i - 1]
        lim_pct = 19.9 if code6[:3] in ("300", "301", "688") else 9.9
        if (closes[i] / prev - 1) * 100 >= lim_pct - 0.3:
            lim_days.append(i)
    if not lim_days:
        return None
    last_lim = lim_days[-1]
    ago = len(k) - 1 - last_lim

    # ② 趋势:收盘>MA20 且 MA20向上
    ma20 = sum(closes[-20:]) / 20
    ma20_prev = sum(closes[-21:-1]) / 20
    trend_ok = closes[-1] > ma20 and ma20 > ma20_prev
    if not trend_ok:
        return None

    # ④ 缩量:当日量∈[15%,50%]×涨停日量
    v_today, v_lim = vols[-1], vols[last_lim]
    if v_lim <= 0:
        return None
    ratio = v_today / v_lim
    if not (0.15 <= ratio <= 0.5):
        return None

    # ⑤ 梯队:行业当日涨停≥3家(None=网络失败不拦)
    ech = _echelon_count(code6)
    if ech is not None and ech < 3:
        return None

    # ⑥ 涨停日主力净占比≥15%(None=不拦)
    mf = _mainforce_pct(code6, k[last_lim]["date"])
    if mf is not None and mf < 15:
        return None

    # 可核验数据链:涨停日量/当日量/量比三件套+梯队+主力
    hits = [
        f"{ago}日前涨停" if ago > 0 else "昨涨停",
        f"涨停日量{v_lim/1e4:.0f}万手",
        f"当日量{v_today/1e4:.0f}万手",
        f"缩量{ratio*100:.0f}%",
    ] + ([f"梯队{ech}家"] if ech is not None else []) \
      + ([f"主力{mf:.0f}%"] if mf is not None else [])

    score = (30 if ratio <= 0.3 else 20)
    score += 25 if (ech or 0) >= 5 else (15 if (ech or 0) >= 3 else 0)
    score += 20 if (mf or 0) >= 30 else (12 if (mf or 0) >= 15 else 0)
    score += 10 if ago == 4 else (7 if ago < 4 else 4)
    score += 10 if trend_ok else 0
    score += 5
    return min(score, 100), hits


# ---------- 冷却簿(同票5个交易日,以卖出日计) ----------

def _cooldown_map():
    try:
        return json.loads(COOLDOWN.read_text())
    except Exception:
        return {}


def _in_cooldown(code6: str, k) -> bool:
    sold = _cooldown_map().get(code6)
    if not sold:
        return False
    dates = [x["date"] for x in k]
    if sold not in dates:
        return False
    return len(dates) - 1 - dates.index(sold) < 5


# ---------- 一字板 ----------

def _is_one_word_limit_up(k):
    """当日一字涨停(开盘涨停且未开板):买不进,顺延次名。"""
    if len(k) < 2:
        return False
    prev = k[-2]["close"]
    lim = prev * 1.0995
    return k[-1]["open"] >= lim and k[-1]["low"] >= lim - 0.001


def _is_sealed_limit_down(k):
    """收盘封死跌停(卖不出):顺延次日。"""
    if len(k) < 2:
        return False
    prev = k[-2]["close"]
    lim_dn = prev * 0.9005
    return k[-1]["close"] <= lim_dn and k[-1]["open"] <= lim_dn


# ---------- 近10交易日涨停滚动集(选股预筛:只对涨停过的票做完整评估) ----------

ROLL = DATA / "limit_roll.json"


def _index_trade_days(n=11):
    """最近 n 个交易日:库内大票日期序列(离线;盘中库里少今天则补今天)。失败 None。"""
    from services import kline_store as _ks
    dates = []
    for probe in ("600000", "600519", "000001", "600036", "000002"):
        try:
            k = _ks.get_daily(probe, n + 5)
        except Exception:
            k = None
        if k and len(k) >= n:
            dates = [x["date"] for x in k][-n:]
            break
    if not dates:
        return None
    today = date.today().strftime("%Y-%m-%d")
    if dates[-1] < today and _is_trade_day():
        dates = (dates + [today])[1:] if len(dates) >= n else dates + [today]
    return dates[-n:]


def _roll_rebuild(w10):
    """全池扫库重建近10交易日涨停图(仅断档时,~1分钟,一次性)。"""
    from services import kline_store as _ks
    wset, codes = set(w10), {}
    for code6, _n in universe():
        try:
            k = _ks.get_daily(code6, 30)
        except Exception:
            k = None
        if not k or len(k) < 2:
            continue
        lim = 19.9 if code6[:3] in ("300", "301", "688") else 9.9
        for i in range(1, len(k)):
            if k[i]["date"] in wset and k[i - 1]["close"] > 0 \
                    and (k[i]["close"] / k[i - 1]["close"] - 1) * 100 >= lim - 0.3:
                codes.setdefault(code6, []).append(k[i]["date"])
    return {"through": w10[-2], "codes": codes}


def _roll_candidates(zt_today, today):
    """维护滚动集并返回候选码集(近10交易日涨停过);失败返 None→调用方走全池。"""
    win = _index_trade_days(11) or []
    if len(win) < 5 or win[-1] != today:      # 非交易日/日历拿不到→不预筛
        return None
    w10 = set(win[-10:])
    try:
        roll = json.loads(ROLL.read_text())
    except Exception:
        roll = {}
    if not roll or roll.get("through") != win[-2]:   # 断档→全池重建
        roll = _roll_rebuild(win[-10:])
    codes = roll.setdefault("codes", {})
    for c in list(codes):                     # 清窗口外日期
        codes[c] = [d for d in codes[c] if d in w10]
        if not codes[c]:
            del codes[c]
    for c in zt_today:                        # 今日涨停并入
        ds = codes.get(c, [])
        if today not in ds:
            ds.append(today)
        codes[c] = ds
    roll["through"] = today
    try:
        ROLL.write_text(json.dumps(roll, ensure_ascii=False))
    except Exception:
        pass
    return set(codes)


# ---------- 选股(建轮档案+锁定前三买价) ----------

def run_selection(archive: bool = True):
    """六条件→六因子排序→冷却过滤→前三锁定买价(一字板顺延次名)。
    archive=True(14:55 自动跑):写名单+建轮档案(进台账/持仓生命周期)。"""
    global _ZT_TODAY
    out = []
    stale = 0
    today_s = date.today().strftime("%Y-%m-%d")
    require_today = _require_today_bar()
    pool = universe()
    zt_today = set()
    try:
        from services import kline_store as _ks0
        snap = _ks0.snapshot_today_bars([c for c, _ in pool], force=True)   # 全池当日快照(一次批量)
        zt_today = {c for c, b in (snap or {}).items()
                    if b.get("prev_close") and b["prev_close"] > 0
                    and b["close"] / b["prev_close"] - 1 >= 0.099}          # 当日涨停集(宽阈口径)
    except Exception:
        snap = {}
    _ZT_TODAY = zt_today
    if require_today and not snap:
        raise RuntimeError("当日行情快照为空:中止选股(不拿昨日数据充当日)")
    # 近10交易日涨停滚动集预筛(只评估涨停过的票;拿不到日历→全池,不误杀)
    try:
        cand = _roll_candidates(zt_today, date.today().strftime("%Y-%m-%d"))
        if cand:
            pool = [(c, n) for c, n in pool if c in cand]
            print(f"[watchdog] 涨停滚动集: 候选 {len(pool)} 只", flush=True)
    except Exception:
        pass
    # 持仓中的票排除(资金已占用,续命判定走 settle;同一笔钱不花两次)
    holding = set()
    try:
        _d = json.loads(HIST.read_text())
        for _r in _d.get("rounds", []):
            for _s in _r.get("stocks", []):
                if _s.get("buy_price") is not None and not _s.get("_exit_why"):
                    holding.add(_s["code"].split(".")[-1])
    except Exception:
        pass
    for code6, name in pool:
        if code6 in holding:
            continue
        from services import kline_store as _ks
        kline_hit = _ks.get_daily(code6, 120) is not None
        k = tencent_daily(code6, 120)
        if not k:
            continue
        if require_today and k[-1]["date"] < today_s:
            stale += 1
            continue
        if _in_cooldown(code6, k):
            continue
        r = score_stock(code6, k, name)
        if r:
            out.append({"code": code6, "name": name, "score": r[0],
                        "hits": r[1], "price": k[-1]["close"], "_k": k})
        # K线库命中(无网络IO)不节流;未命中走了网络才 sleep 防限流
        if not kline_hit:
            time.sleep(0.25)
    if stale and not out:
        raise RuntimeError(f"{stale} 只均缺当日行情:中止选股(不拿昨日数据充当日)")
    out.sort(key=lambda x: -x["score"])
    top = out[:10]

    buys = []
    cap = 3 - len(holding)          # 持仓上限3只(2026-10-13):当日可买=空位数
    for s in top:
        if len(buys) >= cap:
            break
        if _is_one_word_limit_up(s["_k"]):
            s["hits"] = (s["hits"] or []) + ["一字板顺延"]
            continue
        buys.append(s)
    for s in top:
        s.pop("_k", None)

    day = date.today().strftime("%Y-%m-%d")
    picks = [{"code": s["code"], "name": s["name"], "score": s["score"],
              "hits": s["hits"], "price": s["price"]} for s in top]
    (DATA / "recommended_tail.json").write_text(
        json.dumps({"date": day, "stocks": picks,
                    "generated_at": datetime.now().isoformat()}, ensure_ascii=False))

    if archive and buys:
        try:
            d = json.loads(HIST.read_text())
        except Exception:
            d = {"rounds": []}
        stocks = [{"code": s["code"], "name": s["name"], "price": s["price"],
                   "score": s["score"], "hits": s["hits"],
                   "buy_price": s["price"]} for s in buys]
        d["rounds"] = [r for r in d.get("rounds", []) if r.get("date") != day]
        d["rounds"].append({"date": day, "stocks": stocks})
        HIST.write_text(json.dumps(d, ensure_ascii=False))
    return picks


# ---------- 手动立即选股(自选行情卡「策略信号」按钮) ----------

_RUN = {"running": False, "started_at": None, "finished_at": None,
        "picks": 0, "error": None}


def run_async() -> bool:
    """后台线程立即跑一轮选股(archive=False:只算名单刷新展示,不碰已执行轮——
    14:55 官方跑负责归档+锁价+推卡);进行中重复点击忽略。"""
    import threading
    if _RUN["running"]:
        return False
    _RUN.update({"running": True,
                 "started_at": datetime.now().isoformat(timespec="seconds"),
                 "finished_at": None, "picks": 0, "error": None})

    def work():
        try:
            picks = run_selection(archive=False)
            _RUN["picks"] = len(picks or [])
        except Exception as e:
            _RUN["error"] = str(e)
        finally:
            _RUN["running"] = False
            _RUN["finished_at"] = datetime.now().isoformat(timespec="seconds")
            print(f"[watchdog] 手动选股完成: {_RUN['picks']} 只"
                  + (f" (err={_RUN['error']})" if _RUN["error"] else ""), flush=True)

    threading.Thread(target=work, daemon=True, name="manual-selection").start()
    return True


def run_status() -> dict:
    return dict(_RUN)


# ---------- 结算(逐票生命周期) ----------

def settle_all():
    """次一交易日起逐票评估:跌停→跌停价跑(封死顺延次日)>炸板累计>3→走
    >收盘涨停→续命>无涨停无跌停且持仓满3交易日(含买入日)→尾盘走,未满则持有。
    出场写冷却簿+镜像。"""
    try:
        d = json.loads(HIST.read_text())
    except Exception:
        d = {"rounds": []}
    settled = []
    failed = []
    cool = _cooldown_map()
    changed = False
    today_s = date.today().strftime("%Y-%m-%d")
    require_today = _require_today_bar()
    for r in d.get("rounds", []):
        if r.get("settled"):
            continue
        bought = [s for s in r.get("stocks", []) if s.get("buy_price") is not None]
        if not bought:
            continue
        for s in bought:
            if s.get("_exit_why"):
                continue
            code6 = s["code"].split(".")[-1]
            k = tencent_daily(code6, 15)
            if not k:
                failed.append(f"{s['name']}(K线源失败)")
                continue
            if require_today and k[-1]["date"] < today_s:
                # 当日快照缺失(断网/停牌):绝不拿昨日K线当今日评估,持仓原样保留
                failed.append(f"{s['name']}(当日行情缺失,未评估)")
                continue
            today, prev = k[-1], k[-2]["close"]
            if today["date"] <= r["date"]:      # 买入当日不评估
                continue
            chg = (today["close"] / prev - 1) * 100
            lim_pct = 19.9 if code6[:3] in ("300", "301", "688") else 9.9
            lim_up_px = prev * (1 + lim_pct / 100)
            exit_why = None
            if chg <= -lim_pct + 0.3:
                if _is_sealed_limit_down(k):
                    s["_hold_note"] = f"跌停封死卖不出({today['date']})"
                else:
                    exit_why = "跌停即跑"
            elif today["high"] >= lim_up_px - 0.01 and today["close"] < lim_up_px - 0.01:
                n = int(s.get("_broken_count", 0)) + 1
                s["_broken_count"] = n
                changed = True
                if n > 3:
                    exit_why = f"炸板{n}次离场"
            elif chg >= lim_pct - 0.3:
                pass                                              # 涨停续命
            else:
                # 无涨停无跌停(2026-10-13新规):持仓满3个交易日(含买入日)→尾盘走,未满继续持有
                hold_days = sum(1 for x in k if r["date"] <= x["date"] <= today["date"])
                if hold_days >= 3:
                    exit_why = f"断板离场·第{hold_days}日"
                else:
                    s["_hold_note"] = f"持有中(第{hold_days}/3交易日)"
                    changed = True
            if exit_why:
                s["_exit_why"] = f"{exit_why}({today['date']})"
                s["_exit_px"] = today["close"]
                s.pop("_hold_note", None)      # 出场后不留“持有中(第N/3日)”旧备注
                cool[code6] = today["date"]
                changed = True
                settled.append({"date": r["date"], "name": s["name"], "why": exit_why,
                                "px": today["close"], "code": code6,
                                "buy": s.get("buy_price")})
                # 策略票卖出→自动移出自选(仅系统来源且该票已无任何持仓)
                try:
                    still = any(
                        s2.get("buy_price") and not s2.get("_exit_why")
                        for rd in d.get("rounds", []) for s2 in rd.get("stocks", [])
                        if s2["code"].split(".")[-1] == code6)
                    if not still:
                        conn2 = dbm2.connect()
                        conn2.execute(
                            "DELETE FROM watchlist WHERE code=? AND source='system'", (code6,))
                        conn2.commit(); conn2.close()
                except Exception:
                    pass
            time.sleep(0.25)
        if all(s.get("_exit_why") for s in bought):
            r["settled"] = True
            changed = True
    if changed:
        HIST.write_text(json.dumps(d, ensure_ascii=False))
        COOLDOWN.write_text(json.dumps(cool, ensure_ascii=False))
        try:
            from services.chan_backtest_mirror import sync_chan_backtest
            sync_chan_backtest()
        except Exception:
            pass
        # 出场盈亏回填(chan_trades 权威净额;缺失按价差百分比兜底)
        if settled:
            try:
                import db as dbm3
                conn3 = dbm3.connect()
                for x in settled:
                    row = conn3.execute(
                        "SELECT net, pct FROM chan_trades"
                        " WHERE round_date=? AND code=? AND net IS NOT NULL",
                        (x["date"], x["code"])).fetchone()
                    if row:
                        x["net"], x["pct"] = row[0], row[1]
                    elif x.get("buy"):
                        x["pct"] = round((x["px"] / x["buy"] - 1) * 100, 2)
                conn3.close()
            except Exception:
                pass
    if failed:
        print("[watchdog] settle 数据源失败(下轮再试):", failed)
    return {"settled": settled, "failed": failed}


# ---------- 调度(14:55,交易日;错过窗口有网自动补) ----------

def _is_trade_day() -> bool:
    try:
        with urllib.request.urlopen("http://qt.gtimg.cn/q=sh000001", timeout=4) as f:
            raw = f.read().decode("gbk", "ignore")
        return raw.split("~")[30][:8] == date.today().strftime("%Y%m%d")
    except Exception:
        return datetime.now().weekday() < 5


def _require_today_bar() -> bool:
    """结算/选股是否必须拿到“今天”的K线:交易日 09:30 后(含盘后)一律要求。

    2026-10-21 事故:断网时当日快照失败,日K只到昨天,结算把昨天当今天
    (第3/3日卖出被算成第2/3日持有),选股也拿昨收当现价——必须显式中止。
    """
    return _is_trade_day() and datetime.now().strftime("%H:%M") >= "09:30"


SCHED_MARK = DATA / "selection_sched.json"   # 仅调度器写;手动跑不写→不抑制14:55官方跑


def _ran_today(day: str) -> bool:
    try:
        return json.loads(SCHED_MARK.read_text()).get("date") == day
    except Exception:
        return False


def _pl_cell(x) -> str:
    """卖出卡盈亏单元格:A股红涨绿跌,+金额(百分比);缺数据显 —。"""
    net, pct = x.get("net"), x.get("pct")
    if net is None and pct is None:
        return "—"
    pos = (net or 0) > 0 or (net is None and (pct or 0) > 0)
    neg = (net or 0) < 0 or (net is None and (pct or 0) < 0)
    color = "red" if pos else ("green" if neg else "grey")
    amt = f"{net:+,.0f}元" if net is not None else ""
    pp = f"({pct:+.2f}%)" if pct is not None else ""
    return f"<font color='{color}'>{amt} {pp}</font>".strip()


def start_scheduler():
    import threading

    def loop():
        while True:
            try:
                now = datetime.now()
                hm = now.strftime("%H:%M")
                day = now.strftime("%Y-%m-%d")
                if (_is_trade_day() and not _ran_today(day) and hm >= "14:55"):
                    caught_up = hm >= "15:05"
                    r = settle_all()
                    if r.get("failed") and hm < "15:30":
                        print(f"[watchdog] 结算未完成({len(r['failed'])}只),60s 后重试", flush=True)
                        time.sleep(60)
                        continue
                    picks = run_selection(archive=True)
                    try:
                        SCHED_MARK.write_text(json.dumps(
                            {"date": day,
                             "at": datetime.now().isoformat(timespec="seconds")}))
                    except Exception:
                        pass
                    print(f"[watchdog] 选股{'补跑' if caught_up else ''}完成:"
                          f"{len(picks)} 只;结算 {len(r.get('settled', []))} 笔")
                    try:
                        from services.feishu_push import ensure_push
                        day2 = day
                        st = r.get("settled") or []
                        if st:
                            ensure_push("settle", f"💰 卖出卡 · {len(st)}笔", "",
                                f"settle:{day2}",
                                rows=[{"股票": x["name"], "原因": x["why"],
                                       "卖价": f"**{x['px']}**",
                                       "盈亏": _pl_cell(x)} for x in st])
                        d2 = json.loads(HIST.read_text())
                        hold = [s2 for rd in d2["rounds"] for s2 in rd.get("stocks", [])
                                if s2.get("buy_price") and not s2.get("_exit_why")]
                        if hold:
                            ensure_push("holding_daily", f"💼 持仓卡 · {len(hold)}只", "",
                                f"holding:{day2}",
                                rows=[{"股票": h["name"], "买价": h["buy_price"],
                                       "状态": h.get("_hold_note") or "持仓中(按规则评估)"}
                                      for h in hold],
                                footer=f"评估口径:跌停跑>炸板3走>涨停续命>无涨跌停满3交易日走")
                        if picks:
                            ensure_push("selection", f"⚡ 选股卡 · {len(picks)}只", "",
                                f"selection:{day2}",
                                rows=[{"名次": i + 1, "股票": p["name"], "评分": f"**{p['score']}**",
                                       "标签": ",".join((p.get("hits") or [])[:4])}
                                      for i, p in enumerate(picks[:10])],
                                footer="14:57 按收盘价买入前三")
                            buys = [st for rd in d2["rounds"] if rd.get("date") == day2
                                    for st in rd.get("stocks", []) if st.get("buy_price")]
                            if buys:
                                ensure_push("plan", f"🛒 买入卡 · 今日14:57", "",
                                    f"plan:{day2}",
                                    rows=[{"股票": b["name"], "买价(锁定)": f"**{b['buy_price']}**"} for b in buys],
                                    footer="持仓上限3只(可买=空位数) · 选股日收盘价买入 · 次一交易日起评估出场")
                        fails = r.get("failed") or []
                        if fails:
                            ensure_push("settle", f"⚠️ 结算未完成 · {len(fails)}只", "",
                                f"settle_fail:{day2}",
                                rows=[{"标的": f, "处理": "未评估 · 持仓不动"} for f in fails],
                                footer="当日行情缺失/停牌 · 下个交易日继续")
                    except Exception as e:
                        print("[watchdog] push hook:", e)
            except Exception as e:
                print("[watchdog] scheduler:", e)
            time.sleep(60)

    threading.Thread(target=loop, daemon=True, name="daily-selection").start()
    print("[watchdog] selection scheduler started", flush=True)
