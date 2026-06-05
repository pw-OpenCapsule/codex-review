#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/lark_base_issue.py"
MOCK_DIR="$(mktemp -d)"
ISSUE_FILE="$(mktemp)"
CALL_LOG="$(mktemp)"

cleanup() {
  rm -rf "$MOCK_DIR"
  rm -f "$ISSUE_FILE" "$CALL_LOG"
}
trap cleanup EXIT

cat > "$MOCK_DIR/lark-cli" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$LARK_MOCK_CALL_LOG"
if [[ "$*" == *"+record-search"* ]]; then
  if [[ "${LARK_MOCK_EXISTING:-0}" == "1" ]]; then
    printf '{"records":[{"record_id":"rec_existing","fields":{"issue_key":"demo-key"}}]}\n'
  else
    printf '{"records":[]}\n'
  fi
  exit 0
fi
if [[ "$*" == *"+record-upsert"* ]]; then
  if [[ "$*" == *"--record-id rec_existing"* ]]; then
    printf '{"updated":true,"record":{"record_id":"rec_existing"}}\n'
  else
    printf '{"created":true,"record":{"record_id":"rec_new"}}\n'
  fi
  exit 0
fi
printf '{"ok":true}\n'
SH
chmod +x "$MOCK_DIR/lark-cli"

cat > "$ISSUE_FILE" <<'JSON'
{
  "metadata": {
    "repo": "group/demo",
    "branch": "main",
    "base_sha": "1111111111111111111111111111111111111111",
    "head_sha": "2222222222222222222222222222222222222222",
    "review_date": "2026-06-05",
    "artifact_json": "/tmp/review.json"
  },
  "issues": [
    {
      "issue_key": "demo-key",
      "severity": "P2",
      "summary_zh": "缓存未失效",
      "file": "src/cache.py",
      "line_start": 20,
      "line_end": 21,
      "evidence": "更新配置后仍读取旧值",
      "owner_lark_id": "ou_123",
      "blame_author": "Dev User"
    }
  ]
}
JSON

export PATH="$MOCK_DIR:$PATH"
export LARK_MOCK_CALL_LOG="$CALL_LOG"
export LARK_BASE_TOKEN="base_token"
export LARK_BASE_TABLE_ID="tbl_issue"

python3 "$PY" --artifact "$ISSUE_FILE" --dry-run | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["processed"] == 1
assert d["records"][0]["dry_run"] is True
assert d["records"][0]["fields"]["issue_key"] == "demo-key"
assert d["records"][0]["fields"]["status"] == "待处理"
print("dry OK")
'

LARK_MOCK_EXISTING=0 python3 "$PY" --artifact "$ISSUE_FILE" >/tmp/lark-base-create.out
grep -q '+record-search' "$CALL_LOG" || { echo "FAIL: search not called"; exit 1; }
grep -q '+record-upsert' "$CALL_LOG" || { echo "FAIL: create not called"; exit 1; }
grep -q '"created": true' /tmp/lark-base-create.out || { echo "FAIL: create result"; exit 1; }

: > "$CALL_LOG"
LARK_MOCK_EXISTING=1 python3 "$PY" --artifact "$ISSUE_FILE" >/tmp/lark-base-update.out
grep -q -- '--record-id rec_existing' "$CALL_LOG" || { echo "FAIL: update record id missing"; exit 1; }
grep -q '"updated": true' /tmp/lark-base-update.out || { echo "FAIL: update result"; exit 1; }

echo OK
