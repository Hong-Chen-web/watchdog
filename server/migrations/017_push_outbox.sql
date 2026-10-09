-- 017 飞书推送发件箱(防丢:先落库后发送,失败退避重试,目标级投递记录)
CREATE TABLE IF NOT EXISTS push_outbox (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL,      -- signal/settle/selection/plan/holding_daily/test
  title      TEXT NOT NULL,
  body       TEXT,
  dedup_key  TEXT UNIQUE,        -- 防重(如 signal:600812:B1:2026-10-09)
  status     TEXT NOT NULL DEFAULT 'pending',   -- pending/sent/failed
  retries    INTEGER DEFAULT 0,
  last_error TEXT,
  created_at TEXT DEFAULT (datetime('now','localtime')),
  sent_at    TEXT
);
CREATE TABLE IF NOT EXISTS push_delivery (
  outbox_id INTEGER NOT NULL,
  target    TEXT NOT NULL,       -- feishu.id
  ok        INTEGER DEFAULT 0,
  error     TEXT,
  PRIMARY KEY (outbox_id, target)
);
