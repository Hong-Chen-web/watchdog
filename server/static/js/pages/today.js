/* 看门狗 Web 工作台 · 今日页渲染 */
/* ---------- 今日页 ---------- */
function renderToday(){
  if (S.page === 'today') $('#pageSub').textContent = todaySub();   /* 盘中/已收盘等状态随时钟刷新 */
  renderTodayKpis();
  renderTodayHoldings();

  const RNG = { '1m':'近 1 月', '3m':'近 3 月', 'all':'全部' };
  $('#rangeSeg').innerHTML = '<div class="dd" id="rangeDD"><button class="dd-btn" data-act="dd-toggle">'+RNG[S.range]
    +'<svg class="chev" viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg></button><div class="dd-menu">'
    + Object.keys(RNG).map(v=>'<div class="dd-item'+(S.range===v?' on':'')+'" data-act="range" data-v="'+v+'">'+RNG[v]
      + (S.range===v?'<svg viewBox="0 0 24 24"><path d="M5 12l4.5 4.5L19 7"/></svg>':'')+'</div>').join('')
    + '</div></div>';
  renderChart();

  renderTodayTimeline();
}
/* 今日时间轴:全事件流 — 流水 / 待办新建与完成 / 今日买卖 / 信号与卡片推送 / 台账同步 + 计划锚点。
   按发生时间倒序(最新在最上);同一时刻计划锚点排在实际事件前;窗口贴顶时自动跟随最新事件。 */
