#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/meegle_bug.py"

export MEEGLE_BIN="$ROOT/tests/fixtures/meegle_mock.sh"
export MEEGLE_SEVERITY_MAP="P0:1 P1:2 P2:3 P3:4 P4:5 P5:5"

state=$(mktemp)

# Test 1: dry-run
out=$(python3 "$PY" --project-key 6a13e31e9407c20a72ed6e82 \
  --work-item-type issue --state-file "$state" \
  --dry-run \
  --bug '{"severity":"P0","summary":"测试缺陷","file":"a.py","line_start":1,"line_end":1,"repo":"r","pr":"1","pr_url":"http://x","assignee":"u1","blame_author":"foo","blame_sha":"abc","blame_date":"2026-01-01","evidence":"e","original":"o"}')
echo "$out" | grep -q '"dry_run":true' || { echo "FAIL: dry_run not detected"; exit 1; }
echo "$out" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
p = d["payload"]
f = {x["field_key"]: x["field_value"] for x in p["fields"]}
assert f["severity"] == "1", "sev got " + str(f.get("severity"))
assert "登录" not in f["name"]
print("dry-run OK")
' || exit 1

# Test 2: real call via mock (no dry-run)
out=$(python3 "$PY" --project-key 6a13e31e9407c20a72ed6e82 \
  --work-item-type issue --state-file "$state" \
  --bug '{"severity":"P1","summary":"another","file":"b.py","line_start":2,"line_end":3,"repo":"r2","pr":"2","pr_url":"http://y","assignee":"u2","blame_author":"bar","blame_sha":"def","blame_date":"2026-01-02","evidence":"e2","original":"o2"}')
echo "$out" | grep -q '"work_item_id":99999999' || { echo "FAIL: mock create"; exit 1; }

# Test 3: idempotency — second call with same args should skip
out2=$(python3 "$PY" --project-key 6a13e31e9407c20a72ed6e82 \
  --work-item-type issue --state-file "$state" \
  --bug '{"severity":"P1","summary":"another","file":"b.py","line_start":2,"line_end":3,"repo":"r2","pr":"2","pr_url":"http://y","assignee":"u2","blame_author":"bar","blame_sha":"def","blame_date":"2026-01-02","evidence":"e2","original":"o2"}')
echo "$out2" | grep -q '"skipped":true' || { echo "FAIL: idempotency"; exit 1; }

rm -f "$state"
echo OK
