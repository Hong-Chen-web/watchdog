/* 看门狗 Web 工作台 · 系统页渲染 + 模块装配 */
/* ---------- 系统页 ---------- */
function renderSys(){
  const s = D.sysmon;
  $('#sysCollected').textContent = '采集于 '+hhmm(s.collected_at)+' · Mole';
  const score = s.health_score||0;
  $('#ringArc').setAttribute('stroke-dasharray', (score/100*314).toFixed(1)+' 314');
  $('#ringVal').textContent = score;
  $('#ringMsg').textContent = s.health_score_msg||'';
  $('#cpuUse').textContent = f1(s.cpu.usage)+'% · load '+s.cpu.load1.toFixed(1);
  const pc = s.cpu.per_core || [];
  const pcMax = Math.max(...pc, 1);
  $('#cpuCores').innerHTML = pc.map(v=>'<i style="height:'+Math.max(4, v/pcMax*34)+'px"></i>').join('');
  const mem = s.memory;
  $('#memUse').textContent = (mem.used/1073741824).toFixed(1)+' / '+(mem.total/1073741824).toFixed(1)+' GB('+mem.used_percent.toFixed(0)+'%)· swap '+(mem.swap_used/1073741824).toFixed(1)+'GB';
  $('#memBar').style.width = mem.used_percent+'%';
  $('#uptimeProcs').textContent = s.uptime+' · '+s.procs+' 进程';

  const src = [
    ['ok','腾讯行情(清单/K线/快照)', '在线 · 快线 '+hhmm(lastUpdate)+' · 失败 '+D.quotes.fails+' 次', 'qt.gtimg.cn / ifzq.gtimg.cn'],
    ['ok','新浪(行业分类图)', '缓存就绪 · '+D.files.industry.mtime, D.files.industry.name],
    ['warn','东财(仅主力净占比)', '永久缓存 · '+D.files.fflow.kb+'KB · '+D.files.fflow.mtime, 'fflow_cache.json · 每票每涨停日只拉一次'],
    ['ok','本地K线库', D.files.klines.info, 'data/klines.db'],
  ];
  $('#srcBody').innerHTML = src.map(x=>'<div class="kvrow"><span><span class="dot '+x[0]+'"></span>'+x[1]+'</span><b style="text-align:right">'+x[2]+'<br><span class="tsmall">'+esc(x[3])+'</span></b></div>').join('');

  const f = D.files;
  $('#fileBody').innerHTML =
    '<div class="kvrow"><span>涨停滚动集</span><b>'+f.limitRoll.n+' 只 · 更新 '+f.limitRoll.mtime+'</b></div>'
   +'<div class="kvrow"><span>选股归档(下一轮)</span><b>'+D.tail.next_run_day+' · '+D.tail.stocks.length+' 只候选</b></div>'
   +'<div class="kvrow"><span>实盘台账</span><b>'+D.live.rounds+' 回合 · 同步 '+hhmm(D.live.synced_at||'')+'</b></div>'
   +'<div class="kvrow"><span>frozen 后端包</span><b>'+(f.frozen.exists ? '存在 · '+f.frozen.mtime : '未打包(源码运行)')+'</b></div>'
   +'<div class="kvrow"><span>清理状态</span><b>'+(D.clean.running ? '进行中 '+D.clean.current : '空闲 · 上次完成 '+(D.clean.finished_at?hhmm(D.clean.finished_at):'—'))+'</b></div>';
  $('#svcBody').innerHTML =
    '<div class="kvrow"><span><span class="dot ok"></span>后端 8790</span><b>'+D.health.status+' · v'+D.health.schema_version+'</b></div>'
   +'<div class="kvrow"><span><span class="dot ok"></span>sidecar 源码模式</span><b>venv python</b></div>'
   +'<div class="kvrow"><span><span class="dot '+(pushMasterOn()?'ok':'warn')+'"></span>飞书推送通道</span><b>'+D.push.channels.length+' 通道 · '+D.push.channels.filter(c=>c.ok).length+' 正常'+(pushMasterOn()?'':' · 总开关关')+'</b></div>'
   +'<div class="kvrow"><span><span class="dot off"></span>frozen 分发</span><b>'+(f.frozen.exists?'存在':'源码兜底')+'</b></div>';
  $('#hostBody').innerHTML =
    '<div class="kvrow"><span>型号</span><b>'+esc(s.hardware.model)+'</b></div>'
   +'<div class="kvrow"><span>芯片</span><b style="font-size:11.5px">'+esc((s.hardware.cpu_model||'').slice(0,28))+'</b></div>'
   +'<div class="kvrow"><span>内存 / 磁盘</span><b>'+s.hardware.total_ram+' / '+s.hardware.disk_size+'</b></div>'
   +'<div class="kvrow"><span>系统</span><b style="font-size:11.5px">'+esc(s.hardware.os_version)+'</b></div>'
   +'<div class="kvrow"><span>垃圾箱</span><b>'+f.trash+'</b></div>';
  renderPush();
}
