"""账本模块接口:/api/ledger(ledger_* 三表)+ /api/import/numbers(Numbers 导入管线)。"""
import os
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from .common import get_conn, validate_date

router = APIRouter(prefix="/api/ledger", tags=["ledger"])

# smart-any 防重:同文本 120s 内重复提交返回上次结果(双击/重发不重复记账)
_smart_dedup = {}
_smart_dedup_lock = __import__("threading").Lock()
import_router = APIRouter(prefix="/api/import", tags=["ledger"])


def _range_where(month, start, end):
    """month / start+end → WHERE 片段与参数;全不传 = 全部历史。"""
    if month:
        if len(month) != 7 or month[4] != "-":
            raise HTTPException(400, "month want YYYY-MM")
        return "substr(e.date,1,7)=?", [month]
    conds, args = [], []
    if start:
        validate_date(start); conds.append("e.date>=?"); args.append(start)
    if end:
        validate_date(end); conds.append("e.date<=?"); args.append(end)
    return (" AND ".join(conds), args) if conds else ("", [])


@router.get("/summary")
def ledger_summary(month: str = None, start: str = None, end: str = None):
    where, args = _range_where(month, start, end)
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT e.amount, c.id cid FROM ledger_entries e"
            " JOIN ledger_categories c ON c.id=e.category_id"
            f"{' WHERE ' + where if where else ''}", args).fetchall()
        year = int(month[:4]) if month else int((start or "1970-01-01")[:4])
        cats = conn.execute(
            "SELECT c.id, c.name, c.name_en, c.color,"
            " COALESCE(b.monthly,0) budget_month, COALESCE(b.annual,0) budget_year"
            " FROM ledger_categories c LEFT JOIN ledger_budgets b"
            " ON b.category_id=c.id AND b.year=? ORDER BY c.sort", (year,)).fetchall()
        actual = {c["id"]: 0.0 for c in cats}
        income = 0.0
        for r in rows:
            if r["amount"] < 0:
                actual[r["cid"]] += -r["amount"]
            else:
                income += r["amount"]
        expense = sum(actual.values())
        return {"month": month, "start": start, "end": end,
                "income": round(income, 2), "expense": round(expense, 2),
                "net": round(income - expense, 2),
                "categories": [
                    {"id": c["id"], "name": c["name"], "name_en": c["name_en"],
                     "color": c["color"], "budget_month": c["budget_month"],
                     "budget_year": c["budget_year"],
                     "actual": round(actual.get(c["id"], 0), 2),
                     "remaining": round(c["budget_month"] - actual.get(c["id"], 0), 2)}
                    for c in cats]}
    finally:
        conn.close()


@router.get("/entries")
def ledger_entries(month: str = None, start: str = None, end: str = None,
                   category: str = None, limit: int = 50, offset: int = 0):
    where, args = _range_where(month, start, end)
    if category:
        where = (where + " AND " if where else "") + "c.name=?"
        args = args + [category]
    q = ("SELECT e.id, e.date, e.payee, e.amount, e.note, e.source,"
         " c.name category FROM ledger_entries e"
         " JOIN ledger_categories c ON c.id=e.category_id"
         f"{' WHERE ' + where if where else ''}"
         " ORDER BY e.date DESC, e.id DESC LIMIT ? OFFSET ?")
    args = args + [min(limit, 500), offset]
    conn = get_conn()
    try:
        return [dict(r) for r in conn.execute(q, args).fetchall()]
    finally:
        conn.close()


@router.delete("/entries/{eid}", status_code=204)
def delete_entry(eid: int):
    conn = get_conn()
    try:
        conn.execute("DELETE FROM ledger_entries WHERE id=?", (eid,))
        conn.commit()
    finally:
        conn.close()


@router.post("/categories", status_code=201)
def add_category(body: dict):
    name = (body.get("name") or "").strip()
    if not name:
        raise HTTPException(400, "名称不能为空")
    conn = get_conn()
    try:
        exists = conn.execute("SELECT id FROM ledger_categories WHERE name=?", (name,)).fetchone()
        if exists:
            return {"id": exists["id"], "existed": True}
        cur = conn.execute("INSERT INTO ledger_categories(name) VALUES(?)", (name,))
        conn.commit()
        return {"id": cur.lastrowid}
    finally:
        conn.close()


