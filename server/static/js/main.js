/* 看门狗 Web 工作台 · 事件绑定 / 卡片折叠 / 启动与轮询(必须最后引入) */
/* ---------- 事件绑定 ---------- */
/* 原生下拉(select)变更不走 click 委托 */
document.addEventListener('change', ev=>{
  if (ev.target && ev.target.id === 'tradeRange'){ S.tradeRange = ev.target.value; renderTrade(); }
});
document.addEventListener('click', ev=>{
  document.querySelectorAll('.dd.open').forEach(d=>{ if(!d.contains(ev.target)) d.classList.remove('open'); });
  if (S.aiOpen && !ev.target.closest('#aiPanel') && !ev.target.closest('[data-act="ai-open"]')){
    S.aiOpen = false; renderAi();   /* 点其他地方 = 最小化;已发出的记录后台继续 */
  }
  const el = ev.target.closest('[data-act]'); if(!el) return;
  const a = el.dataset.act;
  if (a==='nav') navigate(el.dataset.page);
  else if (a==='close-drawer') closeDrawer();
  else if (a==='dd-toggle'){ el.closest('.dd').classList.toggle('open'); }
  else if (a==='range'){ S.range = el.dataset.v; renderToday(); }
  else if (a==='cal'){ S.calSel = el.dataset.date; renderCal(); }
  else if (a==='seg'){ S.tradeSeg = el.dataset.v; renderTrade(); }
  else if (a==='open-hold') openHold(el.dataset.code);
  else if (a==='open-trades'){ S.tradeSeg = 'trades'; renderTrade(); navigate('trade'); }
  else if (a==='open-watch') openWatch(el.dataset.code);
  else if (a==='open-tl') openTl(el.dataset.k);
  else if (a==='open-todo') openTodo(+el.dataset.id);
  else if (a==='open-pick') openPick(el.dataset.code);
  else if (a==='open-entry') openEntry(+el.dataset.id);
  else if (a==='open-cat') openCat(el.dataset.name);
  else if (a==='toggle-todo'){ const t = D.todos.find(x=>x.id===+el.dataset.id); if(!t) return; const nv = !t.done;
    fetch('/api/todos/'+t.id, {method:'PATCH', headers:{'Content-Type':'application/json'}, body: JSON.stringify({done:nv})})
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return refreshData(); })
      .then(()=>{ toast(nv?'已标记完成 · 已写入':'已重新打开 · 已写入'); if ($('#dwBody').innerHTML.includes('待办')) closeDrawer(); })
      .catch(()=>toast('写入失败:后端不可达')); }
  else if (a==='mcat'){ S.cat = el.dataset.v; renderMoney(); closeDrawer(); }
  else if (a==='mtrend'){ S.month = el.dataset.v; S.cat='全部'; renderMoney(); }
  else if (a==='month-shift'){ const i = D.months.findIndex(x=>x.month===S.month) - (+el.dataset.d); if(i>=0 && i<D.months.length){ S.month = D.months[i].month; S.cat='全部'; renderMoney(); } else toast('没有更多月份了'); }
  else if (a==='lv'){ const side = el.dataset.t==='s'?'s':'f', v = el.dataset.v;
    const key = side==='s' ? 'lvStock' : 'lvFut';
    const url = side==='s' ? '/api/chan/monitor-level' : '/api/chan/futures-level';
    S.lvPending = side;                      /* 写入期间禁止轮询回填,胶囊不来回跳 */
    S[key] = v; renderTrade();
    fetch(url, {method:'PUT', headers:{'Content-Type':'application/json'}, body: JSON.stringify({level:v})})
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status);
        S.lvPending = null;
        return refreshData().then(()=>{ toast('已切到 '+v+' · 已写入 settings 并触发重扫'); setTimeout(fetchFutures, 1200); }); })
      .catch(()=>{ S.lvPending = null;
        /* 失败不保留乐观值:回填服务器真实级别,避免"胶囊显示已切但图窗仍按旧级别" */
        return refreshData().then(()=>toast('切换失败 · 当前服务器级别 '+(side==='s'?S.lvStock:S.lvFut))); }); }
  else if (a==='add-todo'){ const v = $('#newTodo').value.trim(); if(!v) return;
    fetch('/api/todos', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({title:v, priority:2})})
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); $('#newTodo').value=''; return refreshData(); })
      .then(()=>{ navigate('time'); toast('待办已写入'); })
      .catch(()=>toast('写入失败:后端不可达')); }
  else if (a==='food-ai'){ const t=$('#foodText').value.trim(); if(!t) return;
    el.disabled = true;
    fetch('/api/food', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({text: t, meal: $('#foodMeal').value || ''})})
      .then(async r=>{ const j = await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.detail || ('HTTP '+r.status));
        $('#foodText').value = '';
        toast('已记 '+j.items.length+' 条 · 合计 '+f0(j.total)+' kcal(估算)'); return refreshData(); })
      .catch(e=>toast('AI 记录失败:'+e.message))
      .finally(()=>{ el.disabled = false; }); }
  else if (a==='food-add'){ const food = $('#foodName').value.trim(); if(!food){ toast('填一下食物名'); return; }
    fetch('/api/food', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({food: food, portion: $('#foodPortion').value.trim(),
                            kcal: $('#foodKcal').value === '' ? null : $('#foodKcal').value,
                            meal: $('#foodMeal').value || ''})})
      .then(async r=>{ const j = await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.detail || ('HTTP '+r.status));
        $('#foodName').value = $('#foodPortion').value = $('#foodKcal').value = '';
        toast('已记录'); return refreshData(); })
      .catch(e=>toast('记录失败:'+e.message)); }
  else if (a==='food-del'){ fetch('/api/food/'+el.dataset.id, {method:'DELETE'})
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return refreshData(); })
      .then(()=>toast('已删除')).catch(()=>toast('删除失败')); }
  else if (a==='food-profile'){
    fetch('/api/food/profile', {method:'PUT', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({height_cm: $('#hpHeight').value, weight_kg: $('#hpWeight').value,
                            age: $('#hpAge').value, sex: $('#hpSex').value, activity: $('#hpAct').value})})
      .then(async r=>{ const j = await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.detail || ('HTTP '+r.status));
        toast('档案已存 · 推荐每日 '+f0(j.recommended)+' kcal'); return refreshData(); })
      .catch(e=>toast('保存失败:'+e.message)); }
  else if (a==='food-target'){
    fetch('/api/food/target', {method:'PUT', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({kcal: $('#hpTarget').value})})
      .then(async r=>{ const j = await r.json().catch(()=>({})); if(!r.ok) throw new Error(j.detail || ('HTTP '+r.status));
        $('#hpTarget').value = ''; toast('每日目标已改为 '+f0(j.target)+' kcal'); return refreshData(); })
      .catch(e=>toast('保存失败:'+e.message)); }
  else if (a==='sell-eval'){ dwHead('卖出评估','明日 '+nextTradeDay(TODAY0_STR)+' 尾盘'); draw('<div class="dw-sec"><div class="hd">将评估的持仓</div>'
      + D.portfolio.holdings.map(h=>kv(h.name, '第 '+tradeDaysSince(h.buy_date)+' 日 · 浮盈 '+sgn(h.pnl_pct)+'%')).join('')
      + '</div><div class="dw-sec"><div class="hd">规则</div><div class="dw-note" style="margin:0">满 3 个交易日 → 尾盘走;若跌停 → 跌停价跑(封死顺延);炸板累计 >3 → 走;收盘涨停 → 续命。'
      + '</div></div><div class="dw-actions"><button class="btn" data-act="soon" data-what="导出评估结果">导出评估结果</button></div>'); }
  else if (a==='sim-scan'){ if (S.scanSim) return; S.scanSim = true; const b = $('#scanBtn'); b.textContent='扫描中…'; setTimeout(()=>{ b.textContent='模拟清理扫描'; S.scanSim=false; toast('模拟扫描完成 · 未真实执行清理(避免误删)'); }, 1300); }
  else if (a==='disk-analyze') toast('「磁盘分析」此入口暂未开放(后端 /api/disk/analyze 全盘走查较慢)');
  else if (a==='open-push') openPush(+el.dataset.id);
  else if (a==='open-bot') openBot(el.dataset.id);
  else if (a==='bot-save'){
    const id = el.dataset.id;
    const name = $('#botName').value.trim(), hook = $('#botHook').value.trim();
    if (!name || !hook) return toast('名称与 Webhook 不能为空');
    const codes = $('#botCodes').value.split(/[\s,，、]+/).filter(Boolean);
    const acct = $('#botAcct').checked;
    toast('保存中…');
    fetch('/api/chan/feishu/bots/'+id, {method:'PUT', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({name, webhook: hook, codes, account_cards: acct})})
      .then(r=> r.ok ? r.json() : r.json().catch(()=>({})).then(j=>{ throw new Error(j.detail||('HTTP '+r.status)); }))
      .then(()=>refreshData())
      .then(()=>{ toast('通道已保存 · 已写入'); openBot(id); })
      .catch(e=>toast('保存失败:'+(e.message||'后端不可达')));
  }
  else if (a==='bot-test'){ toast('测试卡发送中…');
    fetch('/api/chan/feishu/test', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({bot_id: el.dataset.id})})
      .then(r=>r.json()).then(j=>{ toast(j.status==='sent' ? '测试卡已送达「'+j.target+'」 ✓'
        : '测试失败:'+((j.last_error||'未知错误').replace('feishu ',''))); })
      .catch(()=>toast('发送失败:后端不可达')); }
  else if (a==='push-master'){ const nv = !pushMasterOn();
    fetch('/api/ui/push-master', {method:'PUT', headers:{'Content-Type':'application/json'}, body: JSON.stringify({on:nv})})
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); D.push.master = nv?'on':'off'; D.feishu.master = nv; renderPush(); renderSys(); toast('飞书总开关 → '+(nv?'开':'关')+' · 已写入(off 时只入箱留档)'); })
      .catch(()=>toast('写入失败:后端不可达')); }
  else if (a==='pool-toggle'){ S.poolOpen = !S.poolOpen; renderPool(); }
  else if (a==='push-toggle'){ S.pushOpen = !S.pushOpen; renderPush(); }
  else if (a==='push-test'){ toast('测试卡发送中…');
    fetch('/api/chan/feishu/test', {method:'POST', headers:{'Content-Type':'application/json'}, body: '{}'})
      .then(r=>r.json()).then(j=>{ toast(j.status==='sent' ? '测试卡已发送到通知群 ✓' : '测试卡状态:'+(j.status||'?')+(j.last_error?(' · '+j.last_error):'')); refreshData(); })
      .catch(()=>toast('发送失败:后端不可达')); }
  else if (a==='blind') toggleBlind();
  else if (a==='ai-open'){ S.aiOpen = true; if (el.dataset.intent) S.aiIntent = el.dataset.intent; renderAi(); setTimeout(()=>$('#aiInput').focus(), 0); }
  else if (a==='ai-close'){ S.aiOpen = false; S.aiIntent = null; renderAi(); }
  else if (a==='ai-send') aiSend();
  else if (a==='ai-example'){ S.aiOpen = true; $('#aiInput').value = el.dataset.txt || ''; aiSend(); }
  else if (a==='soon') toast('「'+el.dataset.what+'」此入口暂未开放');
  else if (a==='card-fold'){
    const card = el.closest('.card'); const key = el.dataset.key;
    card.classList.toggle('cfold');
    const open = !card.classList.contains('cfold');
    el.textContent = open ? '▾' : '▸';
    const mm = JSON.parse(localStorage.getItem('wd-fold') || '{}');
    mm[key] = !open; localStorage.setItem('wd-fold', JSON.stringify(mm));
  }
  else if (a==='open-settings'){ wdNative({cmd:'settings'}); }
  else if (a==='open-chart'){ wdNative({cmd:'kline', code: el.dataset.code, name: el.dataset.name||el.dataset.code}); }
  else if (a==='watch-del'){ const code = el.dataset.code;
    fetch('/api/market/watchlist/'+code, {method:'DELETE'})
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); closeDrawer(); return refreshData(); })
      .then(()=>toast('已从自选移除 '+code+' · 已写入'))
      .catch(()=>toast('删除失败:后端不可达')); }
  else if (a==='sel-run'){ fetch('/api/chan/selection/run', {method:'POST'})
      .then(r=>r.json()).then(j=>{ toast(j.started ? '选股已在后台启动(只算名单,不碰已执行轮)' : '选股已在进行中');
        let left = 10; const iv = setInterval(()=>{ refreshData(); if (--left<=0) clearInterval(iv); }, 3000); })
      .catch(()=>toast('启动失败:后端不可达')); }
  else if (a==='mod-toggle'){ const id = el.dataset.id, cur = D.modules.find(x=>x.id===id), nv = !(cur&&cur.enabled);
    fetch('/api/modules/'+id, {method:'PUT', headers:{'Content-Type':'application/json'}, body: JSON.stringify({enabled:nv})})
      .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); if (cur) cur.enabled = nv; renderModules(); toast((nv?'已启用 · ':'已停用 ')+(MOD_ZH[id]||id)); })
      .catch(()=>toast('写入失败:后端不可达')); }
});
$('#watchQ').addEventListener('input', e=>{ S.watchQ = e.target.value; renderTrade(); });
$('#aiInput').addEventListener('keydown', e=>{ if (e.key==='Enter'){ e.preventDefault(); aiSend(); } });
$('#newTodo').addEventListener('keydown', e=>{ if (e.key==='Enter'){ e.preventDefault(); const b=document.querySelector('[data-act="add-todo"]'); if(b) b.click(); } });
$('#foodText').addEventListener('keydown', e=>{ if (e.key==='Enter'){ e.preventDefault(); const b=document.querySelector('[data-act="food-ai"]'); if(b) b.click(); } });
document.addEventListener('keydown', e=>{
  if (e.key==='Escape'){ closeDrawer(); if (S.aiOpen){ S.aiOpen = false; S.aiIntent = null; renderAi(); } }
  const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName);
  if (!typing && (e.key==='b'||e.key==='B') && !e.metaKey && !e.ctrlKey && !e.altKey) toggleBlind();
  if (!typing && (e.key==='a'||e.key==='A') && !e.metaKey && !e.ctrlKey && !e.altKey){ S.aiOpen = true; renderAi(); $('#aiInput').focus(); }
});
$('#overlay').addEventListener('click', closeDrawer);

