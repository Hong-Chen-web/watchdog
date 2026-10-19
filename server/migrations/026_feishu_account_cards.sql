-- 026 专线账户卡开关:account_cards=1 的订阅专线,除订阅股票信号外同时接收
-- 账户级卡(卖出/选股/持仓/买入);0=旧行为(账户级卡只进 codes 为空的广播通道)
ALTER TABLE feishu ADD COLUMN account_cards INTEGER NOT NULL DEFAULT 0;
