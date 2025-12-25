#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config/settings.env
source "$ROOT_DIR/config/settings.env"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_dirs

ensure_gh_auth

DATE_INPUT="${1:-}"
REPORT_DATE="${DATE_INPUT:-$(TZ="$TZ" date +%F)}"
RUN_FILE="$RUN_DIR/run-$REPORT_DATE.tsv"
TODAY="$(TZ="$TZ" date +%F)"
TARGET_ENTRY="${RETRY_ONLY:-}"

if [[ "$REPORT_DATE" != "$TODAY" && "${LARK_DRY_RUN:-0}" != "1" ]]; then
  log "报告日期非今日，跳过发送：$REPORT_DATE"
  exit 0
fi

report_marker() {
  printf 'codex-review-report-sent:%s' "$REPORT_DATE"
}

report_already_sent() {
  local gh_repo="$1"
  local pr_number="$2"
  local marker
  local already

  marker="$(report_marker)"
  already="$(gh pr view --repo "$gh_repo" "$pr_number" --json comments --jq "[.comments[].body | contains(\"$marker\")] | any")"
  [[ "$already" == "true" ]]
}

normalize_for_pr_comment() {
  local text="$1"

  REPORT_TEXT="$text" python3 - <<'PY'
import os
import re

text = os.environ.get("REPORT_TEXT", "")
if not text.strip():
    raise SystemExit(0)

text = text.replace("\r\n", "\n")
text = re.sub(r"<text_tag[^>]*>(.*?)</text_tag>", r"[\1]", text)
text = re.sub(r"<at[^>]*></at>", "", text)
text = re.sub(r"<[^>]+>", "", text)

lines = []
for line in text.splitlines():
    stripped = line.strip()
    if not stripped:
        lines.append("")
        continue
    if stripped in ("责任人:", "责任人：", "责任人"):
        continue
    lines.append(line.rstrip())

print("\n".join(lines).strip())
PY
}

post_report_comment() {
  local gh_repo="$1"
  local pr_number="$2"
  local content="$3"
  local marker
  local normalized

  marker="$(report_marker)"
  normalized="$(normalize_for_pr_comment "$content")"
  if [[ -z "$(printf '%s' "$normalized" | tr -d '[:space:]')" ]]; then
    normalized="审查结果已发送。"
  fi

  gh pr comment --repo "$gh_repo" "$pr_number" --body "<!-- ${marker} -->"$'\n\n'"$normalized" >/dev/null
}

codex_setup_required() {
  local review_text="$1"

  REVIEW_TEXT="$review_text" python3 - <<'PY'
import os
import re

text = os.environ.get("REVIEW_TEXT", "")
if re.search(r"To use Codex here,", text, flags=re.IGNORECASE):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

trigger_codex_review() {
  local gh_repo="$1"
  local pr_number="$2"

  gh pr comment --repo "$gh_repo" "$pr_number" --body "$CODEX_PROMPT (retry $(date +'%F %T'))" >/dev/null
}

schedule_retry() {
  local gitlab_path="$1"
  local branch="$2"
  local gh_repo="$3"
  local pr_number="$4"
  local delay="${RETRY_DELAY_SECONDS:-1800}"
  local repo_slug="${gitlab_path//\//_}-${branch//\//-}"
  local retry_file="$RUN_DIR/retry-$REPORT_DATE-$repo_slug.tsv"
  local now_ts next_ts attempt existing_ts

  now_ts="$(date +%s)"
  next_ts=$((now_ts + delay))
  attempt=1

  if [[ -f "$retry_file" ]]; then
    IFS=$'\t' read -r existing_ts attempt _ _ _ < "$retry_file" || true
    if [[ -n "$existing_ts" && "$existing_ts" -ge "$now_ts" ]]; then
      log "已存在重试计划，跳过重复调度：$gitlab_path@$branch"
      return 1
    fi
    if [[ -n "${attempt:-}" ]]; then
      attempt=$((attempt + 1))
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$next_ts" "$attempt" "$gitlab_path" "$branch" "$pr_number" > "$retry_file"

  local delay_seconds=$((next_ts - now_ts))
  if [[ "$delay_seconds" -lt 0 ]]; then
    delay_seconds=0
  fi

  (
    sleep "$delay_seconds"
    cd "$ROOT_DIR"
    RETRY_ONLY="${gitlab_path}@${branch}" ./scripts/send_lark_report.sh "$REPORT_DATE"
  ) >> "$RUN_DIR/retry-$REPORT_DATE-$repo_slug.log" 2>&1 &

  log "已安排 ${delay_seconds}s 后重试发送：$gitlab_path@$branch"
  return 0
}

strip_urls() {
  sed -E 's#https?://[^ )]+##g'
}

extract_location() {
  local review_text="$1"

  REVIEW_TEXT="$review_text" python3 - <<'PY'
import os
import re
import sys

text = os.environ.get("REVIEW_TEXT", "")
m = re.search(r"https?://github.com/[^\s)]+/blob/([0-9a-fA-F]{7,40})/([^#\s)]+)#L(\d+)(?:-L(\d+))?", text)
if not m:
    sys.exit(0)

commit = m.group(1)
path = m.group(2)
start = m.group(3)
end = m.group(4) or start
print(f"{commit}\t{path}\t{start}\t{end}")
PY
}

get_code_snippet() {
  local repo_dir="$1"
  local commit="$2"
  local path="$3"
  local start="$4"
  local end="$5"
  local branch="$6"
  local content=""

  if [[ ! -d "$repo_dir/.git" ]]; then
    return 1
  fi

  if [[ -n "$commit" ]] && git -C "$repo_dir" cat-file -e "$commit:$path" 2>/dev/null; then
    content="$(git -C "$repo_dir" show "$commit:$path")"
  elif git -C "$repo_dir" cat-file -e "origin/$branch:$path" 2>/dev/null; then
    content="$(git -C "$repo_dir" show "origin/$branch:$path")"
  elif git -C "$repo_dir" cat-file -e "HEAD:$path" 2>/dev/null; then
    content="$(git -C "$repo_dir" show "HEAD:$path")"
  else
    return 1
  fi

  if [[ -z "$content" ]]; then
    return 1
  fi

  printf '%s\n' "$content" | sed -n "${start},${end}p"
}

get_blame_authors() {
  local repo_dir="$1"
  local commit="$2"
  local path="$3"
  local start="$4"
  local end="$5"
  local branch="$6"
  local ref=""

  if [[ ! -d "$repo_dir/.git" ]]; then
    return 1
  fi

  if [[ -n "$commit" ]] && git -C "$repo_dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    ref="$commit"
  elif git -C "$repo_dir" rev-parse -q --verify "origin/$branch" >/dev/null 2>&1; then
    ref="origin/$branch"
  else
    ref="HEAD"
  fi

  if ! git -C "$repo_dir" cat-file -e "$ref:$path" 2>/dev/null; then
    return 1
  fi

  REPO_DIR="$repo_dir" REF="$ref" PATH_FILE="$path" START="$start" END="$end" python3 - <<'PY'
import os
import subprocess
from collections import Counter

repo = os.environ["REPO_DIR"]
ref = os.environ["REF"]
path = os.environ["PATH_FILE"]
start = os.environ["START"]
end = os.environ["END"]

cmd = [
    "git", "-C", repo, "blame",
    "--line-porcelain",
    "-L", f"{start},{end}",
    ref, "--", path
]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if res.returncode != 0:
    raise SystemExit(1)

counts = Counter()
names = {}
current_name = ""
current_email = ""

for line in res.stdout.splitlines():
    if line.startswith("author "):
        current_name = line[len("author "):].strip()
    elif line.startswith("author-mail "):
        current_email = line[len("author-mail "):].strip().strip("<>")
    elif line.startswith("\t"):
        key = (current_email or current_name).strip()
        if key:
            counts[key] += 1
            names[key] = (current_name.strip(), current_email.strip())
        current_name = ""
        current_email = ""

for key, count in counts.most_common():
    name, email = names.get(key, ("", ""))
    print(f"{name}\t{email}\t{count}")
PY
}

lookup_lark_id() {
  local email="$1"
  local name="$2"
  local map_path="${LARK_USER_MAP:-$ROOT_DIR/config/lark_user_map.tsv}"

  if [[ ! -f "$map_path" ]]; then
    return 1
  fi

  EMAIL="$email" NAME="$name" MAP_PATH="$map_path" python3 - <<'PY'
import os

email = (os.environ.get("EMAIL") or "").strip().lower()
name = (os.environ.get("NAME") or "").strip().lower()
path = os.environ["MAP_PATH"]

with open(path, "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        git_key = parts[0].strip().lower()
        lark_id = parts[1].strip()
        if not lark_id:
            continue
        if email and email == git_key:
            print(lark_id)
            raise SystemExit(0)
        if name and name == git_key:
            print(lark_id)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

format_mention_line() {
  local authors_tsv="$1"
  local max_mentions="${LARK_MENTION_MAX:-3}"
  local mentions=()
  local count=0

  while IFS=$'\t' read -r author_name author_email author_lines; do
    [[ -z "$author_name" && -z "$author_email" ]] && continue
    if [[ "$count" -ge "$max_mentions" ]]; then
      break
    fi
    lark_id="$(lookup_lark_id "$author_email" "$author_name" || true)"
    if [[ -n "$lark_id" ]]; then
      mentions+=("<at id=${lark_id}></at>")
    else
      display="$author_name"
      if [[ -z "$display" ]]; then
        display="$author_email"
      fi
      if [[ -n "$author_email" && "$author_email" != "$display" ]]; then
        display="$display ($author_email)"
      fi
      if [[ -n "$display" ]]; then
        mentions+=("@${display}")
      fi
    fi
    count=$((count + 1))
  done <<< "$authors_tsv"

  if [[ "${#mentions[@]}" -eq 0 ]]; then
    return 1
  fi

  local joined=""
  local mention=""
  for mention in "${mentions[@]}"; do
    if [[ -z "$joined" ]]; then
      joined="$mention"
    else
      joined="$joined, $mention"
    fi
  done
  printf '责任人: %s' "$joined"
}

code_lang() {
  local path="$1"
  local ext="${path##*.}"

  case "$ext" in
    dart) echo "dart" ;;
    js) echo "javascript" ;;
    jsx) echo "javascript" ;;
    ts) echo "typescript" ;;
    tsx) echo "typescript" ;;
    py) echo "python" ;;
    go) echo "go" ;;
    java) echo "java" ;;
    kt) echo "kotlin" ;;
    swift) echo "swift" ;;
    rb) echo "ruby" ;;
    php) echo "php" ;;
    c) echo "c" ;;
    cc|cpp|cxx|hpp|hxx|hh) echo "cpp" ;;
    h) echo "c" ;;
    cs) echo "c_sharp" ;;
    m) echo "objective_c" ;;
    json) echo "json" ;;
    yml|yaml) echo "yaml" ;;
    sh|bash|zsh) echo "bash" ;;
    sql) echo "sql" ;;
    md) echo "markdown" ;;
    toml) echo "toml" ;;
    xml) echo "xml" ;;
    html|htm) echo "html" ;;
    css) echo "css" ;;
    scss) echo "scss" ;;
    *) echo "plain_text" ;;
  esac
}

