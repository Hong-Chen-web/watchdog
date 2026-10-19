"""发件箱定向投递回归(2026-10-19 修复:通道订阅过滤 _targets / flush 路由)。

背景:此前 _targets() 无条件全量返回所有通道(注释"全员广播"),导致期货信号
也会投到只订阅了个股 webhook 的专线。现在:feishu.codes 为空=全员广播;
非空=只投 code 命中的订阅通道;无 code 的账户级卡(卖出/选股/持仓/买入)进
全员广播通道 + 勾了 account_cards 的专线。
(夹具全部为合成数据:虚构通道名/代码/example.invalid webhook。)

跑法:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/python -m unittest tests.test_push_routing -v
"""
import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

import services.feishu_push as fp  # noqa: E402

MIG_DIR = SERVER_ROOT / "migrations"

# 合成夹具:专线A 订阅 2 只、专线B 订阅 1 只、全员广播 0 只(=收全部)
FEISHU_ROWS = [
    ("b1", "bot", "订阅专线A", "https://example.invalid/h1",
     json.dumps(["sh.600001", "sz.000002"])),
    ("b2", "bot", "订阅专线B", "https://example.invalid/h2",
     json.dumps(["sh.600003"])),
    ("n1", "bot", "全员广播", "https://example.invalid/h3", "[]"),
]


