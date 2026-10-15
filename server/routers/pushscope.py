"""推送范围配置:控制哪些标的的盘中信号推飞书(每日四卡不受限)。
scope={"mode":"all"} 或 {"mode":"custom","stocks":[code6...],"futures":["JM0"...]}
"""
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter(prefix="/api/push", tags=["push"])


def get_scope() -> dict:
    import db as dbm
    import json
    conn = dbm.connect()
    try:
        row = conn.execute("SELECT value FROM settings WHERE key='push_scope'").fetchone()
        if row:
            d = json.loads(row["value"])
            if d.get("mode") in ("all", "custom"):
                return d
    except Exception:
        pass
    finally:
        conn.close()
    return {"mode": "all"}


def stock_in_scope(code6: str) -> bool:
    s = get_scope()
    return s["mode"] == "all" or code6 in (s.get("stocks") or [])


def future_in_scope(symbol: str) -> bool:
    s = get_scope()
    return s["mode"] == "all" or symbol in (s.get("futures") or [])


class ScopeIn(BaseModel):
    mode: str = "all"          # all | custom
    stocks: list[str] = []
    futures: list[str] = []


@router.get("/scope")
def read_scope():
    """当前范围 + 可选标的清单(自选含ETF / 期货7品种)。"""
    import db as dbm
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        stocks = [{"code": r["code"], "name": r["name"]}
                  for r in conn.execute("SELECT code,name FROM watchlist ORDER BY code")]
    finally:
        conn.close()
    from services.futures_monitor import FUTURES, FUT_NAMES
    s = get_scope()
    return {"mode": s["mode"], "stocks": s.get("stocks") or [],
            "futures": s.get("futures") or [],
            "all_stocks": stocks,
            "all_futures": [{"code": f, "name": FUT_NAMES.get(f, f)} for f in FUTURES]}


@router.put("/scope")
def write_scope(body: ScopeIn):
    import db as dbm
    import json
    conn = dbm.connect()
    try:
        conn.execute(
            "INSERT INTO settings(key,value) VALUES('push_scope',?)"
            " ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (json.dumps({"mode": body.mode, "stocks": body.stocks,
                         "futures": body.futures}, ensure_ascii=False),))
        conn.commit()
    finally:
        conn.close()
    return get_scope()
