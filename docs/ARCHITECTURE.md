# 看门狗 Watchdog · 架构与接口总览

> 2026-10-06 归并后唯一主项目:`/Users/chenhong/github/personal-workbench/`
> 老目录 `github/chan-monitor` 已删除,引擎整体移入本项目 `chan/`。

## 目录结构(本仓库内)

```
personal-workbench/
├── app/appkit/          # 桌面端(Swift/AppKit,唯一 UI 主线)
│   ├── Sources/WatchdogCore/   # 核心库(主题/组件/卡片/主窗)
│   ├── Sources/Watchdog/       # 可执行壳(sidecar+AppDelegate)
│   ├── Tests/                  # 60 个测试(夹具=真实接口抓包)
│   ├── bin/watchdog-server     # 后端 PyInstaller 二进制(sidecar)
│   ├── Assets/(图标/字体)      # bundle_app.sh → dist/Watchdog.app + dmg
│   └── chan/            # ★ 缠论引擎(原 chan-monitor,8787)
│       ├── run.sh       # 独立起:uvicorn 8787(交易日调度/选股/图表/飞书)
│       └── data/        # 台账 backtest_tail_history.json / watchlist_manual / charts
├── server/              # 桌面端后端 FastAPI 8790(sidecar)
│   ├── routers/         # modules/todo/ledger(+smart)/market/portfolio
│   │                    # (+calib,trades)/backtest(+live)/sysmon/disk/journal/goals/chan
│   ├── services/        # chan_backtest_mirror(台账镜像) smart_entry(NL记账)
│   │                    # numbers_import cleaner mole_clean quotes sysmon
│   └── migrations/      # SQLite ~/Library/Application Support/Workbench/workbench.db
├── design/              # Web 版原型(8791, node server.js)——UI 对照基准
└── docs/                # 本文档
```

依赖仓(仍在 github/ 顶层,勿删):`chan.py-repo`(缠论库)、`czsc-repo/`(venv 解释器)、`Mole/`(系统监控/清理二进制源)。

## 进程(2026-10-06 晚:缠论引擎已整体移除)

| 端口 | 进程 | 职责 |
|---|---|---|
| **8790** | `server/`(sidecar 随 App 起,唯一后端) | 数据层:SQLite 镜像台账(历史已冻结落库)、行情快线、账本/待办/目标、NL 记账、磁盘 |
| **8791** | `design/server.js`(node) | Web 版原型(对照用) |

**已移除**:8787 缠论引擎(chan/ 目录+chan.py-repo,2026-10-06)。历史台账 117 笔/曲线/信号快照/飞书配置均已落库保留;期货监控、缠论图表、实时选股随引擎下线(futures 模块已注销,`/api/chan/futures` 返回空态,`_proxy` 类接口 503)。持仓/回测卡数据=库内最后镜像,不再更新。

## 数据流(自上游到卡)

```
腾讯/东财行情 ──> 8787(选股/估值)──> chan/data/backtest_tail_history.json
                                              │(文件直读)
       8790 chan_backtest_mirror ─────────────┘
        ├─ 落库 chan_trades(117 笔)/chan_round_ledger/chan_kv(汇总+tail 快照)
        ├─ watchlist = chan 手动清单 + 当前持仓(收敛式)
        └─ /api/portfolio|/trades|/history|/backtest/live  ←─ 持仓卡/回测卡
8790 quotes 线程(3s,交易时段) ─> watchlist+指数 ─ /api/market/quotes ← 自选卡
NL 记账:App 输入 ─ /api/ledger/smart ─ smart_entry 规则解析 ─ ledger_entries
```

## 桌面端调用接口清单(8790)

| 接口 | 卡/用途 |
|---|---|
| GET /api/modules · PUT /{id} | 侧栏装配+编辑布局 |
| GET /api/portfolio · /history · /trades · /calib(PUT/DELETE) · POST /sync-chan | 持仓概览/买卖明细 |
| GET /api/backtest/live | 策略回测(实盘台账) |
| GET /api/market/quotes · POST /watchlist · DELETE /watchlist/{code} | 自选行情 |
| GET /api/chan/tail(智能路由) · /futures · /chart · /chart-levels · /feishu/config | 策略信号/期货/图表/飞书 |
| GET/PUT /api/llm · POST /api/llm/test | 大模型配置(settings 表主存,env 兜底;smart-any 自然语言识别用) |
| GET/POST /api/ledger/summary·entries·months·smart · PUT /budgets/{y} · POST/DELETE /categories | 收支账本/预算与目标 |
| GET/POST /api/journal | 日志与复盘 |
| GET/POST/PATCH/DELETE /api/goals | 目标(合并卡内) |
| GET /api/todos | 今日待办 |
| GET /api/sysmon · /disk/clean-scan|clean-run|clean-status | 系统与磁盘 |

## 打包

```
cd app/appkit
swift test && swift build -c release
./bundle_app.sh          # dist/Watchdog.app + Watchdog_1.0.0_aarch64.dmg
```
改后端后需重打 sidecar:`cd server && ../czsc-repo/.venv/bin/python -m PyInstaller watchdog-server.spec --distpath ../app/appkit/bin --noconfirm`
