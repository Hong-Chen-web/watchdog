-- 002_seed.sql · 类别名对齐 + 回测演示种子(公开口径)
-- 个人持仓/资产/自选等真实数据不进种子:新装库由运行时数据桥接填充。

UPDATE ledger_categories SET name='娱乐旅游', name_en='Entertainment'
 WHERE name='娱乐/旅游';

-- 回测档案演示种子(口径与 README 公开数字一致)
INSERT INTO backtest_runs(id, label, params, final_equity, total_return, trades,
                          win_rate, pl_ratio, worst_hit)
VALUES (1, '涨停缩量 · 3成仓 2019-2026',
        '{"bt_start":"2019-01-01","bt_capital":100000,"bt_fraction":0.3}',
        3836000, 3736, 1170, 50.0, 2.01, -8.4);

INSERT OR IGNORE INTO backtest_yearly(run_id, year, return_pct) VALUES
  (1, 2019, 4), (1, 2020, 108), (1, 2021, 82), (1, 2022, 60),
  (1, 2023, 98), (1, 2024, 95), (1, 2025, 12), (1, 2026, 42);