get_review_text() {
  local gh_repo="$1"
  local pr_number="$2"
  local pr_json

  pr_json="$(gh pr view --repo "$gh_repo" "$pr_number" --json comments,reviews)"

  CODEX_REVIEW_AUTHOR="${CODEX_REVIEW_AUTHOR:-}" CODEX_PROMPT="${CODEX_PROMPT:-}" PR_JSON="$pr_json" \
  python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("PR_JSON", "")
if not raw.strip():
    sys.exit(0)

data = json.loads(raw)
author = os.environ.get("CODEX_REVIEW_AUTHOR") or ""
prompt = os.environ.get("CODEX_PROMPT") or ""

comments = data.get("comments") or []
reviews = data.get("reviews") or []

def body_text(item):
    return item.get("body") if isinstance(item, dict) else None

texts = []
if author:
    for item in comments:
        if (item.get("author") or {}).get("login") == author:
            text = body_text(item)
            if text:
                texts.append(text)
    for item in reviews:
        if (item.get("author") or {}).get("login") == author:
            text = body_text(item)
            if text:
                texts.append(text)
else:
    for item in comments:
        text = body_text(item)
        if not text:
            continue
        if prompt and prompt in text:
            continue
        texts.append(text)
    for item in reviews:
        text = body_text(item)
        if text:
            texts.append(text)

print("\n".join(texts))
PY
}

