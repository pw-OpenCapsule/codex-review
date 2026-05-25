#!/usr/bin/env bash
# Mock codex CLI for tests. Reads stdin, returns fixed JSON.
# Usage: codex_exec_mock.sh exec [--output-last-message PATH] -
set -euo pipefail

out_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out_path="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Drain stdin
cat >/dev/null

payload='{"issues":[
  {"severity":"P0","summary_zh":"`login()` 失败时未返回错误，调用方拿到 null","file":"src/auth.py","line_start":42,"line_end":48,"evidence":"src/auth.py:42 的 except 块吞掉异常"},
  {"severity":"P2","summary_zh":"`format_time()` 未处理 None 输入","file":"src/util.py","line_start":15,"line_end":17,"evidence":"util.py:15 直接 strftime"}
],"rejected":[
  {"severity":"P1","original":"foo.go 缺少错误处理","reason":"仓库无 foo.go"}
]}'

if [[ -n "$out_path" ]]; then
  echo "$payload" >"$out_path"
fi
echo "$payload"
