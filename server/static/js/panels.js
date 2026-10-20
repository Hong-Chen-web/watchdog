/* 看门狗 Web 工作台 · 飞书推送面板 + AI 记录/问答面板 */
/* ---------- 飞书推送(只读:发件箱 / 逐目标投递 / 卡面预览) ---------- */
function pushMasterOn(){ return S.pushMaster == null ? D.push.master !== 'off' : S.pushMaster; }
function renderPush(){
  const P = D.push, on = pushMasterOn();
  $('#pushMasterChip').className = 'lv' + (on ? ' on' : '');
  $('#pushMasterChip').textContent = '总开关 · ' + (on ? '开' : '关');
  $('#pushChannels').innerHTML = P.channels.map(c=>{
    const st = c.ok ? '<span class="dot ok"></span><span class="tsmall" style="margin-left:2px">送达正常</span>'
                    : '<span class="dot warn"></span><span class="tsmall" style="margin-left:2px">'
                      + (c.err_code ? 'webhook '+c.err_code+' 失效 · 已静默' : '未投递过') + '</span>';
    return '<div class="chcard clickable" data-act="open-bot" data-id="'+esc(c.id)+'" title="点击编辑通道(Webhook / 订阅 / 账户卡)">'
      +'<div class="l1">'+st+'</div>'
      +'<b>'+esc(c.name)+'</b>'
      +'<span class="sub">' + (c.codes > 0 ? '订阅 ' + c.codes + ' 只' + (c.account_cards ? ' + 账户卡' : '') : '全员广播')
      + ' · 最近投递 #' + (c.last_id || '—') + ' ›</span></div>';
  }).join('');
  const st = P.stats;
  $('#pushStats').innerHTML = [
    ['今日入箱', st.today], ['已送达', st.sent], ['待重试', st.pending], ['停发留档', st.skipped], ['失败', st.failed], ['信号卡累计', st.signal]
  ].map(x=>'<div><small>'+x[0]+'</small><b>'+x[1]+'</b></div>').join('');
  /* 右栏「信号」卡:当日推送(常驻可见) */
  const tds = P.recent.filter(m => (m.created_at||'').slice(0,10) === TODAY0_STR);
  const stag = $('#sigTag'); if (stag) stag.textContent = '今日 ' + (P.stats.today || tds.length) + ' 条';
  const sb = $('#sigBody');
  if (sb){
    sb.className = '';
    sb.innerHTML = tds.length ? tds.map(m=>{
      const t2 = m.kind==='settle' ? 'tag-red' : (m.kind==='test'||m.kind==='plan') ? 'tagsm' : 'tag-acc';
      return '<div class="td-row" data-act="open-push" data-id="'+m.id+'" style="cursor:pointer">'
        + '<span class="tsmall">'+hhmm(m.created_at)+'</span>'
        + '<span class="'+t2+'">'+esc(m.kcn)+'</span>'
        + '<span style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--body)">'+esc(m.title)+'</span>'
        + '</div>';
    }).join('') : '<div class="footnote" style="margin-top:2px">今天还没有推送</div>';
  }
  /* 主卡:记录列表可展开/收起 */
  const rows = P.recent.map(m=>{
    const ok = m.deliveries.filter(d=>d.ok===1).length, tot = m.deliveries.length || P.channels.length;
    const del = m.status==='sent' ? ('送达 '+ok+'/'+tot)
              : m.status==='pending' ? ('待重试 · 第 '+m.retries+' 次')
              : m.status==='skipped' ? '停发留档' : '失败';
    const tag = m.kind==='settle' ? 'tag-red' : (m.kind==='test'||m.kind==='plan') ? 'tagsm' : 'tag-acc';
    return '<div class="push-row" data-act="open-push" data-id="'+m.id+'">'
      +'<span class="push-time">'+hhmm(m.created_at)+'</span>'
      +'<span class="'+tag+'">'+esc(m.kcn)+'</span>'
      +'<span class="push-title">'+esc(m.title)+'</span>'
      +'<span class="push-del">'+del+'</span><span class="tl-go">›</span></div>';
  }).join('');
  $('#pushBody').innerHTML =
    '<div class="ptoggle" data-act="push-toggle">'
    + (S.pushOpen ? '收起' : '展开') + ' · 最近 ' + P.recent.length + ' 条记录 '
    + '<span class="tl-go">'+(S.pushOpen ? '▴' : '▾')+'</span></div>'
    + (S.pushOpen ? rows : '');
}
const mkCell = v => { const raw = String(v==null?'':v);
  return /^\*{0,2}[\d,]+(\.\d+)?\*{0,2}$/.test(raw) ? '<b>'+mk(raw)+'</b>' : esc(raw); };
