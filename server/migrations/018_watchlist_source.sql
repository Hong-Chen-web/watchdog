-- 018 自选来源区分:manual=用户手动加(永不动);system=策略买入自动加(卖出后自动移除)
ALTER TABLE watchlist ADD COLUMN source TEXT NOT NULL DEFAULT 'manual';