summarize_review_with_ai() {
  local repo="$1"
  local branch="$2"
  local pr_number="$3"
  local review_text="$4"
  local location="$5"

  if [[ -z "${CODEX_SUMMARY_API:-}" || -z "${CODEX_SUMMARY_TOKEN:-}" ]]; then
    return 1
  fi

  REPO_NAME="$repo" BRANCH_NAME="$branch" PR_NUMBER="$pr_number" REVIEW_TEXT="$review_text" LOCATION="$location" \
  CODEX_SUMMARY_API="$CODEX_SUMMARY_API" CODEX_SUMMARY_TOKEN="$CODEX_SUMMARY_TOKEN" CODEX_SUMMARY_MODEL="${CODEX_SUMMARY_MODEL:-gpt-4o-mini}" \
  python3 - <<'PY'
import json
import os
import sys
import urllib.request
import urllib.error
import re

repo = os.environ["REPO_NAME"]
branch = os.environ["BRANCH_NAME"]
pr_number = os.environ["PR_NUMBER"]
api = os.environ["CODEX_SUMMARY_API"]
token = os.environ["CODEX_SUMMARY_TOKEN"]
model = os.environ.get("CODEX_SUMMARY_MODEL", "gpt-4o-mini")
review_text = os.environ.get("REVIEW_TEXT", "").strip()
location = os.environ.get("LOCATION", "").strip()

def normalize(text: str) -> str:
    text = re.sub(r"<details>.*?</details>", "", text, flags=re.S)
    text = re.sub(r"(?mi)^To use Codex here,.*$", "", text)
    text = re.sub(
        r"To use Codex here, https://chatgpt\\.com/codex/settings/connectors\\.?\\s*",
        "",
        text,
    )
    def repl(m):
        path = m.group("path")
        lines = m.group("lines").replace("L", "")
        return f"{path}:{lines}"
    text = re.sub(
        r"https?://github.com/[^\\s)]+/blob/[^/]+/(?P<path>[^#\\s)]+)#(?P<lines>L\\d+(?:-L\\d+)?)",
        repl,
        text,
    )
    text = text.replace("P0 Badge", "P0").replace("P1 Badge", "P1")
    text = re.sub(r"https?://\\S+", "", text)
    return text.strip()

normalized = normalize(review_text)
has_severity = bool(re.search(r"\\bP[01]\\b", normalized))

system_prompt = """你是代码审计摘要器。请严格输出 JSON（不要额外文字），格式如下：
{
  "issues": [
    {"severity": "P0|P1", "summary": "简短中文概述", "suggestion": "简短中文建议"}
  ]
}
要求：
- 只输出中文，summary/suggestion 不要包含 URL 或 Markdown 链接
- summary/suggestion 不要输出代码或尖括号内容
- 不要输出 PR 编号或链接
- 如果原始审查没有明确 P0/P1，则输出 {"issues": []}
- summary/suggestion 各不超过 50 字"""

user_prompt = f"仓库: {repo}\n分支: {branch}\n位置: {location or '未知'}\n原始审查内容:\n{normalized}"

if not normalized:
    print(json.dumps({"issues": []}))
    sys.exit(0)

payload = {
    "model": model,
    "temperature": 0.2,
    "max_tokens": 600,
    "messages": [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ],
}

req = urllib.request.Request(
    api,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "Authorization": token},
)

