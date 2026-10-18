/* 看门狗 Web 工作台 · 核心:全局状态 S/D、格式化与脱敏、主题语言、交易日历、Toast/Drawer、导航(最先引入) */
let D = null;
const _NOW = new Date();
const TODAY0_STR = _NOW.getFullYear()+'-'+String(_NOW.getMonth()+1).padStart(2,'0')+'-'+String(_NOW.getDate()).padStart(2,'0');
const wdBridge = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wd) || null;
let wdLang = 'zh';   /* 'zh' | 'en',由 URL 参数/localStorage 决定 */
const wdNative = m => { if (wdBridge) wdBridge.postMessage(JSON.stringify(m));
  else toast('桌面 App 内可用:'+(m.cmd==='kline'?'原生 K 线窗':'原生设置窗')); };
function ingest(j){
  D = j;
  TD.clear(); (D.live.curve||[]).forEach(c=>TD.add(c.date)); TD.add(TODAY0_STR);
  for (const k of Object.keys(calMap)) delete calMap[k];
  (D.trades||[]).forEach(t=>{
    if (t.round_date) calPush(t.round_date).trades.push({side:'买', name:t.name, code:t.code, price:t.buy, shares:t.shares, round:t});
    if (t.sell_date) calPush(t.sell_date).trades.push({side:'卖', name:t.name, code:t.code, price:t.sell, shares:t.shares, pnl:t.net, pct:t.pct, round:t});
  });
  (D.entries||[]).forEach(e=>{ const c = calPush(e.date); if (e.amount<0){ c.spend += -e.amount; c.spendList.push(e); } });
  lastUpdate = D.quotes.updated_at || '—';
}
/* ---------- 主题 / 语言(原生设置为源,URL 参数透传;浏览器直开时读 localStorage) ---------- */
const URLQ = new URLSearchParams(location.search);
const _tq = URLQ.get('theme');
let WEB_THEME = _tq === 'dark' || _tq === 'sky' ? 'sky'
  : _tq === 'light' || _tq === 'mist' ? 'mist'
  : (localStorage.getItem('wd-theme') || 'mist');
wdLang = (URLQ.get('lang') === 'en' || URLQ.get('lang') === 'zh') ? URLQ.get('lang')
  : (localStorage.getItem('wd-lang') || 'zh');
localStorage.setItem('wd-theme', WEB_THEME);
localStorage.setItem('wd-lang', wdLang);
document.documentElement.dataset.theme = WEB_THEME === 'sky' ? 'dark' : 'light';
/* 原生设置切换的入口:主题即时换肤;语言页内重载(窗口不关) */
window.wdApplyTheme = t => {
  const v = t === 'sky' ? 'sky' : 'mist';
  localStorage.setItem('wd-theme', v);
  WEB_THEME = v;
  document.documentElement.dataset.theme = v === 'sky' ? 'dark' : 'light';
  if (window.D) renderChart();   /* 图表颜色在渲染时读取,换肤后重画 */
};
window.wdApplyLang = l => {
  const v = l === 'en' ? 'en' : 'zh';
  if (v === wdLang) return;
  localStorage.setItem('wd-lang', v);
  wdLang = v;
  const u = new URL(location.href);
  u.searchParams.set('lang', v);
  u.searchParams.set('theme', WEB_THEME === 'sky' ? 'sky' : 'mist');
  location.href = u.toString();
};

