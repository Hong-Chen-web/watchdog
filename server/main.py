"""看门狗 Watchdog · 本地后台(装配式结构,对应设计说明书第 11 节)
main.py 只负责装配:建 app、CORS、错误信封、迁移、按模块挂载 router。
一个模块 = routers/ 一个文件;停用模块 = 从 MODULE_ROUTERS 摘掉一行。
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

import sys
from pathlib import Path

import db as dbm
from routers.common import http_error
from routers import modules, todo, ledger, portfolio, backtest, sysmon, market, disk, journal, goals, chan

# 模块 → router 的装配表(与 module_config 表的 module_id 对应)
MODULE_ROUTERS = {
    "modules":   modules.router,        # 装配配置本身
    "todo":      todo.router,
    "ledger":    ledger.router,         # 另含 /api/import/numbers
    "import":    ledger.import_router,
    "market":    market.router,
    "portfolio": portfolio.router,
    "backtest":  backtest.router,
    "sysmon":    sysmon.router,
    "disk":      disk.router,           # 垃圾清理 + 磁盘检索(Mole)
    "journal":   journal.router,        # 日志与复盘
    "goals":     goals.router,          # 目标(month/year/long 枚举)
    "chan":      chan.router,           # 缠论桥(监控/轮次/期货/飞书)
}

ALLOWED_ORIGINS = [
    "http://127.0.0.1:8791", "http://localhost:8791",
    "http://127.0.0.1:8790", "http://localhost:8790", "tauri://localhost",
]


@asynccontextmanager
async def lifespan(app: FastAPI):
    import threading as _th
    def _initial_mirror():
        try:
            from services.chan_backtest_mirror import sync_chan_backtest
            sync_chan_backtest()
        except Exception:
            pass
        try:
            import db as dbm
            from services.numbers_import import import_numbers
            conn = dbm.connect()
            conn.row_factory = __import__("sqlite3").Row
            import_numbers(conn)
            conn.close()
        except Exception:
            pass
    _th.Thread(target=_initial_mirror, daemon=True).start()
    conn = dbm.connect()
    ver = dbm.migrate(conn)
    from routers.chan import ensure_feishu_from_json
    ensure_feishu_from_json(conn)   # 首启:飞书配置从缠论 json 灌入表
    conn.close()
    # 行情快线(3s 腾讯批量:自选+指数)
    from services import quotes as quotes_fastline
    quotes_fastline.start()
    # 持仓同步线程:60s 轮(缠论在线才有新数据);14:55 落资产快照
    import threading
    from services import chan_bridge

    def holdings_loop():
        import time as _t
        last_snap_date = None
        while True:
            try:
                c = dbm.connect()
                chan_bridge.sync_holdings(c)
                now = _t.localtime()
                if now.tm_hour == 14 and now.tm_min >= 55 and last_snap_date != _t.strftime("%Y-%m-%d"):
                    chan_bridge.snapshot_account(c)
                    last_snap_date = _t.strftime("%Y-%m-%d")
                c.close()
            except Exception as e:
                print("[watchdog] holdings sync:", e)
            _t.sleep(60)

    threading.Thread(target=holdings_loop, daemon=True, name="chan-holdings").start()
    # 每日选股调度(14:55 交易日,桌面端内置,原 8787 能力)
    from services import selection as _sel
    _sel.start_scheduler()
    # 期货缠论监控(盘中自动轮询,内置)
    from services import futures_monitor as _fm
    _fm.start()
    print(f"[watchdog] db ready: {dbm.DB_PATH} (schema v{ver})")
    yield


app = FastAPI(title="Watchdog(看门狗)", version="0.2.1", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_exception_handler(HTTPException, http_error)

for _name, _router in MODULE_ROUTERS.items():
    app.include_router(_router)


@app.get("/api/health")
def health():
    conn = dbm.connect()
    try:
        ver = conn.execute("PRAGMA user_version").fetchone()[0]
        n_mod = conn.execute("SELECT COUNT(*) c FROM module_config").fetchone()["c"]
        return {"status": "ok", "db": "ok", "schema_version": ver,
                "modules": n_mod, "routers": list(MODULE_ROUTERS),
                "version": app.version}
    finally:
        conn.close()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8790, log_level="info")
