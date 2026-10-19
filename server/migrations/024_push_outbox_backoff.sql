-- 024 发件箱退避重试:next_try_at 到期才重试(1m/5m/15m 退避);retries>=4 由 flush_once 落为 failed 终态
ALTER TABLE push_outbox ADD COLUMN next_try_at TEXT;
