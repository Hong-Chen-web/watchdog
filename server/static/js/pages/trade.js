/* 看门狗 Web 工作台 · 交易页:持仓/自选/选股 + 候选池·冷却簿 + 期货监控 */
/* ---------- 交易页 ---------- */
function segCount(){ return ['持仓 · '+D.portfolio.holdings.length, '自选 · '+D.watch.length, '买卖明细 · '+(D.trades||[]).length]; }
function renderTrade(){
  $('#tradeSeg').innerHTML = '<span data-act="seg" data-v="hold" class="'+(S.tradeSeg==='hold'?'on':'')+'">'+segCount()[0]+'</span>'
    + '<span data-act="seg" data-v="watch" class="'+(S.tradeSeg==='watch'?'on':'')+'">'+segCount()[1]+'</span>'
    + '<span data-act="seg" data-v="trades" class="'+(S.tradeSeg==='trades'?'on':'')+'">'+segCount()[2]+'</span>';
  const rw = $('#tradeRangeWrap'), rs = $('#tradeRange');
  if (rw) rw.hidden = S.tradeSeg !== 'trades';
  if (rs) rs.value = S.tradeRange;
  const idx = D.quotes.indices;
  $('#idxPills').innerHTML = Object.entries(idx).map(([n,v],i)=>{
    return '<div class="pill"><div class="ic"><svg viewBox="0 0 24 24"><path d="M4 15l5-5 3.5 3.5L19 7"/></svg></div>'
      +'<div><small>'+n+'</small><b class="num">'+f2(v.price)+'</b><span class="s2 '+cls(v.chg_pct)+'">'+sgn(v.chg_pct)+'%</span></div></div>';
  }).join('') + '<div class="pill" style="cursor:default"><div class="ic"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg></div>'
      +'<div><small>行情快线</small><b class="num" style="font-size:15px">'+hhmm(lastUpdate)+'</b><span class="s2">更新 · 失败 '+D.quotes.fails+' 次</span></div></div>';

  if (S.tradeSeg==='hold'){
    $('#tradeBody').innerHTML = '<table><thead><tr><th>股票</th><th class="num">成本</th><th class="num">现价</th><th class="num">股数</th><th class="num">市值</th><th class="num">浮盈</th><th>状态</th></tr></thead><tbody>'
      + D.portfolio.holdings.map(h=>'<tr class="row-hover clickable" data-act="open-hold" data-code="'+h.code+'">'
        +'<td><b>'+esc(h.name)+'</b><span class="code">'+h.code+'</span></td>'
        +'<td class="num">'+mpx(h.buy_price)+'</td><td class="num">'+mpx(h.last)+'</td>'
        +'<td class="num">'+m0(h.shares)+'</td><td class="num">'+m0(h.value)+'</td>'
        +'<td class="num '+cls(h.pnl_pct)+'">'+sgn(h.pnl_pct)+'%</td>'
        +'<td><span class="tagsm">第'+tradeDaysSince(h.buy_date)+'日</span></td></tr>').join('')
      + '</tbody></table>';
    $('#tradeNote').textContent = '持仓上限 3 只 · 可买数 = 3 − 持仓数 · 点击行看卖出评估与规则。';
  } else if (S.tradeSeg==='watch'){
    const q = S.watchQ.trim().toLowerCase();
    const rows = D.watch.filter(w=>!q || w.code.includes(q) || w.name.toLowerCase().includes(q));
    $('#tradeBody').innerHTML = '<table><thead><tr><th>股票</th><th class="num">现价</th><th class="num">涨跌</th><th class="num">行情时间</th><th></th></tr></thead><tbody>'
      + (rows.length ? rows.map(w=>'<tr class="row-hover clickable" data-act="open-watch" data-code="'+w.code+'">'
        +'<td><b>'+esc(w.name)+'</b><span class="code">'+w.code+'</span></td>'
        +'<td class="num">'+m2(w.price)+'</td>'
        +'<td class="num '+cls(w.chg_pct)+'">'+sgn(w.chg_pct)+'%</td>'
        +'<td class="num tsmall">'+(w.quote_at?hhmm(w.quote_at):'—')+'</td><td class="num tsmall">›</td></tr>').join('')
        : '<tr><td colspan="5" style="color:var(--mut)">没有匹配「'+esc(S.watchQ)+'」的自选</td></tr>')
      + '</tbody></table>';
    $('#tradeNote').textContent = '共 '+D.watch.length+' 只自选 · 行情快线 '+hhmm(lastUpdate)+' 更新(每 3s)· 点击行看详情。';
  } else {
    const q = S.watchQ.trim().toLowerCase();
    const all = D.trades || [];
    const rng = ['10','30','all'].includes(S.tradeRange) ? S.tradeRange : '10';
    const cut = rng === 'all' ? '' : dayShift(TODAY0_STR, 1 - parseInt(rng, 10));
    const scope = cut ? all.filter(t=>(t.sell_date || t.round_date) >= cut) : all;
    const rows = scope.filter(t=>!q || String(t.code).includes(q) || String(t.name||'').toLowerCase().includes(q));
    const closed = scope.filter(t=>t.sell_date);
    const netSum = closed.reduce((s,t)=>s+(t.net||0),0);
    const rangeLabel = rng === 'all' ? '全部' : '近' + rng + '天';
    $('#tradeBody').innerHTML = '<table><thead><tr><th>轮次</th><th>股票</th><th class="num">股数</th><th class="num">买入</th><th class="num">卖出</th><th>卖出日</th><th class="num">净额</th><th class="num">盈亏%</th></tr></thead><tbody>'
      + (rows.length ? rows.map(t=>{
          const live = t.sell == null;
          return '<tr class="row-hover clickable" data-act="open-chart" data-code="'+esc(t.code)+'" data-name="'+esc(t.name||t.code)+'">'
            + '<td class="tsmall">'+md(t.round_date)+'</td>'
            + '<td><b>'+esc(t.name)+'</b><span class="code">'+esc(t.code)+'</span></td>'
            + '<td class="num">'+m0(t.shares)+'</td>'
            + '<td class="num">'+mpx(t.buy)+'</td>'
            + '<td class="num">'+(live ? '<span class="tag-acc">持仓中</span>' : mpx(t.sell))+'</td>'
            + '<td class="tsmall">'+md(t.sell_date)+'</td>'
            + '<td class="num '+cls(t.net)+'">'+(live ? '—' : mSgn(t.net))+'</td>'
            + '<td class="num '+cls(t.pct)+'">'+(live ? '—' : sgn(t.pct)+'%')+'</td></tr>';
        }).join('')
        : '<tr><td colspan="8" style="color:var(--mut)">'+(q ? '没有匹配「'+esc(S.watchQ)+'」的交易' : (all.length ? rangeLabel+'内暂无交易' : '暂无交易记录'))+'</td></tr>')
      + '</tbody></table>';
    $('#tradeNote').textContent = rangeLabel + ' · ' + scope.length + ' 笔(已结算 ' + closed.length + ' · 持仓中 ' + (scope.length - closed.length) + ') · 区间已实现净额 ' + mSgn(netSum) + (rng === 'all' ? '' : ' · 全部共 ' + all.length + ' 笔') + ' · 点击行打开原生 K 线。';
  }

  const lvS = D.stocklv, lvF = D.futlv;
  /* 胶囊跟服务器真值走(写入进行中除外):重启/其它端切换后不会被本地旧值钉住 */
  if (S.lvPending !== 's') S.lvStock = lvS.level;
  if (S.lvPending !== 'f') S.lvFut = lvF.level;
  $('#lvStock').innerHTML = lvS.choices.map(c=>'<span class="lv'+(S.lvStock===c?' on':'')+'" data-act="lv" data-t="s" data-v="'+c+'">'+c+'</span>').join('');
  $('#lvFut').innerHTML = lvF.choices.map(c=>'<span class="lv'+(S.lvFut===c?' on':'')+'" data-act="lv" data-t="f" data-v="'+c+'">'+c+'</span>').join('');

  $('#pickTag').textContent = '最近一轮 '+D.tail.date+' 已执行 · 下一轮 '+D.tail.next_run_day;
  $('#pickBody').innerHTML = D.tail.stocks.map(s=>'<tr class="row-hover clickable" data-act="open-pick" data-code="'+s.code+'">'
    +'<td><b>'+esc(s.name)+'</b><span class="code">'+s.code+'</span></td>'
    +'<td class="num">'+mpx(s.price)+'</td><td class="num">'+scoreStars(s.score)+'<span class="tsmall">'+s.score+'</span></td>'
    +'<td><span class="tag-acc">'+ (D.portfolio.holdings.some(h=>h.code===s.code) ? '已买入' : '候选') +'</span></td></tr>').join('');
}

