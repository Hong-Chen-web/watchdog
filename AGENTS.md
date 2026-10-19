# AGENTS.md — 看门狗 Watchdog 维护交接手册

> 面向接手的 AI 编码代理(opencode 等)。本文件是**唯一权威手册**,读完即可开始维护。
> 用户是 A 股短线打板交易者,这个项目是他的**实盘参考工作台**,账目正确性高于一切。

## 1. 这个项目是什么

macOS 原生量化工作台:**AppKit(Swift)桌面壳 + FastAPI(Python)内置后端 + czsc 缠论引擎**,单 App 全包。
- 主窗口 = **WKWebView 装载 Web 工作台**(2026-10-17 换版):sidecar 提供静态壳 `/ui`(server/static/index.html + css/ + js/,经 `/ui-assets/*` 下发;无数据入库)+ 一次性快照 `/api/ui/bootstrap`;写动作直接打各真接口(todos PATCH / 监控级别 PUT / 飞书 test / modules PUT / smart-any)。原生 K 线窗、设置窗经 `window.webkit.messageHandlers.wd` 桥回 App(WebMainWindow.swift 的 WDBridge);`--chart 代码 [名称]`、`--settings` 深链保留。
- 核心业务:**涨停缩量策略**全自动流水线——每天 14:55 自动结算持仓 + 自动选股,14:57 按收盘价买入前三,飞书推卡(卖出卡/持仓卡/买入卡/选股卡);盘中按监控级别扫缠论买卖点推飞书
- 仓库:https://github.com/Hong-Chen-web/watchdog (main 分支)

## 2. 目录地图

```
app/appkit/           Swift 壳(WatchdogCore 库 + Watchdog 可执行)
  Sources/WatchdogCore/   ★主窗口=WebMainWindow(WKWebView+wd桥,K线/设置回原生);活件:ChartWindow(原生K线图)/SettingsWindow/Theme/Components(共享控件)/Models/APIClient/ModuleState/Lifecycle/ChanCode
  Sources/WatchdogCore/Legacy/  旧原生仪表盘(MainWindow/Cards*/OverviewPane/CardView/TradesWindow/Dialogs/ComponentsLegacy)——App 壳不再调用,保留供回退参考与渲染测试(swift test 仍全量编译)
  bundle_app.sh           打 .app(含 frozen 后端)+ dmg
  dist/Watchdog.app       用户实际运行的 App(launchd 守护指向这里)
server/               FastAPI 后端
  main.py                 入口(8790 端口;启动:轻量czsc壳→迁移→调度器→各监控线程)
  static/ ★桌面版主界面(WKWebView 装载;index.html + css/4个 + js/11个,业务在 services/ui_snapshot.py 与 services/ai_query.py)
  routers/ui.py           ★Web UI:/ui 页面 + /api/ui/bootstrap 快照 + /api/ui/push-master
  routers/                chan(缠论/选股/信号/图表)/feishu(通道配置CRUD,路径仍 /api/chan/feishu*)/market/portfolio/ledger/todo/pushscope...
  services/
    selection.py          ★选股+结算引擎(六条件/六因子/滚动集/卖出规则)
    kline_store.py        ★K线底库(SQLite data/klines.db)+当日快照合成+4h合成
    stocks_monitor.py     ★股票信号监控(级别可配,settings键 stocks_monitor_level)
    futures_monitor.py    ★期货信号监控(级别可配,settings键 futures_monitor_level)
    feishu_push.py        ★飞书事务性发件箱(重试/幂等/多机器人定向)
    chan_backtest_mirror.py  实盘台账镜像(轮档案→SQLite,持仓/盈亏/资产曲线)
  migrations/NNN_*.sql    数据库迁移(PRAGMA user_version 顺序执行,当前 v25)
  watchdog-server.spec    PyInstaller frozen 打包配置(含 static 数据)
data/                 运行数据(gitignore):klines.db/轮档案/冷却簿/行业图/信号滚动集
~/Library/Application Support/Workbench/workbench.db   主数据库(设置/自选/信号/台账)
```

## 3. 策略规则(改前必读,用户会逐条核对)