def _mk_db(with_outbox: bool = False) -> str:
    path = tempfile.mktemp(prefix="wd_test_", suffix=".db")
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE feishu(
        id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('bot','notify')),
        name TEXT NOT NULL, webhook TEXT NOT NULL,
        codes TEXT NOT NULL DEFAULT '[]',
        account_cards INTEGER NOT NULL DEFAULT 0)""")
    conn.executemany("INSERT INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
                     FEISHU_ROWS)
    if with_outbox:
        for f in ("017_push_outbox.sql", "024_push_outbox_backoff.sql",
                  "025_push_outbox_code.sql"):
            conn.executescript((MIG_DIR / f).read_text(encoding="utf-8"))
        conn.execute("CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)")
    conn.commit()
    conn.close()
    return path


class _DbSwapMixin:
    db_path = None

    @classmethod
    def _swap_db(cls, path: str):
        def connect():
            c = sqlite3.connect(path)
            c.row_factory = sqlite3.Row
            return c
        cls._orig_dbm = fp.dbm
        fp.dbm = types.SimpleNamespace(connect=connect, DB_PATH=path)

    @classmethod
    def _restore_db(cls):
        fp.dbm = cls._orig_dbm
        if cls.db_path and os.path.exists(cls.db_path):
            os.unlink(cls.db_path)


class TargetFilterTest(_DbSwapMixin, unittest.TestCase):
    """_targets() 订阅过滤纯逻辑。"""

    @classmethod
    def setUpClass(cls):
        cls.db_path = _mk_db()
        cls._swap_db(cls.db_path)

    @classmethod
    def tearDownClass(cls):
        cls._restore_db()

    def _ids(self, kind, code=None):
        return [t["id"] for t in fp._targets(kind, code)]

    def test_norm_code(self):
        self.assertEqual(fp._norm_code("sh.600001"), "600001")
        self.assertEqual(fp._norm_code("600001"), "600001")
        self.assertEqual(fp._norm_code("sz.000002"), "000002")
        self.assertEqual(fp._norm_code("C0"), "c0")
        self.assertEqual(fp._norm_code(None), "")

    def test_futures_only_broadcast(self):
        # 玉米 C0 不匹配任何订阅 → 只投全员广播(修复前:三通道全投)
        self.assertEqual(self._ids("signal", "C0"), ["n1"])

    def test_subscribed_stock_hits_owner_and_broadcast(self):
        self.assertEqual(self._ids("signal", "600001"), ["b1", "n1"])
        self.assertEqual(self._ids("signal", "sh.600001"), ["b1", "n1"])
        self.assertEqual(self._ids("signal", "600003"), ["b2", "n1"])
        self.assertEqual(self._ids("signal", "sz.000002"), ["b1", "n1"])

    def test_account_cards_broadcast_only(self):
        for kind in ("settle", "selection", "plan", "holding_daily", "test"):
            self.assertEqual(self._ids(kind), ["n1"], kind)

    def test_account_cards_flag_extends_to_dedicated(self):
        # b1 勾「同时接收账户卡」→ 账户卡进 b1+广播;b2 未勾 → 只进广播;信号定向逻辑不变
        conn = fp.dbm.connect()
        conn.execute("UPDATE feishu SET account_cards=1 WHERE id='b1'")
        conn.commit()
        conn.close()
        try:
            for kind in ("settle", "selection", "plan", "holding_daily"):
                self.assertEqual(self._ids(kind), ["b1", "n1"], kind)
            self.assertEqual(self._ids("signal", "600003"), ["b2", "n1"])   # 未勾通道信号路由不变
            self.assertEqual(self._ids("signal", "600001"), ["b1", "n1"])   # 勾了也只收命中订阅的信号
            self.assertEqual(self._ids("signal", "688888"), ["n1"])         # 非订阅信号不进 b1
        finally:
            conn = fp.dbm.connect()
            conn.execute("UPDATE feishu SET account_cards=0 WHERE id='b1'")
            conn.commit()
            conn.close()

    def test_unmatched_code_still_broadcast(self):
        self.assertEqual(self._ids("signal", "999999"), ["n1"])

    def test_bad_codes_json_treated_as_broadcast(self):
        path = tempfile.mktemp(prefix="wd_bad_", suffix=".db")
        conn = sqlite3.connect(path)
        conn.execute("CREATE TABLE feishu(id TEXT PRIMARY KEY, kind TEXT, name TEXT,"
                     " webhook TEXT, codes TEXT DEFAULT '[]',"
                     " account_cards INTEGER NOT NULL DEFAULT 0)")
        conn.execute("INSERT INTO feishu(id,kind,name,webhook,codes)"
                     " VALUES('x','bot','坏配置','https://e.invalid/x','not-json')")
        conn.commit()
        conn.close()
        orig = fp.dbm

        def connect():
            c = sqlite3.connect(path)
            c.row_factory = sqlite3.Row
            return c

        try:
            fp.dbm = types.SimpleNamespace(connect=connect, DB_PATH=path)
            self.assertEqual([t["id"] for t in fp._targets("signal", "600001")], ["x"])
        finally:
            fp.dbm = orig
            os.unlink(path)


class FlushRoutingTest(_DbSwapMixin, unittest.TestCase):
    """ensure_push(code) → flush_once():按订阅只投命中通道(_send_webhook 打桩)。"""

    @classmethod
    def setUpClass(cls):
        cls.db_path = _mk_db(with_outbox=True)
        cls._swap_db(cls.db_path)

    def setUp(self):
        self.sent = []
        self._orig_send = fp._send_webhook
        fp._send_webhook = lambda webhook, kind, title, body: self.sent.append(
            (webhook, kind, title))

    def tearDown(self):
        fp._send_webhook = self._orig_send
        conn = fp.dbm.connect()
        conn.execute("DELETE FROM push_outbox")
        conn.execute("DELETE FROM push_delivery")
        conn.commit()
        conn.close()

    def _status(self, dedup):
        conn = fp.dbm.connect()
        row = conn.execute("SELECT status,last_error FROM push_outbox WHERE dedup_key=?",
                           (dedup,)).fetchone()
        conn.close()
        return dict(row) if row else None

    def _targets_of(self, dedup):
        conn = fp.dbm.connect()
        rows = conn.execute("""SELECT target FROM push_delivery
            WHERE outbox_id=(SELECT id FROM push_outbox WHERE dedup_key=?)""",
                            (dedup,)).fetchall()
        conn.close()
        return sorted(r["target"] for r in rows)

    def test_coded_message_routes_subscription_only(self):
        fp.ensure_push("signal", "期货卡", "", "t-fut", code="C0")
        fp.flush_once()
        self.assertEqual(self._status("t-fut")["status"], "sent")
        self.assertEqual(self._targets_of("t-fut"), ["n1"])

    def test_stock_message_routes_owner_plus_broadcast(self):
        fp.ensure_push("signal", "股票卡", "", "t-stk", code="600001")
        fp.flush_once()
        self.assertEqual(self._targets_of("t-stk"), ["b1", "n1"])

    def test_account_card_broadcast_only(self):
        fp.ensure_push("settle", "卖出卡", "", "t-settle")
        fp.flush_once()
        self.assertEqual(self._targets_of("t-settle"), ["n1"])

    def test_account_card_routes_to_flagged_channel(self):
        conn = fp.dbm.connect()
        conn.execute("UPDATE feishu SET account_cards=1 WHERE id='b2'")
        conn.commit()
        conn.close()
        try:
            fp.ensure_push("selection", "选股卡", "", "t-sel2")
            fp.flush_once()
            self.assertEqual(self._targets_of("t-sel2"), ["b2", "n1"])
            self.assertEqual(self._status("t-sel2")["status"], "sent")
        finally:
            conn = fp.dbm.connect()
            conn.execute("UPDATE feishu SET account_cards=0 WHERE id='b2'")
            conn.commit()
            conn.close()

    def test_partial_failure_retries_and_marks_failed_target(self):
        calls = []

        def flaky(webhook, kind, title, body):
            calls.append(webhook)
            if webhook.endswith("h1"):   # 订阅通道 b1 挂
                raise RuntimeError("boom")
        fp._send_webhook = flaky
        fp.ensure_push("signal", "股票卡2", "", "t-stk2", code="600001")
        fp.flush_once()
        st = self._status("t-stk2")
        self.assertEqual(st["status"], "pending")         # b1 失败 → 整体待重试
        self.assertEqual(self._targets_of("t-stk2"), ["b1", "n1"])
        conn = fp.dbm.connect()
        row = conn.execute("""SELECT ok FROM push_delivery WHERE outbox_id=
            (SELECT id FROM push_outbox WHERE dedup_key='t-stk2') AND target='b1'""").fetchone()
        conn.close()
        self.assertEqual(row["ok"], 0)

    def test_no_matching_channel_marks_skipped(self):
        conn = fp.dbm.connect()
        conn.execute("DELETE FROM feishu WHERE id='n1'")   # 只剩订阅通道
        conn.commit()
        conn.close()
        try:
            fp.ensure_push("signal", "期货卡2", "", "t-fut2", code="C0")
            fp.flush_once()
            st = self._status("t-fut2")
            self.assertEqual(st["status"], "skipped")
            self.assertIn("订阅过滤", st["last_error"])
        finally:
            conn = fp.dbm.connect()
            conn.execute("INSERT INTO feishu(id,kind,name,webhook,codes) VALUES(?,?,?,?,?)",
                         FEISHU_ROWS[2])
            conn.commit()
            conn.close()

    def test_webhook_19001_marks_permanent_silent(self):
        def bad(webhook, kind, title, body):
            if webhook.endswith("h1"):
                raise RuntimeError("feishu code=19001 token invalid")
        fp._send_webhook = bad
        fp.ensure_push("signal", "股票卡3", "", "t-stk3", code="600001")
        fp.flush_once()
        self.assertEqual(self._status("t-stk3")["status"], "sent")   # 19001 静默,不阻塞
        conn = fp.dbm.connect()
        row = conn.execute("""SELECT ok FROM push_delivery WHERE outbox_id=
            (SELECT id FROM push_outbox WHERE dedup_key='t-stk3') AND target='b1'""").fetchone()
        conn.close()
        self.assertEqual(row["ok"], 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
