"""大模型配置:settings 表主存,env 兜底(OpenAI 兼容协议)。"""
import os


def effective():
    """返回 (base, key, model, source):库 > 环境变量 > 无。"""
    import db as dbm
    conn = dbm.connect()
    try:
        rows = {r[0]: (r[1] or "").strip() for r in conn.execute(
            "SELECT key,value FROM settings WHERE key LIKE 'llm_%'").fetchall()}
    finally:
        conn.close()
    db_cfg = bool(rows.get("llm_base") or rows.get("llm_key"))
    base = rows.get("llm_base") or os.environ.get("WD_LLM_BASE", "")
    key = rows.get("llm_key") or os.environ.get("WD_LLM_KEY", "")
    model = rows.get("llm_model") or os.environ.get("WD_LLM_MODEL", "deepseek-chat")
    src = "db" if db_cfg else ("env" if (os.environ.get("WD_LLM_BASE") or os.environ.get("WD_LLM_KEY")) else "none")
    return base.strip(), key.strip(), model.strip(), src
