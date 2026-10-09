"""Mole CLI 桥:spawn Mole/bin/status-go --json,2.5s 缓存。
对应设计说明书第 8 节(按需请求驱动、超时降级)。"""
import json
import subprocess
import threading
import time

MOLE_BIN = "/Users/chenhong/github/Mole/bin/status-go"
CACHE_TTL = 2.5
TIMEOUT = 6

_lock = threading.Lock()
_cache = {"data": None, "at": 0.0}


def mole_metrics():
    """返回 (err, metrics_dict);错误不缓存,前端降级显示上次快照。"""
    with _lock:
        if _cache["data"] and time.time() - _cache["at"] < CACHE_TTL:
            return None, _cache["data"]
        try:
            p = subprocess.run([MOLE_BIN, "--json"], capture_output=True,
                               text=True, timeout=TIMEOUT)
        except Exception as e:
            return e, None
        if p.returncode != 0:
            return RuntimeError(p.stderr.strip() or f"exit {p.returncode}"), None
        try:
            data = json.loads(p.stdout)
        except ValueError as e:
            return e, None
        _cache["data"] = data
        _cache["at"] = time.time()
        return None, data