function renderTodayTimeline(){
  const T = TODAY0_STR, ev = [];
  /* 计划锚点(全天时间骨架) */
  ev.push({ts:'09:15:00', pri:1, cls:'tl-plan', d:{act:'open-tl', k:'auction'}, text:'集合竞价开始'});
  ev.push({ts:'14:55:00', pri:1, cls:'tl-plan', d:{act:'open-tl', k:'select'},
    text:'自动选股 · 下一轮 '+D.tail.next_run_day+'(最近一轮 '+D.tail.date+' 已执行 · '+D.tail.stocks.length+' 只)'});
  ev.push({ts:'15:00:00', pri:1, cls:'tl-plan', d:{act:'open-tl', k:'settle'}, text:'收盘结算 · 无卖出则持仓顺延(以 15:00 结算为准)'});
  /* 实盘台账同步 */
  if (D.live && D.live.synced_at) ev.push({ts:hhmm(D.live.synced_at)+':00', pri:2, cls:'tl-ok', d:{act:'open-tl', k:'sync'},
    text:'实盘台账已同步 · 净值 '+m0(D.live.total_now)+' · 累计 '+D.live.rounds+' 回合'});
  /* 今日流水(消费/收入,时间=记账时刻) */
  todayEntries().forEach(e=>{
    ev.push({ts:hhmm(e.created_at)+':00', pri:2, cls:'tl-ok', d:{act:'open-entry', id:e.id},
      text:(e.amount<0?'消费':'收入')+' · '+esc(e.payee||e.category||'—')
        +(e.note?' · '+esc(e.note):'')+' · '
        +'<b class="'+(e.amount<0?'':'up')+'">'+(e.amount<0?'':'+')+m2(e.amount)+'</b>'});
  });
  /* 待办:今日新建 / 今日完成 */
  (D.todos||[]).forEach(t=>{
    if (String(t.created_at||'').slice(0,10)===T) ev.push({ts:hhmm(t.created_at)+':00', pri:2, cls:'tl-ok',
      d:{act:'open-todo', id:t.id},
      text:'新建待办「'+esc(t.title)+'」'+(t.due_date?' · 截止 '+md(t.due_date):'')});
    if (t.done && String(t.completed_at||'').slice(0,10)===T) ev.push({ts:hhmm(t.completed_at)+':00', pri:2, cls:'tl-ok',
      d:{act:'open-todo', id:t.id},
      text:'完成待办「'+esc(t.title)+'」'});
  });
  /* 今日买卖(策略执行:卖出评估 14:55 / 收盘价买入 14:57) */
  (D.trades||[]).forEach(t=>{
    if (t.round_date===T) ev.push({ts:'14:57:00', pri:2, cls:'tl-ok',
      d:{act:'open-chart', code:t.code, name:t.name||t.code},
      text:'买入 '+esc(t.name)+' '+esc(t.code)+' · '+m0(t.shares)+' 股 @'+mpx(t.buy)+' · '+yuan(t.buy*t.shares)});
    if (t.sell_date===T) ev.push({ts:'14:55:00', pri:2, cls:'tl-ok',
      d:{act:'open-chart', code:t.code, name:t.name||t.code},
      text:'卖出 '+esc(t.name)+' '+esc(t.code)+' · 净额 '+mSgn(t.net)+' · 盈亏 '+sgn(t.pct)+'%'});
  });
  /* 今日推送(信号卡/卖出卡/选股卡/持仓卡等,时间=入箱时刻) */
  ((D.push||{}).today||[]).forEach(r=>{
    ev.push({ts:hhmm(r.created_at)+':00', pri:2, cls:'tl-ok', d:{act:'open-push', id:r.id},
      text:esc(r.kcn||r.kind)+' · '+esc(r.title)
        +(r.status==='failed'?' <b class="dn">失败</b>':r.status==='skipped'?' <span class="tagsm">停发留档</span>':'')});
  });
  ev.sort((a,b)=> a.ts===b.ts ? (a.pri-b.pri) : (a.ts>b.ts?-1:1));   /* 倒序:最新在最上 */
  const tb = $('#tlBody');
  const first = !tb.childElementCount;
  const keepTop = tb.scrollTop, prevH = tb.scrollHeight;
  const stickTop = keepTop < 48;                     /* 贴顶(正看最新)才自动跟随 */
  tb.innerHTML = ev.map(e=>'<div class="tl-row clickable" '
    + Object.keys(e.d).map(k=>'data-'+k+'="'+String(e.d[k]).replace(/"/g,'&quot;')+'"').join(' ')
    +'><span class="tl-time">'+e.ts.slice(0,5)+'</span><span class="tl-dot '+e.cls+'"></span>'
    +'<span class="tl-main">'+e.text+'</span><span class="tl-go">›</span></div>').join('');
  if (first || stickTop) tb.scrollTop = 0;           /* 首帧直接看最新;贴顶才跟随 */
  else tb.scrollTop = Math.max(0, keepTop + (tb.scrollHeight - prevH));  /* 上翻看旧事件不打扰,补偿顶部落入的新行 */
}
/* 盘中轻量刷新用:指标块 / 持仓卡可单独重绘(不动图表与时间轴) */
function renderTodayKpis(){
  const p = D.portfolio;
  $('#kpi-total').textContent = m0(p.total);
  $('#kpi-cashmv').textContent = '现金 '+m0(p.cash)+' · 持仓 '+m0(p.market_value);
  $('#kpi-day').className = 'num ' + cls(p.day_pnl);
  $('#kpi-day').textContent = mSgn(p.day_pnl);
  $('#kpi-day2').innerHTML = '<span class="'+cls(p.day_pnl)+'">'+p.day_pnl_pct.toFixed(2)+'%</span> · 持仓 '+p.holdings.length+' 只';
  /* 新鲜度直接标在页头:行情时间不前进=没刷新,一眼可见 */
  if (S.page === 'today') $('#pageSub').textContent = todaySub() + (wdLang === 'en' ? ' · Quotes ' : ' · 行情 ') + hhmm(lastUpdate);
  const un = undoneTodos();
  $('#kpi-todo').textContent = un.length;
  $('#kpi-todo2').textContent = '其中逾期 '+overdueTodos().length+' 件';
  const mExp = D.summaries[D.months[0].month].expense;
  $('#kpi-exp').textContent = yuan(mExp);
  $('#kpi-exp2').textContent = '今天 '+yuan(todaySpend())+' · '+todayEntries().length+' 笔';
}
function renderTodayHoldings(){
  const p = D.portfolio;
  $('#holdTitle').textContent = '持仓 '+p.holdings.length+' 只';
  const next = nextTradeDay(TODAY0_STR);
  $('#holdRule').textContent = '下一交易日 '+md(next)+' 满 3 日评估';
  /* 强调卡:下一交易日卖出评估提示(此前一直没填充,是旧 bug) */
  const wd = '日一二三四五六'[new Date(next+'T00:00:00').getDay()];
  $('#promoTitle').textContent = '下个交易日 · '+md(next)+' 周'+wd;
  $('#promoText').innerHTML = p.holdings.length
    ? p.holdings.length+' 只持仓满 3 个交易日 → 尾盘评估卖出<br>14:55 照常结算 + 选股,先卖出再买入'
    : '当前无持仓 · 14:55 选股后按收盘价买入前三';
  $('#holdBody').innerHTML = p.holdings.map(h=>{
    const day = tradeDaysSince(h.buy_date);
    return '<tr class="row-hover clickable" data-act="open-hold" data-code="'+h.code+'">'
      +'<td><b>'+esc(h.name)+'</b><span class="code">'+h.code+'</span></td>'
      +'<td class="num">'+mpx(h.buy_price)+'</td><td class="num">'+mpx(h.last)+'</td>'
      +'<td class="num '+cls(h.pnl_pct)+'">'+sgn(h.pnl_pct)+'%</td>'
      +'<td><span class="tagsm">'+md(h.buy_date)+' 买入 · 第'+day+'日</span></td></tr>';
  }).join('');
}
function renderCal(){
  const _b = new Date(TODAY0_STR+'T00:00:00');
  const CAL_Y = _b.getFullYear(), CAL_M = _b.getMonth();
  const CAL_DIM = new Date(CAL_Y, CAL_M+1, 0).getDate();
  const CAL_PRE = CAL_Y+'-'+String(CAL_M+1).padStart(2,'0')+'-';
  const first = new Date(CAL_Y, CAL_M, 1).getDay(); // 0=周日
  const lead = (first+6)%7; // 周一开头
  const ct = $('#calM'); if (ct) ct.textContent = wdLang === 'en'
    ? ['January','February','March','April','May','June','July','August','September','October','November','December'][CAL_M]
    : ['一月','二月','三月','四月','五月','六月','七月','八月','九月','十月','十一月','十二月'][CAL_M];
  const cy = $('#calY'); if (cy) cy.textContent = wdLang === 'en' ? CAL_Y+' · Tap a day' : CAL_Y+' · 点日期看当天';
  let cells = '';
  for (let i=0;i<lead;i++) cells += '<div class="cal-day empty"></div>';
  for (let d=1; d<=CAL_DIM; d++){
    const date = CAL_PRE+String(d).padStart(2,'0');
    const wd = (lead + d - 1) % 7;
    const c = calMap[date] || {trades:[],spend:0};
    let dots = '';
    if (c.trades.length) dots += '<i class="dt-trade"></i>';
    if (c.spend>0) dots += '<i class="dt-spend"></i>';
    cells += '<div class="cal-day'+(wd>=5?' wk':'')+(date===TODAY0_STR?' today':'')+(S.calSel===date?' sel':'')+'" data-act="cal" data-date="'+date+'">'+d
      + (dots ? '<span class="d">'+dots+'</span>' : '') + '</div>';
  }
  $('#calGrid').innerHTML = cells;
  renderCalDetail();
}
function renderCalDetail(){
  const date = S.calSel, c = calMap[date] || {trades:[],spend:0,spendList:[]};
  let html = '<div class="t">'+md(date)+(wdLang === 'en'
    ? ' ('+['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][new Date(date+'T00:00:00').getDay()]+') · Day details'
    : '('+['日','一','二','三','四','五','六'][new Date(date+'T00:00:00').getDay()]+') 当天明细')+'</div>';
  if (!c.trades.length && !c.spend) html += '<div style="color:var(--mut)">无交易、无支出</div>';
  c.trades.forEach(t=>{
    const pnl = t.pnl!=null ? ' <span class="'+cls(t.pnl)+'">'+sgn(t.pnl)+' ('+sgn(t.pct)+'%)</span>' : '';
    html += '<div class="ev"><b>'+t.side+' '+mk((t.shares/100))+'手</b><span>'+esc(t.name)+' '+mpx(t.price)+pnl+'</span></div>';
  });
  if (c.spend) html += '<div class="ev"><b>支出</b><span>'+yuan(c.spend)+' · '+c.spendList.length+' 笔</span></div>';
  $('#calDetail').innerHTML = html;
}
