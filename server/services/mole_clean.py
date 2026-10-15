"""Mole 清理桥:解析 clean.sh --dry-run 的可清理清单。
真删除涉及 sudo 与交互确认,不在后台静默执行——由前端引导在终端运行。"""
import re
import subprocess
import threading
import time

MOLE_CLEAN = "/Users/chenhong/github/Mole/bin/clean.sh"
TIMEOUT = 120
CACHE_TTL = 300

_ansi = re.compile(r"\x1b\[[0-9;]*m")
_item = re.compile(r"→\s+(.+?)\s*·\s*([\d,.]+\s*\w*?)\s*items?,\s*([0-9.]+\s*[KMG]?B)")
_lock = threading.Lock()
_cache = {"data": None, "at": 0.0}
_busy = False   # 扫描在途标记:第二个请求不阻塞,拿 "__scanning__" 哨兵去轮询


def invalidate():
    """清理完成后由 cleaner 调:缓存作废,立即可重扫。"""
    with _lock:
        _cache["data"], _cache["at"] = None, 0.0


def rescan_async():
    def _go():
        try:
            clean_scan()
        except Exception:
            pass
    threading.Thread(target=_go, daemon=True, name="mole-rescan").start()


def _size_bytes(s: str) -> int:
    m = re.match(r"([0-9.]+)\s*([KMG]?B)", s.strip())
    if not m:
        return 0
    v = float(m.group(1))
    return int(v * {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}[m.group(2)])


def clean_scan():
    """返回 (err, {free_gb, groups:[{group, items:[{name, count, size_txt, size_bytes}]}], total_bytes})
    err=="__scanning__":别的请求正在扫且缓存为空——前端直接轮询,不要排队阻塞。"""
    global _busy
    with _lock:
        if _cache["data"] and time.time() - _cache["at"] < CACHE_TTL:
            return None, _cache["data"]
        if _busy:
            return "__scanning__", None
        _busy = True
    try:
        return _scan_now()
    finally:
        with _lock:
            _busy = False


def _scan_now():
    try:
        p = subprocess.run(["bash", MOLE_CLEAN, "--dry-run"],
                           capture_output=True, text=True,
                           timeout=TIMEOUT, stdin=subprocess.DEVNULL)
    except Exception as e:
        return e, None
    # clean.sh 在非 tty 下固定 exit=1 但输出完整;以内容为准
    if not p.stdout or "Dry Run" not in _ansi.sub("", p.stdout):
        return RuntimeError(p.stderr.strip()[-300:] or "clean 无输出"), None

    text = _ansi.sub("", p.stdout)
    free = None
    m = re.search(r"Free space:\s*([0-9.]+GB)", text)
    if m:
        free = m.group(1)
    groups, cur = [], None
    for line in text.splitlines():
        g = re.match(r"➤\s+(.+)", line.strip())
        if g:
            cur = {"group": g.group(1).strip(), "items": []}
            groups.append(cur)
            continue
        im = _item.search(line)
        if im and cur is not None:
            cur["items"].append({
                "name": im.group(1).strip(),
                "count": im.group(2).strip(),
                "size_txt": im.group(3).strip(),
                "size_bytes": _size_bytes(im.group(3)),
            })
    total = sum(i["size_bytes"] for g in groups for i in g["items"])
    data = {"free_gb": free, "groups": groups, "total_bytes": total}
    with _lock:
        _cache["data"], _cache["at"] = data, time.time()
    return None, data