try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
except Exception:
    sys.exit(1)

content = (
    data.get("choices", [{}])[0]
    .get("message", {})
    .get("content", "")
    .strip()
)

if not content:
    sys.exit(1)

try:
    parsed = json.loads(content)
except Exception:
    sys.exit(1)

issues = parsed.get("issues") or []
if has_severity and not issues:
    sys.exit(1)

for issue in issues:
    severity = (issue.get("severity") or "").strip().upper()
    summary = (issue.get("summary") or "").strip()
    suggestion = (issue.get("suggestion") or "").strip()
    if not severity or not summary:
        continue
    print(f"{severity}\t{summary}\t{suggestion}")
PY
}

normalize_review_text() {
  local review_text="$1"

  REVIEW_TEXT="$review_text" python3 - <<'PY'
import os
import re

text = os.environ.get("REVIEW_TEXT", "")
if not text.strip():
    raise SystemExit(0)

text = re.sub(r"<details>.*?</details>", "", text, flags=re.S)
text = re.sub(r"(?mi)^To use Codex here,.*$", "", text)
text = re.sub(
    r"To use Codex here, https://chatgpt\\.com/codex/settings/connectors\\.?\\s*",
    "",
    text,
)

def repl(m):
    path = m.group("path")
    lines = m.group("lines").replace("L", "")
    return f"{path}:{lines}"

text = re.sub(
    r"https?://github.com/[^\\s)]+/blob/[^/]+/(?P<path>[^#\\s)]+)#(?P<lines>L\\d+(?:-L\\d+)?)",
    repl,
    text,
)
text = re.sub(r"https?://\\S+", "", text)
print(text.strip())
PY
}

