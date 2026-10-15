-- 001_init.sql · 个人工作台 v1 初始结构(对应设计说明书第 4 节)
-- 幂等键/口径约定见 docs/设计说明书.html

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS module_config (
  module_id  TEXT PRIMARY KEY,
  enabled    INTEGER NOT NULL DEFAULT 1,
  sort       INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS todos (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  title        TEXT NOT NULL,
  due_date     TEXT,
  priority     INTEGER NOT NULL DEFAULT 3,
  done         INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  completed_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_todos_due ON todos(due_date, done);

CREATE TABLE IF NOT EXISTS ledger_categories (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  name    TEXT NOT NULL UNIQUE,
  name_en TEXT,
  color   TEXT NOT NULL DEFAULT '#8e8e93',
  sort    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS ledger_budgets (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id INTEGER NOT NULL REFERENCES ledger_categories(id),
  year        INTEGER NOT NULL,
  annual      REAL NOT NULL DEFAULT 0,
  monthly     REAL NOT NULL DEFAULT 0,
  UNIQUE(category_id, year)
);

CREATE TABLE IF NOT EXISTS ledger_entries (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  date        TEXT NOT NULL,
  payee       TEXT,
  category_id INTEGER NOT NULL REFERENCES ledger_categories(id),
  amount      REAL NOT NULL,
  note        TEXT,
  source      TEXT NOT NULL DEFAULT 'manual',
  external_id TEXT UNIQUE,
  created_at  TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
CREATE INDEX IF NOT EXISTS idx_ledger_date ON ledger_entries(date);

CREATE TABLE IF NOT EXISTS watchlist (
  code      TEXT PRIMARY KEY,
  name      TEXT NOT NULL,
  note      TEXT,
  sort      INTEGER DEFAULT 0,
  added_at  TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE IF NOT EXISTS quotes_cache (
  code       TEXT PRIMARY KEY,
  name       TEXT,
  price      REAL,
  chg_pct    REAL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS signals (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  code    TEXT,
  name    TEXT,
  kind    TEXT NOT NULL,
  message TEXT NOT NULL,
  payload TEXT,
  read    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS chan_rounds (
  round_id  TEXT PRIMARY KEY,
  sel_date  TEXT NOT NULL,
  raw       TEXT NOT NULL,
  synced_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE IF NOT EXISTS holdings (
  code       TEXT NOT NULL,
  round_id   TEXT NOT NULL REFERENCES chan_rounds(round_id),
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

CREATE TABLE IF NOT EXISTS account_snapshots (
  date         TEXT PRIMARY KEY,
  cash         REAL,
  market_value REAL,
  total        REAL,
  source       TEXT NOT NULL DEFAULT 'chan'
);

CREATE TABLE IF NOT EXISTS backtest_runs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  label        TEXT NOT NULL,
  params       TEXT,
  final_equity REAL,
  total_return REAL,
  trades       INTEGER,
  win_rate     REAL,
  pl_ratio     REAL,
  worst_hit    REAL
);

CREATE TABLE IF NOT EXISTS backtest_yearly (
  run_id     INTEGER NOT NULL REFERENCES backtest_runs(id),
  year       INTEGER NOT NULL,
  return_pct REAL NOT NULL,
  PRIMARY KEY(run_id, year)
);

CREATE TABLE IF NOT EXISTS backtest_curve (
  run_id  INTEGER NOT NULL REFERENCES backtest_runs(id),
  seq     INTEGER NOT NULL,
  date    TEXT,
  equity REAL,
  PRIMARY KEY(run_id, seq)
);

CREATE TABLE IF NOT EXISTS sysmon_samples (
  ts     TEXT PRIMARY KEY,
  health INTEGER,
  cpu    REAL,
  mem_pct REAL,
  net_rx REAL
);

CREATE TABLE IF NOT EXISTS sync_log (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  source  TEXT NOT NULL,
  status  TEXT NOT NULL,
  message TEXT,
  ts      TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

-- 模块种子(与前台原型九模块一致;名称由前端 i18n,后端只存注册事实)
INSERT OR IGNORE INTO module_config(module_id, enabled, sort) VALUES
  ('portfolio', 1, 0), ('backtest', 1, 1), ('todo', 1, 2),
  ('ledger', 1, 3), ('market', 1, 4), ('sysmon', 1, 5),
  ('strategy', 0, 6), ('futures', 0, 7), ('calendar', 0, 8);

-- 账本类别种子(实测自用户 Numbers「简单预算」模板 8 类别)
INSERT OR IGNORE INTO ledger_categories(name, name_en, color, sort) VALUES
  ('食物',     'Food',      '#ff9f0a', 1),
  ('房屋',     'Housing',   '#0a84ff', 2),
  ('娱乐/旅游','Entertainment','#bf5af2', 3),
  ('旅行',     'Travel',    '#64d2ff', 4),
  ('医疗',     'Medical',   '#ff5a5f', 5),
  ('个人物品', 'Personal',  '#ffd60a', 6),
  ('人情',     'Social',    '#30d158', 7),
  ('其他',     'Other',     '#8e8e93', 8);

INSERT OR REPLACE INTO settings(key, value) VALUES
  ('lang', 'zh'),
  ('poll_interval_quotes', '3'),
  ('poll_interval_sysmon', '3');
