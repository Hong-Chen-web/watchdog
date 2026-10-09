-- 011: 缠论实盘逐轮结算台账(资产曲线数据源;account_snapshots 种子口径后续废弃)
CREATE TABLE IF NOT EXISTS chan_round_ledger (
    round_date   TEXT PRIMARY KEY,
    sell_date    TEXT,
    realized_net REAL,
    synced_at    TEXT
);