fallback_summary() {
  local repo="$1"
  local branch="$2"
  local pr_number="$3"
  local review_text="$4"
  local issues
  local first_line
  local severity=""
  local cleaned=""

  issues="$(printf '%s\n' "$review_text" | grep -E 'P0|P1' | head -n 5 || true)"
  if [[ -n "$issues" ]]; then
    first_line="$(printf '%s\n' "$issues" | head -n 1)"
    if [[ "$first_line" == *P0* ]]; then
      severity="P0"
    else
      severity="P1"
    fi
    cleaned="$(printf '%s' "$first_line" | strip_urls | sed -E 's/<[^>]+>//g; s/\\*\\*//g; s/!\\[[^]]*\\]\\([^)]*\\)//g')"
    printf '%s\t%s\t%s\n' "$severity" "$cleaned" ""
  else
    printf '%s\t%s\t%s\n' "NONE" "无 P0/P1 风险或审查未完成" ""
  fi
}

build_run_file_from_prs() {
  local report_date="$1"
  local gitlab_path branch gh_repo branch_slug head_branch pr_number pr_url

  : > "$RUN_FILE"

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line
    line="$(strip_comment "$raw")"
    line="$(printf '%s' "$line" | awk '{$1=$1; print}')"
    [[ -z "$line" ]] && continue

    gitlab_path="${line%@*}"
    branch="${line#*@}"
    if [[ "$gitlab_path" == "$branch" || -z "$branch" ]]; then
      branch="$DEFAULT_BRANCH"
    fi

    gh_repo="$(github_repo "$gitlab_path")"
    branch_slug="${branch//\//-}"
    head_branch="audit/head/$report_date-$branch_slug"

    pr_number="$(gh pr list --repo "$gh_repo" --head "$head_branch" --state all --json number --jq '.[0].number // empty')"
    if [[ -z "$pr_number" ]]; then
      continue
    fi

    pr_url="$(gh pr view --repo "$gh_repo" "$pr_number" --json url --jq '.url')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$gitlab_path" "$branch" "$gh_repo" "$pr_number" "$pr_url" >> "$RUN_FILE"
  done < "$ROOT_DIR/config/repos.txt"
}

