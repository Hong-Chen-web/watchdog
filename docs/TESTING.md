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
| 单元测试 | 42 例(下表),不触碰真实库 | 逻辑回归 |

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

**test_backtest_curve.py — 逐日净值曲线**

| 用例 | 守什么 |
|---|---|
| test_cumulative_by_sell_day | 按卖出日聚合并累计;同日多笔并一点 |
| test_open_round_uses_buy_date_zero_net | 未卖轮用买入日、净额 0(不虚增) |
| test_empty_ledger | 空台账 → 空曲线 |
| test_no_duplicate_dates | 绝不出现重复日期点(旧实现「最近一日」恒 0.00% 的根因) |

**test_net_proxy.py — 出网代理纪律**

| 用例 | 守什么 |
|---|---|
| test_opener_has_empty_proxy | 默认 opener 不挂任何代理(不读系统/环境代理) |
| test_install_ignores_dead_env_proxy | 环境塞死代理 + install() 后仍直连成功(2026-10-21 事故复现防线) |
| test_requests_session_trust_env_off | requests 统一入口 trust_env=False、无代理 |
| test_main_installs_before_startup | main.py 在启动链路最先安装空代理 opener |

**test_selection_guard.py — 当日行情缺失防线**

| 用例 | 守什么 |
|---|---|
| test_stale_bar_does_not_touch_position | 缺当日K线:结算记 failed,绝不写「第N/3日持有」或出场 |
| test_fresh_bar_still_evaluates | 当日K线在:防线不误伤,照常完成评估 |
| test_empty_snapshot_aborts | 当日快照为空:选股中止(不落空名单) |
| test_stale_candidates_abort | 候选日K全停在昨天:选股中止,不拿昨收入榜 |

**test_food.py — 健康页 /api/food**

| 用例 | 守什么 |
|---|---|
| test_recommended_male_sedentary | Mifflin-St Jeor 推荐公式(男 175/80/30 久坐 标准 → 1550) |
| test_weekly_loss_goal_variants | 每周减重速度:维持=TDEE/温和/标准;0.75kg/周触底保护;越界收敛 |
| test_breakdown_mode | breakdown 口径:BMR/TDEE/缺口/floored 逐项对 |
| test_recommended_female_floor | 女性下限保护(不低于 1200);取整到 10 |
| test_recommended_incomplete_profile_returns_none | 档案不全/超范围 → 不推荐 |
| test_meal_auto_by_hour | 没选餐次按钟点归档(早/午/晚/加餐) |
| test_clean_items_sanitize | AI 条目清洗:截断/限幅/非数字→未估/坏数据丢弃 |
| test_overview_empty_defaults | 空态:目标 2000 兜底、7 天日历齐全 |
| test_manual_add_patch_delete | 手动记录 → 改热量 → 删除全链路 |
| test_add_requires_food | 空提交 400 |
| test_ai_parse_failure_raises_text | 未配置大模型 → 400 文案(降级手动) |
| test_ai_text_inserts_items | AI 拆条目落库(打桩,不出网) |
| test_profile_and_target | 档案推荐/自定义目标/重存档案保留目标/清除回推荐/越界 400 |

## 2. tier2 · 联网冒烟(脚本自动跑,只读)

`scripts/check_endpoints.py`,20 项断言:

| 接口 | 断言 |
|---|---|
| /api/health | status/db ok;schema ≥ 27;模块数 = 16 |
| /api/ui/bootstrap | today = 服务器本地日期(前端跨日重载锚点);含 portfolio/todos/push/watch/tail/food;资产口径字段齐全;飞书通道 ≥ 1(数量=用户数据)且字段(id/name/codes/account_cards/ok/last_id);push.today 为列表;选股轮三键;自选列表 |
| /api/ui/live | 五区块(portfolio/quotes/watch/push/trades);push 含 today/channels |
| /api/portfolio | 12 个口径字段齐全(total/cash/市值/本金/累计与当日盈亏/持仓/同步时间等) |
| /api/chan/feishu/config | bots 含 account_cards 字段 |

> tier2 只读;需要写动作的手测数据,用完必须删(todos DELETE / ledger entries DELETE)。

## 3. 关键链路人工核验清单(涉及该面板的改动必做)

