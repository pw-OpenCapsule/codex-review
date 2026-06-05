#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
load_settings "$ROOT_DIR"

ensure_dirs

usage() {
  cat <<'EOF'
Usage: send_lark_report.sh [REPORT_DATE] [--dry|--dry-run|-n] [--force|-f]
  REPORT_DATE           指定报告日期（默认今天）
  --dry, --dry-run, -n   发送到测试 webhook；Lark Base 只 dry-run
  --force, -f            保留兼容参数；本地 artifact 模式不会写 PR 标记
EOF
}

DATE_INPUT=""
LARK_DRY_RUN="${LARK_DRY_RUN:-0}"
FORCE_RESEND="${FORCE_RESEND:-0}"

for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run|-n)
      LARK_DRY_RUN=1
      ;;
    --force|-f)
      FORCE_RESEND=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$DATE_INPUT" ]]; then
        DATE_INPUT="$arg"
      else
        die "未知参数：$arg"
      fi
      ;;
  esac
done

date_days_ago() {
  local days="$1"

  if TZ="$TZ" date -d "$days day ago" +%F >/dev/null 2>&1; then
    TZ="$TZ" date -d "$days day ago" +%F
  else
    TZ="$TZ" date -v-"${days}"d +%F
  fi
}

TODAY="$(TZ="$TZ" date +%F)"
TODAY_DOW="$(TZ="$TZ" date +%u)"
TARGET_ENTRY="${RETRY_ONLY:-}"
ALLOW_ANY_DATE=0
REPORT_DATES=()
REPO_KEYS=()
REPO_CADENCES=()

if [[ -n "$DATE_INPUT" ]]; then
  REPORT_DATES=("$DATE_INPUT")
  ALLOW_ANY_DATE=1
elif [[ "$TODAY_DOW" -eq 1 ]]; then
  REPORT_DATES=("$(date_days_ago 2)" "$(date_days_ago 1)" "$TODAY")
else
  REPORT_DATES=("$TODAY")
fi

set_repo_cadence() {
  local key="$1"
  local cadence="$2"
  local i

  for i in "${!REPO_KEYS[@]}"; do
    if [[ "${REPO_KEYS[$i]}" == "$key" ]]; then
      REPO_CADENCES[$i]="$cadence"
      return 0
    fi
  done

  REPO_KEYS+=("$key")
  REPO_CADENCES+=("$cadence")
}

load_repo_cadences() {
  local raw parsed repo_spec cadence_raw cadence gitlab_path branch
  REPO_KEYS=()
  REPO_CADENCES=()

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    parsed="$(parse_repo_line "$raw" || true)"
    [[ -z "$parsed" ]] && continue
    IFS=$'\t' read -r repo_spec cadence_raw <<< "$parsed"

    gitlab_path="${repo_spec%@*}"
    branch="${repo_spec#*@}"
    if [[ "$gitlab_path" == "$branch" || -z "$branch" ]]; then
      branch="$DEFAULT_BRANCH"
    fi

    if ! cadence="$(normalize_cadence "$cadence_raw")"; then
      log "无效审计频率，默认每周：$repo_spec $cadence_raw"
      cadence="weekly"
    fi

    set_repo_cadence "$gitlab_path@$branch" "$cadence"
  done < "$REPOS_FILE"
}

repo_cadence_for() {
  local gitlab_path="$1"
  local branch="$2"
  local key="${gitlab_path}@${branch}"
  local cadence=""
  local i

  for i in "${!REPO_KEYS[@]}"; do
    if [[ "${REPO_KEYS[$i]}" == "$key" ]]; then
      cadence="${REPO_CADENCES[$i]}"
      break
    fi
  done

  if [[ -z "$cadence" ]]; then
    cadence="weekly"
  fi

  printf '%s' "$cadence"
}

should_send_report_date() {
  local report_date="$1"

  if (( ALLOW_ANY_DATE )); then
    return 0
  fi

  if [[ "$report_date" == "$TODAY" ]]; then
    return 0
  fi

  if [[ "$TODAY_DOW" -eq 1 ]]; then
    local saturday sunday
    saturday="$(date_days_ago 2)"
    sunday="$(date_days_ago 1)"
    [[ "$report_date" == "$saturday" || "$report_date" == "$sunday" ]]
    return
  fi

  return 1
}

resolve_lark_webhook() {
  if [[ "${LARK_DRY_RUN:-0}" == "1" ]]; then
    if [[ -z "${LARK_WEBHOOK_URL_DRY:-}" ]]; then
      die "LARK_WEBHOOK_URL_DRY 为空"
    fi
    printf '%s' "$LARK_WEBHOOK_URL_DRY"
    return 0
  fi

  if [[ -z "${LARK_WEBHOOK_URL:-}" ]]; then
    die "LARK_WEBHOOK_URL 为空"
  fi
  printf '%s' "$LARK_WEBHOOK_URL"
}

check_lark_response() {
  local body="$1"

  RESPONSE_BODY="$body" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("RESPONSE_BODY", "").strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
code = data.get("code")
if code is None:
    code = data.get("StatusCode")
if code is None:
    sys.exit(0)
try:
    code = int(code)
except Exception:
    sys.exit(1)
sys.exit(0 if code == 0 else 1)
PY
}

