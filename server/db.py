"""SQLite 连接与迁移。库文件位置遵循设计说明书第 9 节。"""
import os
import sqlite3
from pathlib import Path

APP_DIR = Path(os.environ.get(
    "WORKBENCH_HOME",
    os.path.expanduser("~/Library/Application Support/Workbench"),
))
DB_PATH = Path(os.environ.get("WORKBENCH_DB", APP_DIR / "workbench.db"))
MIGRATIONS_DIR = Path(__file__).parent / "migrations"


def connect() -> sqlite3.Connection:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def migrate(conn: sqlite3.Connection) -> int:
    """按 PRAGMA user_version 顺序执行 migrations/NNN_*.sql,返回当前版本号。"""
    cur = conn.execute("PRAGMA user_version")
    version = cur.fetchone()[0]
    files = sorted(MIGRATIONS_DIR.glob("[0-9]" * 3 + "_*.sql"))
    for f in files:
        n = int(f.name.split("_", 1)[0])
        if n <= version:
            continue
        conn.executescript(f.read_text(encoding="utf-8"))
        conn.execute(f"PRAGMA user_version = {n}")  # PRAGMA 不支持参数绑定,n 来自受控文件名
        conn.commit()
        version = n
    return version
