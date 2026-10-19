#!/bin/bash
# 看门狗 Watchdog 回归入口
# 用法:scripts/regression.sh [all|tier1|tier2]   (默认 all)
#   tier1 = 离线:JS 语法 / 前端资源完整性 / Python 编译 / 单元测试(server/tests)
#   tier2 = 联网冒烟:需 sidecar 运行在 127.0.0.1:8790(只读,不动数据)
# 交付门槛:tier1 + tier2 全绿;改动 Swift 另跑 `cd app/appkit && swift test`。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="/Users/chenhong/github/czsc-repo/.venv/bin/python"
MODE="${1:-all}"
FAILS=0

hdr(){ echo; echo "── $1"; }

tier1(){
  hdr "tier1 · JS 语法(node --check,按 index.html 加载清单)"
  local n=0 bad=0
  while IFS= read -r rel; do
    if node --check "$ROOT/server/static/$rel" >/dev/null 2>/tmp/wd_js_err; then
      n=$((n+1))
    else
      bad=$((bad+1)); echo "  ✗ $rel"; sed -n '1,2p' /tmp/wd_js_err
    fi
  done < <(grep -oE 'src="/ui-assets/[^"]+\.js"' "$ROOT/server/static/index.html" \
           | sed -E 's/^src="\/ui-assets\///; s/"$//')
  if [ "$bad" = 0 ]; then echo "  ✓ JS 语法 $n 个通过"; else FAILS=$((FAILS+bad)); fi

  hdr "tier1 · 前端资源完整性 + 脚本加载顺序"
  "$PY" - "$ROOT" <<'PYEOF' || FAILS=$((FAILS+1))
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
idx = (root / "server/static/index.html").read_text(encoding="utf-8")
refs = re.findall(r'(?:src|href)="(/ui-assets/[^"]+\.(?:js|css))"', idx)
bad = [r for r in refs if not (root / "server/static" / r[len("/ui-assets/"):]).is_file()]
if bad:
    print("  ✗ 缺失资源:")
    for x in bad:
        print("     ", x)
    sys.exit(1)
js = [r for r in refs if r.endswith(".js")]
order_ok = js and js[0] == "/ui-assets/js/core.js" and js[-1] == "/ui-assets/js/main.js"
print("  ✓ 资源 %d 个全在(css %d / js %d)" % (len(refs), len(refs) - len(js), len(js)))
if not order_ok:
    print("  ✗ 脚本顺序:core.js 必须最先、main.js 必须最后")
    sys.exit(1)
PYEOF

  hdr "tier1 · Python 编译(路由/服务/测试/入口)"
  if "$PY" -m compileall -q "$ROOT/server/routers" "$ROOT/server/services" \
        "$ROOT/server/tests" "$ROOT/server/main.py" >/dev/null; then
    echo "  ✓ 编译通过"
  else
    echo "  ✗ 编译失败"; FAILS=$((FAILS+1))
  fi

  hdr "tier1 · 单元测试(server/tests)"
  ( cd "$ROOT/server" && "$PY" -m unittest discover -s tests -p 'test_*.py' ) \
      >/tmp/wd_unittest.log 2>&1
  local uc=$?
  tail -3 /tmp/wd_unittest.log | sed 's/^/  /'
  if [ "$uc" = 0 ]; then echo "  ✓ 全绿"; else echo "  ✗ 有失败(详情 /tmp/wd_unittest.log)"; FAILS=$((FAILS+1)); fi
}

tier2(){
  hdr "tier2 · 联网冒烟(只读;需 sidecar 在 127.0.0.1:8790)"
  "$PY" "$ROOT/scripts/check_endpoints.py" || FAILS=$((FAILS+1))
}

case "$MODE" in
  tier1) tier1 ;;
  tier2) tier2 ;;
  all)   tier1; tier2 ;;
  *) echo "用法:$0 [all|tier1|tier2]"; exit 2 ;;
esac

echo
if [ "$FAILS" = 0 ]; then
  echo "== 回归通过($MODE) =="
else
  echo "== 回归失败 $FAILS 项($MODE) =="
fi
[ "$FAILS" = 0 ]