**选股(14:55 自动 / 手动按钮)**:候选=近10交易日涨停滚动集(limit_roll.json)→排除持仓票+冷却票(卖出后5交易日)→六条件硬门槛:
1. 近10交易日涨停过 2. 收盘>MA20且MA20向上 3. 剔ST/退 4. 当日量=涨停日量15%~50%(缩量)
5. 所属行业当日涨停≥3家(梯队,新浪行业图) 6. 涨停日主力净占比≥15%(东财fflow f57)
→ 六因子排序(缩量30/梯队25/主力20/新鲜度10/趋势10/卫生5)→取前三(**可买数=3−当前持仓数,持仓上限3只**)→一字板顺延→买入价=选股日收盘价锁定。

**卖出(次一交易日起每日评估,优先级从上到下)**:
1. 跌停→跌停价跑(封死顺延) 2. 炸板累计>3→走 3. 收盘涨停→续命 4. **无涨停无跌停:持仓满3个交易日(含买入日)→尾盘走,未满持有**。
卖出→写冷却簿+移出自选(仅 source='system' 的条目)。

## 4. 日常运维(改代码后的部署 = 四步,缺一不可)

```bash
# ① 后端改动 → 不需要冻结包也行:App 优先用 venv 源码
# ② Web UI 改动(server/static/ 下 index.html/css/js)→ 同样只需重启 App:
#    守护循环:app 死掉 ~15s 自动拉起
pkill -x Watchdog        # 守护自动重启 App→新 sidecar;WebView 重载 /ui
# ③ Swift 壳改动(如 WebMainWindow)→ 需要换包,流程:
#    launchctl unload ~/Library/LaunchAgents/com.chenhong.watchdog.plist
#    pkill -x Watchdog
#    cd app/appkit && swift build -c release && ./bundle_app.sh
#    open dist/Watchdog.app && launchctl load ~/Library/LaunchAgents/com.chenhong.watchdog.plist
# ④ 重打 frozen:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/pyinstaller watchdog-server.spec --noconfirm
```

- **venv**:`/Users/chenhong/github/czsc-repo/.venv/bin/python`(跑后端脚本一律用它)
- 后端 8790,健康检查 `curl 127.0.0.1:8790/api/health`
- 日志:`$TMPDIR/wd-sidecar.log`
- 应用偏好 venv 源码,frozen(`server/dist/watchdog-server`)仅分发兜底——**frozen 改动也要测启动**(曾经 excludes 误剔 email 启动即崩)

## 5. 数据源纪律(用户明令:腾讯优先)

- **清单/K线/快照=腾讯**(qt.gtimg.cn / ifzq.gtimg.cn),**行业分类=新浪**(腾讯无公开成员接口),**东财只剩一处**:条件⑥主力净占比(fflow daykline 的 p[6]=f57,**永久缓存 data/fflow_cache.json 每票每涨停日只拉一次**)。禁止新增东财依赖。
- **一切出网必须绕 Clash 代理**(代理 127.0.0.1:7897 常挂):requests 用 `sess.trust_env=False`;urllib 用 `build_opener(ProxyHandler({}))`;git push 必须加三旗标 `-c http.proxy= -c https.proxy= -c http.https://github.com.proxy=`
- 腾讯指数K线(ifzq)已 501——交易日历用**库内大票日期序列**(selection._index_trade_days)

## 6. 十大坑(踩过,N 次复发的已标★)

1. ★**回退会吞掉之后的修复**:git 大回退前,先列出区间内所有 bug fix 单独重放;回退后逐个 grep 检查已知联动还在不在(del_watch 联动机器人票池被吞过两次)
2. ★**协议字段格式**:出场原因 `_exit_why` 被多处解析(最后括号取日期),改格式(加说明文字)必须 grep 全部解析点
3. ★**缓存覆盖度**:逐票循环调批量接口时,缓存命中必须校验"请求的 codes 都在缓存里"(snapshot_today_bars 首票顶替其余票致持仓永不评估)
4. **NSStackView 装大图/混合分隔线会约束崩解**(图压成一条/行全叠一处)——大图区和大表单用**纯 frame 布局**;FlippedStack 进滚动容器必须 `fitTo`
5. **PillBar/自绘控件 NSButton regularSquare 固有宽虚胖**——按文字实测宽定宽
6. **当日买卖盈亏口径**:当日买入的票不计当日盈亏(成本=收盘价),但**当日卖出的已实现必须算**(日盈亏=当日卖出净额+隔夜持仓浮动)
7. **Python heredoc 里中文注释符 `#` 混进 swift/python 替换脚本会炸**;批量替换必须 assert 锚点
8. **AX 自动化**:锁屏时 AX 遍历会永久阻塞(不是树大)——锁屏只走**离屏渲染测试**;自绘选中态的 AX 属性不可见→查后端请求日志;窗口重建窗口期按按钮会点到残留元素
9. **gh 通道推送**(git push 挂死时的正规快进):blob(幂等上传,PNG 也要)→tree(base_tree=远端树,条目 sha 用**远端返回的 blob sha**)→commit(parents=[远端tip])→PATCH refs→本地 `git fetch(三旗标)+reset --hard`
10. **改配置/迁移后必须重启 sidecar 再实测**(不重启=测的旧代码);`pkill -x Watchdog` 后确认进程 0 再拉起

