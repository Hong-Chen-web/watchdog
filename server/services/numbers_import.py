"""Numbers 账本导入(numbers-parser 直读 .numbers,无需 GUI)。
实测结构:sheet「2026年支出」表「交易」= 日期/描述/类别/总额(340 行,含分月标题行);
sheet「2026预算」表「摘要(按类别)」= 类别/总年预算/单月预算/实际支出/差额。
幂等键:sha1(date|payee|amount|category)。"""
import hashlib
import warnings
from datetime import date, datetime

warnings.filterwarnings("ignore")

DEFAULT_PATH = ("/Users/chenhong/Library/Mobile Documents/com~apple~Numbers/"
                "Documents/支出统计支出预算.numbers")

COL_MAP = {  # 表头模糊映射
    "date":   ["日期", "时间", "date"],
    "payee":  ["描述", "商户", "备注", "payee"],
    "cat":    ["类别", "分类", "category"],
    "amount": ["总额", "金额", "数量", "amount"],
    "budget_cat":   ["类别", "category"],
    "budget_annual": ["总年预算", "年度预算"],
    "budget_month":  ["单月预算", "月度预算"],
}


def _match(header: str, keys) -> bool:
    h = str(header or "").strip()
    return any(k in h for k in keys)


def _norm_date(v):
    if isinstance(v, datetime):
        return v.date().isoformat()
    if isinstance(v, date):
        return v.isoformat()
    s = str(v or "").strip()
    return s[:10] if len(s) >= 10 else None


def import_numbers(conn, path: str = DEFAULT_PATH, year: int = None):
    from numbers_parser import Document
    year = year or date.today().year
    doc = Document(path)

    tx_table = budget_table = None
    goal_tables = []  # (scope, table):表头=事项/建立日期/回顾日期/目标/结果
    for sheet in doc.sheets:
        for tb in sheet.tables:
            hdr = [c.value for c in next(tb.iter_rows())]
            if _match(hdr[0] if hdr else "", COL_MAP["date"]) and any(
                    _match(h, COL_MAP["cat"]) for h in hdr):
                tx_table = tb
            elif any(_match(h, COL_MAP["budget_annual"]) for h in hdr):
                budget_table = tb
            elif hdr and _match(hdr[0], ["事项", "目标项"]) and any(
                    _match(h, ["回顾日期"]) for h in hdr):
                goal_tables.append(("long" if "长期" in sheet.name else "year", tb))
    if tx_table is None:
        raise ValueError("未找到交易表(表头需含 日期+类别)")

    cur = conn.cursor()
    report = {"categories_new": 0, "entries_imported": 0, "entries_skipped": 0,
              "budgets_upserted": 0, "unmatched_categories": [], "rows_invalid": 0}

    def cat_id(name):
        name = str(name or "").strip()
        if not name or name in ("总计", "合计", "Total", "total", "Sum"):
            return None
        row = cur.execute(
            "SELECT id FROM ledger_categories WHERE name=?", (name,)).fetchone()
        if row:
            return row["id"]
        cur.execute("INSERT INTO ledger_categories(name) VALUES(?)", (name,))
        report["categories_new"] += 1
        return cur.lastrowid

    # ---- 预算表 ----
    if budget_table is not None:
        for row in list(budget_table.iter_rows())[budget_table.num_header_rows:]:
            v = [c.value for c in row]
            if not v or not v[0]:
                continue
            cid = cat_id(v[0])
            if cid is None:  # 总计/合计行
                continue
            annual = float(v[1] or 0)
            monthly = float(v[2] or 0)
            cur.execute(
                "INSERT INTO ledger_budgets(category_id,year,annual,monthly)"
                " VALUES(?,?,?,?) ON CONFLICT(category_id,year)"
                " DO UPDATE SET annual=excluded.annual, monthly=excluded.monthly",
                (cid, year, annual, monthly))
            report["budgets_upserted"] += 1

    # ---- 交易表 ----
    for row in list(tx_table.iter_rows())[tx_table.num_header_rows:]:
        v = [c.value for c in row]
        if len(v) < 4:
            continue
        d = _norm_date(v[0])
        if not d:  # 分月标题行等无日期行
            report["rows_invalid"] += 1
            continue
        try:
            amount = -abs(float(v[3] or 0))  # Numbers 支出为正 → 存负数
        except (TypeError, ValueError):
            report["rows_invalid"] += 1
            continue
        payee = str(v[1] or "").strip()
        cat_name = str(v[2] or "").strip()
        cid = cat_id(cat_name)
        if cid is None:
            report["rows_invalid"] += 1
            continue
        ext = hashlib.sha1(
            f"{d}|{payee}|{amount}|{cat_name}".encode()).hexdigest()
        cur.execute(
            "INSERT OR IGNORE INTO ledger_entries"
            "(date,payee,category_id,amount,source,external_id)"
            " VALUES(?,?,?,?, 'numbers', ?)",
            (d, payee, cid, amount, ext))
        if cur.rowcount:
            report["entries_imported"] += 1
        else:
            report["entries_skipped"] += 1

    cur.execute("INSERT INTO sync_log(source,status,message) VALUES(?,?,?)",
                ("numbers", "ok",
                 f"imported={report['entries_imported']} skipped={report['entries_skipped']}"))

    # ---- 目标表(年度/长期,全删重导保持与 Numbers 同步) ----
    report["goals"] = 0
    if goal_tables:
        cur.execute("DELETE FROM goals WHERE source='numbers'")
        for scope, tb in goal_tables:
            for row in list(tb.iter_rows())[tb.num_header_rows:]:
                v = [c.value for c in row]
                if not v or not v[0]:
                    continue
                cur.execute(
                    "INSERT INTO goals(scope,title,start_date,review_date,detail,result,source)"
                    " VALUES(?,?,?,?,?,?,'numbers')",
                    (scope, str(v[0]).strip(), _norm_date(v[1]), _norm_date(v[2]),
                     str(v[3] or "").strip() or None, str(v[4] or "").strip() or None))
                report["goals"] += 1

    conn.commit()
    return report
