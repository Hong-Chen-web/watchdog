"""大模型配置接口:GET/PUT /api/llm + POST /api/llm/test(OpenAI 兼容)。"""
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter(prefix="/api/llm", tags=["llm"])


class LLMPayload(BaseModel):
    base: str = ""
    key: str = ""
    model: str = ""


@router.get("")
def get_llm():
    from services.llm_cfg import effective
    base, key, model, src = effective()
    return {"base": base, "key": key, "model": model, "source": src}


@router.put("")
def put_llm(body: LLMPayload):
    """保存配置;空值=清除该项(回落环境变量或本地规则)。"""
    import db as dbm
    conn = dbm.connect()
    try:
        for k, v in (("llm_base", body.base), ("llm_key", body.key), ("llm_model", body.model)):
            v = (v or "").strip()
            if v:
                conn.execute("INSERT INTO settings(key,value) VALUES(?,?) "
                             "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (k, v))
            else:
                conn.execute("DELETE FROM settings WHERE key=?", (k,))
        conn.commit()
    finally:
        conn.close()
    return get_llm()


@router.post("/test")
def test_llm(body: LLMPayload = None):
    """连通性测试:body 带未保存的值则直接测之,否则用当前生效配置。"""
    import requests
    if body and (body.base.strip() or body.key.strip()):
        base = body.base.strip().rstrip("/")
        key, model = body.key.strip(), body.model.strip() or "deepseek-chat"
    else:
        from services.llm_cfg import effective
        base, key, model, _ = effective()
        base = base.rstrip("/")
    if not base or not key:
        return {"ok": False, "error": "未配置接口地址或 API Key"}
    try:
        r = requests.post(
            f"{base}/chat/completions",
            headers={"Authorization": f"Bearer {key}"},
            json={"model": model, "messages": [{"role": "user", "content": "回复OK"}],
                  "max_tokens": 8, "temperature": 0},
            timeout=15)
        data = r.json()
        if r.status_code == 200 and data.get("choices"):
            return {"ok": True, "model": model,
                    "reply": (data["choices"][0]["message"]["content"] or "").strip()[:40]}
        return {"ok": False, "error": f"HTTP {r.status_code}: {str(data.get('error') or data)[:160]}"}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}: {str(e)[:160]}"}
