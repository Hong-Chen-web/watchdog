"""行情模块接口:/api/market(自选维护 + 行情快照,数据源腾讯)+ K线数据(本项目 data/klines)。"""
import os
from pathlib import Path

from fastapi import APIRouter, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

from .common import get_conn

router = APIRouter(prefix="/api/market", tags=["market"])

# K线历史数据(2026-10-05 起主存于看门狗;chan-monitor 经软链继续读)
KLINE_DIR = Path(os.environ.get(
    "WATCHDOG_KLINES",
    os.path.expanduser("~/github/personal-workbench/data/klines")))


@router.get("/klines/list")
def kline_list():
    """已落地的 K 线文件清单:{symbol: [levels]}。"""
    if not KLINE_DIR.exists():
        return {"dir": str(KLINE_DIR), "symbols": []}
    groups = {}
    for f in sorted(KLINE_DIR.glob("*.csv")):
        sym, _, level = f.stem.rpartition("_")
        groups.setdefault(sym, []).append(level)
    return {"dir": str(KLINE_DIR), "symbols": [
        {"symbol": s, "levels": sorted(lv)} for s, lv in sorted(groups.items())]}


@router.get("/klines/file")
def kline_file(symbol: str, level: str = "day", limit: int = 500):
    """某品种某级别 K 线 CSV(最近 limit 行,时间正序)。"""
    import re
    if not re.fullmatch(r"[0-9A-Za-z.]{1,24}", symbol + level):
        raise HTTPException(400, "参数含非法字符")
    path = KLINE_DIR / f"{symbol}_{level}.csv"
    if not path.exists():
        raise HTTPException(404, f"无此K线: {symbol}_{level}")
    lines = path.read_text(encoding="utf-8").strip().splitlines()
    body = lines[1:]
    tail = body[-min(limit, len(body)):]
    return PlainTextResponse(lines[0] + "\n" + "\n".join(tail))


def _fetch_quote(code: str):
    """腾讯 qt.gtimg 拉一次行情:返回 (name, price, chg_pct);失败抛错。
    市场前缀推导:6→sh,0/3→sz,8/4→bj。"""
    import re
    import urllib.request
    c = re.sub(r"\D", "", code)[-6:]
    if not re.fullmatch(r"\d{6}", c):
        raise HTTPException(400, f"代码不合法: {code}")
    prefix = "sh" if c[0] == "6" else "bj" if c[0] in "48" else "sz"
    url = f"https://qt.gtimg.cn/q={prefix}{c}"
    try:
        with urllib.request.urlopen(url, timeout=6) as r:
            text = r.read().decode("gbk", "ignore")
    except Exception as e:
        raise HTTPException(502, f"行情源失败: {e}")
    parts = text.split("~")
    if len(parts) < 33 or not parts[1]:
        raise HTTPException(400, f"未找到股票: {code}")
    return parts[1], float(parts[3]), float(parts[32])


@router.get("/watchlist")
def watchlist():
    conn = get_conn()
    try:
        return [dict(r) for r in conn.execute(
            "SELECT code, name, price, chg_pct, note, sort FROM watchlist"
            " ORDER BY sort, code").fetchall()]
    finally:
        conn.close()


class WatchIn(BaseModel):
    code: str = Field(min_length=4, max_length=12)


@router.post("/watchlist", status_code=201)
def add_watch(body: WatchIn):
    import re
    code = re.sub(r"\D", "", body.code)[-6:]
    name, price, chg = _fetch_quote(code)
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO watchlist(code,name,source) VALUES(?,?,'manual')"
            " ON CONFLICT(code) DO UPDATE SET name=excluded.name",
            (code, name))
        conn.execute(
            "UPDATE watchlist SET name=?, price=?, chg_pct=?,"
            " quote_at=datetime('now','localtime') WHERE code=?",
            (name, price, chg, code))
        conn.commit()
        return {"code": code, "name": name, "price": price, "chg_pct": chg}
    finally:
        conn.close()


@router.delete("/watchlist/{code}", status_code=204)
def del_watch(code: str):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM watchlist WHERE code=?", (code,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"自选无 {code}")
    finally:
        conn.close()


@router.post("/watchlist/sync-chan", status_code=200)
def sync_chan_watchlist():
    """把 chan-monitor 的手动监控列表(watchlist_manual.json)同步进自选表。
    批量拉一次腾讯行情取名+现价,幂等 upsert。"""
    import json
    import re
    import urllib.request
    from pathlib import Path
    src = Path("/Users/chenhong/github/personal-workbench/chan/data/watchlist_manual.json")
    try:
        codes = json.loads(src.read_text(encoding="utf-8"))
    except Exception as e:
        raise HTTPException(502, f"读缠论监控列表失败: {e}")
    clean = []
    for c in codes:
        m = re.fullmatch(r"(?:sh|sz|bj)\.(\d{6})", str(c).strip())
        if m:
            clean.append(m.group(1))
    if not clean:
        raise HTTPException(404, "缠论监控列表为空")
    q = ",".join(codes).replace(".", "")  # 腾讯批量只认无点前缀(sz002384,sh688256)
    try:
        with urllib.request.urlopen(f"https://qt.gtimg.cn/q={q}", timeout=8) as r:
            text = r.read().decode("gbk", "ignore")
    except Exception as e:
        raise HTTPException(502, f"行情源失败: {e}")
    conn = get_conn()
    try:
        added = 0
        for line in text.strip().split(";"):
            parts = line.split("~")
            if len(parts) < 33 or not parts[1]:
                continue
            code = parts[2][-6:]
            name, price, chg = parts[1], float(parts[3]), float(parts[32])
            cur = conn.execute("SELECT code FROM watchlist WHERE code=?",
                               (code,)).fetchone()
            conn.execute(
                "INSERT INTO watchlist(code,name,source) VALUES(?,?,'manual')"
                " ON CONFLICT(code) DO UPDATE SET name=excluded.name",
                (code, name))
            conn.execute(
                "INSERT INTO quotes_cache(code,name,price,chg_pct,updated_at)"
                " VALUES(?,?,?,?,datetime('now','localtime'))"
                " ON CONFLICT(code) DO UPDATE SET name=excluded.name,"
                " price=excluded.price, chg_pct=excluded.chg_pct",
                (code, name, price, chg))
            added += 0 if cur else 1
        conn.commit()
        return {"synced": len(clean), "added": added}
    finally:
        conn.close()


@router.get("/quotes")
def market_quotes():
    """指数快照 + 自选现价(快线线程每 3s 刷新)。"""
    from services.quotes import snapshot
    conn = get_conn()
    try:
        wl = [dict(r) for r in conn.execute(
            "SELECT code, name, price, chg_pct, quote_at FROM watchlist"
            " WHERE price IS NOT NULL ORDER BY sort, code").fetchall()]
        return {**snapshot(), "watchlist": wl}
    finally:
        conn.close()


@router.post("/portfolio-sync")
def market_portfolio_sync():
    """手动触发一次缠论持仓同步。"""
    from services.chan_bridge import sync_holdings
    conn = get_conn()
    try:
        return sync_holdings(conn)
    finally:
        conn.close()
