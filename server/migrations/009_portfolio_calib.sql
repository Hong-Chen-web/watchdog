-- 009: 持仓实际口径校准(chan 轮不记股数/现金,用户可校准真实账户口径)
CREATE TABLE IF NOT EXISTS portfolio_calib (
    code   TEXT PRIMARY KEY,   -- 股票代码;特殊行 '__cash__' = 可用现金覆盖
    shares REAL NOT NULL,      -- __cash__ 行存现金金额
    updated_at TEXT DEFAULT (datetime('now','localtime'))
);
