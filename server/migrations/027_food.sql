-- 027 健康页:饮食明细(food_entries)+ 每日热量目标(settings.health_profile,按身高体重推荐)
CREATE TABLE IF NOT EXISTS food_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,                      -- YYYY-MM-DD
  meal TEXT NOT NULL DEFAULT '其他',        -- 早餐/午餐/晚餐/加餐
  food TEXT NOT NULL,                      -- 食物名
  portion TEXT NOT NULL DEFAULT '',        -- 份量描述,如 1碗/200g
  kcal REAL,                               -- 估算千卡,可空(未估)
  created_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
CREATE INDEX IF NOT EXISTS idx_food_date ON food_entries(date);

INSERT OR IGNORE INTO module_config(module_id, enabled, sort) VALUES ('food', 1, 16);
