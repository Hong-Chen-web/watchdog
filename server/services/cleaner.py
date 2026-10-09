"""看门狗安全清理:只删用户级缓存/日志(可重建类),排除 Mole 白名单与系统目录。
进度态供前端按钮内进度条轮询。删除的是目录**内容**,保留目录本身。"""
import os
import shutil
import threading
import time
from pathlib import Path

HOME = Path.home()
WHITE = [  # 沿用 Mole 保护名单(不碰开发资产与配置)
    "ms-playwright", "huggingface", ".m2", "gradle", "ollama", "surge",
    "JetBrains", "renv", "pypoetry", "tealdeer", "CloudKit", "Mobile Documents",
    "FontRegistry", "Spotlight", "com.apple", "group.com.apple", "Workbench",
    "chan-monitor", "personal-workbench", "Google/Chrome/Default",
]
TARGET_ROOTS = [HOME / "Library/Caches", HOME / "Library/Logs", HOME / ".cache"]

_lock = threading.Lock()
_prog = {"running": False, "current": "", "done": 0, "total": 0,
         "freed": 0, "skipped": 0, "error": None, "finished_at": None}


def _whitelisted(p: Path) -> bool:
    s = str(p)
    return any(w.lower() in s.lower() for w in WHITE)


def _dir_size(p: Path) -> int:
    total = 0
    for root, _, files in os.walk(p):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def targets():
    """可清理的顶层目录(估算大小,白名单排除)。"""
    out = []
    for root in TARGET_ROOTS:
        if not root.exists():
            continue
        for d in sorted(root.iterdir()):
            if d.is_dir() and not _whitelisted(d):
                out.append({"path": str(d), "name": d.name,
                            "size": _dir_size(d)})
    out.sort(key=lambda x: -x["size"])
    return out


def _clear_contents(d: Path) -> int:
    freed = 0
    for child in d.iterdir():
        try:
            if child.is_dir() and not child.is_symlink():
                sz = _dir_size(child)
                shutil.rmtree(child, ignore_errors=True)
            else:
                sz = child.stat().st_size
                child.unlink(missing_ok=True)
            freed += sz
        except OSError:
            pass
    return freed


def run_clean():
    with _lock:
        if _prog["running"]:
            return {"started": False, "reason": "清理进行中"}
        _prog.update(running=True, done=0, freed=0, skipped=0,
                     error=None, finished_at=None, current="统计目标…")
    tgts = [t for t in targets() if t["size"] > 1024 * 1024]  # 只清 >1MB 的
    _prog["total"] = len(tgts)

    def worker():
        for i, t in enumerate(tgts):
            _prog["current"] = t["name"]
            try:
                freed = _clear_contents(Path(t["path"]))
                _prog["freed"] += freed
                _prog["done"] = i + 1
            except Exception as e:
                _prog["skipped"] += 1
                _prog["error"] = f"{t['name']}: {e}"
                _prog["done"] = i + 1
        _prog["running"] = False
        _prog["current"] = ""
        _prog["finished_at"] = time.strftime("%H:%M:%S")
        # 清完垃圾让"可释放"数字跟上:作废 Mole 扫描缓存并后台重扫(~30s)
        try:
            from services.mole_clean import invalidate, rescan_async
            invalidate()
            rescan_async()
        except Exception:
            pass

    threading.Thread(target=worker, daemon=True, name="cleaner").start()
    return {"started": True, "targets": len(tgts)}


def status():
    with _lock:
        return dict(_prog)
