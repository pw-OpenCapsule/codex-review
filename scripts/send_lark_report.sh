#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config/settings.env
source "$ROOT_DIR/config/settings.env"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_dirs

DATE_INPUT="${1:-}"
REPORT_DATE="${DATE_INPUT:-$(TZ="$TZ" date +%F)}"
RUN_FILE="$RUN_DIR/run-$REPORT_DATE.tsv"

if [[ ! -f "$RUN_FILE" ]]; then
  die "未找到运行记录文件: $RUN_FILE"
fi

report=""
while IFS=$'\t' read -r gitlab_path branch gh_repo pr_number pr_url; do
  [[ -z "$gitlab_path" ]] && continue

  bodies="$(gh pr view --repo "$gh_repo" "$pr_number" --json comments,reviews,reviewThreads --jq '[.comments[].body, .reviews[].body, .reviewThreads[].comments[].body] | map(select(.!=null)) | join("\n")')"

  report+="仓库: $gitlab_path"$'\n'
  report+="分支: $branch"$'\n'

  issues="$(printf '%s\n' "$bodies" | grep -E 'P0|P1' | head -n 5 || true)"
  if [[ -n "$issues" ]]; then
    while IFS= read -r issue; do
      [[ -z "$issue" ]] && continue
      report+="- $issue"$'\n'
    done <<< "$issues"
  else
    report+="暂无 P0/P1 或审查仍在进行中。"$'\n'
  fi

  report+="拉取请求：$pr_url"$'\n\n'
done < "$RUN_FILE"

TITLE="每日代码审查报告（$REPORT_DATE）"

payload="$(python3 - <<'PY'
import json
import os
import sys

title = os.environ["TITLE"]
content = sys.stdin.read().strip() or "暂无审计结果。"

payload = {
    "msg_type": "interactive",
    "card": {
        "header": {
            "title": {"tag": "plain_text", "content": title},
            "template": "blue"
        },
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": content}}
        ]
    }
}

print(json.dumps(payload))
PY
)"

if [[ -z "$LARK_WEBHOOK_URL" ]]; then
  die "LARK_WEBHOOK_URL 为空"
fi

curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$LARK_WEBHOOK_URL" >/dev/null