/* ---------- 候选池 · 冷却簿 ---------- */
let POOL_ROWS = [];
function renderPool(){
  const PL = D.pool; const body = $('#poolBody');
  if (!body || !PL || !PL.codes) return;
  const holdCodes = new Set((D.portfolio.holdings||[]).map(h=>h.code));
  const tailCodes = new Set((D.tail.stocks||[]).map(x=>x.code));
  const names = {};
  (D.portfolio.holdings||[]).forEach(h=>names[h.code]=h.name);
  (D.watch||[]).forEach(w=>{ if(!names[w.code]) names[w.code]=w.name; });
  (D.tail.stocks||[]).forEach(x=>{ names[x.code]=x.name; });
  const cd = PL.cooldown || {};
  const tdDates = [...TD].sort();
  const coolLeft = code => { const sold = cd[code]; if (!sold) return null;
    const i = tdDates.indexOf(sold); if (i < 0) return null;
    const elapsed = tdDates.length - 1 - i; return elapsed < 5 ? (5 - elapsed) : 0; };
  const rows = Object.entries(PL.codes).map(([code, dates])=>{
    const last = (dates && dates.length) ? dates[dates.length-1] : '—';
    let st = '观察', cls2 = 'tagsm', left = null;
    const l = coolLeft(code);
    if (l !== null && l > 0){ st = '冷却 · 剩 '+l+' 日'; cls2 = 'tagsm'; left = l; }
    if (tailCodes.has(code)){ st = '本轮入选'; cls2 = 'tag-acc'; }
    if (holdCodes.has(code)){ st = '持仓中'; cls2 = 'tag-red'; }
    return {code, last, n:(dates||[]).length, st, cls2, left, name: names[code] || ''};
  }).sort((a,b)=> b.last.localeCompare(a.last) || b.n - a.n);
  POOL_ROWS = rows;
  const cooling = rows.filter(r => r.st.indexOf('冷却') === 0);
  const pt = $('#poolTag'); if (pt) pt.textContent = '截至 '+(PL.through||'—')+' · 池内 '+rows.length+' · 冷却中 '+cooling.length;
  const cb = $('#coolBody');
  if (cb) cb.innerHTML = cooling.length
    ? '<div class="chips2 hits" style="margin:2px 0 6px">'+cooling.map(r=>'<span>'+esc(r.code)+(r.name?' '+esc(r.name):'')+' · 剩 '+r.left+' 日</span>').join('')+'</div>'
    : '<div class="footnote" style="margin:2px 0 6px">冷却簿:当前没有冷却中的票(簿内历史 '+Object.keys(cd).length+' 条)</div>';
  const pc = $('#poolColl'); if (pc) pc.style.display = S.poolOpen ? '' : 'none';
  const shown = S.poolOpen ? rows : rows.slice(0, 20);
  body.innerHTML = shown.map(r=>'<tr class="row-hover clickable" data-act="open-chart" data-code="'+esc(r.code)+'" data-name="'+esc(r.name||r.code)+'">'
    + '<td><span class="code" style="margin:0">'+esc(r.code)+'</span></td>'
    + '<td>'+esc(r.name || '—')+'</td>'
    + '<td><span class="tagsm">'+r.last+'</span></td>'
    + '<td class="num">'+r.n+'</td>'
    + '<td><span class="'+r.cls2+'">'+esc(r.st)+'</span></td></tr>').join('')
    + (rows.length > 20 ? '<tr><td colspan="5" style="padding:0"><div class="ptoggle" data-act="pool-toggle">'+(S.poolOpen ? '收起 · 最近涨停优先 ▴' : '展开全部 '+rows.length+' 只 · 最近涨停优先 ▾')+'</div></td></tr>' : '');
}