/* ---------- 启动 ---------- */
/* 卡片折叠:全部 .card(带 chead/cal-title)卡头小箭头,状态持久化 */
function initFold(){
  const saved = JSON.parse(localStorage.getItem('wd-fold') || '{}');
  document.querySelectorAll('.card').forEach(card => {
    const head = card.querySelector(':scope > .chead, :scope > .cal-title');
    if (!head || head.querySelector('.coll-btn')) return;
    const page = card.closest('.page');
    const idx = page ? [...page.querySelectorAll(':scope > .card')].indexOf(card) : 0;
    const key = (page ? page.id : '?') + '#' + idx;
    card.dataset.fold = key;
    const btn = document.createElement('span');
    btn.className = 'coll-btn';
    btn.dataset.act = 'card-fold';
    btn.dataset.key = key;
    btn.title = '展开/收起';
    head.appendChild(btn);
    if (saved[key]) { card.classList.add('cfold'); btn.textContent = '▸'; }
    else btn.textContent = '▾';
  });
}

/* 脱敏眼睛:注入到每个页头(标题行右侧) */
initFold();
$$('.head').forEach(h=>h.insertAdjacentHTML('beforeend',
  '<button class="iconbtn" data-act="blind" title="一键脱敏">'+EYE_ON+'</button>'));
