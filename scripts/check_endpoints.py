#!/usr/bin/env python
"""tier2 联网冒烟(只读):sidecar 需运行在 127.0.0.1:8790。

检查 health 版本/模块、bootstrap 形状(资产/待办/推送通道/时间轴数据/选股轮)、
live 轻量接口、portfolio 口径字段、feishu config(account_cards 字段)。
绝不写库;有失败则退出码 1。

跑法:/Users/chenhong/github/czsc-repo/.venv/bin/python scripts/check_endpoints.py
"""
import json
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:8790"
# 绕 Clash 纪律:本机直连,显式空 ProxyHandler(requests/urllib 不读环境代理)
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

PASS, FAIL = [], []


def get(path, timeout=15):
    with _opener.open(BASE + path, timeout=timeout) as r:
        return json.loads(r.read().decode())


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f"  ← {detail!r}"))


def main():
    t0 = time.time()
    h = get("/api/health")
    check("health: status/db ok", h.get("status") == "ok" and h.get("db") == "ok", h)
    check("health: schema >= 27", int(h.get("schema_version") or 0) >= 27, h.get("schema_version"))
    check("health: 模块数 = 16", h.get("modules") == 16, h.get("modules"))

    b = get("/api/ui/bootstrap", timeout=40)
    from datetime import date as _date
    check("bootstrap: today = 服务器本地日期(前端跨日重载锚点)",
          b.get("today") == _date.today().isoformat(), b.get("today"))
    for k in ("portfolio", "todos", "push", "watch", "tail", "health", "food"):
        check(f"bootstrap: 含 {k}", k in b)
    pf = b.get("portfolio") or {}
    check("bootstrap: 资产口径字段齐全",
          all(k in pf for k in ("total", "cash", "market_value", "day_pnl",
                                "principal", "holdings")))
    chs = (b.get("push") or {}).get("channels") or []
    need = {"id", "name", "codes", "account_cards", "ok", "last_id"}
    check("bootstrap: 飞书通道 >= 1 且字段齐全", len(chs) >= 1 and all(need <= set(c) for c in chs),
          [sorted(set(c)) for c in chs][:1])   # 通道数量=用户数据(可增删),只校验非空且字段完整
    check("bootstrap: push.today 为列表", isinstance((b.get("push") or {}).get("today"), list))
    tl = b.get("tail") or {}
    check("bootstrap: 选股轮状态三键", all(k in tl for k in ("date", "stocks", "next_run_day")), tl)
    check("bootstrap: 自选列表", isinstance(b.get("watch"), list))

    lv = get("/api/ui/live", timeout=10)
    check("live: 五区块齐全",
          all(k in lv for k in ("portfolio", "quotes", "watch", "push", "trades")),
          sorted(lv.keys()))
    lvp = lv.get("push") or {}
    check("live: push 含 today/channels",
          isinstance(lvp.get("today"), list) and bool(lvp.get("channels")))

    po = get("/api/portfolio")
    check("portfolio: 口径字段齐全",
          all(k in po for k in ("total", "cash", "market_value", "principal",
                                "total_pnl", "total_pnl_pct", "day_pnl",
                                "day_pnl_pct", "holdings", "synced_at",
                                "calibrated", "source")))

    fc = get("/api/chan/feishu/config")
    bots = fc.get("bots") or []
    check("feishu config: bots 含 account_cards 字段",
          len(bots) >= 1 and all("account_cards" in x for x in bots))

    dt = time.time() - t0
    print(f"\n  tier2: {len(PASS)} 通过 / {len(FAIL)} 失败 · {dt:.1f}s")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
