-- 010: 缠论实盘台账镜像(从 8787 /api/backtest 持久化,断线可用)
CREATE TABLE IF NOT EXISTS chan_rounds (
    round_date TEXT NOT NULL,
    code       TEXT NOT NULL,
    name       TEXT,
    price      REAL,             -- 买入参考价(选股日收盘)
    exit_why   TEXT,             -- 出场原因(null=持仓中)
    settled    INTEGER DEFAULT 0, -- 0=pending 1=settled
    seq        INTEGER,          -- 轮内顺序(=评分序)
    PRIMARY KEY (round_date, code)
);
CREATE TABLE IF NOT EXISTS chan_kv (
    k TEXT PRIMARY KEY,
    v TEXT,                      -- JSON
    synced_at TEXT
);