function boot(){
  document.title = wdLang === 'en' ? 'Watchdog' : '看门狗 Watchdog';
  S.calSel = TODAY0_STR; S.month = D.months[0].month;
  renderToday(); renderCal(); renderTrade(); renderMoney(); renderTime(); renderHealth(); renderSys(); renderModules(); renderPush(); renderPool(); renderAi();
  syncEye();
  navigate('today');
  /* 支持 ?page=trade|money|time|sys 直达(用于无头截图验收) */
  const _pp = new URLSearchParams(location.search).get('page');
  if (_pp && PAGE_META[_pp]) navigate(_pp);
  /* ?seg=hold|watch|trades 直达交易页分段(同用于验收) */
  const _sg = new URLSearchParams(location.search).get('seg');
  if (['hold','watch','trades'].includes(_sg)){ S.tradeSeg = _sg; navigate('trade'); renderTrade(); }
}
setInterval(fetchFutures, 5000);

/* ---------- 盘中实时刷新 ---------- */
/* 轻量切片(总资产/今日盈亏/持仓现价/自选行情/明细/推送面板)每 3s,与后端行情快线同频;
   60s 全量快照兜底(待办/账本/系统等低频数据);回到前台立即全量刷一次 */
let liveBusy = false, lastLiveOk = 0;
/* 单块渲染失败不能拖垮整轮刷新:曾因渲染前抛错(D.feishu 缺失等)→ 整页停在旧帧,
   但 3s 轮询请求照发,看起来就是"数据不刷新" */
