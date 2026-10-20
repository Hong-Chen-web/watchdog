"""健康页接口:/api/food(饮食明细 + AI 估热量 + 按身高体重推荐每日热量目标)。

- 明细:按日 CRUD;热量为 AI/手填的估算值,只做参考不承诺精确。
- 目标:Mifflin-St Jeor BMR × 活动系数 − 500 kcal(约每周减 0.5kg),下限保护。
- AI:llm_cfg 配置的大模型(OpenAI 兼容),把一句话拆成多条食物并估千卡;
  未配置/解析失败返回 400 文案,前端降级手动录入。
"""
import json
import re
from datetime import date, datetime, timedelta

from fastapi import APIRouter, HTTPException

from .common import get_conn

router = APIRouter(prefix="/api/food", tags=["food"])

MEALS = ["早餐", "午餐", "晚餐", "加餐"]
# Mifflin-St Jeor 活动系数
ACTIVITY = {"久坐": 1.2, "轻度活动": 1.375, "中度活动": 1.55, "高强度": 1.725}
PROFILE_KEY = "health_profile"


# ---------- 纯函数(单测覆盖) ----------

def _meal_auto(now: datetime = None) -> str:
    """没选餐次时按钟点归档。"""
    h = (now or datetime.now()).hour
    if h < 10:
        return "早餐"
    if h < 14:
        return "午餐"
    if h < 21:
        return "晚餐"
    return "加餐"


def _recommended(p: dict) -> int | None:
    """按身高体重年龄性别活动量推荐每日摄入(Mifflin-St Jeor,减脂缺口 500)。档案不全返回 None。"""
    try:
        w = float(p["weight_kg"]); h = float(p["height_cm"]); a = float(p["age"])
        sex = p.get("sex")
        if not (25 <= w <= 300 and 100 <= h <= 250 and 10 <= a <= 100 and sex in ("男", "女")):
            return None
    except (KeyError, TypeError, ValueError):
        return None
    bmr = 10 * w + 6.25 * h - 5 * a + (5 if sex == "男" else -161)
    tdee = bmr * ACTIVITY.get(p.get("activity") or "久坐", 1.2)
    target = tdee - 500                      # 约每周 -0.5kg 的温和缺口
    floor = 1200 if sex == "女" else 1500    # 不低于基础代谢安全线
    return int(round(max(floor, target) / 10) * 10)


def _clean_items(items) -> list:
    """AI 返回的条目清洗:food 必填截断,kcal 限幅,portion 截断。"""
    out = []
    for it in (items or [])[:10]:
        if not isinstance(it, dict):
            continue
        food = str(it.get("food") or "").strip()
        if not food:
            continue
        try:
            kcal = max(0.0, min(float(it.get("kcal")), 5000))
        except (TypeError, ValueError):
            kcal = None
        out.append({"food": food[:60], "portion": str(it.get("portion") or "").strip()[:40],
                    "kcal": kcal})
    return out


# ---------- 档案 ----------

def _get_profile(conn) -> dict:
    row = conn.execute("SELECT value FROM settings WHERE key=?", (PROFILE_KEY,)).fetchone()
    try:
        p = json.loads(row["value"] or "{}") if row else {}
    except (json.JSONDecodeError, TypeError):
        p = {}
    return p if isinstance(p, dict) else {}


def _put_profile(conn, p: dict):
    conn.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
                 (PROFILE_KEY, json.dumps(p, ensure_ascii=False)))


@router.put("/profile")
def food_profile(body: dict = None):
    """保存身体档案;target_kcal 缺省=按档案推荐,显式给出则覆盖(未给出保留旧目标)。"""
    b = body or {}
    try:
        p = {"height_cm": float(b["height_cm"]), "weight_kg": float(b["weight_kg"]),
             "age": int(b["age"]), "sex": b.get("sex"),
             "activity": b.get("activity") if b.get("activity") in ACTIVITY else "久坐"}
    except (KeyError, TypeError, ValueError):
        raise HTTPException(400, "档案要填:身高cm/体重kg/年龄/性别(男|女)")
    if _recommended(p) is None:
        raise HTTPException(400, "数值超出合理范围,检查身高/体重/年龄")
    conn = get_conn()
    try:
        old = _get_profile(conn)
        if b.get("target_kcal") not in (None, ""):
            try:
                tk = int(float(b["target_kcal"]))
                if not 800 <= tk <= 6000:
                    raise ValueError
                p["target_kcal"] = tk
            except (TypeError, ValueError):
                raise HTTPException(400, "目标热量需在 800-6000 之间")
        elif "target_kcal" in old:
            p["target_kcal"] = old["target_kcal"]   # 只更新档案时保留已设目标
        _put_profile(conn, p)
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "profile": p, "recommended": _recommended(p),
            "target": p.get("target_kcal") or _recommended(p)}


@router.put("/target")
def food_target(body: dict = None):
    """只改每日目标;kcal 传空 = 清掉自定义,回到推荐值。"""
    b = body or {}
    conn = get_conn()
    try:
        p = _get_profile(conn)
        if b.get("kcal") in (None, ""):
            p.pop("target_kcal", None)
        else:
            try:
                tk = int(float(b["kcal"]))
            except (TypeError, ValueError):
                raise HTTPException(400, "目标要是整数 kcal")
            if not 800 <= tk <= 6000:
                raise HTTPException(400, "目标需在 800-6000 之间")
            p["target_kcal"] = tk
        _put_profile(conn, p)
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "target": p.get("target_kcal") or _recommended(p) or 2000}


