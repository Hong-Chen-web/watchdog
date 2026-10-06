"""账本模块接口:/api/ledger(ledger_* 三表)+ /api/import/numbers(Numbers 导入管线)。"""
import os
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from .common import get_conn, validate_date

router = APIRouter(prefix="/api/ledger", tags=["ledger"])
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


@router.get("/annual")
def ledger_annual(year: int = None):
    """年度财务分析:总览/月度趋势/分类结构/异常账单/改进建议/下年度基线。"""
    from datetime import date
    year = year or date.today().year
    conn = get_conn()
    try:
        rows = conn.execute(
            "SELECT e.date, e.payee, e.amount, c.name cat FROM ledger_entries e"
            " JOIN ledger_categories c ON c.id=e.category_id"
            " WHERE e.date BETWEEN ? AND ? ORDER BY e.date",
            (f"{year}-01-01", f"{year}-12-31")).fetchall()
    finally:
        conn.close()
    expenses = [r for r in rows if r["amount"] < 0]
    incomes = [-r["amount"] for r in rows if r["amount"] > 0]
    total_out = -sum(r["amount"] for r in expenses)
    total_in = sum(incomes)

    by_month = {}
    for r in expenses:
        m = r["date"][5:7]
        by_month[m] = by_month.get(m, 0) + (-r["amount"])
    months = [{"month": k, "expense": round(v, 2)} for k, v in sorted(by_month.items())]
    avg_m = total_out / 12

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
         "amount": -r["amount"], "why": f"单笔为全年均笔({avg_item:.0f})的 {(-r['amount'])/avg_item:.0f} 倍"}
        for r in expenses if avg_item > 0 and -r["amount"] > avg_item * 3]
    anomalies += [
        {"date": f"{year}-{m['month']}", "payee": "整月", "cat": "-",
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
            tips.append(f"{top['cat']} 占支出 {top['pct']}%,压缩 10% 可省 {top['total']*0.1:.0f} 元/年")
    big_anom = [a for a in anomalies if a["payee"] != "整月"]
    if big_anom:
        tips.append(f"有 {len(big_anom)} 笔异常大额,合计 {-sum(a['amount'] for a in big_anom):.0f} 元,建议逐笔复盘必要性")
    hf = [a for a in anomalies if "高频" in a["why"]]
    if hf:
        tips.append(f"『{hf[0]['payee']}』全年 {hf[0]['amount']:.0f} 元/{hf[0]['why'].split()[0]},设月度上限更可控")
    save_rate = (total_in - total_out) / total_in * 100 if total_in else 0
    tips.append(f"今年结余率 {save_rate:.0f}%;" + ("建议下年提到 20% 以上" if save_rate < 20 else "保持"))
    plan = {c["cat"]: round(c["total"] / 12 * 1.05, 0) for c in cats}   # 基线=月均×1.05

    return {"year": year, "entries": len(rows),
            "total_in": round(total_in, 2), "total_out": round(total_out, 2),
            "net": round(total_in - total_out, 2), "avg_month": round(avg_m, 2),
            "max_item": round(max(amounts), 2) if amounts else 0,
            "save_rate": round(save_rate, 1),
            "months": months, "cats": cats,
            "anomalies": anomalies[:10], "tips": tips, "next_year_plan": plan}


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
