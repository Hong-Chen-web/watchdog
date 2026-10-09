"""缠论桥:chan-monitor(8787)只读代理 + 本地 data 文件读取(飞书配置/推送记录)。
原则:不改缠论服务,所有写入类操作(测试推送)仅原样转发其自身接口。"""
import json
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException
from datetime import datetime

from .common import get_conn
from pydantic import BaseModel

router = APIRouter(prefix="/api/chan", tags=["chan"])

CHAN_BASE = "http://127.0.0.1:8787"
CHAN_DATA = Path("/Users/chenhong/github/personal-workbench/chan/data")


def _proxy(path: str, method: str = "GET", payload: dict = None):
    raise HTTPException(503, "缠论引擎已移除(2026-10-06),该实时能力下线")


def _read_json(name: str, default):
    try:
        return json.loads((CHAN_DATA / name).read_text(encoding="utf-8"))
    except Exception:
        return default


def _mask(hook: str) -> str:
    """webhook 打码:只露最后 6 位。"""
    if not hook:
        return ""
    return "…" + hook[-6:]


@router.get("/state")
def chan_state():
    """缠论引擎已移除:返回说明态(前端仅作存活展示)。"""
    return {"level": None, "levels": [], "watchlist": [], "scanning": False,
            "removed": True}



@router.get("/tail")
def chan_tail():
    """最近选股轮次:优先本地新生成(内置选股引擎),否则库内快照。"""
    import json as _json
    from datetime import datetime, timedelta
    from pathlib import Path as _P
    live = _P("/Users/chenhong/github/personal-workbench/data/recommended_tail.json")
    if live.exists():
        try:
            d = _json.loads(live.read_text(encoding="utf-8"))
            if d.get("stocks"):
                dd = datetime.now()
                while True:
                    dd += timedelta(days=1)
                    if dd.weekday() < 5:
                        break
                d.setdefault("next_run_day", dd.strftime("%Y-%m-%d"))
                return d
        except Exception:
            pass
    import db as dbm
    conn = dbm.connect()
    conn.row_factory = __import__("sqlite3").Row
    try:
        row = conn.execute("SELECT v FROM chan_kv WHERE k='tail'").fetchone()
    finally:
        conn.close()
    snap = _json.loads(row["v"]) if row else {"date": None, "stocks": []}
    d = datetime.now()
    while True:
        d += timedelta(days=1)
        if d.weekday() < 5:
            break
    snap.setdefault("next_run_day", d.strftime("%Y-%m-%d"))
    return snap


@router.get("/futures")
def chan_futures(level: str = None):
    """期货缠论监控(内置引擎:新浪K线+czsc,盘中自动轮询)。"""
    from services import futures_monitor as fm
    return fm.snapshot(level)


@router.post("/futures-scan")
def chan_futures_scan(level: str = None):
    q = f"?level={urllib.parse.quote(level)}" if level else ""
    return _proxy(f"/api/futures/scan{q}", method="POST", payload={})


def _db_bots(conn):
    import json as _j
    rows = conn.execute(
        "SELECT id,name,webhook,codes FROM feishu WHERE kind='bot' ORDER BY id").fetchall()
    out = []
    for r in rows:
        try:
            codes = _j.loads(r["codes"])
        except ValueError:
            codes = []
        out.append({"id": r["id"], "name": r["name"], "webhook": r["webhook"], "codes": codes})
    return out


def _db_notify(conn):
    return [{"name": r["name"], "webhook": r["webhook"]} for r in conn.execute(
        "SELECT name,webhook FROM feishu WHERE kind='notify' ORDER BY name").fetchall()]


def _sync_chan_json(conn):
    """表 → chan-monitor json(引擎已于 v57 移除,目录不存在时跳过双写)。"""
    if not CHAN_DATA.exists():
        return
    _save_json_atomic("feishu_bots.json", _db_bots(conn))
    _save_json_atomic("feishu_notify.json", _db_notify(conn))


def ensure_feishu_from_json(conn):
    """首启:表空则从 chan json 灌入(一次性)。"""
    if conn.execute("SELECT COUNT(*) c FROM feishu").fetchone()["c"]:
        return
    for b in _read_json("feishu_bots.json", []):
        conn.execute(
            "INSERT OR IGNORE INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
            (b.get("id") or "?", "bot", b.get("name") or "?", b.get("webhook") or "",
             json.dumps(b.get("codes") or [])))
    for g in _read_json("feishu_notify.json", []):
        conn.execute("INSERT OR IGNORE INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
                     (g.get("name") or "?", "notify", g.get("name") or "?",
                      g.get("webhook") or "", "[]"))
    conn.commit()


