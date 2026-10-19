# 测试与回归手册

> 配套:`scripts/regression.sh`(tier1 离线 / tier2 联网)+ `server/tests/`(单元测试)。
> **铁律:每次调整必跑 `./scripts/regression.sh all`,全绿才能交付;每个新修的 bug 必须
> ①加最小回归用例 ②登记本文档「回归日志」。**
> 隐私纪律:夹具一律合成数据;断言不写死真实金额/持仓/代码(需要形状时先抓真实响应、替换为演示值)。

## 0. 怎么跑

| 命令 | 用途 | 前提 |
|---|---|---|
| `./scripts/regression.sh all` | 交付前全量(tier1 + tier2) | sidecar 在跑(8790),只读不写库 |
| `./scripts/regression.sh tier1` | 只跑离线静态 + 单测 | 无(App 可不开) |
| `cd app/appkit && swift test` | Swift 壳回归(逻辑/离屏渲染/像素断言) | 改 Swift 时必跑 |
| 浏览器开 `http://127.0.0.1:8790/ui` | 手工链路核验(与 App 内同一页面) | sidecar 在跑 |

## 1. tier1 · 离线自动化(脚本自动跑)

| 检查 | 内容 | 失败含义 |
|---|---|---|
| JS 语法 | `node --check` 全部 11 个 js(清单取自 index.html) | 前端任意 js 语法错 |
| 资源完整性 | index.html 引用的 15 个 js/css 全部存在;`core.js` 最先、`main.js` 最后 | 资源缺失/加载顺序错 |
| Python 编译 | routers / services / tests / main.py | 后端语法错 |
| 单元测试 | 25 例(下表),不触碰真实库 | 逻辑回归 |

### 单元测试用例清单(server/tests)

**test_push_routing.py — 飞书路由与发件箱状态机**

| 用例 | 守什么 |
|---|---|
| test_norm_code | 代码归一 `sh.600001`/`sz.000002`/`C0` → 可比较键 |
| test_futures_only_broadcast | 期货信号只进广播通道,不进个股专线 |
| test_subscribed_stock_hits_owner_and_broadcast | 命中订阅的股票信号 → 专线 + 广播 |
| test_unmatched_code_still_broadcast | 无匹配订阅的信号只进广播 |
| test_account_cards_broadcast_only | 账户卡(卖出/选股/持仓/买入)默认只进广播通道 |
| test_account_cards_flag_extends_to_dedicated | 勾选 account_cards 的专线收账户卡;信号定向不受影响 |
| test_bad_codes_json_treated_as_broadcast | 坏订阅 JSON 容错为广播 |
| test_coded_message_routes_subscription_only(flush) | 入箱→flush 端到端定向 |
| test_stock_message_routes_owner_plus_broadcast(flush) | 同上,股票版 |
| test_account_card_broadcast_only(flush) | 账户卡 flush 定向 |
| test_account_card_routes_to_flagged_channel(flush) | 勾选通道收账户卡(flush 级) |
| test_partial_failure_retries_and_marks_failed_target | 部分目标失败 → 整体 pending 重试,失败目标记录 ok=0 |
| test_no_matching_channel_marks_skipped | 订阅过滤后无人收 → skipped(留档不重试) |
| test_webhook_19001_marks_permanent_silent | webhook 失效(19001) → 单次尝试后静默,不阻塞消息 |
| test_transient_failure_backoff_and_terminal_failed | 退避 1m/5m/15m;第 4 次仍 15m;第 5 轮转 failed 终态且**必须落库** |
| test_direct_test_records_immediately | 「发送测试卡」直发后落终态记录(ok=1/2/0)→ 通道卡「状态/最近投递」立即可刷新 |
| test_repush_to_target_records_and_targets_only | 补发:只直发指定通道(不惊动广播/其他专线),落新终态记录;失败 19001 → ok=2 |

**test_futures_signal_dedup.py — 期货信号去重**

| 用例 | 守什么 |
|---|---|
| test_cross_day_same_bar_never_repushed | 同一 bar 跨天不得重发(实盘曾重复 8 次) |
| test_new_day_new_bar_still_pushes | 新交易日的未推 bar 正常推(别防过头) |
| test_new_signal_pushes_once_then_day_debounce | 新信号推一次;同日同类静默防轰炸 |
| test_prune_keeps_recent_drops_old | 去重簿裁剪(35 天) |
| test_5m_footer_tag_correct | 卡片 footer 级别标签口径 |

**test_migrations.py — 迁移完整性**

| 用例 | 守什么 |
|---|---|
| test_all_migrations_applied_in_order | 全新库按序应用到最新版(user_version == 最大迁移号) |
| test_rerun_is_idempotent | 重复迁移幂等 |
| test_key_tables_and_columns | 关键列:push_outbox.retries/next_try_at(v24)、code(v25)、feishu.account_cards(v26) |