build_payload() {
  local title="$1"
  local content="$2"

  TITLE="$title" REPORT_CONTENT="$content" python3 - <<'PY'
import json
import os
import re

title = os.environ["TITLE"]
content = os.environ.get("REPORT_CONTENT", "").strip() or "暂无审计结果。"
message_type = os.environ.get("LARK_MESSAGE_TYPE", "card_v2").strip()


def build_post_payload(title, content):
    elements = []
    for line in content.splitlines():
        elements.append([{"tag": "text", "text": line or " "}])
    return {
        "msg_type": "post",
        "content": {"post": {"zh_cn": {"title": title, "content": elements}}},
    }


def build_card_payload(title, content):
    date = ""
    repo = ""
    match = re.match(r"^(.+?)代码审查报告（([^）]+)）\s*-\s*(.+)$", title)
    if match:
        date = match.group(2).strip()
        repo = match.group(3).strip()

    issue_count = len(re.findall(r"^- ", content, flags=re.M))
    sev_matches = [m.group(0) for m in re.finditer(r"\bP[0-5]\b", content)]
    max_sev = min(sev_matches, key=lambda item: int(item[1])) if sev_matches else ""
    color = {
        "P0": "red",
        "P1": "orange",
        "P2": "yellow",
        "P3": "blue",
        "P4": "green",
        "P5": "neutral",
    }.get(max_sev, "blue")

    overview = []
    if repo:
        overview.append(f"**仓库**：`{repo}`")
    if date:
        overview.append(f"**日期**：{date}")
    if issue_count:
        overview.append(f"**风险**：<text_tag color='{color}'>{issue_count} 项</text_tag>")

    elements = []
    if overview:
        elements.append({"tag": "markdown", "content": "\n".join(overview), "text_size": "normal"})
        elements.append({"tag": "hr"})
    elements.append({"tag": "markdown", "content": content})
    return {
        "msg_type": "interactive",
        "card": {
            "schema": "2.0",
            "config": {"wide_screen_mode": True},
            "header": {"title": {"tag": "plain_text", "content": title}, "template": "blue"},
            "body": {"elements": elements},
        },
    }


if message_type == "post":
    payload = build_post_payload(title, content)
else:
    payload = build_card_payload(title, content)
print(json.dumps(payload))
PY
}

use_rich_tags=0
case "${LARK_MESSAGE_TYPE:-card_v2}" in
  card|card_v2|interactive_v2) use_rich_tags=1 ;;
esac

render_local_artifact_content() {
  local artifact_json="$1"
  local use_rich="$2"

  ARTIFACT_JSON="$artifact_json" USE_RICH_TAGS="$use_rich" python3 - <<'PY'
import json
import os
import sys

path = os.environ["ARTIFACT_JSON"]
use_rich = os.environ.get("USE_RICH_TAGS") == "1"
data = json.load(open(path, encoding="utf-8"))
issues = data.get("issues") or []
if not issues:
    sys.exit(2)

colors = {"P0": "red", "P1": "orange", "P2": "yellow", "P3": "blue", "P4": "green", "P5": "neutral"}
lines = ["【发现】", ""]
for issue in issues:
    sev = (issue.get("severity") or "P5").upper()
    summary = issue.get("summary_zh") or issue.get("summary") or ""
    file = issue.get("file") or ""
    start = issue.get("line_start") or 0
    end = issue.get("line_end") or start
    location = file
    if file and start:
        location = f"{file}:{start}"
        if end and end != start:
            location += f"-{end}"
    label = f"<text_tag color='{colors.get(sev, 'neutral')}'>{sev}</text_tag>" if use_rich else f"[{sev}]"
    line = f"- {label} {summary}"
    if location:
        line += f"（位置: {location}）"
    owner = issue.get("owner_lark_id") or issue.get("lark_owner") or ""
    if owner:
        line += f"（疑似责任人：<at id={owner}></at>）"
    lines.append(line)
    evidence = issue.get("evidence") or ""
    if evidence:
        lines.append(f"  证据：{evidence}")
print("\n".join(lines))
PY
}

upsert_lark_base_from_artifact() {
  local artifact_json="$1"

  if [[ "${LARK_BASE_ENABLED:-0}" != "1" ]]; then
    return 0
  fi

  local dry_arg=()
  if [[ "${LARK_DRY_RUN:-0}" == "1" ]]; then
    dry_arg=(--dry-run)
  fi

  if python3 "$SCRIPT_DIR/lib/lark_base_issue.py" --artifact "$artifact_json" "${dry_arg[@]}" \
      >>"$RUN_DIR/lark-base-$REPORT_DATE.log" 2>&1; then
    log "Lark Base 已处理：$artifact_json"
  else
    log "Lark Base 写入失败：${artifact_json}（详见 ${RUN_DIR}/lark-base-${REPORT_DATE}.log）"
  fi
}

