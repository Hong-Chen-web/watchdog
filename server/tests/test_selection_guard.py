"""选股/结算的“当日行情必须存在”防线。

2026-10-21 事故:断网时当日快照失败,日K只到昨天——
· 结算把昨天当今天:第 3/3 日应卖出被算成“第 2/3 日持有”;
· 选股拿昨收当现价入榜,推出去的选股卡整张是旧数据。
本测试锁死:缺当日K线时结算记 failed(不改任何持仓状态),选股直接中止。

跑法:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/python -m unittest tests.test_selection_guard -v
"""
import json
import sys
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path
from unittest import mock

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

from services import selection as sel  # noqa: E402


class SettleStaleBarTest(unittest.TestCase):
    def test_stale_bar_does_not_touch_position(self):
        today = date.today()
        buy_day = (today - timedelta(days=2)).strftime("%Y-%m-%d")
        bars = [
            {"date": (today - timedelta(days=3)).strftime("%Y-%m-%d"), "close": 5.1},
            {"date": (today - timedelta(days=1)).strftime("%Y-%m-%d"), "close": 5.0},
        ]
        hist = {"rounds": [{"date": buy_day, "stocks": [
            {"code": "sz.002480", "name": "合成股份", "buy_price": 5.0}]}]}
        path = Path(tempfile.mktemp(prefix="wd_hist_", suffix=".json"))
        path.write_text(json.dumps(hist), encoding="utf-8")
        try:
            with mock.patch.object(sel, "HIST", path), \
                 mock.patch.object(sel, "_require_today_bar", return_value=True), \
                 mock.patch.object(sel, "tencent_daily", return_value=bars), \
                 mock.patch.object(sel, "_cooldown_map", return_value={}):
                r = sel.settle_all()
            self.assertEqual(r["settled"], [])
            self.assertTrue(any("当日行情缺失" in x for x in r["failed"]),
                            f"缺当日K线必须记 failed,实际 {r}")
            st = json.loads(path.read_text())["rounds"][0]["stocks"][0]
            self.assertNotIn("_exit_why", st)
            self.assertNotIn("_hold_note", st, "不得把昨天当今天写『第N/3日持有』")
        finally:
            path.unlink(missing_ok=True)

    def test_fresh_bar_still_evaluates(self):
        """当日K线在 → 防线不误伤(再走原有评估分支)。"""
        today = date.today().strftime("%Y-%m-%d")
        buy_day = (date.today() - timedelta(days=2)).strftime("%Y-%m-%d")
        bars = [
            {"date": (date.today() - timedelta(days=1)).strftime("%Y-%m-%d"), "close": 5.0},
            {"date": today, "close": 5.05, "high": 5.1, "low": 4.95},
        ]
        hist = {"rounds": [{"date": buy_day, "stocks": [
            {"code": "sz.002480", "name": "合成股份", "buy_price": 5.0}]}]}
        path = Path(tempfile.mktemp(prefix="wd_hist_ok_", suffix=".json"))
        path.write_text(json.dumps(hist), encoding="utf-8")
        # 只验证“不因 stale 被拦”:评估会走 hold/exit 分支,隔离文件与副作用
        with mock.patch.object(sel, "HIST", path), \
             mock.patch.object(sel, "COOLDOWN", path.with_suffix(".cool.json")), \
             mock.patch.object(sel, "_require_today_bar", return_value=True), \
             mock.patch.object(sel, "tencent_daily", return_value=bars), \
             mock.patch.object(sel, "_cooldown_map", return_value={}), \
             mock.patch("services.chan_backtest_mirror.sync_chan_backtest"):
            try:
                r = sel.settle_all()
            except Exception as e:  # 台账镜像等副作用失败不影响断言
                self.fail(f"当日K线存在时不应抛异常: {e}")
        self.assertEqual(r["failed"], [], "当日K线存在不得记 failed")
        st = json.loads(path.read_text())["rounds"][0]["stocks"][0] if path.exists() else {}
        self.assertTrue(st.get("_hold_note") or st.get("_exit_why"),
                        "应当完成评估(写持有说明或出场)")
        for p in (path, path.with_suffix(".cool.json")):
            p.unlink(missing_ok=True)


class SelectionStaleGuardTest(unittest.TestCase):
    def test_empty_snapshot_aborts(self):
        with mock.patch.object(sel, "universe", return_value=[("600000", "浦发银行")]), \
             mock.patch.object(sel, "_require_today_bar", return_value=True), \
             mock.patch("services.kline_store.snapshot_today_bars", return_value={}):
            with self.assertRaises(RuntimeError) as ctx:
                sel.run_selection(archive=False)
        self.assertIn("当日行情", str(ctx.exception))

    def test_stale_candidates_abort(self):
        """快照有值但每只票的日K都停在昨天 → 不许拿昨收入榜。"""
        bars = [{"date": (date.today() - timedelta(days=1)).strftime("%Y-%m-%d"),
                 "close": 5.0}]
        with mock.patch.object(sel, "universe", return_value=[("600000", "浦发银行")]), \
             mock.patch.object(sel, "_require_today_bar", return_value=True), \
             mock.patch("services.kline_store.snapshot_today_bars",
                        return_value={"600000": {"date": date.today().strftime("%Y-%m-%d"),
                                                 "close": 5.0}}), \
             mock.patch.object(sel, "tencent_daily", return_value=bars):
            with self.assertRaises(RuntimeError) as ctx:
                sel.run_selection(archive=False)
        self.assertIn("当日行情", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
