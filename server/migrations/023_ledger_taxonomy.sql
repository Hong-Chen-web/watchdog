-- 023 · 账本分类收敛:场景类(旅行)拆成品类类(交通/住宿),补投资口径
-- 口径与自动记账规则同源(services/smart_entry.py):按"支出性质"归类,场景记在 note 里。
-- 改名用 UPDATE + INSERT OR IGNORE,老库重复执行也安全(id 不变,预算/流水不受影响)。

UPDATE ledger_categories SET name='住宿', name_en='Lodging',       color='#64d2ff', sort=3 WHERE name='旅行';
UPDATE ledger_categories SET name='购物', name_en='Shopping',      color='#ffd60a', sort=5 WHERE name='个人物品';
UPDATE ledger_categories SET name='娱乐', name_en='Entertainment', color='#bf5af2', sort=6 WHERE name='娱乐旅游';

INSERT OR IGNORE INTO ledger_categories(name, name_en, color, sort) VALUES
  ('交通', 'Transport',  '#5ac8fa', 2),
  ('投资', 'Investment', '#ff375f', 9);

UPDATE ledger_categories SET name_en='Food',    color='#ff9f0a', sort=1  WHERE name='食物';
UPDATE ledger_categories SET name_en='Housing', color='#0a84ff', sort=8  WHERE name='房屋';
UPDATE ledger_categories SET name_en='Medical', color='#ff5a5f', sort=7  WHERE name='医疗';
UPDATE ledger_categories SET name_en='Social',  color='#30d158', sort=4  WHERE name='人情';
UPDATE ledger_categories SET name_en='Other',   color='#8e8e93', sort=10 WHERE name='其他';
