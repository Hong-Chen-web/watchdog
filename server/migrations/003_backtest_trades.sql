-- 003_backtest_trades.sql · 回测逐笔明细表(数据源:回测报告 HTML 全部明细表)

CREATE TABLE IF NOT EXISTS backtest_trades (
  run_id       INTEGER NOT NULL REFERENCES backtest_runs(id),
  seq          INTEGER NOT NULL,              -- 报告序号 #
  buy_date     TEXT,
  sell_date    TEXT,
  name         TEXT,
  code         TEXT,                          -- 原样保留 sz.000670 / sh.600318
  buy_price    REAL,
  sell_price   REAL,
  shares       REAL,
  pnl_pct      REAL,                          -- +14.36% → 14.36
  pnl_amount   REAL,                          -- ¥+4,244 → 4244(正负号保留)
  hold_txt     TEXT,                          -- '2天'
  exit_reason  TEXT,                          -- 三天未板到期卖出 等
  vol_shrink   TEXT,                          -- 缩量 '48%'
  big_order    TEXT,                          -- 大单
  PRIMARY KEY(run_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_bt_trades_sell ON backtest_trades(run_id, sell_date);
