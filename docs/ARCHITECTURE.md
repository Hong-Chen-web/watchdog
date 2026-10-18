# 看门狗 Watchdog · 架构速览

> 2026-10-18 复核重写(上一版落款 2026-10-06,其间经历过"引擎移除 → 内置 czsc 回归"的弯路,旧文已不代表现状)。
> 本文只回答"东西在哪、怎么连";策略规则 / 部署四步 / 数据源纪律等运维规约,以根目录 **AGENTS.md** 为准。

## 进程

| 端口 | 进程 | 职责 |
|---|---|---|
| 8790 | `server/`(sidecar,随 App 起,launchd 守护兜底) | 唯一后端:装配式 FastAPI + 内置 czsc(venv 内轻量壳)+ 调度器 + 各监控线程 |

- **App**(`Watchdog.app`,Swift 壳):管理 sidecar 生命周期;主窗口 = WKWebView 装载 `/ui`
- 原生窗口经 JS 桥 `window.wd` 回调:原生 K 线窗、设置窗;命令行深链 `--chart <代码> [名称]`、`--settings`
- 缠论计算在 8790 进程内(`services/czsc_light.py` 轻量壳 + czsc 库);独立 8787 引擎已不复存在
- `design/` = 早期 Web 原型(仅对照参考,不参与运行)

## 目录结构

```
personal-workbench/
├── app/appkit/              # Swift 包(SPM):WatchdogCore 库 + Watchdog 可执行壳
│   ├── Sources/WatchdogCore/        活代码:WebMainWindow(主窗口 WKWebView+wd 桥)/ChartWindow(原生K线窗)/
│   │                                SettingsWindow/Theme/Components(共享控件:字体/PillBar/FlippedStack)/Models/
│   │                                ModuleState/APIClient/Lifecycle/ChanCode
│   ├── Sources/WatchdogCore/Legacy/ 旧原生仪表盘(MainWindow/Cards*/Overview/CardView/TradesWindow/Dialogs/
│   │                                ComponentsLegacy):App 壳不再调用,保留供回退参考与渲染测试
│   ├── Tests/WatchdogTests/         81 个测试(逻辑/离屏渲染/像素断言);Legacy/ 下 4 个属旧仪表盘渲染
│   ├── bundle_app.sh                打 .app + dmg;dist/Watchdog.app = 用户实际运行的 App
│   └── bin/watchdog-server          frozen 后端(分发兜底;开发期 App 优先 venv 源码)
├── server/                  # FastAPI 后端(sidecar)
│   ├── main.py                  入口:轻量 czsc 壳 → 迁移 → 调度器 → 监控线程 → 路由装配
│   ├── static/                  ★Web 工作台(index.html + css/4 + js/11;零构建,git 直读,经 /ui-assets 下发)
│   ├── routers/                 ui(壳+快照+AI问答) / chan(缠论/选股/信号/图表) / feishu(通道配置,路径 /api/chan/feishu*) /
│   │                            market / portfolio / ledger / todo / goals / journal / modules / pushscope / llm / disk / sysmon / backtest
│   ├── services/                selection(选股+结算) / kline_store(K线底库) / stocks_monitor / futures_monitor /
│   │                            feishu_push(事务性发件箱) / chan_backtest_mirror(台账镜像) / ui_snapshot(bootstrap 快照) /
│   │                            ai_query(只读问答) / quotes / numbers_import / smart_entry / cleaner / mole_clean ...
│   └── migrations/NNN_*.sql     SQLite 迁移(PRAGMA user_version 顺序执行;当前 v23)
├── data/                    运行数据(gitignore):klines.db / 轮档案 / 冷却簿 / 行业图 / 涨停滚动集 / fflow_cache.json
└── docs/                    本文档 + img/(README 截图) + project-memory/(历史项目记忆,gitignore)
```

主数据库:`~/Library/Application Support/Workbench/workbench.db`(设置 / 自选 / 信号 / 台账 / 待办 / 账本)

## 数据流

- **行情**:腾讯(清单/K线/快照/行情快线)→ 新浪(行业分类图)→ 东财仅剩主力净占比(永久缓存 `data/fflow_cache.json`);出网一律绕 Clash 代理
- **存储**:workbench.db(业务主库)+ `data/`(全 A 日 K 底库、涨停滚动集、冷却簿、行业图)
- **策略流水线**(每交易日):14:55 结算持仓 + 选股(六条件硬门槛 → 六因子排序 → 前三)→ 14:57 按收盘价买入 → 盘中股票/期货监控按级别扫缠论买卖点 → 飞书卡经事务性发件箱推送 → 收盘后 chan_backtest_mirror 镜像实盘台账
- **Web 工作台**:`/ui` 是无数据静态壳(no-store),启动拉一次 `GET /api/ui/bootstrap`(ui_snapshot 进程内直调各 router,单项失败不拖垮整屏);写动作直打各真接口(todos / monitor-level / feishu test / modules / smart-any)

## 接口速览(8790)

| 组 | 主要接口 | 用途 |
|---|---|---|
| 工作台 | GET /ui · /ui-assets/* · /api/ui/bootstrap · POST /api/ai/ask · PUT /api/ui/push-master | Web 壳 / 首屏快照 / AI 只读问答 / 推送总开关 |
| 缠论 | /api/chan/state·tail·signals·chart·chartdata·chart-levels · /selection/run·status · /monitor-level · /futures·futures-level·futures-scan | 监控 / 选股 / 期货 / 信号 / 图表 |
| 飞书配置 | /api/chan/feishu(·test ·config ·bots ·notify) | 通道 CRUD + 测试推送 |
| 持仓·回测 | /api/portfolio · /history · /trades · /calib · /sync-chan · /api/backtest/live | 持仓 / 台账 / 实盘回测 |
| 行情 | /api/market/quotes · /watchlist | 自选与行情快线 |
| 账本·待办 | /api/ledger/*(summary·entries·months·smart·smart-any·budgets·report·annual) · /api/todos · /api/goals · /api/journal | 账本 / 待办 / 目标 / 日志 |
| 系统 | /api/modules · /api/sysmon · /api/disk/* · /api/llm | 模块装配 / 系统监控 / 磁盘 / 大模型配置 |

## 打包

```bash
cd app/appkit
swift test                                     # 全量回归(交付前必跑)
swift build -c release && ./bundle_app.sh      # dist/Watchdog.app + dmg
# 重打 frozen 后端(发 Release 时):
cd server && /Users/chenhong/github/czsc-repo/.venv/bin/pyinstaller watchdog-server.spec --noconfirm
```
