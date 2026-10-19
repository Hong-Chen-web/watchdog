-- 025 发件箱定向投递:code=本卡标的(股票6位数字/期货品种如 C0);发送时按 feishu.codes 订阅过滤通道
ALTER TABLE push_outbox ADD COLUMN code TEXT;