/* ---------- 期货监控(交易页侧栏;STATE 缓存,轮询刷新) ---------- */
let FUT = null, FUTMISS = 0;
function fetchFutures(){
  if (S.page !== 'trade') return;
  fetch('/api/chan/futures').then(r => r.json()).then(j => { FUT = j; FUTMISS = 0; renderFutures(); })
    .catch(() => { if (++FUTMISS >= 3 && FUT == null){ FUT = {stocks: []}; renderFutures(); } });
}
function renderFutures(){
  const body = $('#futBody'); if (!body || !FUT) return;
  const meta = $('#futMeta');
  if (meta) meta.textContent = (FUT.quote_at ? hhmm(FUT.quote_at) : '—') + (FUT.scanning ? ' · 扫描中' : '');
  body.innerHTML = (FUT.stocks || []).map(f => {
    const dir = (f.chanpy && f.chanpy.last_bi_dir) || '';
    const dcls = dir === '向上' ? 'up' : (dir === '向下' ? 'dn' : '');
    const zs = (f.chanpy && f.chanpy.last_zs) || [];
    return '<tr class="row-hover clickable" data-act="open-chart" data-code="'+esc(f.code)+'" data-name="'+esc(f.name)+'">'
      + '<td><b>'+esc(f.name)+'</b><span class="code">'+esc(f.code)+'</span></td>'
      + '<td class="num">'+m2(f.live_price != null ? f.live_price : f.close)+'</td>'
      + '<td class="num '+cls(f.chg_pct)+'">'+sgn(f.chg_pct)+'%</td>'
      + '<td class="num">'+((f.chanpy && f.chanpy.bi_count) != null ? f.chanpy.bi_count : '—')+'</td>'
      + '<td><span class="'+dcls+'" style="font-weight:600">'+esc(dir || '—')+'</span></td>'
      + '<td class="num tsmall">'+(zs.length ? zs[0]+' − '+zs[1] : '—')+'</td></tr>';
  }).join('') || '<tr><td colspan="6" style="color:var(--mut)">没有监控中的期货品种</td></tr>';
}
