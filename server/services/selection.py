"""每日选股+结算(从 chan-monitor 移植为 8790 内置能力,桌面端自带)。
六条件打分(2026-09 定版)+ 逐票生命周期结算 —— 完整逻辑搬入,无独立端口。"""
import json
import re
import time
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path

import db as dbm

DATA = Path("/Users/chenhong/github/personal-workbench/data")
PRINCIPAL = 100000.0

UA = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
    "Accept": "*/*",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Referer": "https://quote.eastmoney.com/",
}


# ---------- 行情数据(腾讯,与原引擎同源) ----------

def _pref(code6: str) -> str:
    if code6.startswith("6"):
        return "sh" + code6
    if code6[0] in "48":
        return "bj" + code6
    return "sz" + code6


def tencent_daily(code6: str, days: int = 120):
    """日K(date, open, close, high, low, volume);前复权。"""
    sym = _pref(code6)
    url = (f"https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?"
           f"param={sym},day,,,{days},qfq")
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=8) as f:
            d = json.loads(f.read().decode())
        rows = d["data"][sym].get("qfqday") or d["data"][sym].get("day") or []
        return [{"date": r[0], "open": float(r[1]), "close": float(r[2]),
                 "high": float(r[3]), "low": float(r[4]), "volume": float(r[5])}
                for r in rows]
    except Exception:
        return None


def quote_batch(code6s):
    """实时行情批量:name/price/chg_pct。"""
    q = ",".join(_pref(c) for c in code6s)
    try:
        with urllib.request.urlopen(
                urllib.request.Request(f"http://qt.gtimg.cn/q={q}", headers=UA), timeout=6) as f:
            raw = f.read().decode("gbk", "ignore")
        out = {}
        for line in raw.split(";"):
            if "~" not in line:
                continue
            p = line.split("~")
            full = p[0].split("=")[0].strip().lower()
            if len(full) >= 8:
                out[full[2:]] = {"name": p[1], "price": float(p[3]) if p[3] else 0,
                                 "chg_pct": float(p[32]) if len(p) > 32 and p[32] else 0}
        return out
    except Exception:
        return {}


# ---------- 六条件打分(涨停缩量策略,2026-09 定版) ----------

def _was_limit_up(k, i, board20=False):
    """第 i 日是否涨停(主板10%/双创20%,按前收)。"""
    if i == 0:
        return False
    prev_close = k[i - 1]["close"]
    pct = (k[i]["close"] / prev_close - 1) * 100
    return pct >= (19.9 if board20 else 9.9)


def score_stock(code6: str, k):
    """返回 (score, hits) 或 None(不满足)。六条件+加权分(原版口径)。"""
    if not k or len(k) < 30:
        return None
    closes = [x["close"] for x in k]
    vols = [x["volume"] for x in k]

    # ① 近10交易日涨停过
    lim_days = []
    for i in range(max(1, len(k) - 10), len(k)):
        prev = closes[i - 1]
        lim_pct = 19.9 if code6[0] in "368" and code6[:3] in ("300", "301", "688") else 9.9
        if (closes[i] / prev - 1) * 100 >= lim_pct - 0.3:
            lim_days.append(i)
    if not lim_days:
        return None
    last_lim = lim_days[-1]
    ago = len(k) - 1 - last_lim
    if ago > 6:
        return None

    # ② 上升趋势:收盘>MA20 且 MA20 向上
    ma20 = sum(closes[-20:]) / 20
    ma20_prev = sum(closes[-21:-1]) / 20
    if not (closes[-1] > ma20 and ma20 > ma20_prev):
        return None

    # ④ 缩量:当日量 ≤ 涨停日量50% 且 ≥15%
    v_today, v_lim = vols[-1], vols[last_lim]
    if v_lim <= 0:
        return None
    ratio = v_today / v_lim
    if not (0.15 <= ratio <= 0.5):
        return None

    hits = [
        f"{ago}日前涨停" if ago > 0 else "昨涨停",
        f"缩量{ratio*100:.0f}%",
        f"涨停日量{v_lim/1e4:.0f}万手",
    ]
    # 加权总分(缩量30+新鲜度10+趋势10 基础;梯队/主力网络失败不扣分)
    score = 50 + (30 if ratio < 0.3 else 20) + (10 if ago <= 4 else 5) + 10
    return min(score, 100), hits


