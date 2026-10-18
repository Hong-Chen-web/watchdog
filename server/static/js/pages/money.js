/* 看门狗 Web 工作台 · 金钱页渲染 */
/* ---------- 金钱页 ---------- */
function renderMoney(){
  const m = S.month, sum = D.summaries[m], mm = D.months.find(x=>x.month===m);
  $('#mMoneyTitle').textContent = m.replace('-',' 年 ')+' 月' + (m===D.months[0].month ? ' · 本月' : '');
  const prevM = D.months.find(x=>x.month < m);
  const mom = prevM && prevM.expense ? (sum.expense-prevM.expense)/prevM.expense*100 : null;
  $('#moneyStats').innerHTML =
    '<div><small>支出</small><b class="num dn">'+yuan(sum.expense)+'</b></div>'
   +'<div><small>收入</small><b class="num up">'+yuan(sum.income)+'</b></div>'
   +'<div><small>结余</small><b class="num '+cls(sum.income-sum.expense)+'">'+yuan(sum.income-sum.expense)+'</b></div>'
   +'<div><small>笔数</small><b class="num">'+mm.entries+'</b></div>'
   +(mom!=null?'<div><small>环比上月</small><b class="num '+cls(mom)+'">'+sgn(mom)+'%</b></div>':'');
  const cats = (sum.categories||[]).filter(c=>c.actual>0);
  $('#moneyCats').innerHTML = cats.map(c=>'<span style="cursor:pointer" data-act="open-cat" data-name="'+esc(c.name)+'">'+c.name+' '+yuan(c.actual)+(c.budget_month>0?' / '+m2(c.budget_month):'')+'</span>').join('');
  const chips = ['全部'].concat(cats.map(c=>c.name));
  $('#moneyChips').innerHTML = chips.map(c=>'<span class="chipf'+(S.cat===c?' on':'')+'" data-act="mcat" data-v="'+esc(c)+'">'+esc(c)+'</span>').join('');
  const rows = D.entries.filter(e=>e.date.slice(0,7)===m && (S.cat==='全部' || e.category===S.cat));
  $('#moneyBody').innerHTML = rows.length ? rows.map(e=>'<tr class="row-hover clickable" data-act="open-entry" data-id="'+e.id+'">'
    +'<td class="tsmall">'+e.date.slice(5)+'</td><td>'+esc(e.payee||'—')+(e.demo?' <span class="tagsm">AI 演示</span>':'')+'</td>'
    +'<td><span class="tagsm">'+esc(e.category)+'</span></td>'
    +'<td class="num '+(e.amount<0?'':'up')+'">'+(e.amount<0?'':'+')+m2(e.amount)+'</td></tr>').join('')
    : '<tr><td colspan="4" style="color:var(--mut)">该筛选下没有流水</td></tr>';
  const older = D.months.findIndex(x=>x.month===m) >= D.months.length - 0;
  $('#moneyNote').textContent = '共 '+rows.length+' 笔' + (S.cat!=='全部'?'(筛选:'+S.cat+')':'') + ' · 点行看详情 · 账本数据全量嵌入('+D.entries.length+' 笔)。';

  const ms = D.months.slice(0,9).reverse();
  const mx = Math.max(...ms.map(x=>x.expense), 1);
  $('#mTrend').innerHTML = ms.map(x=>'<div class="tb'+(x.month===m?' on':'')+'" data-act="mtrend" data-v="'+x.month+'" title="'+x.month+' '+yuan(x.expense)+'">'
    +'<i style="height:'+Math.max(6, x.expense/mx*62)+'px"></i><span>'+x.month.slice(5)+'</span></div>').join('');
  const te = todayEntries();
  $('#todayLedTag').textContent = '共 '+te.length+' 笔 · '+yuan(te.filter(e=>e.amount<0).reduce((s,e)=>s-e.amount,0));
  $('#todayLedBody').innerHTML = te.length ? te.map(e=>'<div class="td-row"><span class="td-t" data-act="open-entry" data-id="'+e.id+'">'+esc(e.payee)+' · '+esc(e.category)+'</span><span class="tsmall">'+m2(e.amount)+'</span></div>').join('')
    : '<div class="footnote" style="margin-top:2px">今天还没有记账</div>';
}
