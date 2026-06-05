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
OUT_HTML="$RUN_DIR/dashboard.html"
OUT_JSON="$RUN_DIR/dashboard.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$MOCK_DIR" "$(dirname "$ARTIFACT")" "$WORK_DIR" "$STATE_DIR"

cat > "$MOCK_DIR/gh" <<'SH'
#!/usr/bin/env bash
echo "gh should not be called by local dashboard" >&2
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
      "severity": "P0",
      "summary_zh": "严重问题",
      "file": "src/app.py",
      "line_start": 9,
      "line_end": 9,
      "evidence": "证据"
    }
  ],
  "rejected": []
}
JSON

printf 'group/demo\tmain\texample-code-review/demo\t1111111111111111111111111111111111111111\t2222222222222222222222222222222222222222\t%s\t%s\n' \
  "$ARTIFACT" "${ARTIFACT%.json}.md" > "$RUN_DIR/run-2026-06-05.tsv"

export PATH="$MOCK_DIR:$PATH"
export CODEX_REVIEW_SETTINGS="$SETTINGS"

bash "$ROOT/scripts/build_review_dashboard.sh" --days 1 --output "$OUT_HTML" --json "$OUT_JSON"

python3 - "$OUT_JSON" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["summary"]["total"] == 1
assert data["summary"]["withIssues"] == 1
row = data["reviews"][0]
assert row["gitlabPath"] == "group/demo"
assert row["reviewBackend"] == "codex_sdk"
assert row["maxSeverity"] == "P0"
assert row["issueCount"] == 1
print("OK")
PY

grep -q '严重问题' "$OUT_HTML" || {
  echo "FAIL: dashboard html missing issue summary"
  exit 1
}
