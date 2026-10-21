"""健康页 /api/food 回归:饮食明细 CRUD + 热量目标推荐 + AI 拆条目降级。

纯函数(推荐公式/餐次归档/条目清洗)直接测;CRUD 用临时空库跑完全部迁移后
打桩 routers.food.get_conn,不触碰真实 workbench.db;AI 调用打桩,不出网。
夹具全部为合成数据。

跑法:cd server && /Users/chenhong/github/czsc-repo/.venv/bin/python -m unittest tests.test_food -v
"""
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

SERVER_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER_ROOT))

import db as dbm  # noqa: E402
from fastapi import HTTPException  # noqa: E402

from routers import food  # noqa: E402


class TmpDBTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = tempfile.mktemp(prefix="wd_food_", suffix=".db")
        conn = sqlite3.connect(cls.path)
        try:
            dbm.migrate(conn)
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

    def setUp(self):
        conn = self._conn()
        try:
            conn.execute("DELETE FROM food_entries")
            conn.execute("DELETE FROM settings WHERE key='health_profile'")
            conn.commit()
        finally:
            conn.close()
        # 打桩:router 内的 get_conn 指向临时库
        self._patcher = mock.patch("routers.food.get_conn", side_effect=self._conn)
        self._patcher.start()

    def tearDown(self):
        self._patcher.stop()


class PureFunctionsTest(unittest.TestCase):
    def test_recommended_male_sedentary(self):
        # 男 175/80/30 久坐: BMR=1748.75 TDEE=2098.5 缺口0.5kg×1100=550 → 1548.5 → 1550
        self.assertEqual(food._recommended(
            {"height_cm": 175, "weight_kg": 80, "age": 30, "sex": "男", "activity": "久坐"}), 1550)

    def test_recommended_female_floor(self):
        # 女 160/55/28 轻度: BMR=1249 TDEE=1717.4 -500=1217.4 → floor 1200 生效与否看数值
        r = food._recommended({"height_cm": 160, "weight_kg": 55, "age": 28, "sex": "女",
                               "activity": "轻度活动"})
        self.assertGreaterEqual(r, 1200)
        self.assertEqual(r % 10, 0)

    def test_recommended_incomplete_profile_returns_none(self):
        self.assertIsNone(food._recommended({"height_cm": 175}))
        self.assertIsNone(food._recommended({"height_cm": 999, "weight_kg": 80, "age": 30,
                                             "sex": "男"}))

    def test_weekly_loss_goal_variants(self):
        p = {"height_cm": 175, "weight_kg": 80, "age": 30, "sex": "男", "activity": "久坐"}
        self.assertEqual(food._recommended(dict(p, weekly_loss=0)), 2100)      # 维持 = TDEE
        self.assertEqual(food._recommended(dict(p, weekly_loss=0.25)), 1820)   # 温和
        self.assertEqual(food._recommended(dict(p, weekly_loss=0.5)), 1550)    # 标准(缺省同)
        self.assertEqual(food._recommended(dict(p, weekly_loss=0.75)), 1500)   # 触底保护
        self.assertEqual(food._recommended(dict(p, weekly_loss=2)), 1500)      # 越界收敛到 1kg/周

    def test_breakdown_mode(self):
        bd = food._recommended({"height_cm": 175, "weight_kg": 80, "age": 30, "sex": "男",
                                "activity": "久坐", "weekly_loss": 0.5}, breakdown=True)
        self.assertEqual(bd["recommended"], 1550)
        self.assertEqual(bd["bmr"], 1749)          # 800+1093.75-150+5
        self.assertEqual(bd["tdee"], 2098)         # 1748.75×1.2(round-half-even)
        self.assertEqual(bd["deficit"], 550)       # 0.5kg × 1100
        self.assertFalse(bd["floored"])

    def test_meal_auto_by_hour(self):
        self.assertEqual(food._meal_auto(datetime(2026, 10, 20, 8, 0)), "早餐")
        self.assertEqual(food._meal_auto(datetime(2026, 10, 20, 12, 0)), "午餐")
        self.assertEqual(food._meal_auto(datetime(2026, 10, 20, 19, 0)), "晚餐")
        self.assertEqual(food._meal_auto(datetime(2026, 10, 20, 23, 30)), "加餐")

    def test_clean_items_sanitize(self):
        out = food._clean_items([{"food": "米饭", "portion": "1碗", "kcal": 230},
                                 {"food": "x" * 100, "kcal": 99999},
                                 {"food": "", "kcal": 5},
                                 {"kcal": 5},
                                 {"food": "炸鸡", "kcal": "abc"},
                                 "not-a-dict"])
        self.assertEqual(len(out), 3)
        self.assertEqual(out[0]["kcal"], 230)
        self.assertEqual(len(out[1]["food"]), 60)      # 截断
        self.assertEqual(out[1]["kcal"], 5000)         # 限幅
        self.assertIsNone(out[2]["kcal"])              # 非数字 → 未估