@router.delete("/categories/{cid}", status_code=204)
def delete_category(cid: int):
    """删分类:无流水才允许;预算随分类级联删(SQLite FK)。"""
    conn = get_conn()
    try:
        n = conn.execute("SELECT COUNT(*) c FROM ledger_entries e"
                         " JOIN ledger_categories c ON c.id=e.category_id"
                         " WHERE c.id=?", (cid,)).fetchone()["c"]
        if n:
            raise HTTPException(400, f"该分类有 {n} 笔流水,不能删")
        conn.execute("DELETE FROM ledger_budgets WHERE category_id=?", (cid,))
        conn.execute("DELETE FROM ledger_categories WHERE id=?", (cid,))
        conn.commit()
    finally:
        conn.close()


@router.post("/smart", status_code=201)
def smart_entry(body: dict):
    """自然语言记账:『昨天午饭花了35』→ 自动归类落库(本地规则解析,无 LLM)。"""
    from services.smart_entry import parse_entry
    text = (body.get("text") or "").strip()
    if not text:
        raise HTTPException(400, "说点什么,比如『昨天午饭花了35』")
    try:
        parsed = parse_entry(text)
    except ValueError as e:
        raise HTTPException(422, str(e))
    create_ledger_entry(LedgerEntryIn(
        date=parsed["date"], payee=parsed["payee"] or "",
        category=parsed["category"], amount=parsed["amount"]))
    return parsed


