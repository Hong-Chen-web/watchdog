"""迁移完整性回归:全新空库按序执行 migrations/NNN_*.sql。

校验:user_version == 最大迁移号(全部按序应用);关键表/列到位
(v24 退避 / v25 code / v26 account_cards);重复执行幂等。
(用临时空库,不触碰真实 workbench.db。)

跑法:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/python -m unittest tests.test_migrations -v
"""
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

import db as dbm  # noqa: E402

MIG_DIR = SERVER_ROOT / "migrations"
MAX_N = max(int(f.name[:3]) for f in MIG_DIR.glob("[0-9][0-9][0-9]_*.sql"))


class MigrationIntegrityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = tempfile.mktemp(prefix="wd_mig_", suffix=".db")
        conn = sqlite3.connect(cls.path)
        try:
            cls.ver = dbm.migrate(conn)
        finally:
            conn.close()

    @classmethod
    def tearDownClass(cls):
        if os.path.exists(cls.path):
            os.unlink(cls.path)

    def _conn(self):
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def test_all_migrations_applied_in_order(self):
        self.assertEqual(self.ver, MAX_N)
        conn = self._conn()
        try:
            self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], MAX_N)
        finally:
            conn.close()

    def test_rerun_is_idempotent(self):
        conn = self._conn()
        try:
            self.assertEqual(dbm.migrate(conn), MAX_N)
        finally:
            conn.close()

    def test_key_tables_and_columns(self):
        conn = self._conn()
        try:
            tbls = {r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            for t in ("feishu", "push_outbox", "push_delivery", "settings",
                      "watchlist", "todos", "ledger_entries", "food_entries"):
                self.assertIn(t, tbls, t)

            def cols(table):
                return {r["name"]: r for r in conn.execute(f"PRAGMA table_info({table})")}

            f = cols("feishu")
            self.assertIn("account_cards", f)                 # v26
            self.assertTrue(f["account_cards"]["notnull"])
            self.assertEqual(f["account_cards"]["dflt_value"], "0")
            p = cols("push_outbox")
            for c in ("retries", "next_try_at",        # v24 退避
                      "code"):                          # v25 定向投递
                self.assertIn(c, p, c)
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
