-- 013: ledger 逐笔化(同日多笔出场不吞行)
DROP TABLE IF EXISTS chan_round_ledger;
CREATE TABLE chan_round_ledger (
    round_date   TEXT NOT NULL,
    code         TEXT NOT NULL DEFAULT '',
    sell_date    TEXT,
    realized_net REAL,
    synced_at    TEXT,
    PRIMARY KEY (round_date, code)
);