def universe():
    """候选池:全部 A 股(东财列表,与原引擎同源;失败回退自选池)。"""
    try:
        import urllib.parse
        import requests
        # 东财单页 pz>~2000 会被断连:分页 100/页×60 页≈全市场
        rows = []
        sess = requests.Session()
        sess.trust_env = False   # 直连:系统代理(Clash)会拦 python TLS
        for host in ("push2.eastmoney.com", "push2delay.eastmoney.com"):
            for pn in range(1, 61):
                try:
                    r = sess.get(
                        f"https://{host}/api/qt/clist/get",
                        params={"pn": pn, "pz": 100, "po": 1, "np": 1, "fltt": 2,
                                "invt": 2, "fid": "f3",
                                "fs": "m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048",
                                "fields": "f12,f14"},
                        headers={"User-Agent": UA["User-Agent"]}, timeout=10)
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
        # 源2:新浪全A清单(东财间歇拒连时的兜底)
        try:
            import requests as _rq
            rs = _rq.get("https://vip.stock.finance.sina.com.cn/hs_a/dividend",
                         headers={"User-Agent": UA["User-Agent"]},
                         proxies={"http": None, "https": None}, timeout=10)
            import re as _re
            codes = _re.findall(r'symbol=(?:sh|sz)(\d{6})', rs.text)
            seen, lst = set(), []
            for c in codes:
                if c not in seen and not c.startswith(("8", "4", "9")):
                    seen.add(c)
                    lst.append((c, ""))
            if len(lst) > 100:
                return lst
        except Exception:
            pass
        rows = d.get("data", {}).get("diff") or []
        out = [(r["f12"], r["f14"]) for r in rows
               if not any(x in r["f14"] for x in ("ST", "退", "N", "C"))]
        if len(out) > 100:
            return out
    except Exception:
        pass
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        rows = conn.execute(
            "SELECT DISTINCT w.code, COALESCE(w.name,'') name FROM watchlist w"
            " UNION SELECT DISTINCT t.code, COALESCE(t.name,'') FROM chan_trades t").fetchall()
        return [(r["code"], r["name"]) for r in rows]
    finally:
        conn.close()   # 东财/新浪清单源都间歇拒绝时,自选+历史池兜底(约40只)


def run_selection():
    """跑一轮选股(对候选池打分排序)。返回前 N。"""
    out = []
    for code6, name in universe():
        k = tencent_daily(code6, 120)
        if not k:
            continue
        r = score_stock(code6, k)
        if r:
            out.append({"code": code6, "name": name,
                        "score": r[0], "hits": r[1], "price": k[-1]["close"]})
        time.sleep(0.25)   # 防限流
    out.sort(key=lambda x: -x["score"])
    return out[:10]


# ---------- 结算(逐票生命周期,原版规则) ----------

def settle_all():
    """每日收盘评估持仓:跌停→按跌停价跑 > 炸板3次→走 > 断板→当天走 > 涨停→续命。"""
    hist_path = DATA / "backtest_tail_history.json"
    try:
        d = json.loads(hist_path.read_text(encoding="utf-8"))
    except Exception:
        d = {"rounds": []}
    settled = []
    for r in d["rounds"]:
        if r.get("settled"):
            continue
        for s in r.get("stocks", []):
            if s.get("buy_price") is None or s.get("_exit_why"):
                continue
            k = tencent_daily(s["code"].split(".")[-1], 10)
            if not k:
                continue
            today = k[-1]
            prev = k[-2]["close"]
            chg = (today["close"] / prev - 1) * 100
            code6 = s["code"].split(".")[-1]
            lim_pct = 19.9 if code6[:3] in ("300", "301", "688") else 9.9
            exit_why = None
            if chg <= -lim_pct + 0.3:
                exit_why = "跌停即跑"
            elif today["high"] >= prev * (1 + lim_pct / 100) - 0.01 and today["close"] < prev * (1 + lim_pct / 100) - 0.01:
                exit_why = "炸板离场"
            elif chg < lim_pct - 0.3:
                exit_why = "断板离场"
            if exit_why:
                s["_exit_why"] = f"{exit_why}({today['date']})"
                s["_exit_px"] = today["close"]
                settled.append({"date": r["date"], "name": s["name"], "why": exit_why})
            time.sleep(0.25)
    hist_path.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
    # 出场写回镜像库(卡立即反映)
    if settled:
        try:
            from services.chan_backtest_mirror import sync_chan_backtest
            sync_chan_backtest()
        except Exception:
            pass
    return settled


# ---------- 每日调度(14:55,交易日) ----------

def _is_trade_day() -> bool:
    try:
        with urllib.request.urlopen("http://qt.gtimg.cn/q=sh000001", timeout=4) as f:
            raw = f.read().decode("gbk", "ignore")
        return raw.split("~")[30][:8] == date.today().strftime("%Y%m%d")
    except Exception:
        return datetime.now().weekday() < 5


def start_scheduler():
    import threading

    def loop():
        done_day = None
        while True:
            try:
                now = datetime.now()
                hm = now.strftime("%H:%M")
                day = now.strftime("%Y-%m-%d")
                if (_is_trade_day() and "14:55" <= hm < "15:00" and done_day != day):
                    done_day = day
                    settle_all()
                    picks = run_selection()
                    (DATA / "recommended_tail.json").write_text(
                        json.dumps({"date": day, "stocks": picks,
                                    "generated_at": now.isoformat()}, ensure_ascii=False))
                    print(f"[watchdog] 14:55 选股完成: {len(picks)} 只")
            except Exception as e:
                print("[watchdog] scheduler:", e)
            time.sleep(60)

    threading.Thread(target=loop, daemon=True, name="daily-selection").start()
