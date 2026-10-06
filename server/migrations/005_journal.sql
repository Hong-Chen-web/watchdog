-- 005_journal.sql · 日志与复盘:todo 完成总结 + 每日回顾/自由笔记

ALTER TABLE todos ADD COLUMN summary TEXT;  -- 勾选完成时的一句话总结

CREATE TABLE IF NOT EXISTS journal (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  date       TEXT NOT NULL,                  -- YYYY-MM-DD
  kind       TEXT NOT NULL,                  -- daily(每日总结) / note(自由笔记)
  content    TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
CREATE INDEX IF NOT EXISTS idx_journal_date ON journal(date);

INSERT OR IGNORE INTO module_config(module_id, enabled, sort) VALUES ('journal', 1, 10);