const mkText = t => mk(esc(String(t==null?'':t)));
function openPush(id){
  const P = D.push, m = P.recent.find(x=>x.id===id) || ((P.today||[]).find(x=>x.id===id)); if(!m) return;
  const nm = {}; P.channels.forEach(c=>nm[c.id]=c.name);
  let parsed = null; try { parsed = JSON.parse(m.body||''); } catch(e) {}
  const head = '<div class="fhd"><span class="tag-acc">'+esc(m.kcn)+'</span><b>'+esc(m.title)+'</b></div>';
  let card;
  if (parsed && (parsed.rows || parsed.text || parsed.footer)) {
    let t = '';
    if (parsed.text) t += '<div class="ftext">'+mkText(parsed.text)+'</div>';
    if (parsed.rows && parsed.rows.length) {
      const cols = Object.keys(parsed.rows[0]);
      t += '<table><thead><tr>' + cols.map(c=>'<th>'+esc(c)+'</th>').join('') + '</tr></thead><tbody>'
        + parsed.rows.map(r=>'<tr>' + cols.map(c=>'<td>'+mkCell(r[c])+'</td>').join('') + '</tr>').join('')
        + '</tbody></table>';
    }
    if (parsed.footer) t += '<div class="ffoot">'+esc(parsed.footer)+'</div>';
    card = head + t;
  } else {
    card = head + '<div class="ftext">'+mkText(m.body || '(无正文)')+'</div>';
  }
  const dur = (m.sent_at && m.created_at)
    ? Math.max(1, Math.round((new Date(m.sent_at.replace(' ','T')) - new Date(m.created_at.replace(' ','T')))/1000)) + ' 秒' : '—';
  const acts = m.status==='sent' ? '已送达' : m.status==='pending' ? '待重试'
             : m.status==='skipped' ? '停发留档(总开关关)' : '失败';
  draw(
    '<div class="dw-sec"><div class="hd">卡面预览(飞书 interactive 卡)</div><div class="fcard">'+card+'</div></div>'
   +'<div class="dw-sec"><div class="hd">逐目标投递</div>'
   + (m.deliveries.length ? m.deliveries.map(d=>kv(esc(nm[d.target]||d.target), d.ok===1
       ? '<span class="dot ok" style="margin-right:6px"></span>已送达'
       : '<span class="dot warn" style="margin-right:6px"></span>'+esc((d.error||'失败').replace('feishu ','')))).join('')
     : '<div class="footnote" style="margin:0">暂无投递记录(等待发送线程处理)</div>')
   +'</div>'
   +'<div class="dw-sec"><div class="hd">流水信息</div>'
   + kv('状态', acts + (m.status==='sent' ? '' : ' · 已重试 '+m.retries+' 次'))
   + kv('入箱', m.created_at) + kv('送达', m.sent_at || '—') + kv('耗时', dur)
   + kv('去重键', '<span class="code" style="margin:0">'+esc(m.dedup_key||'—')+'</span>')
   +'</div>'
   +'<div class="dw-note">原型只读:数据来自本地发件箱 push_outbox / push_delivery,不会触发真实发送。</div>'
  );
  dwHead(m.title, m.kcn + ' · ' + m.created_at.slice(0,16));
}