function safeRender(fn, tag){
  try { fn(); } catch(e){ console.error('[render]', tag || fn.name, e); }
}
function refreshLive(){
  if (liveBusy || !D || document.hidden) return;
  liveBusy = true;
  fetch('/api/ui/live').then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); })
    .then(j=>{
      if (!D) return;
      if (checkDayRollover(j.today)) return;   /* 跨日(休眠唤醒等)→ 整页重载 */
      if (j.portfolio) D.portfolio = j.portfolio;
      if (j.watch) D.watch = j.watch;
      if (j.quotes){ D.quotes = j.quotes; lastUpdate = D.quotes.updated_at || lastUpdate; }
      if (j.trades){ D.trades = j.trades; safeRender(buildCalMap, 'buildCalMap'); }
      if (j.push){ D.push = j.push; if (D.feishu) D.feishu.master = (j.push.master === 'on'); }
      lastLiveOk = Date.now();
      safeRender(renderTodayKpis, 'todayKpis');
      safeRender(renderTodayHoldings, 'todayHoldings');
      safeRender(renderTodayTimeline, 'todayTimeline');
      safeRender(renderCal, 'cal');
      safeRender(renderTrade, 'trade');
      safeRender(renderPush, 'push');
    })
    .catch(()=>{/* 静默:下一轮再试,看门狗兜底 */})
    .finally(()=>{ liveBusy = false; });
}
setInterval(refreshLive, 3000);
/* 看门狗:盘中 live 超过 20s 没成功(渲染抛错/接口卡住)→ 立即全量重拉,自愈不留旧帧 */
setInterval(()=>{ if (!document.hidden && lastLiveOk && Date.now() - lastLiveOk > 20000) refreshData(); }, 5000);
/* 从其它 App 切回来(窗口重新激活)也补一次全量,不依赖 visibilitychange */
window.addEventListener('focus', ()=>{ if (!document.hidden) refreshData(); });
setInterval(()=>{ if (!document.hidden) refreshData(); }, 60000);
document.addEventListener('visibilitychange', ()=>{ if (!document.hidden) refreshData(); });

fetch('/api/ui/bootstrap').then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); })
  .then(j=>{ ingest(j); boot(); })
  .catch(err=>{ const m = document.querySelector('.main');
    if (m) m.innerHTML = '<div class="card" style="padding:26px;font-size:13px;line-height:1.9">本地数据加载失败:'+esc(String((err&&err.message)||err))+'<br>需要看门狗后端(127.0.0.1:8790)在线,重启 App 后自动重连。</div>'; });
