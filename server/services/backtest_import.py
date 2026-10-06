"""回测报告 HTML 导入:解析 chan-monitor 生成的回测报告(对数曲线/年度节奏/月度资产/全部明细),
落 backtest_runs + backtest_yearly + backtest_curve(月度 93 点)+ backtest_trades(逐笔)。"""
import re
from pathlib import Path

DEFAULT_PATH = "/Users/chenhong/Desktop/回测报告_10万3成仓_2019_2026.html"

_NUM = re.compile(r"[-+]?[\d,]+\.?\d*")


def _cells(row_html):
    return [re.sub(r"<[^>]+>", "", c).strip()
            for c in re.findall(r"<td[^>]*>.*?</td>", row_html, re.S)]


def _num(s, default=None):
    m = _NUM.search(str(s).replace(",", ""))
    if not m:
        return default
    v = float(m.group().replace(",", ""))
    return v


def _wan_to_yuan(s):
    """'¥383.6万' → 3836000;'¥87,412' → 87412。"""
    s = str(s)
    v = _num(s)
    if v is None:
        return None
    return v * 10000 if "万" in s else v


def parse_backtest_html(path: str) -> dict:
    h = Path(path).read_text(encoding="utf-8")
    tables = re.findall(r"<table.*?</table>", h, re.S)
    if len(tables) < 3:
        raise ValueError(f"报告缺少表格(需 3 张,实际 {len(tables)})")

    kpi = {}
    for pat, key in [("总收益", "total_return"), ("胜率", "win_rate"),
                     ("盈亏比", "pl_ratio"), ("期末资产", "final_equity"),
                     ("最差", "worst_hit")]:
        m = re.search(pat + r"\s*</[^>]+>\s*<[^>]+>([-+\d.,%万¥]+)", h)
        if not m:
            m = re.search(pat + r"[^0-9\-+]{0,40}([-+\d.,%万¥]+)", h)
        if m:
            raw = m.group(1)
            if key == "final_equity":
                kpi[key] = _wan_to_yuan("¥" + raw) or _num(raw)
            elif key == "total_return":
                kpi[key] = _num(raw.rstrip("%"))
            elif key == "worst_hit":
                kpi[key] = -abs(_num(raw.rstrip("%")) or 0)
            else:
                kpi[key] = _num(raw)

    yearly = []
    for row in re.findall(r"<tr[^>]*>.*?</tr>", tables[0], re.S)[1:]:
        c = _cells(row)
        if len(c) >= 4 and _num(c[0]):
            yearly.append({"year": int(_num(c[0])),
                           "start": _wan_to_yuan(c[1]) or _num(c[1]),
                           "end": _wan_to_yuan(c[2]) or _num(c[2]),
                           "return_pct": _num(c[3].rstrip("%")),
                           "trades": int(_num(c[4]) or 0),
                           "wl": c[5] if len(c) > 5 else ""})

    monthly = []
    for row in re.findall(r"<tr[^>]*>.*?</tr>", tables[1], re.S)[1:]:
        c = _cells(row)
        if len(c) >= 2 and re.match(r"\d{4}-\d{2}", c[0]):
            monthly.append({"month": c[0],
                            "equity": _wan_to_yuan(c[1]) or _num(c[1])})

    trades = []
    for row in re.findall(r"<tr[^>]*>.*?</tr>", tables[2], re.S)[1:]:
        c = _cells(row)
        if len(c) < 14 or not _num(c[0]):
            continue
        trades.append({
            "seq": int(_num(c[0])), "buy_date": c[1], "sell_date": c[2],
            "name": c[3], "code": c[4],
            "buy_price": _num(c[5]), "sell_price": _num(c[6]),
            "shares": _num(c[7]),
            "pnl_pct": _num(c[8].rstrip("%")),
            "pnl_amount": _num(c[9]),
            "hold_txt": c[10], "exit_reason": c[11],
            "vol_shrink": c[12], "big_order": c[13],
        })
    if not trades:
        raise ValueError("明细表解析为空")
    return {"kpi": kpi, "yearly": yearly, "monthly": monthly, "trades": trades}


def import_backtest(conn, path: str = DEFAULT_PATH, label: str = None,
                    replace_run: int = None) -> dict:
    data = parse_backtest_html(path)
    kpi, trades = data["kpi"], data["trades"]
    label = label or Path(path).stem
    cur = conn.cursor()

    if replace_run:
        run_id = replace_run
        cur.execute("SELECT id FROM backtest_runs WHERE id=?", (run_id,))
        if not cur.fetchone():
            raise ValueError(f"run {run_id} 不存在")
    else:
        row = cur.execute("SELECT id FROM backtest_runs WHERE label=?",
                          (label,)).fetchone()
        run_id = row["id"] if row else cur.execute(
            "INSERT INTO backtest_runs(label) VALUES(?)", (label,)).lastrowid

    sets, args = [], []
    for col, key in [("final_equity", "final_equity"), ("total_return", "total_return"),
                     ("trades", None), ("win_rate", "win_rate"),
                     ("pl_ratio", "pl_ratio"), ("worst_hit", "worst_hit")]:
        if key and kpi.get(key) is not None:
            sets.append(f"{col}=?"); args.append(kpi[key])
    sets.append("trades=?"); args.append(len(trades))
    args.append(run_id)
    cur.execute(f"UPDATE backtest_runs SET {', '.join(sets)} WHERE id=?", args)

    cur.execute("DELETE FROM backtest_yearly WHERE run_id=?", (run_id,))
    cur.executemany(
        "INSERT INTO backtest_yearly(run_id,year,return_pct) VALUES(?,?,?)",
        [(run_id, y["year"], y["return_pct"]) for y in data["yearly"]])

    cur.execute("DELETE FROM backtest_curve WHERE run_id=?", (run_id,))
    cur.executemany(
        "INSERT INTO backtest_curve(run_id,seq,date,equity) VALUES(?,?,?,?)",
        [(run_id, i, m["month"], m["equity"])
         for i, m in enumerate(data["monthly"])])

    cur.execute("DELETE FROM backtest_trades WHERE run_id=?", (run_id,))
    cur.executemany(
        "INSERT INTO backtest_trades(run_id,seq,buy_date,sell_date,name,code,"
        "buy_price,sell_price,shares,pnl_pct,pnl_amount,hold_txt,exit_reason,"
        "vol_shrink,big_order) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [(run_id, t["seq"], t["buy_date"], t["sell_date"], t["name"], t["code"],
          t["buy_price"], t["sell_price"], t["shares"], t["pnl_pct"],
          t["pnl_amount"], t["hold_txt"], t["exit_reason"], t["vol_shrink"],
          t["big_order"]) for t in trades])

    cur.execute("INSERT INTO sync_log(source,status,message) VALUES(?,?,?)",
                ("backtest", "ok",
                 f"run={run_id} trades={len(trades)} monthly={len(data['monthly'])}"))
    conn.commit()
    return {"run_id": run_id, "label": label, "trades": len(trades),
            "monthly_points": len(data["monthly"]), "yearly": len(data["yearly"]),
            "kpi": kpi}