/* ---------- 飞书通道编辑(重建 webhook / 改订阅 / 账户卡开关;写动作直打真接口) ---------- */
function openBot(id){
  fetch('/api/chan/feishu/config').then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); })
    .then(j=>{
      const b = (j.bots||[]).find(x=>x.id===id); if(!b) throw new Error('通道不存在');
      const c = ((D.push||{}).channels||[]).find(x=>x.id===id) || {};
      const stText = c.ok === true ? '<span class="dot ok" style="margin-right:6px"></span>送达正常'
        : (c.err_code ? '<span class="dot warn" style="margin-right:6px"></span>webhook '+c.err_code+' 失效 · 已静默'
                      : '<span class="dot warn" style="margin-right:6px"></span>未投递过');
      draw(
        '<div class="dw-sec"><div class="hd">通道状态</div>'
       + kv('状态', stText)
       + kv('最近投递', c.last_id ? '#'+c.last_id : '—')
       +'</div>'
       +'<div class="dw-sec"><div class="hd">通道配置(保存即写入,真实生效)</div>'
       +'<label class="dwf"><span>名称</span><input id="botName" value="'+esc(b.name||'')+'"></label>'
       +'<label class="dwf"><span>Webhook 地址(飞书群机器人)</span><input id="botHook" value="'+esc(b.webhook||'')+'"></label>'
       +'<label class="dwf"><span>订阅代码(空格分隔;留空 = 全员广播收全部)</span><input id="botCodes" value="'+esc((b.codes||[]).join(' '))+'" placeholder="sh.600000 sz.000001"></label>'
       +'<label class="dwf row"><input type="checkbox" id="botAcct" '+(b.account_cards?'checked':'')+'>'
       + '<span>同时接收账户卡(选股 / 持仓 / 买入 / 卖出)</span></label>'
       +'</div>'
       +'<div class="dw-actions">'
       + '<button class="btn" data-act="bot-save" data-id="'+esc(b.id)+'">保存</button>'
       + '<button class="btn ghost" data-act="bot-test" data-id="'+esc(b.id)+'">发送测试卡</button>'
       +'</div>'
       +'<div class="dw-note">测试卡会真发一条消息进该群。webhook 报 19001 = 地址已失效:到对应飞书群「设置 → 群机器人」重建后,把新地址贴回上面保存即可。</div>'
      );
      dwHead(b.name||'通道', '飞书机器人 · '+b.id);
    })
    .catch(e=>toast('读取通道配置失败:'+(e.message||'后端不可达')));
}

/* ---------- AI 记录:走后端 /api/ledger/smart-any(LLM 解析并直接落库) ---------- */
function aiSend(){
  const inp = $('#aiInput'); const t = (inp.value||'').trim();
  if (!t || S.aiBusy) return;
  S.aiBusy = true;
  S.aiLog.push({text:t, resp:null, err:null});
  inp.value = ''; renderAi();
  /* 先走只读问答引擎;判定为写/指令时转调 smart-any(保留 120s 防重) */
  fetch('/api/ai/ask', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({text:t})})
    .then(r => r.json().then(j => { if (!r.ok) throw new Error(j.detail || ('HTTP '+r.status)); return j; }))
    .then(j => {
      if (j.mode === 'write'){
        return fetch('/api/ledger/smart-any', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({text:t})})
          .then(r2 => r2.json().then(j2 => { if (!r2.ok) throw new Error(j2.detail || ('HTTP '+r2.status)); return j2; }))
          .then(j2 => { const e = S.aiLog[S.aiLog.length-1]; e.resp = j2; e.write = true; });
      }
      S.aiLog[S.aiLog.length-1].resp = {ask:j};
    })
    .catch(e => { const last = S.aiLog[S.aiLog.length-1]; if (last) last.err = String(e.message || e); })
    .finally(() => { S.aiBusy = false; renderAi();
      const last = S.aiLog[S.aiLog.length-1];
      if (last && !last.err){ toast(last.write ? '已执行(后端确认)· 列表已刷新' : '已回答 · 数据已刷新'); refreshData(); } });
}
const AI_KIND = {ledger:['账单','tag-red'], todo:['待办','tag-acc'], goal:['目标','tagsm'],
  watch_add:['加自选','tag-acc'], watch_del:['移自选','tag-red'], stock_level:['股票级别','tag-acc'],
  futures_level:['期货级别','tag-acc'], selection_run:['选股','tag-acc'], push_master:['推送开关','tag-red']};
const MOD_ZH = {portfolio:'持仓', backtest:'实盘回测', todo:'待办', ledger:'账本', annual:'年度账单',
  budget:'预算', market:'行情', strategy:'策略信号', futures:'期货', calendar:'日历',
  feishu:'飞书推送', sysmon:'系统监控', journal:'日志复盘', goals:'目标', food:'饮食健康'};