@router.get("/report")
def ledger_report(month: str = None, year: int = None):
    """财务分析报告:month=YYYY-MM 出月度口径;否则年度口径(annual 同款)。"""
    if month:
        from datetime import date
        y = int(month[:4]); m = int(month[5:7])
        last = [31, 29 if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0 else 28,
                31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return _analyze(f"{month}-01", f"{month}-{last:02d}", avg_days=last, is_month=True)
    return ledger_annual(year)


@router.get("/annual")
def ledger_annual(year: int = None):
    """年度财务分析:总览/月度趋势/分类结构/异常账单/改进建议/下年度基线。"""
    from datetime import date
    year = year or date.today().year
    return _analyze(f"{year}-01-01", f"{year}-12-31", avg_days=365, is_month=False)


def _analyze(d1: str, d2: str, avg_days: int, is_month: bool):
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT e.date, e.payee, e.amount, c.name cat FROM ledger_entries e"
            " JOIN ledger_categories c ON c.id=e.category_id"
            " WHERE e.date BETWEEN ? AND ? ORDER BY e.date",
            (d1, d2)).fetchall()
    finally:
        conn.close()
    expenses = [r for r in rows if r["amount"] < 0]
    incomes = [-r["amount"] for r in rows if r["amount"] > 0]
    total_out = -sum(r["amount"] for r in expenses)
    total_in = sum(incomes)
    label = "本月" if is_month else "全年"

    by_month = {}
    for r in expenses:
        m = r["date"][5:7]
        by_month[m] = by_month.get(m, 0) + (-r["amount"])
    months = [{"month": k, "expense": round(v, 2)} for k, v in sorted(by_month.items())]
    avg_m = total_out / 12 if not is_month else total_out

    by_cat = {}
    for r in expenses:
        by_cat[r["cat"]] = by_cat.get(r["cat"], 0) + (-r["amount"])
    cats = sorted([{"cat": k, "total": round(v, 2),
                    "pct": round(v / total_out * 100, 1) if total_out else 0}
                  for k, v in by_cat.items()], key=lambda x: -x["total"])

    # 异常:单笔 > 全年单笔均值×3;月支出 > 月均×2;同事项高频累计
    amounts = [-r["amount"] for r in expenses]
    avg_item = sum(amounts) / len(amounts) if amounts else 0
    anomalies = [
        {"date": r["date"], "payee": r["payee"] or r["cat"], "cat": r["cat"],
         "amount": -r["amount"], "why": f"单笔为{label}均笔({avg_item:.0f})的 {(-r['amount'])/avg_item:.0f} 倍"}
        for r in expenses if avg_item > 0 and -r["amount"] > avg_item * 3]
    if not is_month:
        anomalies += [
            {"date": f"{d1[:4]}-{m['month']}", "payee": "整月", "cat": "-",
             "amount": m["expense"], "why": f"月支出为月均({avg_m:.0f})的 {m['expense']/avg_m:.1f} 倍"}
            for m in months if avg_m > 0 and m["expense"] > avg_m * 2]
    payee_sum = {}
    for r in expenses:
        k = r["payee"] or r["cat"]
        payee_sum[k] = payee_sum.get(k, [0, 0])
        payee_sum[k][0] += -r["amount"]
        payee_sum[k][1] += 1
    anomalies += [
        {"date": "-", "payee": k, "cat": "-", "amount": round(v[0], 2),
         "why": f"高频小额 {v[1]} 笔累计"}
        for k, v in payee_sum.items() if v[1] >= 8 and v[0] > avg_m]

    # 建议(规则生成)
    tips = []
    if cats:
        top = cats[0]
        if top["pct"] > 30:
            tips.append(f"{top['cat']} 占支出 {top['pct']}%,压缩 10% 可省 {top['total']*0.1:.0f} 元/{'月' if is_month else '年'}")
    big_anom = [a for a in anomalies if a["payee"] != "整月"]
    if big_anom:
        tips.append(f"有 {len(big_anom)} 笔异常大额,合计 {-sum(a['amount'] for a in big_anom):.0f} 元,建议逐笔复盘必要性")
    hf = [a for a in anomalies if "高频" in a["why"]]
    if hf:
        tips.append(f"『{hf[0]['payee']}』全年 {hf[0]['amount']:.0f} 元/{hf[0]['why'].split()[0]},设月度上限更可控")
    save_rate = (total_in - total_out) / total_in * 100 if total_in else 0
    tips.append(f"今年结余率 {save_rate:.0f}%;" + ("建议下年提到 20% 以上" if save_rate < 20 else "保持"))
    plan = {c["cat"]: round(c["total"] / (30 if is_month else 12) * 1.05, 0) for c in cats}

    # 月度环比:上月总支出(vs)
    prev_out = None
    mom_pct = None
    if is_month:
        y2, m2 = int(d1[:4]), int(d1[5:7])
        py, pm = (y2 - 1, 12) if m2 == 1 else (y2, m2 - 1)
        from calendar import monthrange as _mr
        p2 = f"{py}-{pm:02d}-{_mr(py, pm)[1]:02d}"
        conn2 = get_conn()
        try:
            r2 = conn2.execute(
                "SELECT COALESCE(SUM(-amount),0) v FROM ledger_entries"
                " WHERE date BETWEEN ? AND ? AND amount<0",
                (f"{py}-{pm:02d}-01", p2)).fetchone()
            prev_out = round(r2["v"], 2)
        finally:
            conn2.close()
        if prev_out and prev_out > 0:
            mom_pct = round((total_out - prev_out) / prev_out * 100, 1)
    # 近12个月趋势(无论月/年口径,给卡画走势)
    recent = []
    try:
        conn3 = get_conn()
        rr = conn3.execute(
            "SELECT substr(date,1,7) m, SUM(-amount) v FROM ledger_entries"
            " WHERE amount<0 AND date>=date(?, '-11 months', 'start of month')"
            " GROUP BY m ORDER BY m", (d1,)).fetchall()
        recent = [{"month": r["m"][5:7], "expense": round(r["v"], 2)} for r in rr]
        conn3.close()
    except Exception:
        pass
    # 本期 Top 支出明细(前10笔)
    top_entries = [{"date": r["date"], "payee": r["payee"] or r["cat"], "cat": r["cat"],
                    "amount": round(-r["amount"], 2)}
                   for r in sorted(expenses, key=lambda x: x["amount"])[:10]]
    return {"year": int(d1[:4]), "period": d1[:7] if is_month else d1[:4],
            "is_month": is_month, "entries": len(rows),
            "prev_out": prev_out, "mom_pct": mom_pct,
            "recent_months": recent, "top_entries": top_entries,
            "total_in": round(total_in, 2), "total_out": round(total_out, 2),
            "net": round(total_in - total_out, 2), "avg_month": round(avg_m, 2),
            "max_item": round(max(amounts), 2) if amounts else 0,
            "save_rate": round(save_rate, 1),
            "months": months, "cats": cats,
            "anomalies": anomalies[:10], "tips": tips, "next_year_plan": plan}


