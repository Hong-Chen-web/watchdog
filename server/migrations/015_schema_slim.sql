-- 015 表结构精简(2026-10-08)
-- 删死表:chan_rounds(代码零引用);backtest_*(v34 起回测卡=实盘台账,App 只调 /live,
--         八年导入数据已随全库备份到 ~/Documents/workbench_backup_20261008.db)
-- 合并:feishu_bots + feishu_notify → feishu(kind 列区分)
-- 治噪:sync_log 只写不读,截断保留最近 200 条
PRAGMA foreign_keys = OFF;

DROP TABLE IF EXISTS chan_rounds;
DROP TABLE IF EXISTS backtest_runs;
DROP TABLE IF EXISTS backtest_trades;
DROP TABLE IF EXISTS backtest_curve;
DROP TABLE IF EXISTS backtest_yearly;

CREATE TABLE feishu (
  id      TEXT PRIMARY KEY,           -- bot=uuid8;notify=群名
  kind    TEXT NOT NULL CHECK (kind IN ('bot','notify')),
  name    TEXT NOT NULL,
  webhook TEXT NOT NULL,
  codes   TEXT NOT NULL DEFAULT '[]'  -- 仅 bot:监控代码 JSON 数组
);
INSERT INTO feishu(id, kind, name, webhook, codes)
  SELECT id, 'bot', name, webhook, codes FROM feishu_bots;
INSERT INTO feishu(id, kind, name, webhook, codes)
  SELECT name, 'notify', name, webhook, '[]' FROM feishu_notify;
DROP TABLE feishu_bots;
DROP TABLE feishu_notify;

DELETE FROM sync_log WHERE id NOT IN (SELECT id FROM sync_log ORDER BY id DESC LIMIT 200);