function renderAi(){
  $('#aiBar').style.display = S.aiOpen ? 'none' : '';
  $('#aiPanel').classList.toggle('on', !!S.aiOpen);
  $('#aiInput').placeholder = S.aiIntent==='todo' ? '说一句待办,如:明天9点提醒我交话费'
    : S.aiIntent==='ledger' ? '说一笔账,如:午饭25块'
    : '一句话:记账 / 待办,或「把浦发银行加自选」「期货切到30分钟」';
  $('#aiMsgs').innerHTML = S.aiLog.length ? S.aiLog.map(m => {
    const head = '<div class="ai-you">' + esc(m.text) + '</div>';
    if (m.err) return head + '<div class="ai-hint">写入失败:'+esc(m.err)+'(后端 120 秒防重,可稍后重试)</div>';
    const r = m.resp;
    if (!r) return head + '<div class="ai-hint">识别中…(大模型解析)</div>';
    if (r.ask){
      const q = r.ask;
      if (q.mode === 'none' || q.mode === 'chitchat') return head + '<div class="ai-hint">'+esc(q.answer||'…')+'</div>';
      let tbl = '';
      if (q.rows && q.rows.length){
        tbl = '<div style="overflow:auto;margin-top:6px"><table class="ai-table"><thead><tr>'
          + (q.cols||[]).map(c=>'<th>'+esc(c)+'</th>').join('') + '</tr></thead><tbody>'
          + q.rows.map(rw=>'<tr>'+rw.map(c=>'<td>'+esc(String(c))+'</td>').join('')+'</tr>').join('')
          + '</tbody></table></div>';
      }
      return head + '<div class="ai-res"><div class="ai-res-hd"><span class="tag-acc">查询</span><b>'+esc(q.type||'')+'</b></div>'
        + '<div class="ai-done">'+esc(q.answer||'')+'</div>' + tbl + '</div>';
    }
    const items = (r.parsed && r.parsed.length) ? r.parsed.map(it => {
      const kind = AI_KIND[it.type] || ['条目','tagsm'];
      let kv = '';
      if (it.type === 'ledger') kv = '<div class="ai-kv"><i>金额</i><span>'+m2(it.amount)+' 元 · '+esc(it.category||'其他')+(it.date?' · '+it.date:'')+'</span></div>';
      else if (it.type === 'todo') kv = '<div class="ai-kv"><i>截止</i><span>'+esc(it.date||'今天')+'</span></div>';
      else if (it.type === 'goal') kv = '<div class="ai-kv"><i>周期</i><span>'+esc(it.scope||'year')+'</span></div>';
      else {
        if (it.code) kv += '<div class="ai-kv"><i>代码</i><span>'+esc(it.code)+'</span></div>';
        if (it.name) kv += '<div class="ai-kv"><i>名称</i><span>'+esc(it.name)+'</span></div>';
        if (it.level) kv += '<div class="ai-kv"><i>级别</i><span>'+esc(it.level)+'</span></div>';
        if (it.type === 'push_master') kv += '<div class="ai-kv"><i>开关</i><span>'+(it.on===false||it.on==='false'?'关':'开')+'</span></div>';
      }
      return '<div class="ai-res"><div class="ai-res-hd"><span class="'+kind[1]+'">'+kind[0]+'</span><b>'+esc(it.title||'')+'</b></div>'+kv+'</div>';
    }).join('') : '';
    const lines = (r.results||[]).map(x => '<div class="ai-done">✓ '+esc(x)+'</div>').join('');
    const dup = r.dedup ? '<div class="ai-hint">120 秒防重:同句未重复写入</div>' : '';
    const eng = r.engine ? '<div style="margin-top:6px"><span class="tagsm">引擎 '+esc(r.engine)+'</span></div>' : '';
    return head + (items || '<div class="ai-hint">没识别出可记录的条目(试试带金额,或「记得…」「攒…」)</div>') + lines + dup + eng;
  }).join('') : '<div class="ai-hint">一句话:记账 / 待办 / 指令(加自选、切级别、跑选股、开关推送),也可以直接问——花费、持仓、胜率、自选、推送。</div>';
  const box = $('#aiMsgs'); box.scrollTop = box.scrollHeight;
}
function renderModules(){
  const box = $('#modBody'); if (!box || !D.modules) return;
  box.innerHTML = D.modules.map(m => '<div class="kvrow"><b>'+esc(MOD_ZH[m.id]||m.id)+'</b>'
    + '<span class="lv'+(m.enabled?' on':'')+'" style="cursor:pointer" data-act="mod-toggle" data-id="'+esc(m.id)+'">'+(m.enabled?'启用':'停用')+'</span></div>').join('');
}
