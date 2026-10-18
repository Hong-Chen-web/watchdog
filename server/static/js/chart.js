/* 看门狗 Web 工作台 · 资产曲线(SVG) */
/* ---------- 图表 ---------- */
function sliceCurve(range){
  const c = D.live.curve, n = c.length;
  if (range==='1m') return c.slice(-22);
  if (range==='3m') return c.slice(-Math.max(3, Math.floor(n*0.66)));
  return c;
}
function smooth(xs, ys){
  let d = 'M'+xs[0].toFixed(1)+','+ys[0].toFixed(1);
  for (let i=0;i<xs.length-1;i++){
    const x0=xs[Math.max(i-1,0)], y0=ys[Math.max(i-1,0)], x1=xs[i], y1=ys[i],
          x2=xs[i+1], y2=ys[i+1], x3=xs[Math.min(i+2,xs.length-1)], y3=ys[Math.min(i+2,ys.length-1)];
    d += ' C'+(x1+(x2-x0)/6).toFixed(1)+','+(y1+(y2-y0)/6).toFixed(1)+' '+
         (x2-(x3-x1)/6).toFixed(1)+','+(y2-(y3-y1)/6).toFixed(1)+' '+x2.toFixed(1)+','+y2.toFixed(1);
  }
  return d;
}
let CH = null;
function renderChart(){
  const CS = getComputedStyle(document.documentElement);
  const V = n => CS.getPropertyValue(n).trim();
  const cFill = V('--viz-fill'), cHi = V('--viz-hi'), cHi2 = V('--viz-hi2'), cMut = V('--viz-mut');
  const pts = sliceCurve(S.range);
  const W=920,H=250,L=46,R=60,T=26,B=30;
  const xs = pts.map((_,i)=>L+i*(W-L-R)/Math.max(1,pts.length-1));
  let lo=Math.min(...pts.map(p=>p.equity)), hi=Math.max(...pts.map(p=>p.equity));
  const pad=(hi-lo)*0.12||1; lo-=pad; hi+=pad;
  const ys = pts.map(p=>T+(hi-p.equity)*(H-T-B)/(hi-lo));
  const line = smooth(xs,ys);
  const area = line+' L'+xs[xs.length-1].toFixed(1)+','+(H-B+6)+' L'+xs[0].toFixed(1)+','+(H-B+6)+' Z';
  let by = T+(hi-100000)*(H-T-B)/(hi-lo); by = Math.min(Math.max(by,T),H-B);
  let ax = '', mlabel = '';
  const baseLbl = wdLang === 'en' ? 'Principal' : '本金 '+mk(10)+' 万';
  const baseAttr = wdLang === 'en' ? ' x="'+(W-R-8)+'" text-anchor="end"' : ' x="'+(W-R+6)+'"';
  const MN_EN = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  pts.forEach((p,i)=>{ if (i===0 || p.date.slice(5,7)!==pts[i-1].date.slice(5,7))
    mlabel += '<text x="'+xs[i].toFixed(1)+'" y="'+(H-8)+'" text-anchor="middle" class="ax">'
      + (wdLang === 'en' ? MN_EN[+p.date.slice(5,7)-1] : parseInt(p.date.slice(5,7))+'月') + '</text>'; });
  [80000,90000,100000,110000].forEach(v=>{ if(v>=lo&&v<=hi){ const yy=T+(hi-v)*(H-T-B)/(hi-lo);
    ax += '<text x="'+(L-8)+'" y="'+(yy+3.5).toFixed(1)+'" text-anchor="end" class="ax">'+mk(v/1000)+'k</text>'; }});
  const lx = xs[xs.length-1], ly = ys[ys.length-1];
  const svg = '<svg viewBox="0 0 '+W+' '+H+'" class="curve" id="curveSvg">'
    + '<defs><linearGradient id="ga" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="'+cFill+'" stop-opacity="0.5"/><stop offset="100%" stop-color="'+cFill+'" stop-opacity="0.06"/></linearGradient>'
    + '<linearGradient id="gl" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="'+cHi+'"/><stop offset="100%" stop-color="'+cHi2+'"/></linearGradient></defs>'
    + ax + mlabel
    + '<line x1="'+L+'" y1="'+by.toFixed(1)+'" x2="'+(W-R)+'" y2="'+by.toFixed(1)+'" class="base"/>'
    + '<text'+baseAttr+' y="'+(by+3.5).toFixed(1)+'" class="ax">'+baseLbl+'</text>'
    + '<path d="'+area+'" fill="url(#ga)"/>'
    + '<path d="'+line+'" fill="none" stroke="url(#gl)" stroke-width="2.6" stroke-linecap="round"/>'
    + '<circle cx="'+lx.toFixed(1)+'" cy="'+ly.toFixed(1)+'" r="4.5" fill="#fff" stroke="'+cHi2+'" stroke-width="2.4"/>'
    + '<g transform="translate('+(lx-4).toFixed(1)+','+(ly-40).toFixed(1)+')"><rect x="-52" y="-16" width="104" height="27" rx="13.5" fill="'+cHi2+'"/><text x="0" y="3" text-anchor="middle" class="bub">'+m0(D.live.total_now)+'</text></g>'
    + '<line id="crossLine" x1="0" y1="'+T+'" x2="0" y2="'+(H-B)+'" class="cross" opacity="0"/>'
    + '<circle id="crossDot" r="4" fill="'+cHi2+'" stroke="#fff" stroke-width="2" opacity="0"/>'
    + '</svg>';
  $('#chartBox').innerHTML = svg;
  CH = { pts, xs, ys, W, H, L, R, T, B };
  $('#curveRangeTag').textContent = S.range==='1m' ? '近 1 月' : S.range==='3m' ? '近 3 月' : '全部 · ' + pts.length + ' 个交易日';
  const last = pts[pts.length-1], prev = pts[pts.length-2] || last;
  const dv = last.equity - prev.equity, dpct = prev.equity ? dv/prev.equity*100 : 0;
  $('#curveStats').innerHTML =
    '<div><small>当前净值</small><b class="num">'+m0(D.live.total_now)+'</b></div>'
   +'<div><small>累计收益</small><b class="num '+cls(D.live.ret_pct)+'">'+D.live.ret_pct+'%</b></div>'
   +'<div><small>回合 / 胜率</small><b class="num">'+D.live.rounds+' / '+(D.live.win_rounds/D.live.rounds*100).toFixed(0)+'%</b></div>'
   +'<div><small>最近一日</small><b class="num '+cls(dv)+'">'+mSgn(dv)+' ('+sgn(dpct)+'%)</b></div>';
  const wrap = $('#chartBox');
  const svgEl = $('#curveSvg');
  wrap.onpointermove = ev => {
    const r = svgEl.getBoundingClientRect();
    const vx = (ev.clientX - r.left) / r.width * CH.W;
    let i = Math.round((vx - CH.L) / ((CH.W-CH.L-CH.R)/Math.max(1,CH.pts.length-1)));
    i = Math.min(Math.max(i,0), CH.pts.length-1);
    const px = CH.xs[i], py = CH.ys[i], p = CH.pts[i], pp = CH.pts[i-1]||p;
    $('#crossLine').setAttribute('x1',px); $('#crossLine').setAttribute('x2',px); $('#crossLine').setAttribute('opacity',1);
    $('#crossDot').setAttribute('cx',px); $('#crossDot').setAttribute('cy',py); $('#crossDot').setAttribute('opacity',1);
    const chg = p.equity - pp.equity, cpct = pp.equity ? chg/pp.equity*100 : 0;
    const tip = $('#chartTip');
    tip.style.display = 'block';
    tip.innerHTML = '<b>'+m0(p.equity)+'</b> · <span class="'+cls(chg)+'">'+(chg>=0?'+':'')+mk(f0(chg))+' ('+(chg>=0?'+':'')+cpct.toFixed(2)+'%)</span><br>'+p.date+' · '
    + (wdLang === 'en' ? 'Principal '+mk(100000) : '本金 '+mk(10)+' 万');
    const xr = (px/CH.W)*r.width, yr = (py/CH.H)*r.height;
    tip.style.left = Math.min(Math.max(xr-60, 4), r.width-190) + 'px';
    tip.style.top = Math.max(yr-70, 4) + 'px';
  };
  wrap.onpointerleave = ()=>{ $('#chartTip').style.display='none'; const l=$('#crossLine'), d=$('#crossDot'); if(l) l.setAttribute('opacity',0); if(d) d.setAttribute('opacity',0); };
}
