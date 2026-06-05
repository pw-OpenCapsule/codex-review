#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
MOCK_DIR="$TMP_DIR/bin"
RUN_DIR="$TMP_DIR/run"
WORK_DIR="$TMP_DIR/work"
STATE_DIR="$TMP_DIR/state"
SETTINGS="$TMP_DIR/settings.env"
REPOS="$TMP_DIR/repos.txt"
ARTIFACT="$RUN_DIR/reviews/2026-06-05/group_demo-main.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$MOCK_DIR" "$(dirname "$ARTIFACT")" "$WORK_DIR" "$STATE_DIR"

cat > "$MOCK_DIR/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CURL_CALL_LOG"
printf '{"code":0}\n200'
SH
chmod +x "$MOCK_DIR/curl"

cat > "$MOCK_DIR/gh" <<'SH'
#!/usr/bin/env bash
echo "gh should not be called in codex_sdk backend" >&2
exit 99
SH
chmod +x "$MOCK_DIR/gh"

cat > "$SETTINGS" <<EOF
GITHUB_ORG="example-code-review"
DEFAULT_BRANCH="main"
TZ="Asia/Tokyo"
WORKDIR="$WORK_DIR"
STATE_DIR="$STATE_DIR"
RUN_DIR="$RUN_DIR"
REPOS_FILE="$REPOS"
LARK_WEBHOOK_URL=""
LARK_WEBHOOK_URL_DRY="https://example.invalid/webhook"
LARK_MESSAGE_TYPE="card_v2"
LARK_BASE_ENABLED=0
EOF

cat > "$REPOS" <<'EOF'
group/demo@main daily
EOF

cat > "$ARTIFACT" <<'JSON'
{
  "metadata": {
    "repo": "group/demo",
    "branch": "main",
    "base_sha": "1111111111111111111111111111111111111111",
    "head_sha": "2222222222222222222222222222222222222222",
    "review_backend": "codex_sdk",
    "model": "gpt-5.3-codex",
    "review_date": "2026-06-05",
    "artifact_json": "/tmp/review.json"
  },
  "issues": [
    {
      "issue_key": "demo-key",
      "severity": "P1",
      "summary_zh": "本地审查问题",
      "file": "src/app.py",
      "line_start": 3,
      "line_end": 4,
      "evidence": "测试证据"
    }
  ],
  "rejected": []
}
JSON

printf 'group/demo\tmain\texample-code-review/demo\t1111111111111111111111111111111111111111\t2222222222222222222222222222222222222222\t%s\t%s\n' \
  "$ARTIFACT" "${ARTIFACT%.json}.md" > "$RUN_DIR/run-2026-06-05.tsv"

export PATH="$MOCK_DIR:$PATH"
export CODEX_REVIEW_SETTINGS="$SETTINGS"
export CURL_CALL_LOG="$TMP_DIR/curl.log"
export LARK_DRY_RUN=1

bash "$ROOT/scripts/send_lark_report.sh" 2026-06-05 --dry > "$TMP_DIR/out.txt"

grep -q '本地审查问题' "$RUN_DIR/report-2026-06-05-group_demo-main.txt" || {
  echo "FAIL: report content missing"
  exit 1
}
grep -q 'example.invalid/webhook' "$CURL_CALL_LOG" || {
  echo "FAIL: curl not called"
  exit 1
}

echo OK
