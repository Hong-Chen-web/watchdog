"""磁盘模块接口:/api/disk(垃圾清理扫描 + 目录大小检索,引擎=Mole CLI)。"""
import subprocess
import threading
import time

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from services.mole_clean import clean_scan

router = APIRouter(prefix="/api/disk", tags=["disk"])

ANALYZE_BIN = "/Users/chenhong/github/Mole/bin/analyze-go"
_an_lock = threading.Lock()
_an_cache = {"key": None, "data": None, "at": 0.0}


@router.get("/clean-scan")
def disk_clean_scan():
    err, data = clean_scan()
    if err == "__scanning__":   # 有扫描在跑且无缓存:让前端轮询而不是排队 27s
        return {"scanning": True}
    if err:
        raise HTTPException(502, f"Mole 清理扫描失败: {err}")
    return data


@router.get("/analyze")
def disk_analyze(path: str = "~"):
    """目录大小检索(analyze-go --json),同路径 10 分钟缓存。"""
    import os
    path = os.path.expanduser(path)
    if not os.path.isdir(path):
        raise HTTPException(400, f"目录不存在: {path}")
    with _an_lock:
        if _an_cache["key"] == path and time.time() - _an_cache["at"] < 600:
            return _an_cache["data"]
        try:
            import json
            p = subprocess.run([ANALYZE_BIN, "--json", path],
                               capture_output=True, text=True, timeout=90)
        except Exception as e:
            raise HTTPException(502, f"analyze 失败: {e}")
        if p.returncode != 0:
            raise HTTPException(502, p.stderr.strip()[-300:] or "analyze exit")
        try:
            data = json.loads(p.stdout)
        except ValueError as e:
            raise HTTPException(502, f"analyze 输出解析失败: {e}")
        _an_cache.update(key=path, data=data, at=time.time())
        return data


class TerminalCmdIn(BaseModel):
    command: str
    return_app: str = None  # chrome/safari/edge/arc,执行后把焦点切回该浏览器


_RETURN_APPS = {"chrome": "Google Chrome", "safari": "Safari",
                "edge": "Microsoft Edge", "arc": "Arc"}


@router.post("/clean-run")
def disk_clean_run():
    """启动安全清理(仅用户级缓存/日志,后台线程,按钮轮询进度)。"""
    from services.cleaner import run_clean
    return run_clean()


@router.get("/clean-status")
def disk_clean_status():
    from services.cleaner import status
    return status()


@router.post("/terminal")
def open_in_terminal(body: TerminalCmdIn):
    """在 Terminal 新窗口执行命令(危险动作留给用户在终端亲手确认)。
    打开终端会把 Terminal 带到前台,故随后切回 return_app 指定的浏览器。
    注意 AppleScript 字符串只认双引号,不能用 shlex 单引号。"""
    cmd = body.command
    if not cmd.startswith("bash /Users/chenhong/github/Mole/bin/"):
        raise HTTPException(400, "仅允许执行 Mole 脚本")
    back = _RETURN_APPS.get(body.return_app or "")
    cmd_q = cmd.replace("\\", "\\\\").replace('"', '\\"')
    script = f'tell application "Terminal" to do script "{cmd_q}"'
    if back:
        script += f'\ndelay 0.45\ntell application "{back}" to activate'
    p = subprocess.run(["osascript", "-e", script],
                       capture_output=True, text=True, timeout=15)
    if p.returncode != 0:
        raise HTTPException(502, f"打开终端失败: {p.stderr.strip()[:200]}")
    return {"ok": True, "launched": cmd, "focus_returned": bool(back)}
