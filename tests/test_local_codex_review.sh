#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/local_codex_review.py"
MOCK_DIR="$(mktemp -d)"
REPO_DIR="$(mktemp -d)"
OUT_JSON="$(mktemp)"
OUT_MD="$(mktemp)"

cleanup() {
  rm -rf "$MOCK_DIR" "$REPO_DIR"
  rm -f "$OUT_JSON" "$OUT_MD"
}
trap cleanup EXIT

cat > "$MOCK_DIR/openai_codex.py" <<'PY'
import json
import os

class Sandbox:
    read_only = "read_only"
    workspace_write = "workspace_write"
    full_access = "full_access"

class Result:
    def __init__(self, final_response):
        self.final_response = final_response

class Thread:
    def __init__(self, model, sandbox):
        self.model = model
        self.sandbox = sandbox

    def run(self, prompt, sandbox=None):
        capture = os.environ["CODEX_MOCK_CAPTURE"]
        with open(capture, "w", encoding="utf-8") as f:
            json.dump({
                "model": self.model,
                "thread_sandbox": self.sandbox,
                "run_sandbox": sandbox,
                "prompt": prompt,
            }, f, ensure_ascii=False)
        return Result("""```json
{
  "issues": [
    {
      "severity": "P1",
      "summary_zh": "空指针风险",
      "file": "src/app.py",
      "line_start": 10,
      "line_end": 12,
      "evidence": "diff 中直接访问 None"
    }
  ],
  "rejected": [
    {"original": "old finding", "reason": "not in diff"}
  ]
}
```""")

class Codex:
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def thread_start(self, model=None, sandbox=None):
        return Thread(model, sandbox)
PY

git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name "Test User"
mkdir -p "$REPO_DIR/src"
printf 'print("old")\n' > "$REPO_DIR/src/app.py"
git -C "$REPO_DIR" add .
git -C "$REPO_DIR" commit -q -m initial
BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
printf 'print("new")\n' > "$REPO_DIR/src/app.py"
git -C "$REPO_DIR" commit -am update -q
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

CAPTURE="$(mktemp)"
export CODEX_MOCK_CAPTURE="$CAPTURE"
export PYTHONPATH="$MOCK_DIR${PYTHONPATH:+:$PYTHONPATH}"

python3 "$PY" \
  --repo group/demo \
  --branch main \
  --base-sha "$BASE_SHA" \
  --head-sha "$HEAD_SHA" \
  --workdir "$REPO_DIR" \
  --output-json "$OUT_JSON" \
  --output-markdown "$OUT_MD"

python3 - "$OUT_JSON" "$OUT_MD" "$CAPTURE" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
markdown = open(sys.argv[2], encoding="utf-8").read()
capture = json.load(open(sys.argv[3], encoding="utf-8"))

assert data["metadata"]["repo"] == "group/demo"
assert data["metadata"]["branch"] == "main"
assert data["metadata"]["review_backend"] == "codex_sdk"
assert len(data["issues"]) == 1
assert data["issues"][0]["issue_key"]
assert data["issues"][0]["summary_zh"] == "空指针风险"
assert len(data["rejected"]) == 1
assert "## P1 空指针风险" in markdown
assert capture["model"] == "gpt-5.3-codex"
assert capture["thread_sandbox"] == "read_only"
assert capture["run_sandbox"] == "read_only"
assert "git diff --stat" in capture["prompt"]
assert "src/app.py" in capture["prompt"]
print("OK")
PY
