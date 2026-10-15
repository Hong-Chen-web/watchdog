-- 016 盘中缠论买卖点记录(9:30-15:05 每5分钟轮询,同票同类型当日一次)
CREATE TABLE IF NOT EXISTS chan_signals (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  code        TEXT NOT NULL,
  name        TEXT,
  kind        TEXT NOT NULL,           -- B1/B2/B3/S1/S2/S3
  price       REAL,
  bar_time    TEXT,                    -- 触发K线时间
  notified_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_chan_signals_day ON chan_signals(code, kind, substr(notified_at,1,10));