# ---------- AI 拆条目 ----------

def _ai_parse(text: str) -> list:
    from services.llm_cfg import effective as _eff
    try:
        base, key, model, _src = _eff()
    except Exception:
        base = key = None
    if not (base and key):
        raise HTTPException(400, "未配置大模型(设置 · 大模型),可先手动填热量")
    import requests
    sess = requests.Session()
    sess.trust_env = False          # 绕 Clash 纪律:出网不读环境代理
    today = date.today().isoformat()
    sys_prompt = (
        f"今天是{today}。你是饮食记录助手。把用户描述吃的东西拆成食物条目,"
        '只输出 JSON 数组,不要任何多余文字:'
        '[{"food":"食物名","portion":"份量,如 1个/1碗/200g","kcal":整数千卡}]。'
        "用常见中式食物热量估值;没说数量按常见一份;同类合并;最多 8 条。")
    try:
        r = sess.post(f"{str(base).rstrip('/')}/chat/completions",
                      headers={"Authorization": f"Bearer {key}"},
                      json={"model": model or "deepseek-chat",
                            "messages": [{"role": "system", "content": sys_prompt},
                                         {"role": "user", "content": text[:300]}],
                            "temperature": 0}, timeout=30)
        content = r.json()["choices"][0]["message"]["content"]
        m = re.search(r"\[.*\]", content, re.S)
        if not m:
            raise ValueError("no json array")
        items = _clean_items(json.loads(m.group(0)))
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(400, f"AI 识别失败({e.__class__.__name__}),请手动记录")
    if not items:
        raise HTTPException(400, "没认出食物,换个说法或手动记录")
    return items


# ---------- 明细 CRUD ----------

@router.get("")
def food_overview(days: int = 7):
    """今日明细 + 近 N 天每日合计 + 目标(档案覆盖 > 推荐 > 2000 兜底)。"""
    conn = get_conn()
    try:
        today = date.today().isoformat()
        p = _get_profile(conn)
        rec = _recommended(p)
        target = int(p.get("target_kcal") or rec or 2000)
        rows = [dict(r) for r in conn.execute(
            "SELECT id,date,meal,food,portion,kcal,created_at FROM food_entries"
            " WHERE date=? ORDER BY id", (today,))]
        n = max(1, min(int(days or 7), 60))
        start = (date.today() - timedelta(days=n - 1)).isoformat()
        sums = {r["date"]: round(r["k"] or 0) for r in conn.execute(
            "SELECT date, SUM(COALESCE(kcal,0)) k FROM food_entries"
            " WHERE date>=? GROUP BY date", (start,))}
        day_list = [{"date": (date.today() - timedelta(days=n - 1 - i)).isoformat(),
                     "total": sums.get((date.today() - timedelta(days=n - 1 - i)).isoformat(), 0)}
                    for i in range(n)]
        return {"today": today, "target": target, "recommended": rec, "profile": p,
                "meals": MEALS, "activity": ACTIVITY,
                "total": round(sum(r["kcal"] or 0 for r in rows)),
                "entries": rows, "days": day_list}
    finally:
        conn.close()


@router.post("")
def food_add(body: dict = None):
    """记一笔:text 有值走 AI 拆条目,否则按 food/portion/kcal 单条。"""
    b = body or {}
    meal = b.get("meal") if b.get("meal") in MEALS else _meal_auto()
    d = b.get("date") or date.today().isoformat()
    text = (b.get("text") or "").strip()
    if text:
        items = _ai_parse(text)
    else:
        items = _clean_items([{"food": b.get("food"), "portion": b.get("portion"),
                               "kcal": b.get("kcal")}])
        if not items:
            raise HTTPException(400, "写点什么,比如:米饭 1 碗 230")
    conn = get_conn()
    try:
        out = []
        for it in items:
            cur = conn.execute(
                "INSERT INTO food_entries(date,meal,food,portion,kcal) VALUES(?,?,?,?,?)",
                (d, meal, it["food"], it["portion"], it["kcal"]))
            out.append({"id": cur.lastrowid, "meal": meal, **it})
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "items": out, "total": round(sum(i["kcal"] or 0 for i in out))}


@router.patch("/{fid}")
def food_patch(fid: int, body: dict = None):
    """改一条(kcal/food/portion/meal)。"""
    b = body or {}
    sets, vals = [], []
    if "kcal" in b:
        try:
            k = None if b["kcal"] in (None, "") else max(0.0, min(float(b["kcal"]), 5000))
        except (TypeError, ValueError):
            raise HTTPException(400, "热量要是数字")
        sets.append("kcal=?"); vals.append(k)
    for f in ("food", "portion", "meal"):
        if f in b:
            if f == "meal" and b[f] not in MEALS:
                raise HTTPException(400, f"餐次需为 {MEALS}")
            sets.append(f+"=?"); vals.append(str(b[f])[:60])
    if not sets:
        raise HTTPException(400, "没有要改的字段")
    conn = get_conn()
    try:
        cur = conn.execute(f"UPDATE food_entries SET {','.join(sets)} WHERE id=?", (*vals, fid))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, "条目不存在")
    finally:
        conn.close()
    return {"ok": True}


@router.delete("/{fid}")
def food_del(fid: int):
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM food_entries WHERE id=?", (fid,))
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(404, "条目不存在")
    finally:
        conn.close()
    return {"ok": True}
