/* 看门狗 Web 工作台 · 今日页渲染 */
/* ---------- 今日页 ---------- */
function renderToday(){
  const p = D.portfolio;
  $('#kpi-total').textContent = m0(p.total);
  $('#kpi-cashmv').textContent = '现金 '+m0(p.cash)+' · 持仓 '+m0(p.market_value);
  $('#kpi-day').className = 'num ' + cls(p.day_pnl);
  $('#kpi-day').textContent = mSgn(p.day_pnl);
  $('#kpi-day2').innerHTML = '<span class="'+cls(p.day_pnl)+'">'+p.day_pnl_pct.toFixed(2)+'%</span> · 持仓 '+p.holdings.length+' 只';
  const un = undoneTodos();
  $('#kpi-todo').textContent = un.length;
  $('#kpi-todo2').textContent = '其中逾期 '+overdueTodos().length+' 件';
  const mExp = D.summaries[D.months[0].month].expense;
  $('#kpi-exp').textContent = yuan(mExp);
  $('#kpi-exp2').textContent = '今天 '+yuan(todaySpend())+' · '+todayEntries().length+' 笔';

  const RNG = { '1m':'近 1 月', '3m':'近 3 月', 'all':'全部' };
  $('#rangeSeg').innerHTML = '<div class="dd" id="rangeDD"><button class="dd-btn" data-act="dd-toggle">'+RNG[S.range]
    +'<svg class="chev" viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg></button><div class="dd-menu">'
    + Object.keys(RNG).map(v=>'<div class="dd-item'+(S.range===v?' on':'')+'" data-act="range" data-v="'+v+'">'+RNG[v]
      + (S.range===v?'<svg viewBox="0 0 24 24"><path d="M5 12l4.5 4.5L19 7"/></svg>':'')+'</div>').join('')
    + '</div></div>';
  renderChart();

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

  const tl = [
    {k:'sync', time:hhmm(D.live.synced_at||'')||'17:28', cls:'tl-ok', text:'实盘台账已同步 · 净值 '+m0(D.live.total_now)+' · 累计 '+D.live.rounds+' 回合'},
    {k:'settle', time:'15:00', cls:'tl-plan', text:'收盘结算 · 无卖出则持仓顺延(以 15:00 结算为准)'},
    {k:'select', time:'14:55', cls:'tl-plan', text:'自动选股 · 下一轮 '+D.tail.next_run_day+'(最近一轮 '+D.tail.date+' 已执行 · '+D.tail.stocks.length+' 只)'},
    {k:'auction', time:'09:15', cls:'tl-plan', text:'集合竞价开始'},
  ];
  $('#tlBody').innerHTML = tl.map(t=>'<div class="tl-row clickable" data-act="open-tl" data-k="'+t.k+'">'
    +'<span class="tl-time">'+t.time+'</span><span class="tl-dot '+t.cls+'"></span>'
    +'<span class="tl-main">'+t.text+'</span><span class="tl-go">›</span></div>').join('');
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