function refreshData(){
  return fetch('/api/ui/bootstrap').then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); })
    .then(j=>{ ingest(j);
      renderToday(); renderCal(); renderTrade(); renderMoney(); renderTime(); renderSys(); renderModules(); renderPush(); renderPool(); renderAi(); });
}
const $ = s => document.querySelector(s);
const $$ = s => Array.from(document.querySelectorAll(s));
const esc = s => String(s==null?'':s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const f0 = n => (n<0?'-':'') + Math.abs(Math.round(n)).toLocaleString('en-US');
const f2 = n => (n<0?'-':'') + Math.abs(n).toFixed(2);
const f1 = n => (n<0?'-':'') + Math.abs(n).toFixed(1);
const sgn = n => (n>0?'+':'') + f2(n);
const cls = n => n>0 ? 'up' : (n<0 ? 'dn' : '');   /* 零值不着色 */
const hhmm = ts => (ts||'').slice(11,16);
const md = d => d ? (d.slice(5,7).replace(/^0/,'') + '-' + d.slice(8,10)) : '—';
const fsize = b => b>=1048576 ? (b/1048576).toFixed(1)+'MB' : b>=1024 ? (b/1024).toFixed(0)+'KB' : b+'B';
/* 四角星评分 / 四柱风险条 */
const stars = n => '<span class="stars">' + [1,2,3,4].map(i=>'<svg class="'+(i<=n?'on':'')+'" viewBox="0 0 24 24"><path d="M12 2.4 L13.7 10.3 L21.6 12 L13.7 13.7 L12 21.6 L10.3 13.7 L2.4 12 L10.3 10.3 Z"/></svg>').join('') + '</span>';
const rbars = n => '<span class="riskbars">' + [1,2,3,4].map(i=>'<i class="'+(i<=n?'on':'')+'"></i>').join('') + '</span>';
const scoreStars = s => stars(Math.min(4, Math.max(0, Math.round(s/25))));
/* ---------- 脱敏(眼睛):mk 把数字批量换成 •,m0/m2/mpx 是金额专用 ---------- */
const mk = s => S.blind ? String(s).replace(/[0-9]/g,'•') : String(s);
const m0 = n => mk(f0(n));
const m2 = n => mk(f2(n));
const mpx = n => mk(Number(n).toFixed(2));
const mSgn = n => mk(sgn(n));
const yuan = n => '¥' + mk(f2(n));
/* ---------- 脱敏眼睛按钮 ---------- */
const EYE_ON = '<svg viewBox="0 0 24 24"><path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.6"/></svg>';
const EYE_OFF = '<svg viewBox="0 0 24 24"><path d="M3 3l18 18"/><path d="M10.6 5.2A9.3 9.3 0 0 1 12 5.1c6 0 9.5 6.2 9.5 6.2a16.8 16.8 0 0 1-3.2 4"/><path d="M6.7 6.8A16.5 16.5 0 0 0 2.5 11.3S6 17.5 12 17.5c1.3 0 2.5-.3 3.6-.8"/><path d="M10 10.1a2.7 2.7 0 0 0 3.8 3.8"/></svg>';
function syncEye(){
  $$('.iconbtn[data-act="blind"]').forEach(b=>{
    b.classList.toggle('masked', S.blind);
    b.innerHTML = S.blind ? EYE_OFF : EYE_ON;
    b.title = S.blind ? '当前已脱敏 · 点击显示关键数字 [B]' : '一键脱敏 · 隐藏关键数字 [B]';
  });
  const lw = $('#lgBaseWrap'); if (lw) lw.innerHTML = '<i class="lg-b"></i>投入本金 ' + mk(f0(100000));
}
function toggleBlind(){
  if (!D) return;
  S.blind = !S.blind;
  localStorage.setItem('wd-blind', S.blind ? '1' : '0');
  syncEye();
  renderToday(); renderCal(); renderTrade(); renderMoney(); renderTime(); renderSys(); renderPush(); renderAi();
  if ($('#drawer').classList.contains('on')) closeDrawer();
  toast(S.blind ? '已开启脱敏 · 关键数字已隐藏 [B 可切换]' : '已关闭脱敏 · 数字已还原');
}

/* ---------- 交易日历推算 ---------- */
const TD = new Set();   /* boot/ingest 时按当日填充 */
function tradeDayIdx(d){ const a = [...TD].filter(x=>x>=d).sort(); return a.length ? a[0]===d ? 1+[...TD].filter(x=>x>=d && x<=d).length : 0 : 0; }
function tradeDaysSince(d){ return [...TD].filter(x=>x>=d).length; } // 含买入日
function nextTradeDay(after){ let d = new Date(after+'T00:00:00'); do { d.setDate(d.getDate()+1); } while (d.getDay()===0||d.getDay()===6); return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0'); }

/* ---------- 汇总 ---------- */
const undoneTodos = () => D.todos.filter(t=>!t.done);
const overdueTodos = () => undoneTodos().filter(t=>t.overdue);
const todayEntries = () => (D.entries||[]).filter(e=>e.date===TODAY0_STR);
const todaySpend = () => todayEntries().filter(e=>e.amount<0).reduce((s,e)=>s-e.amount,0);
let lastUpdate = '—';   /* ingest 时更新 */

/* 日历事件索引 */
const calMap = {};
function calPush(d, ev){ (calMap[d] = calMap[d] || {trades:[],spend:0,spendList:[]}); return calMap[d]; }
/* 事件索引由 ingest(D) 填充 */

/* ---------- 状态 ---------- */
const S = { page:'today', tradeSeg:'hold', range:'all', watchQ:'', calSel:null,
            month:null, cat:'全部', lvStock:null, lvFut:null, scanSim:false,
            blind: localStorage.getItem('wd-blind')==='1', pushMaster:null, pushOpen:false, poolOpen:false,
            aiOpen:false, aiIntent:null, aiLog:[], aiBusy:false };

/* ---------- Toast ---------- */
function toast(msg, acc){ const t = document.createElement('div'); t.className = 'toast' + (acc?' acc':'');
  t.textContent = msg; $('#toasts').appendChild(t); setTimeout(()=>{t.classList.add('fadeout'); setTimeout(()=>t.remove(),350);}, 2400); }

/* ---------- Drawer ---------- */
function draw(html){ $('#dwBody').innerHTML = html; $('#overlay').classList.add('on'); $('#drawer').classList.add('on'); }
function closeDrawer(){ $('#overlay').classList.remove('on'); $('#drawer').classList.remove('on'); }
function dwHead(title, sub){ $('#dwTitle').textContent = title; $('#dwSub').textContent = sub || ''; }
const kv = (k,v) => '<div class="dw-kv"><span>'+k+'</span><b>'+v+'</b></div>';

/* ---------- 导航 ---------- */
const PAGE_META = { today:['今日',''], trade:['交易','持仓 · 自选 · 选股 · 监控'],
  money:['金钱','账本 · 预算 · 月度趋势'], time:['时间','待办 · 日志 · 复盘'], sys:['系统','主机 · 数据源 · 产物'] };
if (wdLang === 'en'){
  PAGE_META.today = ['Today', ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][_NOW.getMonth()]
    + ' ' + _NOW.getDate() + ' (' + ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][_NOW.getDay()] + ') · '
    + ([0,6].includes(_NOW.getDay()) ? 'Market closed' : (_NOW.getHours() < 15 ? 'Pre-close' : 'Closed'))];
  PAGE_META.trade = ['Trade', 'Holdings · Watchlist · Selection · Monitor'];
  PAGE_META.money = ['Money', 'Ledger · Budget · Monthly trend'];
  PAGE_META.time  = ['Time',  'Todos · Journal · Review'];
  PAGE_META.sys   = ['System', 'Host · Sources · Artifacts'];
} else {
  PAGE_META.today[1] = TODAY0_STR.slice(5).replace('-','月')+'日 周'+'日一二三四五六'[_NOW.getDay()]
    + ([0,6].includes(_NOW.getDay()) ? ' · 休市' : (_NOW.getHours()<15 ? ' · 盘中/未收盘' : ' · 已收盘'));
}
function navigate(p){
  S.page = p;
  $$('.rail .rico').forEach(r => r.classList.toggle('on', r.dataset.page===p));
  ['today','trade','money','time','sys'].forEach(k=>{
    $('#page-'+k).classList.toggle('on', k===p);
    $('#side-'+k).classList.toggle('on', k===p);
  });
  $('#sideCol').style.display = 'flex';
  $('#pageTitle').textContent = PAGE_META[p][0];
  $('#pageSub').textContent = PAGE_META[p][1];
  if (p === 'trade') fetchFutures();
  window.scrollTo({top:0, behavior:'smooth'});
}