@router.get("/feishu")
def chan_feishu():
    conn = get_conn()
    try:
        return {
            "bots": [{"id": b["id"], "name": b["name"],
                      "codes_n": len(b["codes"]), "codes": b["codes"],
                      "webhook": _mask(b["webhook"])} for b in _db_bots(conn)],
            "notify": [{"name": n["name"], "webhook": _mask(n["webhook"])}
                       for n in _db_notify(conn)],
        }
    finally:
        conn.close()


class FeishuTestIn(BaseModel):
    bot_id: Optional[str] = None   # 空=通知群


@router.post("/feishu/test")
def chan_feishu_test(body: FeishuTestIn = None):
    """直发测试消息到通知群(引擎已移除,不再代理 8787)。"""
    from services.feishu_push import ensure_push, flush_once
    ensure_push("test", "看门狗 · 推送测试",
                f"飞书通道正常 · {datetime.now().strftime('%H:%M:%S')}",
                f"test:{datetime.now().strftime('%Y-%m-%d %H:%M')}")
    flush_once()
    import db as dbm2
    conn = get_conn()
    try:
        row = conn.execute(
            "SELECT status,last_error FROM push_outbox"
            " WHERE kind='test' ORDER BY id DESC LIMIT 1").fetchone()
        return dict(row) if row else {"status": "unknown"}
    finally:
        conn.close()


# ---------- 飞书配置维护(写 chan-monitor data/*.json,原子写+备份) ----------

class BotIn(BaseModel):
    name: str
    webhook: str
    codes: list[str] = []


def _save_json_atomic(name: str, data):
    p = CHAN_DATA / name
    bak = CHAN_DATA / (name + ".bak")
    if p.exists():
        bak.write_text(p.read_text(encoding="utf-8"), encoding="utf-8")
    tmp = CHAN_DATA / (name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(p)


@router.get("/feishu/config")
def feishu_config():
    """完整配置(表主存,webhook 明文供编辑)。"""
    conn = get_conn()
    try:
        return {"bots": _db_bots(conn), "notify": _db_notify(conn)}
    finally:
        conn.close()


@router.post("/feishu/bots", status_code=201)
def feishu_bot_create(body: BotIn):
    import uuid
    if not body.webhook.startswith("https://open.feishu.cn/"):
        raise HTTPException(400, "webhook 需为飞书 open API 地址")
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
            (uuid.uuid4().hex[:8], "bot", body.name.strip(), body.webhook.strip(),
             json.dumps([c.strip() for c in body.codes if c.strip()])))
        conn.commit()
        _sync_chan_json(conn)
        return {"ok": True}
    finally:
        conn.close()


@router.put("/feishu/bots/{bot_id}")
def feishu_bot_update(bot_id: str, body: BotIn):
    if not body.webhook.startswith("https://open.feishu.cn/"):
        raise HTTPException(400, "webhook 需为飞书 open API 地址")
    conn = get_conn()
    try:
        cur = conn.execute(
            "UPDATE feishu SET name=?, webhook=?, codes=? WHERE id=? AND kind='bot'",
            (body.name.strip(), body.webhook.strip(),
             json.dumps([c.strip() for c in body.codes if c.strip()]), bot_id))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"bot {bot_id} 不存在")
        _sync_chan_json(conn)
        return {"ok": True}
    finally:
        conn.close()


@router.delete("/feishu/bots/{bot_id}", status_code=204)
def feishu_bot_delete(bot_id: str):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM feishu WHERE id=? AND kind='bot'", (bot_id,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"bot {bot_id} 不存在")
        _sync_chan_json(conn)
        return None
    finally:
        conn.close()


class NotifyIn(BaseModel):
    name: str
    webhook: str


@router.post("/feishu/notify", status_code=201)
def feishu_notify_create(body: NotifyIn):
    conn = get_conn()
    try:
        try:
            conn.execute("INSERT INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
                         (body.name.strip(), "notify", body.name.strip(),
                          body.webhook.strip(), "[]"))
            conn.commit()
        except Exception:
            raise HTTPException(409, f"通知群 {body.name} 已存在")
        _sync_chan_json(conn)
        return {"ok": True}
    finally:
        conn.close()


