-- 006_goals.sql · 目标表(Numbers 年度目标/长期目标两表)+ 预算/目标模块注册

CREATE TABLE IF NOT EXISTS goals (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  scope       TEXT NOT NULL CHECK (scope IN ('month','year','long')),
               -- 枚举:month=月度目标 year=年度目标 long=长期目标
  title       TEXT NOT NULL,               -- 事项
  start_date  TEXT,                        -- 建立日期
  review_date TEXT,                        -- 回顾日期
  detail      TEXT,                        -- 目标(多行)
  result      TEXT,                        -- 结果
  source      TEXT NOT NULL DEFAULT 'numbers',
  sort        INTEGER NOT NULL DEFAULT 0
);

INSERT OR IGNORE INTO module_config(module_id, enabled, sort) VALUES
  ('budget', 1, 11), ('goals', 1, 12);