## 7. 验证方法论(交付前必须自测)

- Swift 侧:全量 `swift test`(仓库已有大量回归:逻辑/离屏渲染/像素断言)。
  **离屏渲染**:`bitmapImageRepForCachingDisplay(in:)+cacheDisplay`→PNG 落 /tmp 目测——锁屏可跑
- 后端:直接用 venv python 调函数冒烟 + `curl` 真接口;数据类改动必须**用当日真实数据核对**(用户会拿规则逐条对)
- Web UI(主界面):浏览器直接开 `http://127.0.0.1:8790/ui` 即可测全部交互(与 App 内同一页面);写动作会真落库,测试数据用完删(参考 /api/todos POST+DELETE、/api/ledger/entries DELETE)。无头截图加 `--run-all-compositor-stages-before-draw`,否则 .page 入场动画会冻在半程拍出"半透明"
- UI 改动:AX 真实点击(AXPressAction)+ 必要时截图;改完的界面要跟用户确认观感

## 8. 用户协作偏好(重要程度不亚于代码)

- **拒绝绕行方案**:出 bug 修根因,别加旁路按钮("你就排查问题 按照正常的逻辑去做啊")
- **不许把验证甩给用户**:交付前自己端到端实测;不许说"你可以试试"
- **"全部验证通过了再给我最终版"**:多任务逐项做完再交付
- 展示用**表格**、说实话不墨迹;日期表述必须精确(会骂人);改完必须重启+实测
- 推送 GitHub 前等他指令;他要"推送上去"才推

## 9. 当前状态(2026-10-15 交接时)

- **持仓/资产/流水以实时接口为准,本文不写快照**:`curl 127.0.0.1:8790/api/portfolio`(交接时 10-13 批三只已按规则卖出结算,10-15 新买入两只;账目/台账全部在线)
- 监控级别:两卡标题行胶囊可切,settings 持久化,互不相干;缠论图窗默认跟随(交接时 股票=4h、期货=4h)
- 资产曲线/台账/飞书卡全部在线;飞书推送总开关 `settings.push_master`(不推时消息入箱留档)
- 手动选股:自选行情卡「⚡策略信号」按钮(archive=False 只算不归档,绝不碰已执行轮)

## 10. 待办/已知边界

- 行业图覆盖率 ~56%(新浪行业分类天然不全,未覆盖票条件⑤按不拦处理)
- frozen 二进制不常更新,发 Release 时记得重打+启动冒烟
- 用户作息:常关机/锁屏,launchd 守护负责拉起;盘后操作多

## 11. 历史档案(ZCode 时代,本地私有)

- `docs/project-memory/` = 前 ZCode 会话项目记忆的全量复制:全部迭代细节(v44–v125)、每个 bug 的根因与修复教训、用户偏好原文、chan-monitor 项目存档。
- **含个人账务/持仓等敏感信息,已 gitignore,绝不提交**(本仓库公开)。
- 排查"似曾相识"的问题时先 grep 这里(按版本号 v102 等直查最快);AGENTS.md 是它的精炼版。

## 隐私红线(2026-10-16 定)

- **个人数据永不入 git**:持仓/资产/账本流水/待办目标/飞书 webhook/真实自选与信号,一律不进仓库(含测试夹具、种子 SQL、截图、提交信息)。
- 测试夹具只用**合成数据**(Fixtures/ 已全部合成化,新增夹具照此执行);种子迁移只放公开口径的演示数据。
- 需要真实接口形状时:先抓真实响应 → 立刻替换人名/代码/金额为演示值再入库。
- 截图入库前逐张目检:真实自选列表/信号卡/持仓卡/webhook 一律裁掉或用演示数据重截。
- 历史已因隐私做过一次孤儿压缩(2026-10-16);**不要再把真实数据提交后指望"下次删掉"——一旦推上去就得再洗一次历史**。
