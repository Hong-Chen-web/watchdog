"""逐日净值曲线回归(2026-10-20 修复:旧实现追加"最新持仓 round_date + summary.assets"伪日期点,
与当日已有点重复 → 曲线末两点相同 → 「最近一日」恒 0.00%)。

跑法:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/python -m unittest tests.test_backtest_curve -v
(夹具全部为合成数据。)
"""
import sys
import unittest
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

from routers.backtest import _equity_curve  # noqa: E402


class EquityCurveTest(unittest.TestCase):
    def test_cumulative_by_sell_day(self):
        ledger = [
            {"round_date": "2026-10-09", "sell_date": "2026-10-13", "realized_net": 500},
            {"round_date": "2026-10-13", "sell_date": "2026-10-13", "realized_net": -200},
            {"round_date": "2026-10-15", "sell_date": "2026-10-19", "realized_net": -1300},
        ]
        curve = _equity_curve(ledger, 100000)
        self.assertEqual([p["date"] for p in curve], ["2026-10-13", "2026-10-19"])
        self.assertEqual([p["equity"] for p in curve], [100300, 99000])   # 累计口径

    def test_open_round_uses_buy_date_zero_net(self):
        ledger = [
            {"round_date": "2026-10-19", "sell_date": None, "realized_net": 0},
            {"round_date": "2026-10-15", "sell_date": "2026-10-19", "realized_net": 900},
        ]
        self.assertEqual(_equity_curve(ledger, 100000),
                         [{"date": "2026-10-19", "equity": 100900}])

    def test_empty_ledger(self):
        self.assertEqual(_equity_curve([], 100000), [])

    def test_no_duplicate_dates(self):
        ledger = [{"round_date": d, "sell_date": d, "realized_net": 1}
                  for d in ("2026-10-13", "2026-10-13", "2026-10-19")]
        dates = [p["date"] for p in _equity_curve(ledger, 100000)]
        self.assertEqual(dates, sorted(set(dates)))   # 同日并一点,绝不重复


if __name__ == "__main__":
    unittest.main(verbosity=2)
