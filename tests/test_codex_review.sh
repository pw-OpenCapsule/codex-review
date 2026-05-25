#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/codex_review.py"
MOCK="$ROOT/tests/fixtures/codex_exec_mock.sh"
SAMPLE="$ROOT/tests/fixtures/codex_review_sample.txt"

export CODEX_EXEC_BIN="$MOCK"
export CODEX_EXEC_TIMEOUT=10

out=$(python3 "$PY" \
  --repo dummy --branch main --pr 42 --sha HEAD \
  --workdir "$ROOT" \
  --review-file "$SAMPLE")

echo "$out" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
n = len(d["issues"])
assert n == 2, "want 2 issues, got " + str(n)
assert d["issues"][0]["severity"] == "P0"
assert d["issues"][0]["file"] == "src/auth.py"
assert len(d["rejected"]) == 1
print("OK")
'
