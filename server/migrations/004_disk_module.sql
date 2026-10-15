-- 004_disk_module.sql · 新增「磁盘与清理」模块(垃圾清理扫描 + 目录检索,Mole 引擎)

INSERT OR IGNORE INTO module_config(module_id, enabled, sort) VALUES ('disk', 1, 9);
