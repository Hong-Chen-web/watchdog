/* 看门狗 Web 工作台 · 时间页渲染(待办/日志) */
/* ---------- 时间页 ---------- */
function renderTime(){
  const un = undoneTodos().sort((a,b)=>(b.overdue?1:0)-(a.overdue?1:0) || (a.due_date||'').localeCompare(b.due_date||''));
  const done = D.todos.filter(t=>t.done);
  const row = t => '<div class="td-row"><span class="ck'+(t.done?' on':'')+'" data-act="toggle-todo" data-id="'+t.id+'">'
    + '<svg viewBox="0 0 24 24"><path d="M5 12l4.5 4.5L19 7"/></svg></span>'
    + '<span class="td-t'+(t.done?' done':'')+'" data-act="open-todo" data-id="'+t.id+'">'+esc(t.title)+'</span>'
    + (t.overdue?'<span class="tag-red">逾期 · '+t.due_date.slice(5)+'</span>':t.today?'<span class="tag-acc">今天</span>':(t.due_date?'<span class="tagsm">'+t.due_date.slice(5)+'</span>':''))
    + (t.demo?'<span class="tagsm">AI 演示</span>':'') + '<span class="tsmall">'+rbars(t.priority)+'</span></div>';
  $('#todoBody').innerHTML = '<div class="grouphd">逾期 ('+un.filter(t=>t.overdue).length+')</div>'
    + un.filter(t=>t.overdue).map(row).join('')
    + '<div class="grouphd">其他未完成 ('+un.filter(t=>!t.overdue).length+')</div>'
    + (un.filter(t=>!t.overdue).map(row).join('') || '<div class="footnote" style="margin:4px">没有其他未完成</div>')
    + '<div class="grouphd">已完成 ('+done.length+')</div>'
    + done.map(row).join('');
  $('#todoStat').textContent = '未完成 '+un.length+' · 已完成 '+done.length;
  $('#sideTodoBody').innerHTML = (un.slice(0,4).map(t=>'<div class="td-row"><span class="ck'+(t.done?' on':'')+'" data-act="toggle-todo" data-id="'+t.id+'">'
    + '<svg viewBox="0 0 24 24"><path d="M5 12l4.5 4.5L19 7"/></svg></span>'
    + '<span class="td-t'+(t.done?' done':'')+'" data-act="open-todo" data-id="'+t.id+'">'+esc(t.title)+'</span>'
    + (t.overdue?'<span class="tag-red">逾期</span>':t.today?'<span class="tag-acc">今天</span>':(t.due_date?'<span class="tagsm">'+t.due_date.slice(5)+'</span>':''))
    + '</div>').join('')) || '';
  $('#todoCntTag').textContent = '共 '+un.length+' 件';
  const j = D.journal;
  $('#journalBody').innerHTML = (j.entries.length ? j.entries.slice(0,6).map(e=>'<div class="td-row"><span class="td-t" style="cursor:default"><b style="font-weight:600">'+e.date.slice(5)+'</b> · '+esc(e.content)+'</span><span class="tagsm">'+e.kind+'</span></div>').join('')
    : '<div class="footnote" style="margin-top:2px">还没有日志</div>');
  $('#evTag').textContent = j.date;
  $('#evBody').textContent = (j.events && j.events.length) ? j.events.map(e=>e.title||JSON.stringify(e)).join(' · ') : '今天还没有事件(交易/账本/待办的动作会出现在这里)。';
}
