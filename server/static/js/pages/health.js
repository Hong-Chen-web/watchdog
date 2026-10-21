/* 看门狗 Web 工作台 · 健康页(环形热量 + 餐次分组 + 7 天趋势 + 身体档案) */
const FD_ICON = {早餐:'🌤', 午餐:'🍱', 晚餐:'🌙', 加餐:'🍎'};

function fdAutoMeal(){
  const h = new Date().getHours();
  return h < 10 ? '早餐' : h < 14 ? '午餐' : h < 21 ? '晚餐' : '加餐';
}
function fdSum(rows){ return (rows || []).reduce((s,e)=>s+(e.kcal||0),0); }

function renderHealth(){
  const f = D.food;
  if (!f || !f.entries) return;
  const MEALS = f.meals || ['早餐','午餐','晚餐','加餐'];
  if (!S.foodMeal || MEALS.indexOf(S.foodMeal) < 0) S.foodMeal = fdAutoMeal();

  /* 餐次分段(记到哪一餐) */
  const seg = $('#fdMealSeg');
  if (seg) seg.innerHTML = MEALS.map(m =>
    '<span class="'+(m===S.foodMeal?'on':'')+'" data-act="meal-pick" data-meal="'+m+'">'+m+'</span>').join('');

  /* 环形进度 */
  const total = f.total || 0, target = f.target || 2000, over = total > target;
  const pct = Math.min(1, total / Math.max(target, 1));
  const arc = $('#fdArc');
  if (arc){
    arc.style.strokeDashoffset = (439.8 * (1 - pct)).toFixed(1);
    $('#fdHero').classList.toggle('over', over);
  }
  $('#fdEat').textContent = f0(total);
  $('#fdGoalSm').textContent = '目标 ' + f0(target);

  const prof = f.profile || {}, bd = f.breakdown || {};
  $('#fdGoalChip').textContent = prof.target_kcal ? '自定义目标 ' + f0(target)
    : (bd.weekly_loss > 0 ? '减脂 · 每周 −' + bd.weekly_loss + 'kg'
      : (bd.weekly_loss === 0 ? '维持体重' : '默认目标'));

  /* 主文案:鼓励为主,不训人 */
  const mealsWith = MEALS.filter(m => f.entries.some(e => e.meal === m)).length;
  if (!f.entries.length){
    $('#fdHeadline').textContent = '今天还没记录';
    $('#fdSubline').textContent = '一句话写下吃了什么,AI 帮你估热量';
  } else if (!over){
    $('#fdHeadline').textContent = total > target * 0.85 ? '离目标很近了' : '今天节奏不错';
    $('#fdSubline').textContent = '';   // 数字都在右侧指标里,不重复
  } else {
    $('#fdHeadline').textContent = '今天超了 ' + f0(total - target) + ' kcal';
    $('#fdSubline').textContent = '偶尔一次没关系,明天回到目标就好';
  }

  /* 三个指标 */
  $('#fdRemain').textContent = over ? '−' + f0(total - target) : f0(target - total);
  $('#fdRemain').className = over ? 'bad' : 'ok';
  $('#fdRemainNote').textContent = over ? 'kcal 超出' : 'kcal 余量';
  $('#fdTdee').textContent = bd.tdee ? f0(bd.tdee) : '—';
  $('#fdCount').textContent = f.entries.length;
  $('#fdMealCount').textContent = mealsWith ? mealsWith + ' 餐有记录' : '还没开张';
  $('#foodStat').textContent = f.today ? f.today.slice(5).replace('-', '/') + ' · ' + (over ? '已超目标' : '在目标内') : '';

  /* 餐次分组 */
  const by = {}; MEALS.forEach(m => by[m] = []);
  f.entries.forEach(e => { (by[e.meal] || (by[e.meal] = [])).push(e); });
  $('#foodBody').innerHTML = MEALS.map(m => {
    const rows = by[m] || [], sum = fdSum(rows);
    const body = rows.length
      ? rows.map(e => '<div class="fd-row"><span class="fd-food"><b>' + esc(e.food) + '</b>'
          + (e.portion ? '<small>' + esc(e.portion) + '</small>' : '') + '</span>'
          + '<span class="fd-kcal' + (e.kcal == null ? ' muted' : '') + '">' + (e.kcal == null ? '—' : f0(e.kcal)) + '</span>'
          + '<span class="fdel" data-act="food-del" data-id="' + e.id + '" title="删除">×</span></div>').join('')
      : '<div class="fd-empty" data-act="meal-add" data-meal="' + m + '">+ 还没记,点这添加</div>';
    return '<div class="fd-meal"><div class="fd-mealhead"><span class="fd-mic">' + (FD_ICON[m] || '🍽') + '</span>'
      + '<b>' + m + '</b><span class="fd-msub">' + (sum ? f0(sum) + ' kcal' : '') + '</span>'
      + '<span class="fd-plus" data-act="meal-add" data-meal="' + m + '" title="记到' + m + '">+</span></div>'
      + body + '</div>';
  }).join('');

  /* 近 7 天 */
  const days = f.days || [];
  const mx = Math.max(target * 1.08, ...days.map(d => d.total), 1);   // 目标线留出顶部空间
  $('#foodBars').innerHTML = '<div class="tline" style="bottom:' + (target / mx * 100).toFixed(1) + '%"></div>'
    + days.map(d => {
      const h = d.total ? Math.max(2, d.total / mx * 100) : 0;
      const today = d.date === f.today;
      return '<div class="fbcol' + (d.total > target ? ' over' : '') + (today ? ' today' : '') + '"'
        + ' title="' + d.date + ' · ' + f0(d.total) + ' kcal"><i style="height:' + h.toFixed(1) + '%"></i></div>';
    }).join('');
  $('#foodDates').innerHTML = days.map(d => {
    const today = d.date === f.today;
    return '<span class="' + (today ? 'today' : '') + '">' + (today ? '今天' : d.date.slice(5).replace('-', '/')) + '</span>';
  }).join('');
  const logged = days.filter(d => d.total > 0);
  const avg = logged.length ? Math.round(logged.reduce((s, d) => s + d.total, 0) / logged.length) : 0;
  $('#foodWeekTag').textContent = '日均 ' + f0(avg) + ' kcal';
  $('#fdWeekAvg').textContent = '目标 ' + f0(target) + ' · 有记录 ' + logged.length + '/' + days.length + ' 天';

  /* 身体档案 */
  const fill = [['#hpHeight', prof.height_cm], ['#hpWeight', prof.weight_kg], ['#hpAge', prof.age]];
  if (fill.every(x => !$(x[0]).value)) fill.forEach(x => { if (x[1] != null) $(x[0]).value = x[1]; });
  if (prof.sex) $('#hpSex').value = prof.sex;
  if (!$('#hpAct').options.length){
    const acts = Object.keys(f.activity || {久坐: 1.2, 轻度活动: 1.375, 中度活动: 1.55, 高强度: 1.725});
    $('#hpAct').innerHTML = acts.map(a => '<option>' + a + '</option>').join('');
  }
  if (prof.activity) $('#hpAct').value = prof.activity;
  $('#hpLoss').value = String(prof.weekly_loss != null ? prof.weekly_loss : 0.5);  // 与后端缺省一致
  $('#fdRecBig').textContent = f.recommended ? f0(f.recommended) : '—';
  $('#hpRec').textContent = f.recommended
    ? ('BMR ' + f0(bd.bmr) + ' · TDEE ' + f0(bd.tdee) + ' − 缺口 ' + f0(bd.deficit)
       + ' → 每周 −' + bd.weekly_loss + 'kg' + (bd.floored ? ' · 已按下限托底' : ''))
    : '填好身高 / 体重 / 年龄后自动计算';

  /* 侧栏 */
  $('#sfTag').textContent = f.today ? f.today.slice(5).replace('-', '/') : '';
  $('#sideFoodBody').innerHTML =
    '<div class="kvrow"><span>已摄入 / 目标</span><b>' + f0(total) + ' / ' + f0(target) + '</b></div>'
    + MEALS.map(m => {
        const s = fdSum(by[m] || []);
        return '<div class="kvrow"><span>' + (FD_ICON[m] || '') + ' ' + m + '</span><b>' + (s ? f0(s) + ' kcal' : '—') + '</b></div>';
      }).join('')
    + '<div class="kvrow"><span>还可吃</span><b class="' + (over ? 'bad' : 'ok') + '">'
      + (over ? '−' + f0(total - target) : f0(target - total)) + ' kcal</b></div>';
}
