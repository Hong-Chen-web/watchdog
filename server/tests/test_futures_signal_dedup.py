"""期货信号去重回归(2026-10-19 修复:同一 bar 信号跨天重复推送)。

背景:实盘发现同一 4h 信号(同一 bar 时间)在连续多日 00:0x 被重复投递 8+ 次——
旧去重键 (symbol, level, kind, today) 含日期且缺 (symbol, level, kind, bar_time) 键,
跨天后旧 bar 信号被判为"新"。修复:补 bar 键,同一 bar 信号永不重发;保留
"同品种同类当日一次"防轰炸语义。(夹具为合成行情数据。)

跑法:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/python -m unittest tests.test_futures_signal_dedup -v
"""
import sys
import types
import unittest
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

import services.futures_monitor as fm  # noqa: E402


class _FakeTime:
    """锚定在 today 的假时钟:strftime 无参时返回 today;time()/localtime() 也基于
    today(供 _prune_sig_seen 计算 cut),整套去重逻辑可完整复现到任意"天"。"""
    _real = fm.time
    today = "2026-10-19"

    @property
    def _now(self):
        from datetime import datetime as _dt
        return _dt.strptime(self.today, "%Y-%m-%d").timestamp()

    def strftime(self, fmt, tup=None):
        if tup is None:
            return self.today if fmt == "%Y-%m-%d" else self._real.strftime(fmt)
        return self._real.strftime(fmt, tup)

    def localtime(self, t=None):
        return self._real.localtime(self._now if t is None else t)

    def time(self):
        return self._now


class FuturesDedupTest(unittest.TestCase):

    def setUp(self):
        self.pushed = []
        fake_fp = types.ModuleType("services.feishu_push")
        fake_fp.ensure_push = lambda kind, title, body, dedup, **kw: self.pushed.append(
            {"kind": kind, "title": title, "dedup": dedup, **kw})
        fake_fp.kind_cn = lambda k: {"S1": "卖① 趋势背驰", "B1": "买① 趋势背驰"}.get(k, k)
        fake_fp.kind_dir = lambda k: "卖点" if k.startswith("S") else "买点"
        self._orig_fp = sys.modules.get("services.feishu_push")
        sys.modules["services.feishu_push"] = fake_fp

        import routers  # noqa: F401  (确保父包含在 sys.modules,便于注入子模块)
        self._orig_scope = sys.modules.get("routers.pushscope")
        fake_scope = types.ModuleType("routers.pushscope")
        fake_scope.future_in_scope = lambda s: True
        sys.modules["routers.pushscope"] = fake_scope

        self._saved_seen = dict(fm._SIG_SEEN)
        self._saved_primed = dict(fm._SIG_PRIMED)
        self._saved_time = fm.time
        self._saved_detect = fm._detect_signals
        fm._SIG_SEEN.clear()
        fm._SIG_PRIMED.clear()
        self.ft = _FakeTime()
        fm.time = self.ft
        self.marks = []
        fm._detect_signals = lambda symbol, c: list(self.marks)

    def tearDown(self):
        fm._detect_signals = self._saved_detect
        fm._SIG_SEEN.clear()
        fm._SIG_SEEN.update(self._saved_seen)
        fm._SIG_PRIMED.clear()
        fm._SIG_PRIMED.update(self._saved_primed)
        fm.time = self._saved_time
        if self._orig_fp is None:
            sys.modules.pop("services.feishu_push", None)
        else:
            sys.modules["services.feishu_push"] = self._orig_fp
        if self._orig_scope is None:
            sys.modules.pop("routers.pushscope", None)
        else:
            sys.modules["routers.pushscope"] = self._orig_scope

    def _push(self, level="4h"):
        return fm._push_futures_signals("C0", None, level=level)

    def test_cross_day_same_bar_never_repushed(self):
        """核心回归:10-14 的 bar 信号在 10-19/10-20 都不得再推(实盘 8 次重发)。"""
        self.marks = [("2026-10-14 11:15", 2360.0, "S1")]
        self._push()                                  # 首轮:静默建基线
        self.assertEqual(self.pushed, [])
        self._push()                                  # 同日再扫:静默
        self.assertEqual(self.pushed, [])
        self.ft.today = "2026-10-20"                  # 跨天:旧代码会重推(回归点)
        self.assertEqual(self._push(), [])
        self.assertEqual(self.pushed, [])
        self.ft.today = "2026-10-25"                  # 更远的另一天(裁剪期内)
        self._push()
        self.assertEqual(self.pushed, [])

    def test_new_signal_pushes_once_then_day_debounce(self):
        """首个新信号推一次(级别/标的全对);同日同类第二个 bar 防轰炸静默;原 bar 再扫静默。"""
        self.marks = []
        self._push()                                  # 基线(空)
        self.marks = [("2026-10-19 10:00", 5000.0, "S1")]
        r = self._push()                              # 新信号 → 推一次
        self.assertEqual(len(self.pushed), 1)
        p = self.pushed[0]
        self.assertIn("fsig:C0:4h:2026-10-19:S1:2026-10-19 10:00", p["dedup"])
        self.assertTrue(p["title"].endswith(" · 4小时"))
        self.assertEqual(p["code"], "C0")
        self.assertIn("4小时级 · 已确认 · 2026-10-19", p["footer"])
        self.assertEqual(len(r), 1)
        self.marks.append(("2026-10-19 14:30", 4980.0, "S1"))
        self._push()                                  # 同日同类第二个 bar → 当日防轰炸静默
        self.assertEqual(len(self.pushed), 1)
        self._push()                                  # 原 bar 再扫 → 静默
        self.assertEqual(len(self.pushed), 1)

    def test_new_day_new_bar_still_pushes(self):
        self.marks = [("2026-10-19 10:00", 5000.0, "S1")]
        self._push()                                  # 基线
        self.ft.today = "2026-10-20"
        self.marks = [("2026-10-20 09:30", 4900.0, "S1")]
        self._push()
        self.assertEqual(len(self.pushed), 1)         # 新的一天新 bar:正常推
        self.assertIn("2026-10-20", self.pushed[0]["dedup"])

    def test_5m_footer_tag_correct(self):
        self.marks = []
        self._push(level="5m")                        # 基线
        self.marks = [("2026-10-19 09:35", 100.0, "B1")]
        self._push(level="5m")
        self.assertEqual(len(self.pushed), 1)
        self.assertIn("5分钟级", self.pushed[0]["footer"])

    def test_prune_keeps_recent_drops_old(self):
        """裁剪:35 天前的键被清,3 天内的保留(锚定假时钟,确定性)。"""
        fm._SIG_SEEN.clear()
        fm._SIG_SEEN[("C0", "4h", "S1", "2026-09-14 11:15")] = True   # 假时钟 today=10-19 → 35 天前
        fm._SIG_SEEN[("C0", "4h", "S1", "2026-10-16 11:15")] = True   # 3 天前
        self.marks = []
        self._push()                                  # 触发裁剪(基线路径也走 prune)
        self.assertNotIn(("C0", "4h", "S1", "2026-09-14 11:15"), fm._SIG_SEEN)
        self.assertIn(("C0", "4h", "S1", "2026-10-16 11:15"), fm._SIG_SEEN)


if __name__ == "__main__":
    unittest.main(verbosity=2)
