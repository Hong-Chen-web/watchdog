"""涨停缩量二波策略(2026-09 定版,与 8787 年度回测口径完全对齐)。

六条件:①近10交易日涨停过 ②趋势(收盘>MA20且MA20向上) ③剔ST/退
④当日量≤涨停日量50%且≥15% ⑤板块梯队≥3家(行业板块当日涨停家数近似概念)
⑥涨停日主力净占比≥15%(东财fflow)。
排序=缩量30+梯队25+主力20+新鲜度10+趋势10+卫生5(4日前涨停最佳)。
同票冷却5个交易日(以卖出日计,trade_cooldown.json)。
买入=评分前三,选股日14:57按收盘价,buy_price锁定;一字涨停买不进顺延次名。
出场(次一交易日起逐票):跌停→跌停价跑(一字跌停封死顺延次日)
>炸板累计>3→走 >收盘涨停→续命 >断板→当天尾盘走。
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
    """日K(date, open, close, high, low, volume);腾讯主源(前复权)→重试→新浪备用。
    返回 None 仅当两源都失败——调用方不得把 None 当"无数据/无票"静默吞。"""
    sym = _pref(code6)
    for attempt in range(2):
        url = (f"https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?"
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

def universe():
    try:
        import requests
        rows = []
        sess = requests.Session()
        sess.trust_env = False
        for host in ("push2.eastmoney.com", "push2delay.eastmoney.com"):
            for pn in range(1, 61):
                try:
                    r = sess.get(
                        f"https://{host}/api/qt/clist/get",
                        params={"pn": pn, "pz": 100, "po": 1, "np": 1, "fltt": 2,
                                "invt": 2, "fid": "f3",
                                "fs": "m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048",
                                "fields": "f12,f14"},
                        headers=UA, timeout=10)
                    page = (r.json().get("data") or {}).get("diff") or []
                    if not page:
                        break
                    rows += page
                except Exception:
                    break
            if rows:
                break
        out = [(x["f12"], x["f14"]) for x in rows
               if not any(t in x["f14"] for t in ("ST", "退", "N", "C"))]
        if len(out) > 100:
            return out
        try:
            rs = sess.get("https://vip.stock.finance.sina.com.cn/hs_a/dividend",
                          headers=UA, proxies={"http": None, "https": None}, timeout=10)
            codes = re.findall(r'symbol=(?:sh|sz)(\d{6})', rs.text)
            seen, lst = set(), []
            for c in codes:
                if c not in seen and not c.startswith(("8", "4", "9")):
                    seen.add(c)
                    lst.append((c, ""))
            if len(lst) > 100:
                return lst
        except Exception:
            pass
    except Exception:
        pass
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


# ---------- 条件⑤梯队(行业当日涨停家数,概念的稳定近似) ----------

_zt_by_industry = None


def _load_zt_industry():
    global _zt_by_industry
    if _zt_by_industry is not None:
        return _zt_by_industry
    out = {}
    try:
        import requests
        sess = requests.Session()
        sess.trust_env = False
        for pn in range(1, 61):
            try:
                r = sess.get(
                    "https://push2.eastmoney.com/api/qt/clist/get",
                    params={"pn": pn, "pz": 100, "po": 1, "np": 1, "fltt": 2, "invt": 2,
                            "fid": "f3",
                            "fs": "m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048",
                            "fields": "f12,f14,f3,f100"},
                    headers=UA, timeout=10)
                page = (r.json().get("data") or {}).get("diff") or []
                if not page:
                    break
                for x in page:
                    ind = (x.get("f100") or "").strip()
                    pct = x.get("f3")
                    if not ind or not isinstance(pct, (int, float)):
                        continue
                    if pct >= 9.9:   # 聚类用宽阈,精确阈值在打分层按代码判
                        out[ind] = out.get(ind, 0) + 1
            except Exception:
                break
    except Exception:
        pass
    _zt_by_industry = out
    return out


def _echelon_count(code6: str):
    """条件⑤:该票所属行业当日涨停家数。返回 家数|None(网络失败不拦,原版容灾)。"""
    try:
        import requests
        sess = requests.Session()
        sess.trust_env = False
        r = sess.get("https://push2.eastmoney.com/api/qt/stock/get",
                     params={"secid": _secid(code6), "fields": "f100"},
                     headers=UA, timeout=6)
        ind = ((r.json().get("data") or {}).get("f100") or "").strip()
        if not ind:
            return None
        return _load_zt_industry().get(ind, 0)
    except Exception:
        return None


def _mainforce_pct(code6: str, zt_date: str):
    """条件⑥:涨停日主力净占比%(东财fflow日线:主力净额/成交额)。网络失败=None(不拦)。"""
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
                    headers=UA, timeout=8)
                rows = (r.json().get("data") or {}).get("klines") or []
                for line in rows:
                    p = line.split(",")
                    if p[0] == zt_date:
                        mf = float(p[1])              # 主力净流入(元)
                        amt = float(p[5]) if len(p) > 5 else 0   # 成交额(f56列)
                        if amt > 0:
                            return mf / amt * 100
                break
            except Exception:
                continue
    except Exception:
        pass
    return None


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


# ---------- 选股(建轮档案+锁定前三买价) ----------

def run_selection(archive: bool = True):
    """六条件→六因子排序→冷却过滤→前三锁定买价(一字板顺延次名)。
    archive=True(14:55 自动跑):写名单+建轮档案(进台账/持仓生命周期)。"""
    out = []
    for code6, name in universe():
        k = tencent_daily(code6, 120)
        if not k:
            continue
        if _in_cooldown(code6, k):
            continue
        r = score_stock(code6, k, name)
        if r:
            out.append({"code": code6, "name": name, "score": r[0],
                        "hits": r[1], "price": k[-1]["close"], "_k": k})
        time.sleep(0.25)
    out.sort(key=lambda x: -x["score"])
    top = out[:10]

    buys = []
    for s in top:
        if len(buys) >= 3:
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


# ---------- 结算(逐票生命周期) ----------

def settle_all():
    """次一交易日起逐票评估:跌停→跌停价跑(封死顺延次日)>炸板累计>3→走
    >收盘涨停→续命>断板→当天尾盘走。出场写冷却簿+镜像。"""
    try:
        d = json.loads(HIST.read_text())
    except Exception:
        d = {"rounds": []}
    settled = []
    failed = []
    cool = _cooldown_map()
    changed = False
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
                exit_why = "断板离场"
            if exit_why:
                s["_exit_why"] = f"{exit_why}({today['date']})"
                s["_exit_px"] = today["close"]
                cool[code6] = today["date"]
                changed = True
                settled.append({"date": r["date"], "name": s["name"], "why": exit_why,
                                "px": today["close"]})
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


def _ran_today(day: str) -> bool:
    try:
        return json.loads((DATA / "recommended_tail.json").read_text()).get("date") == day
    except Exception:
        return False


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
                    picks = run_selection(archive=True)
                    print(f"[watchdog] 选股{'补跑' if caught_up else ''}完成:"
                          f"{len(picks)} 只;结算 {len(r.get('settled', []))} 笔")
                    try:
                        from services.feishu_push import ensure_push
                        day2 = day
                        st = r.get("settled") or []
                        if st:
                            ensure_push("settle", f"💰 结算卡 · {len(st)}笔出场", "",
                                f"settle:{day2}",
                                rows=[{"股票": x["name"], "原因": x["why"],
                                       "卖价": f"**{x['px']}**"} for x in st])
                        d2 = json.loads(HIST.read_text())
                        hold = [s2 for rd in d2["rounds"] for s2 in rd.get("stocks", [])
                                if s2.get("buy_price") and not s2.get("_exit_why")]
                        if hold:
                            ensure_push("holding_daily", f"💼 持仓日报 · {len(hold)}只", "",
                                f"holding:{day2}",
                                rows=[{"股票": h["name"], "买价": h["buy_price"],
                                       "状态": h.get("_hold_note") or "持仓中(按规则评估)"}
                                      for h in hold],
                                footer=f"评估口径:跌停跑>炸板3走>涨停续命>断板走")
                        if picks:
                            ensure_push("selection", f"⚡ 选股完成 · {len(picks)}只", "",
                                f"selection:{day2}",
                                rows=[{"名次": i + 1, "股票": p["name"], "评分": f"**{p['score']}**",
                                       "标签": ",".join((p.get("hits") or [])[:4])}
                                      for i, p in enumerate(picks[:10])],
                                footer="14:57 按收盘价买入前三")
                            buys = [st for rd in d2["rounds"] if rd.get("date") == day2
                                    for st in rd.get("stocks", []) if st.get("buy_price")]
                            if buys:
                                ensure_push("plan", f"🛒 买入单 · 今日14:57", "",
                                    f"plan:{day2}",
                                    rows=[{"股票": b["name"], "买价(锁定)": f"**{b['buy_price']}**"} for b in buys],
                                    footer="选股日收盘价买入 · 次一交易日起评估出场")
                    except Exception as e:
                        print("[watchdog] push hook:", e)
            except Exception as e:
                print("[watchdog] scheduler:", e)
            time.sleep(60)

    threading.Thread(target=loop, daemon=True, name="daily-selection").start()