@router.post("/smart-any")
def smart_any(body: dict):
    """统一自然语言入口:一句话自动识别账单/todo/目标/日志并落库。
    LLM(OpenAI 兼容,设置区/env 可选)优先,本地启发式兜底。
    防重:同一文本 120 秒内重复提交直接返回上次结果(双击/重发不再重复记账)。"""
    import os
    import re as _re
    import time as _time
    import threading as _th
    import db as dbm2
    text = (body.get("text") or "").strip()
    if not text:
        raise HTTPException(400, "说点什么")

    with _smart_dedup_lock:
        hit = _smart_dedup.get(text)
        now = _time.time()
        if hit and now - hit["at"] < 120:
            hit["at"] = now
            return {**hit["resp"], "dedup": True}
        _smart_dedup[text] = {"at": now, "resp": None}   # 占位:防并发双发

    llm_base, llm_key, llm_model, _ = None, None, None, None
    try:
        from services.llm_cfg import effective as _llm_cfg
        llm_base, llm_key, llm_model, _ = _llm_cfg()
    except Exception:
        pass

    def _llm_parse():
        import json as _json
        import requests
        from datetime import date as _d
        today = _d.today()
        sys_prompt = (
            f"今天是{today.year}年{today.month}月{today.day}日(星期{'一二三四五六日'[today.weekday()]})。"
            "把用户的话解析成 JSON 数组(可能含多条)。每条字段:"
            '{"type":"ledger|todo|goal","date":"YYYY-MM-DD或null(相对词按今天换算,没提日期用今天)",'
            '"amount":数字或null,"category":"食物/房屋/娱乐旅游/旅行/医疗/个人物品/人情/其他 之一或null",'
            '"title":"事项"}。用户说『不用记/别记』的条目直接忽略不要输出。只输出 JSON 数组。')
        r = requests.post(
            f"{llm_base.rstrip('/')}/chat/completions",
            headers={"Authorization": f"Bearer {llm_key}"},
            json={"model": llm_model or "deepseek-chat",
                  "messages": [
                      {"role": "system", "content": sys_prompt},
                      {"role": "user", "content": text}],
                  "temperature": 0},
            timeout=30)
        content = r.json()["choices"][0]["message"]["content"]
        m = _re.search(r"\[.*\]", content, _re.S)
        return _json.loads(m.group(0)) if m else []

    def _local_parse():
        """启发式:金额出现=账单;『记得/要/去/办/买…』无金额=todo;『目标/存/攒』=goal。"""
        from services.smart_entry import parse_entry, CAT_KEYWORDS
        from datetime import date, timedelta
        out = []
        # 切句(逗号/分号/然后/顺便)
        parts = _re.split(r"[,;,。;;]|然后|顺便|并且", text)
        date_map = {"昨天": date.today() - timedelta(days=1),
                    "今天": date.today(), "明天": date.today() + timedelta(days=1),
                    "后天": date.today() + timedelta(days=2)}
        cur_date = None
        for seg in parts:
            seg = seg.strip()
            if not seg:
                continue
            for w, d in date_map.items():
                if w in seg:
                    cur_date = d
            has_amount = _re.search(
                r"\d+(?:\.\d+)?\s*(?:块|元|¥)|[零一二两三四五六七八九十百千万]{1,8}\s*(?:块|元)"
                r"|(?:花了|消费|支出|付)\s*\d+|(?:花了|花费|消费|支出|付了?|充了?)"
                r"\s*[零一二两三四五六七八九十百千万]{1,8}|\d+(?:\.\d+)?\s*$", seg)
            if has_amount:
                try:
                    r = parse_entry(seg)
                    if cur_date:
                        r["date"] = cur_date.isoformat()
                    r["type"] = "ledger"
                    out.append(r)
                    continue
                except Exception:
                    pass
            if _re.search(r"目标|存\d|攒\d", seg):
                title = _re.sub(r"^(还有|另外|以及|一个|我的)?(一个)?(目标是?|愿望是?)", "", seg).strip() or seg
                out.append({"type": "goal", "title": title, "scope": "year"})
            else:
                t = _re.sub(r"^(昨天|今天|明天|后天)", "", seg).strip()
                t = _re.sub(r"^(记得|要|得|去|帮我)", "", t).strip()
                if t:
                    out.append({"type": "todo", "title": t,
                                "due_date": cur_date.isoformat() if cur_date else None})
        return out

    items = []
    engine = "local"
    llm_error = None
    if llm_base and llm_key:
        try:
            items = _llm_parse()
            engine = "llm"
        except Exception as e:
            items = []
            llm_error = f"{type(e).__name__}: {str(e)[:120]}"
    if not items:
        items = _local_parse()
        engine = "local"

    results = []
    conn = get_conn()
    try:
        for it in items:
            t = it.get("type")
            if t == "ledger" and it.get("amount"):
                create_ledger_entry(LedgerEntryIn(
                    date=it.get("date") or date.today().isoformat(),
                    payee=(it.get("title") or it.get("payee") or "").strip(), category=it.get("category") or "其他",
                    amount=float(it["amount"])))
                results.append(f"账单:{it.get('title') or it.get('payee') or ''} {it['amount']}元 → {it.get('category')}")
            elif t == "todo":
                conn.execute(
                    "INSERT INTO todos(title, due_date, priority) VALUES(?,?,3)",
                    (it.get("title", "")[:200], it.get("date")))
                conn.commit()
                results.append(f"待办:{it.get('title')}" + (f"(截止 {it['date']})" if it.get("date") else ""))
            elif t == "goal":
                conn.execute(
                    "INSERT INTO goals(scope, title, source) VALUES(?,?, 'manual')",
                    (it.get("scope") or "year", it.get("title", "")))
                conn.commit()
                results.append(f"目标:{it.get('title')}")
    finally:
        conn.close()
    # 识别留痕(以后排查"识别得烂"有据可查)
    try:
        conn2 = dbm2.connect()
        conn2.execute("INSERT INTO sync_log(source,status,message) VALUES(?,?,?)",
                      ("smart", engine,
                       (text[:60] + " ⇒ " + "; ".join(
                           f"{it.get('type')}:{(it.get('title') or it.get('payee') or '')[:18]}"
                           f"{' ' + str(it.get('amount')) + '元' if it.get('amount') else ''}"
                           for it in items))[:250]))
        conn2.commit()
        conn2.close()
    except Exception:
        pass
    resp = {"engine": engine, "parsed": items, "results": results, "llm_error": llm_error}
    with _smart_dedup_lock:
        _smart_dedup[text]["resp"] = resp
        if len(_smart_dedup) > 200:   # 缓存上限:清最老一半
            for k in sorted(_smart_dedup, key=lambda k: _smart_dedup[k]["at"])[:100]:
                _smart_dedup.pop(k, None)
    return resp


