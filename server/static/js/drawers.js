/* 看门狗 Web 工作台 · 抽屉详情(持仓/自选/待办/流水/选股/推送) */
/* ---------- Drawer 内容 ---------- */
function openHold(code){
  const h = D.portfolio.holdings.find(x=>x.code===code); if(!h) return;
  const px = h.shares, day = tradeDaysSince(h.buy_date), nxt = nextTradeDay(TODAY0_STR);
  const val = h.value, cost = h.buy_price*px, pnl = val-cost;
  dwHead(h.name, '持仓详情 · '+h.code);
  draw('<div class="dw-sec"><div class="hd">头寸</div>'
    + kv('买入日', h.buy_date+' · 第 '+day+' 个交易日')
    + kv('成本 / 现价', mpx(h.buy_price)+' → '+mpx(h.last))
    + kv('股数', m0(px)+' 股')
    + kv('市值 / 成本额', m0(val)+' / '+m0(cost))
    + kv('浮动盈亏', '<span class="'+cls(pnl)+'">'+sgn(pnl)+' ('+sgn(h.pnl_pct)+'%)</span>')
    + '</div><div class="dw-sec"><div class="hd">卖出评估(按规则)</div>'
    + kv('持有进度', '第 '+day+' / 3 个交易日')
    + kv('满 3 日评估日', nxt)
    + kv('跌停跑 / 炸板>3', '未触发')
    + kv('收盘涨停续命', '未触发')
    + '</div><div class="dw-actions">'
    + '<button class="btn" data-act="soon" data-what="卖出评估">查看卖出评估</button>'
    + '<button class="btn ghost" data-act="open-chart" data-code="'+code+'" data-name="'+esc(h.name||code)+'">打开 K 线</button>'
    + '</div><div class="dw-note">规则优先级:跌停跑 → 炸板累计>3 走 → 收盘涨停续命 → 满 3 个交易日尾盘走。</div>');
}
function openWatch(code){
  const w = D.watch.find(x=>x.code===code) || D.quotes.watchlist.find(x=>x.code===code); if(!w) return;
  const inHold = D.portfolio.holdings.find(h=>h.code===code);
  dwHead(w.name, '自选 · '+w.code);
  draw('<div class="dw-sec"><div class="hd">行情</div>'
    + kv('现价', m2(w.price)+' <span class="'+cls(w.chg_pct)+'">'+sgn(w.chg_pct)+'%</span>')
    + kv('行情时间', (w.quote_at||lastUpdate).slice(11,16)+' 更新')
    + (inHold? kv('当前持仓', '是 · 第 '+tradeDaysSince(inHold.buy_date)+' 日') : '')
    + '</div><div class="dw-actions">'
    + '<button class="btn" data-act="open-chart" data-code="'+code+'" data-name="'+esc(w.name||code)+'">打开 K 线</button>'
    + '<button class="btn ghost" data-act="soon" data-what="信号监控">加入信号监控</button>'
    + '<button class="btn ghost" data-act="watch-del" data-code="'+code+'" data-name="'+esc(w.name||code)+'">从自选移除</button>'
    + '</div><div class="dw-note">自选监控跟随级别设置;有买卖点会推飞书卡。</div>');
}
function openTl(k){
  const T = {
    sync: ['实盘台账同步','chan_backtest_mirror → SQLite', [['回合数', D.live.rounds+' 笔'],['胜率', (D.live.win_rounds/D.live.rounds*100).toFixed(1)+'%'],
      ['最佳单笔','<span class="up">'+sgn(D.live.best)+'</span>'],['最差单笔','<span class="dn">'+sgn(D.live.worst)+'</span>'],
      ['起始日', D.live.start_date],['同步时间', D.live.synced_at||'—']], '台账从 chan 轮档案镜像而来,收盘后自动更新;资产曲线与持仓卡都基于它。'],
    settle: ['收盘结算','每日 15:00 按规则评估', [['今日卖出行','以 15:00 结算为准'],['当前持仓', D.portfolio.holdings.length+' 只'],['下一评估', nextTradeDay(TODAY0_STR)+' 满 3 日']],
      '有卖出会写冷却簿(卖出后 5 个交易日不再选入)并自动移出自选。'],
    select: ['自动选股','14:55 收盘价买入前三', [['最近一轮', D.tail.date+' · '+D.tail.stocks.length+' 只'],['下一轮', D.tail.next_run_day],
      ['可买数', '3 − 持仓 '+D.portfolio.holdings.length+' = '+(3-D.portfolio.holdings.length)],['买入价', '选股日收盘价锁定']],
      '候选 = 近 10 交易日涨停滚动集 − 持仓 − 冷却;六条件硬门槛 → 六因子排序 → 前三(一字板顺延)。'],
    auction: ['集合竞价','09:15 - 09:25', [['系统动作','无(9:25 快照入库)'],['监控时段','09:31 起轮询']], '竞价数据用于当日快照合成,不影响策略执行。'],
  }[k];
  dwHead(T[0], T[1]);
  draw('<div class="dw-sec">' + T[2].map(x=>kv(x[0], x[1])).join('') + '</div><div class="dw-note">'+T[3]+'</div>');
}
function openTodo(id){
  const t = D.todos.find(x=>x.id===id); if(!t) return;
  const od = t.overdue ? Math.round((new Date(TODAY0_STR) - new Date(t.due_date))/86400000) : 0;
  dwHead(t.title, (t.done?'已完成':'未完成') + ' · 优先级 '+t.priority+' / 3');
  draw('<div class="dw-sec"><div class="hd">信息</div>'
    + kv('到期日', t.due_date + (od? ' · 已逾期 '+od+' 天':'') )
    + kv('创建', t.created_at||'—')
    + kv('完成时间', t.completed_at||'—')
    + '</div><div class="dw-actions">'
    + '<button class="btn" data-act="toggle-todo" data-id="'+t.id+'">'+(t.done?'重新打开':'标记完成')+'</button>'
    + '<button class="btn ghost" data-act="soon" data-what="编辑">编辑</button>'
    + '</div><div class="dw-note">勾选/状态即时写入后端 todos 表。</div>');
}
function openPick(code){
  const s = D.tail.stocks.find(x=>x.code===code); if(!s) return;
  dwHead(s.name, '选股候选 · '+s.code);
  const h = D.portfolio.holdings.find(x=>x.code===code);
  draw('<div class="dw-sec"><div class="hd">本轮('+D.tail.date+')</div>'
    + kv('选股价(收盘锁定)', mpx(s.price))
    + kv('评分', scoreStars(s.score)+' <b>'+s.score+'</b> / 100')
    + kv('状态', h ? '已买入 '+m0(h.shares)+' 股' : '候选')
    + '</div><div class="dw-sec"><div class="hd">命中因子</div><div class="chips2 hits">'
    + s.hits.map(x=>'<span>'+esc(x)+'</span>').join('') + '</div></div>'
    + '<div class="dw-note">六因子:缩量30 / 梯队25 / 主力20 / 新鲜度10 / 趋势10 / 卫生5。评分越高排越前,取前三。</div>');
}
function openEntry(id){
  const e = D.entries.find(x=>x.id===id); if(!e) return;
  dwHead(e.payee||'流水', e.date+' · '+e.category);
  draw('<div class="dw-sec"><div class="hd">明细</div>'
    + kv('金额', '<span class="'+ (e.amount<0?'dn':'up') +'">'+(e.amount<0?'':'+')+m2(e.amount)+'</span>')
    + kv('分类', e.category)
    + kv('来源', e.source==='manual'?'手动记账':e.source)
    + kv('备注', esc(e.note||'—'))
    + '</div><div class="dw-actions">'
    + '<button class="btn" data-act="soon" data-what="编辑流水">编辑</button>'
    + '<button class="btn ghost" data-act="soon" data-what="修改分类">修改分类</button>'
    + '</div>');
}
function openCat(name){
  const sum = D.summaries[S.month]; const c = (sum.categories||[]).find(x=>x.name===name); if(!c) return;
  const cnt = D.entries.filter(e=>e.date.slice(0,7)===S.month && e.category===name && e.amount<0).length;
  dwHead(name, S.month.replace('-',' 年 ')+' 月 · 分类详情');
  draw('<div class="dw-sec">'
    + kv('本月支出', yuan(c.actual)+' · '+cnt+' 笔')
    + kv('月度预算', c.budget_month>0 ? yuan(c.budget_month) : '未设置')
    + kv('剩余', c.budget_month>0 ? '<span class="'+cls(c.remaining)+'">'+yuan(c.remaining)+'</span>' : '—')
    + kv('年度预算', c.budget_year>0 ? '¥'+m0(c.budget_year) : '未设置')
    + '</div><div class="dw-actions"><button class="btn" data-act="mcat" data-v="'+esc(name)+'">筛出该分类流水</button></div>');
}
