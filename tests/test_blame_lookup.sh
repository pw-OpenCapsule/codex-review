#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/blame_lookup.py"

# 用本仓库自身做测试：blame 一行已知存在的代码
out=$(python3 "$PY" --workdir "$ROOT" --file README.md --line-start 1 --line-end 1 2>/dev/null || echo "{}")
echo "$out" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read())
assert "author_email" in d, "no author_email key"
assert "lark_open_id" in d
print("OK")
'
