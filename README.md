# 看门狗 Watchdog

macOS 原生个人工作台:持仓监控 · 实盘回测 · 账本预算 · 自选/期货 · 系统磁盘。AppKit(Swift)桌面端 + FastAPI(Python)内置后端 + czsc 缠论引擎,单应用全包,无外部依赖服务。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/UI-AppKit-orange) ![Python](https://img.shields.io/badge/后端-FastAPI-green)

## 功能

| 模块 | 说明 |
|---|---|
| **持仓概览** | 缠论策略台账镜像(SQLite 落库):真实持仓/股数模型/资产曲线悬停查每日/买卖明细 117 笔/口径校准 |
| **策略回测** | 实盘台账统计:本金/已实现/胜轮/最差轮 + 逐轮资产曲线(日/月/年切换) |
| **策略信号** | 内置选股引擎(六条件打分:涨停缩量/MA20 趋势/剔 ST),14:55 交易日自动选股+结算 |
| **自选行情** | 3s 快线(腾讯),交易日+时段自动轮询,异动 ≥5% 弹 macOS 通知 |
| **期货监控** | 7 品种新浪K线 + czsc 实时结构(笔/中枢/方向),盘中 30s 重算 |
| **收支账本** | Numbers 自动导入 + 自然语言记账(「昨天午饭花了35」自动归类)+ 月份切换 |
| **预算与目标** | 分类预算月/年切换,增删改,目标随周期联动 |
| **年度财务分析** | 年报/月度趋势/分类结构/异常账单检测/改进建议/下年预算基线 |
| **系统与磁盘** | CPU/内存/GPU 六环 + Mole 清理(进度显示) |

深色/浅色主题切换 · 中英双语 · 全数据 SQLite 持久化(断网可用)。

## 快速开始

```bash
# 1. 下载 Release 的 Watchdog_*.dmg,拖入 Applications,双击即可
#    (内置后端+引擎,无依赖;首次启动磁盘扫描约 30s)

# 2. 或源码运行
git clone https://github.com/Hong-Chen-web/watchdog.git
cd watchdog/app/appkit
swift test && swift build -c release && ./bundle_app.sh
open dist/Watchdog.app
```

## 架构

```
Watchdog.app
└─ watchdog-server(PyInstaller, 随 App 启停)
   ├─ FastAPI :8790   数据层:SQLite 镜像/行情快线/账本/选股调度/期货监控
   │                 (czsc 引擎内置,无独立端口)
   └─ data/          台账/配置(SQLite: ~/Library/Application Support/Workbench/)
```

技术栈:Swift/AppKit(61 个 XCTest)+ Python/FastAPI + czsc 缠论库 + 腾讯/新浪/东财行情。详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## License

MIT