if [[ ! -s "$RUN_FILE" ]]; then
  build_run_file_from_prs "$REPORT_DATE"
fi

build_payload() {
  local title="$1"
  local content="$2"

  TITLE="$title" REPORT_CONTENT="$content" python3 - <<'PY'
import json
import os
import sys

title = os.environ["TITLE"]
content = os.environ.get("REPORT_CONTENT", "").strip() or "暂无审计结果。"
message_type = os.environ.get("LARK_MESSAGE_TYPE", "card_v2").strip()

def build_post_payload(title, content):
    lines = content.splitlines()
    elements = []
    in_code = False
    code_buf = []
    fence = chr(96) * 3

    for line in lines:
        stripped = line.strip()
        if stripped.startswith(fence):
            if in_code:
                code_text = "\n".join(code_buf).rstrip("\n")
                if code_text:
                    elements.append([{"tag": "code", "text": code_text}])
                code_buf = []
                in_code = False
            else:
                in_code = True
            continue

        if in_code:
            code_buf.append(line)
            continue

        if not line.strip():
            elements.append([{"tag": "text", "text": " "}])
            continue

        elements.append([{"tag": "text", "text": line}])

    if in_code and code_buf:
        elements.append([{"tag": "code", "text": "\n".join(code_buf).rstrip("\n")}])

    return {
        "msg_type": "post",
        "content": {
            "post": {
                "zh_cn": {
                    "title": title,
                    "content": elements,
                }
            }
        },
    }

def build_card_v2_payload(title, content):
    content = content.strip() or "暂无审计结果。"
    return {
        "msg_type": "interactive",
        "card": {
            "schema": "2.0",
            "config": {"wide_screen_mode": True},
            "header": {
                "title": {"tag": "plain_text", "content": title},
                "template": "blue",
            },
            "body": {
                "elements": [
                    {"tag": "markdown", "content": content}
                ]
            },
        },
    }

if message_type == "post":
    payload = build_post_payload(title, content)
elif message_type in ("card", "card_v2", "interactive_v2"):
    payload = build_card_v2_payload(title, content)
else:
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
}

use_rich_tags=0
case "${LARK_MESSAGE_TYPE:-card_v2}" in
  card|card_v2|interactive_v2) use_rich_tags=1 ;;
esac