process_local_artifact_entry() {
  local report_date="$1"
  local gitlab_path="$2"
  local branch="$3"
  local gh_repo="$4"
  local base_sha="$5"
  local head_sha="$6"
  local artifact_json="$7"
  local artifact_md="$8"
  local cadence report_label report_marker title content payload webhook_url response http_code body
  local repo_slug report_text_file report_payload_file

  [[ -z "$gh_repo" ]] && gh_repo="$(github_repo "$gitlab_path")"
  [[ -z "$artifact_json" ]] && return 1

  if [[ ! -f "$artifact_json" ]]; then
    log "本地 review artifact 不存在，跳过：$artifact_json"
    return 1
  fi

  cadence="$(repo_cadence_for "$gitlab_path" "$branch")"
  report_label="$(cadence_title_label "$cadence")"
  report_marker="$(cadence_report_label "$cadence")"

  if [[ "$cadence" == "daily" && "$TODAY_DOW" -ge 6 && "$report_date" == "$TODAY" ]]; then
    log "周末日报延后到周一发送：${gitlab_path}@${branch}"
    return 0
  fi

  if ! content="$(render_local_artifact_content "$artifact_json" "$use_rich_tags")"; then
    log "审查无风险项，跳过发送：${gitlab_path}@${branch}"
    return 0
  fi

  if [[ -n "${REVIEW_DASHBOARD_URL:-}" ]]; then
    content+=$'\n<br>\n<br>\n'
    content+="Review 状态页：${REVIEW_DASHBOARD_URL}"
  fi

  title="${report_label}代码审查报告（${report_date}） - ${gitlab_path}@${branch}"
  payload="$(build_payload "$title" "$content")"

  repo_slug="${gitlab_path//\//_}-${branch//\//-}"
  report_text_file="$RUN_DIR/report-$report_date-$repo_slug.txt"
  report_payload_file="$RUN_DIR/report-$report_date-$repo_slug.json"
  printf '%s' "$content" > "$report_text_file"
  printf '%s' "$payload" > "$report_payload_file"

  if [[ "${LARK_DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN=1，已生成报告：$report_text_file"
    log "DRY_RUN=1，已生成 payload：$report_payload_file"
    cat "$report_text_file"
  fi

  webhook_url="$(resolve_lark_webhook)"
  if [[ "${LARK_DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN=1，使用测试 webhook 发送"
  fi

  response="$(curl -s -X POST -H 'Content-Type: application/json' -d "$payload" -w $'\n%{http_code}' "$webhook_url")"
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "$http_code" != "200" ]]; then
    log "Lark 发送失败（HTTP ${http_code}），跳过：${gitlab_path}@${branch}"
    [[ -n "$body" ]] && log "Lark 响应: $body"
    return 1
  fi

  if ! check_lark_response "$body"; then
    log "Lark 返回错误，跳过：${gitlab_path}@${branch}"
    [[ -n "$body" ]] && log "Lark 响应: $body"
    return 1
  fi

  upsert_lark_base_from_artifact "$artifact_json"
  log "已发送${report_marker}：${gitlab_path}@${branch}（${base_sha:0:8}..${head_sha:0:8}）"
  sent_any=1
}

refresh_review_dashboard() {
  if [[ "${AUTO_BUILD_REVIEW_DASHBOARD:-0}" != "1" ]]; then
    return 0
  fi

  if [[ ! -x "$SCRIPT_DIR/build_review_dashboard.sh" ]]; then
    log "状态页脚本不存在或不可执行，跳过刷新"
    return 0
  fi

  local dashboard_days="${REVIEW_DASHBOARD_DAYS:-30}"
  if "$SCRIPT_DIR/build_review_dashboard.sh" --days "$dashboard_days" >/dev/null; then
    log "已刷新 Review 状态页"
  else
    log "Review 状态页刷新失败"
  fi
}

load_repo_cadences

sent_any=0
for REPORT_DATE in "${REPORT_DATES[@]}"; do
  RUN_FILE="$RUN_DIR/run-$REPORT_DATE.tsv"
  if [[ "${LARK_DRY_RUN:-0}" != "1" ]]; then
    if ! should_send_report_date "$REPORT_DATE"; then
      log "报告日期不在发送窗口，跳过发送：$REPORT_DATE"
      continue
    fi
  fi

  if [[ ! -s "$RUN_FILE" ]]; then
    log "无运行记录，跳过：$REPORT_DATE"
    continue
  fi

  while IFS=$'\t' read -r gitlab_path branch gh_repo base_sha head_sha artifact_json artifact_md; do
    [[ -z "$gitlab_path" ]] && continue
    if [[ -z "${artifact_md:-}" ]]; then
      log "run 文件不是本地 artifact 格式，跳过：${gitlab_path}@${branch}"
      continue
    fi

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

    process_local_artifact_entry "$REPORT_DATE" "$gitlab_path" "$branch" "$gh_repo" "$base_sha" "$head_sha" "$artifact_json" "$artifact_md"
  done < "$RUN_FILE"
done

if [[ "$sent_any" -eq 0 ]]; then
  log "无审查结果，跳过发送"
  exit 0
fi

refresh_review_dashboard || true