| 面板 | 步骤 | 预期 |
|---|---|---|
| 今日页 · 时间轴 | 打开今日页 | **时间倒序(最新在最上)**、贴顶 0 偏移;滚到中部触发重绘不跳位;行点击 → 对应抽屉(流水/待办/推送/台账/买卖→原生 K 线) |
| 今日页 · 盘中刷新 | 交易时段停留 10s+ | `/api/ui/live` 每 3 秒一次;总资产/今日盈亏/持仓刷新但图表不重绘;`document.hidden` 不轮询;回前台立即全量;页头「· 行情 HH:MM」随行情前进 |
| 今日页 · 刷新自愈 | 注入渲染错误(如 D.feishu 缺失)后等 3s | 其它块照常重绘,总资产回到服务器值;live 超 20s 不成功时看门狗自动全量重拉 |
| 健康页 · 记一笔 | 输入「两个包子一碗粥」回车;餐次分段切换;点空餐次行补记;「手动填热量」展开;点 × 删除 | AI 拆成多条并估千卡(~5s),环形进度/合计即时更新;空行点击切到该餐并聚焦输入框;删除后合计回落;折叠按钮不与餐次分段重叠 |
| 健康页 · 热量目标 | 填身高/体重/年龄/性别/活动量 + 「每周想减」保存 | 显示推荐值及算法明细(BMR/TDEE/缺口);维持体重缺口=0;自定义目标覆盖推荐,清空回推荐;超标日红柱 |
| 今日页 · 跨日/休眠唤醒 | App 跨夜不关,次日唤醒 | 首次轮询发现服务器日期≠页面日期 → **整页自动重载**;副标题日期=当天,状态随钟点(盘前/盘中/已收盘);时间轴/日历/买卖明细窗口锚点=当天 |
| 今日页 · 最近一日 | 资产曲线 | 曲线每日一点(无重复日期);「最近一日」= 最后交易日 vs 前一交易日(不再恒 0.00%) |
| 交易页 · 分段 | 持仓/自选/买卖明细三段 | 买卖明细含今日买卖;`?seg=trades` 直达 |
| 交易页 · 监控级别 | 点级别胶囊(股票/期货);已开原生 K 线窗放着不动 | 胶囊只在**写入成功后**才显示新级别(失败自动回填服务器级别并提示「当前服务器级别」);已开 K 线窗 3s 内自动跟到新级别(后端日志出现新 level 的 chartdata 请求) |
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
| 2026-10-20 | 本批 | WebView 跨夜/休眠后日期与盘中状态停在加载时刻(今日页显示昨日「已收盘」,时间轴/日历/明细窗口锚点全停在昨天;数据本身是新的) | tier2 today 断言 + 人工核验 · 跨日/休眠唤醒 |
| 2026-10-20 | 本批 | 净值曲线追加"最新持仓买入日 + summary.assets"伪日期点 → 同日重复两点 → 「最近一日」恒 0.00% | test_backtest_curve 全组 |
| 2026-10-20 | 本批 | 监控级别胶囊乐观值:PUT 失败仍显示新级别(服务器仍旧级别),K 线窗按旧级别出图;且已开图窗不跟随监控级别切换 | 实操:失败注入回填 15m + 胶囊/服务器/图窗 chartdata 日志三处对齐(30m→15m);tier2 19 项 |
| 2026-10-20 | 本批 | live 刷新链无隔离:渲染前任一异常(如 D.feishu 缺失)让 3s 轮询"请求照发、整页不重绘",看着像数据不刷新且无从判断 | 注入复现(feishu 缺失+total 篡改)→ 3s 内自愈回 85,965;页头新增「· 行情 HH:MM」新鲜度 |
| 2026-10-20 | 本批 | 新功能:健康页(饮食明细 + AI 估热量 + 身高体重推荐目标),迁移 v27(food_entries + 模块 food) | test_food 11 例全绿;实操:AI「两个包子一碗粥」拆 3 条 660 kcal,手动/删除/档案/目标/7 天趋势全点过;tier2 20 项 |
| 2026-10-21 | 本批 | 健康页 UI 重构(对齐 Lifesum/Yazio 的信息层级):环形热量 hero、餐次分组、折叠手动输入、趋势柱背景槽、档案推荐面板;修折叠按钮与餐次分段重叠、目标标签压住「有记录」、零值柱残留 | 浅色/深色/1080 窄屏截图逐张目检;浏览器实操:餐次切换→手动记 100 kcal(落晚餐)→删除还原;点空餐次行切餐并聚焦;42 例单测 + tier2 20 项全绿 |
| 2026-10-21 | 本批 | **实盘事故**:App 进程 urllib 默认 opener 在启动时(Clash 开着)固化系统代理 127.0.0.1:7897,代理 12:20 挂掉后进程内行情/选股/飞书全部 ECONNREFUSED(外部 curl 正常);14:55 持仓卡+选股卡推送失败 | test_net_proxy 4 例(含死代理环境直连);重启后行情 12:20 恢复 15:29、fails 归零;补发 444/445 → sent |
| 2026-10-21 | 本批 | 同日连带:断网时当日快照失败,日K只到昨天,结算把「第3/3日卖出」算成「第2/3日持有」,选股拿 10-20 收盘当现价(选股卡 6 只全为旧数据) | test_selection_guard 4 例;16:08 用真实收盘数据手动重跑 → 真实候选 1 只(吉视传媒 2.47),证实 14:55 卡片为昨日数据 |

## 5. 后续补测(已知缺口)

- selection.py 纯函数(六条件/六因子/滚动集)单测
- smart_entry / numbers 导入去重单测
- Swift 离屏渲染快照接入脚本(锁屏可跑)
- 今日时间轴滚动行为的浏览器自动化(现为人工核验)