## 2. tier2 · 联网冒烟(脚本自动跑,只读)

`scripts/check_endpoints.py`,18 项断言:

| 接口 | 断言 |
|---|---|
| /api/health | status/db ok;schema ≥ 26;模块数 = 15 |
| /api/ui/bootstrap | 含 portfolio/todos/push/watch/tail;资产口径字段齐全;飞书通道 ≥ 3 且字段(id/name/codes/account_cards/ok/last_id);push.today 为列表;选股轮三键;自选列表 |
| /api/ui/live | 五区块(portfolio/quotes/watch/push/trades);push 含 today/channels |
| /api/portfolio | 12 个口径字段齐全(total/cash/市值/本金/累计与当日盈亏/持仓/同步时间等) |
| /api/chan/feishu/config | bots 含 account_cards 字段 |

> tier2 只读;需要写动作的手测数据,用完必须删(todos DELETE / ledger entries DELETE)。

## 3. 关键链路人工核验清单(涉及该面板的改动必做)

| 面板 | 步骤 | 预期 |
|---|---|---|
| 今日页 · 时间轴 | 打开今日页 | **时间倒序(最新在最上)**、贴顶 0 偏移;滚到中部触发重绘不跳位;行点击 → 对应抽屉(流水/待办/推送/台账/买卖→原生 K 线) |
| 今日页 · 盘中刷新 | 交易时段停留 10s+ | `/api/ui/live` 每 3 秒一次;总资产/今日盈亏/持仓刷新但图表不重绘;`document.hidden` 不轮询;回前台立即全量 |
| 交易页 · 分段 | 持仓/自选/买卖明细三段 | 买卖明细含今日买卖;`?seg=trades` 直达 |
| 交易页 · 买卖明细范围 | 默认「近10天」;页头「范围」下拉切换 | 默认只显示最近 10 天(含今日)内有买卖动作的轮次;切近30天/全部即时刷新;底部「区间已实现净额」随范围变化;3s 轮询不打断下拉(控件静态在页头) |
| 交易页 · 飞书推送 | 点通道卡 | 编辑抽屉(名称/webhook/订阅/账户卡——**勾选态须肉眼可见**)保存即生效;发送测试卡有真实结果**且落档**,通道「状态/最近投递」立即刷新 |
| 系统页 | 推送总开关/测试推送 | 总开关 off 时只入箱留档;测试卡进通知群 |
| 原生壳 | `--chart 代码 [名称]` / 设置窗 | K 线窗打开、设置窗正常(WebView 桥 wd) |

## 4. 回归日志(新修 bug 必登记)

| 日期 | 提交 | 根因 | 回归用例 |
|---|---|---|---|
| 2026-10-19 | 45f217d | 发件箱失败无退避终态,僵尸 pending | test_transient_failure_backoff_and_terminal_failed |
| 2026-10-19 | f545be5 | 通道订阅形同虚设,期货信号也投个股专线 | TargetFilterTest 全组 |
| 2026-10-19 | f545be5 | 期货信号跨天重复重发(实盘 8 次) | test_futures_signal_dedup 全组 |
| 2026-10-19 | 15a4125 | 买卖明细视图缺失(Web 换版时未迁移) | 人工核验 · 交易页分段 |
| 2026-10-19 | a937a66 | 盘中总资产/今日盈亏不刷新 | tier2 live + 人工核验 · 盘中刷新 |
| 2026-10-19 | a937a66 | 时间轴缺消费/待办/买卖/推送事件 | 人工核验 · 时间轴 |
| 2026-10-19 | deaee37 | 专线收不到账户卡(无通道开关) | test_account_cards_flag_extends_to_dedicated + flush 版 |
| 2026-10-19 | 本批 | 终态清理 UPDATE 无 commit,pendings 为空时随 close 回滚(僵尸 pending 复发口) | test_transient_failure_backoff_and_terminal_failed(第 5 轮断言) |
| 2026-10-19 | ed1ef1c | 时间轴升序需滚到底看最新 | 人工核验 · 时间轴倒序 |
| 2026-10-19 | 本批 | 「发送测试卡」直发不落投递记录→修好 webhook 后通道状态不刷新 | test_direct_test_records_immediately |
| 2026-10-19 | 本批 | 账户卡复选框被 `.dwf input` 样式盖掉原生勾选外观(实际已勾选,看着像没勾) | 人工核验 · 飞书推送(勾选态可见) |
| 2026-10-19 | 本批 | 专线静默期间已发账户卡无法补发(缺按通道补发能力) | test_repush_to_target_records_and_targets_only + 实操 #380-383 补发成功 |

## 5. 后续补测(已知缺口)

- selection.py 纯函数(六条件/六因子/滚动集)单测
- smart_entry / numbers 导入去重单测
- Swift 离屏渲染快照接入脚本(锁屏可跑)
- 今日时间轴滚动行为的浏览器自动化(现为人工核验)