@router.get("/months")
def ledger_months():
    """有数据的月份清单(降维给筛选器)。"""
    conn = get_conn()
    try:
        return [dict(r) for r in conn.execute(
            "SELECT substr(date,1,7) month, COUNT(*) entries,"
            " ROUND(SUM(CASE WHEN amount<0 THEN -amount ELSE 0 END),2) expense,"
            " ROUND(SUM(CASE WHEN amount>0 THEN amount ELSE 0 END),2) income"
            " FROM ledger_entries GROUP BY month ORDER BY month DESC").fetchall()]
    finally:
        conn.close()


class BudgetItem(BaseModel):
    category_id: int
    monthly: float = 0
    annual: float = 0


class BudgetBulk(BaseModel):
    year: int
    items: list[BudgetItem]


@router.put("/budgets/{year}")
def put_budgets(year: int, body: BudgetBulk):
    """批量维护某年各类别预算(月度/年度),upsert。"""
    conn = get_conn()
    try:
        for it in body.items:
            conn.execute(
                "INSERT INTO ledger_budgets(category_id,year,annual,monthly)"
                " VALUES(?,?,?,?) ON CONFLICT(category_id,year)"
                " DO UPDATE SET annual=excluded.annual, monthly=excluded.monthly",
                (it.category_id, year, it.annual, it.monthly))
        conn.commit()
        return {"year": year, "updated": len(body.items)}
    finally:
        conn.close()


class LedgerEntryIn(BaseModel):
    date: str
    payee: str = ""
    category: str
    amount: float  # 正数输入,存为负(支出)


@router.post("/entries", status_code=201)
def create_ledger_entry(body: LedgerEntryIn):
    validate_date(body.date)
    conn = get_conn()
    try:
        row = conn.execute("SELECT id FROM ledger_categories WHERE name=?",
                           (body.category,)).fetchone()
        cid = row["id"] if row else conn.execute(
            "INSERT INTO ledger_categories(name) VALUES(?)",
            (body.category,)).lastrowid
        cur = conn.execute(
            "INSERT INTO ledger_entries(date,payee,category_id,amount,source)"
            " VALUES(?,?,?,?, 'manual')",
            (body.date, body.payee, cid, -abs(body.amount)))
        conn.commit()
        return {"id": cur.lastrowid, "ok": True}
    finally:
        conn.close()


class NumbersImportIn(BaseModel):
    path: str = None
    year: int = None


@import_router.post("/numbers")
def run_numbers_import(body: NumbersImportIn = None):
    from services.numbers_import import import_numbers, DEFAULT_PATH
    path = (body.path if body and body.path else DEFAULT_PATH)
    year = body.year if body else None
    if not os.path.exists(path):
        raise HTTPException(400, f"numbers 文件不存在: {path}")
    conn = get_conn()
    try:
        return import_numbers(conn, path, year)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(502, f"导入失败: {e}")
    finally:
        conn.close()