@router.delete("/feishu/notify/{name}", status_code=204)
def feishu_notify_delete(name: str):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM feishu WHERE id=? AND kind='notify'", (name,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, f"通知群 {name} 不存在")
        _sync_chan_json(conn)
        return None
    finally:
        conn.close()


@router.get("/signals")
def chan_signals(limit: int = 12):
    """最近推送的信号(缠论 pushed_signals 去重簿)。"""
    rows = _read_json("pushed_signals.json", [])
    if isinstance(rows, list):
        rows = [r for r in rows if isinstance(r, str)][-limit:]
    return {"recent": list(reversed(rows)), "total": len(rows)}


CHART_DIR = CHAN_DATA / "charts"
_LEVELS = ["5m", "30m", "60m", "120m", "day"]
_ENGINES = ["chanpy", "czsc"]


@router.get("/chart-levels")
def chart_levels(code: str):
    """实时生成图表:所有级别/引擎都可用(不依赖预生成文件)。"""
    return {"code": code, "charts": [
        {"level": lv, "engine": eng}
        for lv in ["5m", "30m", "60m", "day"]
        for eng in ["chanpy"]
    ]}


@router.get("/chart")
def chan_chart(code: str, level: str = "day", engine: str = "chanpy"):
    """实时生成K线+缠论笔/中枢标注图(lightweight-charts 内联,无外部文件)。"""
    import json as _json
    import re as _re
    from fastapi.responses import HTMLResponse
    from services.futures_monitor import _sina_kline, LEVELS as _FLV

    code = (code or "").strip()
    minutes = _FLV.get(level, 1440 if level == "day" else 5)
    is_daily = (minutes == 1440)

    def _dt(s):
        s = str(s).replace("T", " ")
        return s[:10] if is_daily else s[:16]

    def _err(msg):
        return HTMLResponse(f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<style>body{{margin:0;background:#0d111e;color:#e2e8f0;font-family:-apple-system;
display:flex;align-items:center;justify-content:center;height:100vh}}</style></head>
<body><div style="text-align:center"><div style="font-size:52px">📈</div>
<h3>暂无K线数据</h3><p style="color:#8892b0">{msg}</p>
<p style="color:#4a5578;font-size:12px">稍后重试,或切换级别后重开</p></div></body></html>""")

    # 代码归一化:sz.000678 / sz000678 / 000678 / 600812 → 股票;其余(含字母,如 JM0)→ 期货
    rows = []
    m = _re.match(r"^(?:sh|sz|bj)?\.?(\d{6})$", code)
    if m:
        bare = m.group(1)
        pfx = "sh" if bare[0] == "6" else ("bj" if bare[0] in "48" else "sz")
        if is_daily:
            from services.selection import tencent_daily
            k = tencent_daily(bare, 250)
            rows = [{"date": r["date"][:10], "open": r["open"], "close": r["close"],
                     "high": r["high"], "low": r["low"], "volume": r["volume"]}
                    for r in (k or [])]
        else:
            # 腾讯股票分钟K(mkline):[YYYYMMDDHHMM,开,收,高,低,量]
            import urllib.request as _ur
            try:
                api = f"https://ifzq.gtimg.cn/appstock/app/kline/mkline?param={pfx}{bare},m{minutes},,320"
                raw = _ur.urlopen(_ur.Request(api, headers={"User-Agent": "Mozilla/5.0"}), timeout=10).read().decode()
                arr = (_json.loads(raw).get("data") or {}).get(f"{pfx}{bare}") or {}
                mk = arr.get(f"m{minutes}") or []
                rows = [{"date": f"{s[0][:4]}-{s[0][4:6]}-{s[0][6:8]} {s[0][8:10]}:{s[0][10:12]}",
                         "open": float(s[1]), "close": float(s[2]), "high": float(s[3]),
                         "low": float(s[4]), "volume": float(s[5])} for s in mk if len(s) >= 6]
            except Exception:
                rows = []
    else:
        bars, _ = _sina_kline(code, minutes if minutes != 1440 else 1440, limit=250)
        if len(bars) < 50:
            from services.futures_monitor import cached_bars
            cb = cached_bars(code, minutes)
            if cb and len(cb) >= 50:
                bars = cb   # 新浪限流抖动,用监控线程缓存
        rows = [{"date": _dt(b.dt),
                 "open": b.open, "close": b.close, "high": b.high,
                 "low": b.low, "volume": b.vol} for b in (bars or [])]   # RawBar 属性=vol

    if len(rows) < 20:
        return _err(f"{code} · {level}")

    # czsc 结构
    bi_marks = []
    zs_marks = []
    bsp_marks = []
    try:
        from datetime import datetime as _dtc
        from czsc import CZSC, RawBar, Freq
        raw = [RawBar(symbol=code, dt=_dtc.fromisoformat(r["date"]),
                      open=r["open"], close=r["close"], high=r["high"],
                      low=r["low"], vol=r["volume"], amount=0,
                      freq=Freq.D if is_daily else Freq.F5)
               for r in rows]
        c = CZSC(raw, max_bi_num=100)
        for b in c.bi_list:
            down = "下" in str(b.direction)
            bi_marks.append({
                "d1": _dt(b.fx_a.dt),
                "p1": float(b.high if down else b.low),
                "d2": _dt(b.fx_b.dt),
                "p2": float(b.low if down else b.high),
                "dir": "down" if down else "up"})
        zs_marks = [{"d1": _dt(z.sdt), "d2": _dt(z.edt),
                     "lo": float(z.zd), "hi": float(z.zg)}
                    for z in (getattr(c, "zs_list", None) or [])]

        # 买卖点:B1/B2/B3 买点、S1/S2/S3 卖点(笔端点+MACD背驰+中枢回抽)
        def _macd_dif(closes, fast=12, slow=26):
            out, ef, es = [], None, None
            kf, ks = 2/(fast+1), 2/(slow+1)
            for cl in closes:
                ef = cl if ef is None else cl*kf + ef*(1-kf)
                es = cl if es is None else cl*ks + es*(1-ks)
                out.append(ef - es)
            return out
        dif = _macd_dif([r["close"] for r in rows])

        def _dif_at(dtstr):
            for i, r in enumerate(rows):
                if r["date"][:16] == dtstr[:16]:
                    return dif[i]
            return None

        def _diverge(b, prev_b, is_low):
            """新低/新高处力度是否背驰:MACD DIF 缩小优先,笔振幅缩小兜底。"""
            d_now, d_prev = _dif_at(_dt(b.fx_b.dt)), _dif_at(_dt(prev_b.fx_b.dt))
            if d_now is not None and d_prev is not None and min(abs(d_now), abs(d_prev)) > 1e-9:
                return abs(d_now) < abs(d_prev)
            if is_low:
                mv_now = abs(float(b.low)/float(b.high) - 1)
                mv_prev = abs(float(prev_b.low)/float(prev_b.high) - 1)
            else:
                mv_now = abs(float(b.high)/float(b.low) - 1)
                mv_prev = abs(float(prev_b.high)/float(prev_b.low) - 1)
            return mv_now < mv_prev * 0.9

        bis = c.bi_list

        def _dn(b):
            return "下" in str(b.direction)

        for i in range(2, len(bis)):          # 一类:同向笔新低新高+背驰(趋势=1,盘整=1p)
            b, prev_b = bis[i], bis[i-2]
            if _dn(b) and float(b.low) < float(prev_b.low) and _diverge(b, prev_b, True):
                trend = i >= 4 and float(prev_b.low) < float(bis[i-4].low)
                bsp_marks.append({"d": _dt(b.fx_b.dt), "p": float(b.low),
                                  "k": "B1" if trend else "B1P"})
            if not _dn(b) and float(b.high) > float(prev_b.high) and _diverge(b, prev_b, False):
                trend = i >= 4 and float(prev_b.high) > float(bis[i-4].high)
                bsp_marks.append({"d": _dt(b.fx_b.dt), "p": float(b.high),
                                  "k": "S1" if trend else "S1P"})
        lows = [(i, float(b.low)) for i, b in enumerate(bis) if _dn(b)]
        if lows:                               # 2/2s:最低点后回抽不破低(第一次=2,再次抬高=2s)
            i_min, p_min = min(lows, key=lambda x: x[1])
            got = 0
            for j in range(i_min+1, min(i_min+6, len(bis))):
                b2 = bis[j]
                if _dn(b2):
                    if float(b2.low) > p_min:
                        got += 1
                        bsp_marks.append({"d": _dt(b2.fx_b.dt), "p": float(b2.low),
                                          "k": "B2" if got == 1 else "B2S"})
                        p_min = float(b2.low)
                    elif got:
                        break
        highs = [(i, float(b.high)) for i, b in enumerate(bis) if not _dn(b)]
        if highs:                              # 卖2/2s:最高点后反抽不过高
            i_max, p_max = max(highs, key=lambda x: x[1])
            got = 0
            for j in range(i_max+1, min(i_max+6, len(bis))):
                b2 = bis[j]
                if not _dn(b2):
                    if float(b2.high) < p_max:
                        got += 1
                        bsp_marks.append({"d": _dt(b2.fx_b.dt), "p": float(b2.high),
                                          "k": "S2" if got == 1 else "S2S"})
                        p_max = float(b2.high)
                    elif got:
                        break
        for z in (getattr(c, "zs_list", None) or []):   # B3/S3:离开中枢后首次回抽不回中枢
            zg, zd, z_end = float(z.zg), float(z.zd), _dt(z.edt)
            for b in bis:
                if _dt(b.fx_b.dt) <= z_end:
                    continue
                down = "下" in str(b.direction)
                if down and float(b.low) > zg:
                    bsp_marks.append({"d": _dt(b.fx_b.dt), "p": float(b.low), "k": "B3"})
                    break
                elif not down and float(b.high) < zd:
                    bsp_marks.append({"d": _dt(b.fx_b.dt), "p": float(b.high), "k": "S3"})
                    break
        seen, dedup = set(), []
        for m in sorted(bsp_marks, key=lambda x: x["d"]):
            key = (m["d"], m["k"])
            if key not in seen:
                seen.add(key)
                dedup.append(m)
        bsp_marks = dedup
    except Exception:
        import traceback
        traceback.print_exc()

    kline_json = _json.dumps(rows, ensure_ascii=False)
    bi_json = _json.dumps(bi_marks, ensure_ascii=False)
    zs_json = _json.dumps(zs_marks, ensure_ascii=False)

    html = """<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body{margin:0;background:#0d111e;color:#e2e8f0;font-family:-apple-system}
.wrap{display:flex;height:100vh}
#chart{flex:1;height:100%}
#side{width:300px;border-left:1px solid #1a2035;padding:14px 10px;overflow-y:auto;box-sizing:border-box}
#side h3{font-size:12px;color:#8892b0;margin:2px 0 8px;font-weight:600}
#side table{width:100%;border-collapse:collapse;font-size:11px}
#side td{padding:6px 2px;border-bottom:1px solid #1a2035;color:#c9d4e8;white-space:nowrap}
.bg{padding:2px 8px;border-radius:4px;font-weight:600;font-size:11px}
.bg.b{background:rgba(255,90,95,.16);color:#ff5a5f;border:1px solid rgba(255,90,95,.35)}
.bg.s{background:rgba(48,209,88,.14);color:#30d158;border:1px solid rgba(48,209,88,.35)}
.ok{color:#5b6b8c;font-size:11px}
.new{background:rgba(10,132,255,.16);color:#0a84ff;border:1px solid rgba(10,132,255,.4);
     padding:1px 6px;border-radius:4px;font-size:10px;font-weight:700}
.none{color:#4a5578}
.zs{font-size:12px;color:#c9d4e8;line-height:1.8}
.legend{position:absolute;left:12px;bottom:26px;font-size:11px;color:#8892b0;pointer-events:none;
        background:rgba(13,17,30,.78);padding:3px 8px;border-radius:6px;z-index:5}
</style>
<script src="https://unpkg.com/lightweight-charts@4.1.3/dist/lightweight-charts.standalone.production.js"></script>
</head><body><div class="wrap">
<div style="position:relative;flex:1"><div id="chart"></div>
<div class="legend">
<span style="color:#ff5a5f">▲红</span>=买 <span style="color:#30d158">▼绿</span>=卖 ·
1 趋势背驰 · 1p 盘整背驰 · 2/2s 二买/类二 · 3 三类回抽 ·
<span style="color:#0a84ff">- -</span> 笔 · <span style="color:#e6b422">▭</span> 中枢
</div>
</div>
<div id="side">
  <h3>买卖点(最近6个)</h3>
  <table id="bspTable"><tr><td class="none">加载中</td></tr></table>
  <h3 style="margin-top:18px">中枢(最近1个)</h3>
  <div id="zsBox" class="none">加载中</div>
</div>
</div>
<script>
const kline=__KLINE__;
const bis=__BI__;
const zss=__ZS__;
const bsp=__BSP__;
const t=x=>(x&&x.length>10)?Math.floor(new Date(x.replace(' ','T')).getTime()/1000):x;
const chart=LightweightCharts.createChart(document.getElementById('chart'),{
  autoSize:true,
  layout:{background:{type:'solid',color:'#0d111e'},textColor:'#8892b0'},
  grid:{vertLines:{color:'#1a2035'},horzLines:{color:'#1a2035'}},
  crosshair:{mode:0},timeScale:{borderColor:'#2a3448'}
});
const series=chart.addCandlestickSeries({upColor:'#ff5a5f',downColor:'#30d158',
  borderUpColor:'#ff5a5f',borderDownColor:'#30d158',wickUpColor:'#ff5a5f',wickDownColor:'#30d158'});
series.setData(kline.map(k=>({time:t(k.date),open:k.open,high:k.high,low:k.low,close:k.close})));
if(bsp.length>0){
  series.setMarkers(bsp.map(x=>({time:t(x.d),
    position:x.k[0]==='B'?'belowBar':'aboveBar',
    color:x.k[0]==='B'?'#ff5a5f':'#30d158',
    shape:x.k[0]==='B'?'arrowUp':'arrowDown',text:x.k.slice(1).toLowerCase()})));
}
if(bis.length>0){
  const ls=chart.addLineSeries({color:'#0a84ff',lineWidth:1,lineStyle:2});
  const pts=[];
  bis.forEach(b=>{pts.push({time:t(b.d1),value:b.p1});pts.push({time:t(b.d2),value:b.p2})});
  ls.setData(pts);
}
if(zss.length>0){
  const lo=chart.addLineSeries({color:'#e6b422',lineWidth:1,priceLineVisible:false,lastValueVisible:false});
  const hi=chart.addLineSeries({color:'#e6b422',lineWidth:1,priceLineVisible:false,lastValueVisible:false});
  const loPts=[],hiPts=[];
  zss.forEach(z=>{loPts.push({time:t(z.d1),value:z.lo},{time:t(z.d2),value:z.lo});
                  hiPts.push({time:t(z.d1),value:z.hi},{time:t(z.d2),value:z.hi});});
  lo.setData(loPts);hi.setData(hiPts);
}
chart.timeScale().fitContent();

const NAMES={B1:'买·1',B1P:'买·1p',B2:'买·2',B2S:'买·2s',B3:'买·3',
             S1:'卖·1',S1P:'卖·1p',S2:'卖·2',S2S:'卖·2s',S3:'卖·3'};
const f=v=>{const s=(+v).toFixed(2);return s.endsWith('.00')?s.slice(0,-3):s};
const recent=bsp.slice(-6);
document.getElementById('bspTable').innerHTML = recent.length
  ? recent.map((x,i)=>`<tr><td>${x.d}</td>
      <td><span class="bg ${x.k[0]==='B'?'b':'s'}">${NAMES[x.k]||x.k}</span></td>
      <td>@${f(x.p)}</td><td class="ok">已确认</td>
      ${i===recent.length-1?'<td><span class="new">NEW</span></td>':''}</tr>`).join('')
  : '<tr><td class="none">暂无(背驰需足够笔数)</td></tr>';
const z=zss.length?zss[zss.length-1]:null;
document.getElementById('zsBox').outerHTML = z
  ? `<div class="zs">${z.d1} ~ ${z.d2}<br>区间 [${f(z.lo)}, ${f(z.hi)}]</div>`
  : '<div class="none">暂无</div>';
</script></body></html>"""
    html = (html.replace("__KLINE__", kline_json).replace("__BI__", bi_json)
                .replace("__ZS__", zs_json).replace("__BSP__", _json.dumps(bsp_marks, ensure_ascii=False)))
    return HTMLResponse(html)




from fastapi.responses import FileResponse  # noqa: E402



