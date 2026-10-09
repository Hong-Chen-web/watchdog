-- 012: 缠论实盘逐笔成交明细(结算轮 rows;持仓轮 buy-only)
CREATE TABLE IF NOT EXISTS chan_trades (
    round_date TEXT NOT NULL,
    code       TEXT NOT NULL,
    name       TEXT,
    shares     REAL,
    buy        REAL,
    sell       REAL,
    sell_date  TEXT,
    net        REAL,
    pct        REAL,
    synced_at  TEXT,
    PRIMARY KEY (round_date, code)
);