sent_any=0
if [[ -s "$RUN_FILE" ]]; then
  while IFS=$'\t' read -r gitlab_path branch gh_repo pr_number pr_url; do
    [[ -z "$gitlab_path" ]] && continue
    if [[ -n "$TARGET_ENTRY" ]]; then
      target_path="${TARGET_ENTRY%@*}"
      target_branch="${TARGET_ENTRY#*@}"
      if [[ "$target_path" == "$target_branch" || -z "$target_branch" ]]; then
        target_branch="$DEFAULT_BRANCH"
      fi
      if [[ "$gitlab_path" != "$target_path" || "$branch" != "$target_branch" ]]; then
        continue
      fi
    fi

    if report_already_sent "$gh_repo" "$pr_number"; then
      log "已发送日报，跳过：$gitlab_path@$branch"
      continue
    fi

    review_text="$(get_review_text "$gh_repo" "$pr_number")"
    if [[ -z "$(printf '%s' "$review_text" | tr -d '[:space:]')" ]]; then
      log "未获取到 review，跳过发送：$gitlab_path@$branch"
      continue
    fi

    if codex_setup_required "$review_text"; then
      log "检测到 Codex 未授权提示，重新触发审查并延后发送：$gitlab_path@$branch"
      if schedule_retry "$gitlab_path" "$branch" "$gh_repo" "$pr_number"; then
        trigger_codex_review "$gh_repo" "$pr_number"
      fi
      continue
    fi

    location_info="$(extract_location "$review_text")"
    location=""
    snippet=""
    path=""
    mention_line=""
    if [[ -n "$location_info" ]]; then
      read -r commit path start end <<< "$location_info"
      location="${path}:${start}-${end}"
      repo_path="$(repo_dir "$gh_repo")"
      snippet="$(get_code_snippet "$repo_path" "$commit" "$path" "$start" "$end" "$branch" || true)"
      authors_tsv="$(get_blame_authors "$repo_path" "$commit" "$path" "$start" "$end" "$branch" || true)"
      if [[ -n "$authors_tsv" ]]; then
        mention_line="$(format_mention_line "$authors_tsv" || true)"
      fi
    fi

    content=""
    summary_lines=""
    if summary_lines="$(summarize_review_with_ai "$gitlab_path" "$branch" "$pr_number" "$review_text" "$location" 2>/dev/null)"; then
      if [[ -n "$summary_lines" ]]; then
        while IFS=$'\t' read -r severity summary suggestion; do
          [[ -z "$severity" || "$severity" == "NONE" ]] && continue
          if [[ "$severity" == "P0" ]]; then
            if [[ "$use_rich_tags" -eq 1 ]]; then
              line="- <text_tag color='red'>P0</text_tag> $summary"
            else
              line="- [P0] $summary"
            fi
          else
            if [[ "$use_rich_tags" -eq 1 ]]; then
              line="- <text_tag color='orange'>P1</text_tag> $summary"
            else
              line="- [P1] $summary"
            fi
          fi
          if [[ -n "$location" || -n "$suggestion" ]]; then
            line+="（"
            if [[ -n "$location" ]]; then
              line+="位置: $location"
            fi
            if [[ -n "$suggestion" ]]; then
              if [[ -n "$location" ]]; then
                line+="，"
              fi
              line+="建议: $suggestion"
            fi
            line+="）"
          fi
          content+="$line"$'\n'
        done <<< "$summary_lines"
      fi
    fi

    if [[ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]]; then
      content="$(normalize_review_text "$review_text")"
    fi

    if [[ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]]; then
      log "审查内容为空，跳过发送：$gitlab_path@$branch"
      continue
    fi

    if [[ -n "$mention_line" ]]; then
      content="$mention_line"$'\n\n'"$content"
    fi

    if [[ -n "$snippet" ]]; then
      lang="$(code_lang "$path")"
      content+=$'\n'"**代码片段：**"$'\n'
      content+='```'"$lang"$'\n'
      content+="$snippet"$'\n'
      content+='```'$'\n'
    fi

    title="每日代码审查报告（${REPORT_DATE}） - ${gitlab_path}@${branch}"
    payload="$(build_payload "$title" "$content")"

    repo_slug="${gitlab_path//\//_}-${branch//\//-}"
    REPORT_TEXT_FILE="$RUN_DIR/report-$REPORT_DATE-$repo_slug.txt"
    REPORT_PAYLOAD_FILE="$RUN_DIR/report-$REPORT_DATE-$repo_slug.json"
    printf '%s' "$content" > "$REPORT_TEXT_FILE"
    printf '%s' "$payload" > "$REPORT_PAYLOAD_FILE"

    if [[ "${LARK_DRY_RUN:-0}" == "1" ]]; then
      log "DRY_RUN=1，已生成报告：$REPORT_TEXT_FILE"
      log "DRY_RUN=1，已生成 payload：$REPORT_PAYLOAD_FILE"
      cat "$REPORT_TEXT_FILE"
      sent_any=1
      continue
    fi

    if [[ -z "$LARK_WEBHOOK_URL" ]]; then
      die "LARK_WEBHOOK_URL 为空"
    fi

    http_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "$payload" "$LARK_WEBHOOK_URL")"
    if [[ "$http_code" != "200" ]]; then
      log "Lark 发送失败（HTTP $http_code），跳过标记：$gitlab_path@$branch"
      continue
    fi
    post_report_comment "$gh_repo" "$pr_number" "$content"
    sent_any=1
  done < "$RUN_FILE"
fi

if [[ "$sent_any" -eq 0 ]]; then
  log "无审查结果，跳过发送"
  exit 0
fi
