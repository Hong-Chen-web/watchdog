-- 4小时级别监控:信号按级别区分(5m/4h)
ALTER TABLE chan_signals ADD COLUMN level TEXT NOT NULL DEFAULT '5m';
