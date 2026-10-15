-- 008_slim_and_config.sql · 表结构精简 + 配置入库
-- 精简原则:没写过的删、纯缓存的并、没用的列不留;配置(装配/语言/飞书)以表为主存

-- ① 删除从未使用的表
DROP TABLE IF EXISTS signals;        -- 信号流(从未写入,行情信号走缠论桥实时读)
DROP TABLE IF EXISTS sysmon_samples; -- 系统采样(sysmon 走 Mole 实时,无需落库)

-- ② quotes_cache(纯缓存)并入 watchlist
ALTER TABLE watchlist ADD COLUMN price REAL;
ALTER TABLE watchlist ADD COLUMN chg_pct REAL;
ALTER TABLE watchlist ADD COLUMN quote_at TEXT;
INSERT INTO watchlist(code, name, price, chg_pct)
  SELECT q.code, q.name, q.price, q.chg_pct FROM quotes_cache q
  WHERE q.code NOT IN (SELECT code FROM watchlist);
UPDATE watchlist SET price = (SELECT price FROM quotes_cache q WHERE q.code = watchlist.code),
                     chg_pct = (SELECT chg_pct FROM quotes_cache q WHERE q.code = watchlist.code)
 WHERE code IN (SELECT code FROM quotes_cache);
DROP TABLE quotes_cache;

-- ③ holdings 先去掉外键重建,再删轮次镜像表(顺序:子表先换,父表后删)
CREATE TABLE holdings_new (
  code       TEXT NOT NULL,
  round_id   TEXT NOT NULL,
  name       TEXT,
  buy_date   TEXT,
  buy_price  REAL,
  shares     REAL,
  status     TEXT NOT NULL DEFAULT 'holding',
  exit_date  TEXT,
  exit_price REAL,
  exit_why   TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  PRIMARY KEY(code, round_id)
);
INSERT INTO holdings_new SELECT code, round_id, name, buy_date, buy_price, shares,
  status, exit_date, exit_price, exit_why, updated_at FROM holdings;
DROP TABLE holdings;
ALTER TABLE holdings_new RENAME TO holdings;
DROP TABLE IF EXISTS chan_rounds;   -- 轮次镜像(raw 无消费方)

-- ④ 飞书配置入库(主存;保存时同步写 chan-monitor json 供其推送)
CREATE TABLE IF NOT EXISTS feishu_bots (
  id      TEXT PRIMARY KEY,
  name    TEXT NOT NULL,
  webhook TEXT NOT NULL,
  codes   TEXT NOT NULL DEFAULT '[]'    -- JSON 数组
);
CREATE TABLE IF NOT EXISTS feishu_notify (
  name    TEXT PRIMARY KEY,
  webhook TEXT NOT NULL
);
-- 数据由后端启动时从 chan json 首次灌入(见 routers/chan.py),SQL 不越权读文件