class FoodCrudTest(TmpDBTestCase):
    def test_overview_empty_defaults(self):
        o = food.food_overview()
        self.assertEqual(o["target"], 2000)
        self.assertEqual(o["entries"], [])
        self.assertEqual(o["total"], 0)
        self.assertEqual(len(o["days"]), 7)
        self.assertIsNone(o["recommended"])

    def test_manual_add_patch_delete(self):
        r = food.food_add({"food": "米饭", "portion": "1碗", "kcal": 230, "meal": "午餐"})
        self.assertTrue(r["ok"])
        fid = r["items"][0]["id"]
        o = food.food_overview()
        self.assertEqual(len(o["entries"]), 1)
        self.assertEqual(o["entries"][0]["food"], "米饭")
        self.assertEqual(o["total"], 230)
        food.food_patch(fid, {"kcal": 300})
        self.assertEqual(food.food_overview()["total"], 300)
        food.food_del(fid)
        self.assertEqual(food.food_overview()["entries"], [])
        with self.assertRaises(HTTPException):
            food.food_del(fid)

    def test_add_requires_food(self):
        with self.assertRaises(HTTPException):
            food.food_add({"portion": "1碗"})

    def test_ai_parse_failure_raises_text(self):
        with mock.patch("services.llm_cfg.effective", return_value=("", "", "", "none")):
            with self.assertRaises(HTTPException) as ctx:
                food.food_add({"text": "两个包子"})
        self.assertIn("未配置大模型", str(ctx.exception.detail))

    def test_ai_text_inserts_items(self):
        items = [{"food": "包子", "portion": "2个", "kcal": 440},
                 {"food": "粥", "portion": "1碗", "kcal": 140}]
        with mock.patch.object(food, "_ai_parse", return_value=items):
            r = food.food_add({"text": "两个包子一碗粥", "meal": "早餐"})
        self.assertEqual(r["total"], 580)
        o = food.food_overview()
        self.assertEqual([e["food"] for e in o["entries"]], ["包子", "粥"])
        self.assertEqual([e["meal"] for e in o["entries"]], ["早餐", "早餐"])

    def test_profile_and_target(self):
        r = food.food_profile({"height_cm": 175, "weight_kg": 80, "age": 30,
                               "sex": "男", "activity": "久坐"})
        self.assertEqual(r["recommended"], 1550)
        self.assertEqual(r["target"], 1550)            # 未设自定义 → 推荐
        t = food.food_target({"kcal": 1800})
        self.assertEqual(t["target"], 1800)
        r2 = food.food_profile({"height_cm": 175, "weight_kg": 78, "age": 30,
                                "sex": "男", "activity": "久坐", "weekly_loss": 0.25})
        self.assertEqual(r2["recommended"], 1800)      # BMR1728.75×1.2=2074.5 − 275 = 1799.5 → 1800
        self.assertEqual(r2["target"], 1800)           # 重新保存档案保留自定义目标
        t2 = food.food_target({"kcal": None})          # 清掉自定义 → 回推荐
        self.assertEqual(t2["target"], r2["recommended"])
        with self.assertRaises(HTTPException):
            food.food_target({"kcal": 99999})
        with self.assertRaises(HTTPException):
            food.food_profile({"height_cm": 175, "weight_kg": 80})   # 缺年龄/性别


if __name__ == "__main__":
    unittest.main(verbosity=2)
