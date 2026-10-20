/* 看门狗 Web 工作台 · 健康页渲染(饮食明细 + 7 天趋势 + 热量目标) */
function renderHealth(){
  const f = D.food;
  if (!f || !f.entries){ const b = $('#foodBody'); if (b) b.innerHTML = '<div class="footnote" style="margin-top:6px">暂无数据(后端未就绪)。</div>'; return; }
  const M = f.meals || ['早餐','午餐','晚餐','加餐'];
  const mealSel = $('#foodMeal');
  if (!mealSel.options.length)
    mealSel.innerHTML = '<option value="">自动</option>' + M.map(m=>'<option>'+m+'</option>').join('');
  const actSel = $('#hpAct');
  if (!actSel.options.length){
    const acts = Object.keys(f.activity || {久坐:1, 轻度活动:1, 中度活动:1, 高强度:1});
    actSel.innerHTML = acts.map(a=>'<option>'+a+'</option>').join('');
  }

  const total = f.total || 0, target = f.target || 2000;
  const over = total > target;
  $('#foodStat').textContent = f.entries.length + ' 条 · 合计 ' + f0(total) + ' kcal' + (over ? ' · 超标 ' + f0(total-target) : ' · 剩 ' + f0(Math.max(0, target-total)));
  const prof = f.profile || {};
  $('#foodTargetTag').textContent = '目标 ' + f0(target) + (prof.target_kcal ? '(自定义)' : (f.recommended ? '(推荐)' : '(默认 · 档案未填)'));
  const bar = $('#foodBar');
  bar.parentElement.classList.toggle('over', over);
  bar.style.width = Math.min(100, total/target*100).toFixed(1) + '%';

  $('#foodBody').innerHTML = f.entries.length
    ? '<table><thead><tr><th>餐次</th><th>食物</th><th class="num">千卡</th><th></th></tr></thead><tbody>'
      + f.entries.map(e=>'<tr><td class="tsmall">'+esc(e.meal)+'</td>'
        +'<td><b>'+esc(e.food)+'</b>'+(e.portion?'<span class="code">'+esc(e.portion)+'</span>':'')+'</td>'
        +'<td class="num '+(e.kcal==null?'':'')+'">'+(e.kcal==null?'<span class="tsmall">未估</span>':f0(Math.round(e.kcal)))+'</td>'
        +'<td style="width:30px"><span class="fdel" data-act="food-del" data-id="'+e.id+'" title="删除">×</span></td></tr>').join('')
      +'</tbody></table>'
    : '<div class="footnote" style="margin-top:6px">今天还没记。一句话写上面输入框,回车即可。</div>';

  const days = f.days || [];
  const mx = Math.max(target, ...days.map(d=>d.total), 1);
  $('#foodBars').innerHTML = '<div class="tline" style="bottom:'+(target/mx*100).toFixed(1)+'%"></div>'
    + days.map(d=>'<div class="fb'+(d.total>target?' over':'')+'" title="'+d.date+' · '+f0(d.total)+' kcal">'
      +'<b>'+(d.total ? f0(d.total) : '')+'</b><i style="height:'+Math.max(2, d.total/mx*100).toFixed(1)+'%"></i>'
      +'<small>'+d.date.slice(5).replace('-','/')+'</small></div>').join('');
  const withData = days.filter(d=>d.total>0);
  $('#foodWeekTag').textContent = '日均 ' + f0(Math.round(days.reduce((s,d)=>s+d.total,0)/Math.max(days.length,1)))
    + ' · 有记录 ' + withData.length + '/' + days.length + ' 天';

  const p = prof;
  const fills = [['#hpHeight', p.height_cm], ['#hpWeight', p.weight_kg], ['#hpAge', p.age]];
  if (fills.every(x=>!$(x[0]).value)) fills.forEach(x=>{ if (x[1] != null) $(x[0]).value = x[1]; });
  if (p.sex) $('#hpSex').value = p.sex;
  if (p.activity) $('#hpAct').value = p.activity;
  $('#hpRec').textContent = f.recommended ? ('按档案推荐 ' + f0(f.recommended) + ' kcal/日' + (prof.target_kcal ? '(已自定义 '+f0(target)+')' : ''))
    : '填好身高/体重/年龄后自动推荐';

  $('#sfTag').textContent = hhmm(lastUpdate);
  $('#sideFoodBody').innerHTML =
    '<div class="kvrow"><span>今日摄入</span><b>'+f0(total)+' / '+f0(target)+' kcal</b></div>'
    +'<div class="kvrow"><span>状态</span><b class="'+(over?'':'')+'">'+(over?'超标 '+f0(total-target):'还剩 '+f0(target-total))+'</b></div>'
    +'<div class="kvrow"><span>近 7 天日均</span><b>'+f0(Math.round(days.reduce((s,d)=>s+d.total,0)/Math.max(days.length,1)))+'</b></div>'
    +'<div class="kvrow"><span>目标来源</span><b>'+(prof.target_kcal?'自定义':(f.recommended?'档案推荐':'默认 2000'))+'</b></div>';
}
