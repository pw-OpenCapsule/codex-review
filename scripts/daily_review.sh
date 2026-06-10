#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_TERMINAL_PROMPT=0

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
load_settings "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: daily_review.sh [--dry|--dry-run|-n]
  --dry, --dry-run, -n  只输出计划，不创建 PR 或评论
EOF
}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run|-n)
      DRY_RUN=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$arg"
      ;;
  esac
done

ensure_dirs

TODAY="$(TZ="$TZ" date +%F)"
TODAY_DOW="$(TZ="$TZ" date +%u)"
RUN_FILE_BASE="run-$TODAY"
QUEUE_FILE_BASE="queue-$TODAY"
if (( DRY_RUN )); then
  RUN_FILE="$RUN_DIR/${RUN_FILE_BASE}.dry.tsv"
  RUN_FILE_TMP="$RUN_DIR/${RUN_FILE_BASE}.dry.tmp.tsv"
  QUEUE_FILE="$RUN_DIR/${QUEUE_FILE_BASE}.dry.tsv"
else
  RUN_FILE="$RUN_DIR/${RUN_FILE_BASE}.tsv"
  RUN_FILE_TMP="$RUN_DIR/${RUN_FILE_BASE}.tmp.tsv"
  QUEUE_FILE="$RUN_DIR/${QUEUE_FILE_BASE}.tsv"
fi
RUN_SENT_FILE="$RUN_DIR/run-$TODAY.sent"
REVIEW_RANGE="${REVIEW_RANGE:-yesterday}"
DAILY_REVIEW_RANGE="${DAILY_REVIEW_RANGE:-$REVIEW_RANGE}"
INTERVAL_REVIEW_RANGE="${INTERVAL_REVIEW_RANGE:-incremental}"
WEEKLY_REVIEW_RANGE="${WEEKLY_REVIEW_RANGE:-$REVIEW_RANGE}"
WEEKLY_REVIEW_DOW="${WEEKLY_REVIEW_DOW:-}"
LOG_YESTERDAY_COMMITS="${LOG_YESTERDAY_COMMITS:-1}"
YESTERDAY_LOG_LIMIT="${YESTERDAY_LOG_LIMIT:-20}"

: > "$RUN_FILE_TMP"
: > "$QUEUE_FILE"

if (( DRY_RUN )); then
  log "DRY RUN: 仅模拟执行，不创建 PR/评论"
fi

yesterday_date() {
  if TZ="$TZ" date -d "yesterday" +%F >/dev/null 2>&1; then
    TZ="$TZ" date -d "yesterday" +%F
  else
    TZ="$TZ" date -v-1d +%F
  fi
}

date_days_ago() {
  local days="$1"

  if TZ="$TZ" date -d "$days day ago" +%F >/dev/null 2>&1; then
    TZ="$TZ" date -d "$days day ago" +%F
  else
    TZ="$TZ" date -v-"${days}"d +%F
  fi
}

resolve_date_range() {
  local range_mode="$1"
  local start_date=""
  local end_date=""
  local dow=""

  case "$range_mode" in
    yesterday)
      start_date="$(yesterday_date)"
      end_date="$start_date"
      ;;
    workday)
      dow="$(TZ="$TZ" date +%u)"
      if [[ "$dow" -ge 6 ]]; then
        log "周末跳过审计"
        return 1
      fi
      if [[ "$dow" -eq 1 ]]; then
        start_date="$(date_days_ago 3)"
        end_date="$(date_days_ago 1)"
      else
        start_date="$(date_days_ago 1)"
        end_date="$start_date"
      fi
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s\t%s\n' "$start_date" "$end_date"
}

review_range_for_cadence() {
  local cadence="$1"

  case "$cadence" in
    daily)
      printf '%s' "$DAILY_REVIEW_RANGE"
      ;;
    every3d|every5d)
      printf '%s' "$INTERVAL_REVIEW_RANGE"
      ;;
    weekly)
      printf '%s' "$WEEKLY_REVIEW_RANGE"
      ;;
    *)
      printf '%s' "$REVIEW_RANGE"
      ;;
  esac
}

ensure_weekly_dow() {
  if [[ -z "$WEEKLY_REVIEW_DOW" ]]; then
    return 0
  fi

  if [[ ! "$WEEKLY_REVIEW_DOW" =~ ^[1-7]$ ]]; then
    die "WEEKLY_REVIEW_DOW 无效：$WEEKLY_REVIEW_DOW（应为 1-7，周一=1）"
  fi
}

should_run_cadence() {
  local cadence="$1"
  local gitlab_path="${2:-}"
  local branch="${3:-}"
  local interval_days=""
  local last_file=""
  local last_date=""
  local elapsed=""

  if [[ "${FORCE_REVIEW:-0}" == "1" ]]; then
    return 0
  fi

  case "$cadence" in
    manual)
      return 1
      ;;
    daily)
      return 0
      ;;
    every3d)
      interval_days=3
      ;;
    every5d)
      interval_days=5
      ;;
    weekly)
      if [[ -z "$WEEKLY_REVIEW_DOW" ]]; then
        return 0
      fi

      [[ "$TODAY_DOW" == "$WEEKLY_REVIEW_DOW" ]]
      return
      ;;
    *)
      return 0
      ;;
  esac

  if [[ "$TODAY_DOW" -ge 6 ]]; then
    return 1
  fi

  last_file="$(cadence_state_file "$gitlab_path" "$branch" "$cadence")"
  if [[ ! -f "$last_file" ]]; then
    return 0
  fi

  last_date="$(cat "$last_file")"
  elapsed="$(workdays_between "$last_date" "$TODAY" || printf '')"
  [[ -n "$elapsed" && "$elapsed" -ge "$interval_days" ]]
}

cadence_state_file() {
  local gitlab_path="$1"
  local branch="$2"
  local cadence="$3"
  local key="${gitlab_path//\//__}__${branch//\//__}__${cadence}"
  printf '%s/%s.cadence' "$STATE_DIR" "$key"
}

mark_cadence_checked() {
  local gitlab_path="$1"
  local branch="$2"
  local cadence="$3"

  case "$cadence" in
    every3d|every5d)
      if (( ! DRY_RUN )); then
        printf '%s\n' "$TODAY" > "$(cadence_state_file "$gitlab_path" "$branch" "$cadence")"
      fi
      ;;
  esac
}

workdays_between() {
  local start="$1"
  local end="$2"

  START_DATE="$start" END_DATE="$end" TZ_NAME="$TZ" python3 - <<'PY'
import datetime
import os
import sys

try:
    start = datetime.date.fromisoformat(os.environ["START_DATE"])
    end = datetime.date.fromisoformat(os.environ["END_DATE"])
except ValueError:
    raise SystemExit(1)

if end <= start:
    print(0)
    raise SystemExit(0)

days = 0
current = start
while current < end:
    current += datetime.timedelta(days=1)
    if current.weekday() < 5:
        days += 1
print(days)
PY
}

ensure_weekly_dow

resolve_initial_base() {
  local dir="$1"
  local head_sha="$2"
  local initial_ref="$3"
  local base_sha=""

  if base_sha="$(git -C "$dir" rev-parse "$initial_ref" 2>/dev/null)"; then
    printf '%s' "$base_sha"
    return 0
  fi

  base_sha="$(git -C "$dir" rev-list --max-parents=0 "$head_sha" | tail -n 1)"
  printf '%s' "$base_sha"
}

compute_score() {
  local dir="$1"
  local base_sha="$2"
  local head_sha="$3"
  local loc=0
  local risk_files=0
  local adds dels path

  while IFS=$'\t' read -r adds dels path; do
    [[ -z "$path" ]] && continue
    if [[ "$adds" == "-" || "$dels" == "-" ]]; then
      continue
    fi
    loc=$((loc + adds + dels))
    if [[ -n "$HIGH_RISK_DIRS" && "$path" =~ $HIGH_RISK_DIRS ]]; then
      risk_files=$((risk_files + 1))
    fi
  done < <(git -C "$dir" diff --numstat "$base_sha" "$head_sha")

  local loc_score=$(( (loc + LOC_WEIGHT - 1) / LOC_WEIGHT ))
  if (( loc_score > MAX_LOC_SCORE )); then
    loc_score=$MAX_LOC_SCORE
  fi

  local score=$((risk_files * DIR_WEIGHT + loc_score))
  printf '%s\t%s\t%s\n' "$score" "$loc" "$risk_files"
}

tracking_ref_for_branch() {
  local branch="$1"

  if [[ "${SYNC_FROM_GITLAB:-0}" == "1" ]]; then
    printf '%s/%s' "$(gitlab_remote_name)" "$branch"
    return 0
  fi

  printf 'origin/%s' "$branch"
}

prepare_repo() {
  local gh_repo="$1"
  local dir
  dir="$(repo_dir "$gh_repo")"

  if [[ ! -d "$dir/.git" ]]; then
    ensure_gh_auth
    log "正在克隆 $gh_repo"
    git clone "https://github.com/$gh_repo.git" "$dir"
  fi

  git -C "$dir" fetch origin --prune
  printf '%s' "$dir"
}

yesterday_base_sha() {
  local dir="$1"
  local head_sha="$2"
  local yesterday
  local end_ts
  local base_sha

  yesterday="$(yesterday_date)"
  end_ts="${yesterday} 23:59:59"
  base_sha="$(git -C "$dir" rev-list -n 1 --before="$end_ts" "$head_sha" 2>/dev/null || true)"

  if [[ -n "$base_sha" ]]; then
    printf '%s' "$base_sha"
    return 0
  fi

  return 1
}

range_shas_for_dates() {
  local dir="$1"
  local ref="$2"
  local start_date="$3"
  local end_date="$4"
  local start_ts
  local end_ts
  local head_sha
  local base_sha

  start_ts="${start_date} 00:00:00"
  end_ts="${end_date} 23:59:59"

  head_sha="$(git -C "$dir" rev-list -n 1 --before="$end_ts" "$ref" 2>/dev/null || true)"
  if [[ -z "$head_sha" ]]; then
    return 1
  fi

  base_sha="$(git -C "$dir" rev-list -n 1 --before="$start_ts" "$ref" 2>/dev/null || true)"
  if [[ -z "$base_sha" ]]; then
    base_sha="$head_sha"
  fi

  printf '%s\t%s\n' "$base_sha" "$head_sha"
}

log_yesterday_commits() {
  local dir="$1"
  local ref="$2"
  local limit="$3"
  local yesterday
  local start_ts
  local end_ts
  local count
  local log_lines

  if (( limit <= 0 )); then
    return 0
  fi

  yesterday="$(yesterday_date)"
  start_ts="${yesterday} 00:00:00"
  end_ts="${yesterday} 23:59:59"

  count="$(git -C "$dir" rev-list --count --since="$start_ts" --until="$end_ts" "$ref" 2>/dev/null || printf '0')"
  if (( count <= 0 )); then
    return 1
  fi

  log "昨日提交（$count 条，展示前 $limit 条）"
  log_lines="$(git -C "$dir" log --since="$start_ts" --until="$end_ts" --pretty=format:'%h %an %s' "$ref" | head -n "$limit")"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "  - $line"
  done <<< "$log_lines"

  if (( count > limit )); then
    log "  - ... 还有 $((count - limit)) 条"
  fi
}

log_range_commits() {
  local dir="$1"
  local ref="$2"
  local limit="$3"
  local start_date="$4"
  local end_date="$5"
  local label="$6"
  local start_ts
  local end_ts
  local count
  local log_lines

  if (( limit <= 0 )); then
    return 0
  fi

  start_ts="${start_date} 00:00:00"
  end_ts="${end_date} 23:59:59"

  count="$(git -C "$dir" rev-list --count --since="$start_ts" --until="$end_ts" "$ref" 2>/dev/null || printf '0')"
  if (( count <= 0 )); then
    return 1
  fi

  log "${label}（${count} 条，展示前 ${limit} 条）"
  log_lines="$(git -C "$dir" log --since="$start_ts" --until="$end_ts" --pretty=format:'%h %an %s' "$ref" | head -n "$limit")"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "  - $line"
  done <<< "$log_lines"

  if (( count > limit )); then
    log "  - ... 还有 $((count - limit)) 条"
  fi
}

sync_from_gitlab() {
  local dir="$1"
  local gitlab_path="$2"
  local branch="$3"
  local remote
  local url
  local resolved_branch

  if [[ "${SYNC_FROM_GITLAB:-0}" != "1" ]]; then
    SYNC_RESOLVED_BRANCH="$branch"
    return 0
  fi

  remote="$(gitlab_remote_name)"
  url="$(gitlab_repo_url "$gitlab_path")"

  if git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
    git -C "$dir" remote set-url "$remote" "$url"
  else
    git -C "$dir" remote add "$remote" "$url"
  fi

  if ! resolved_branch="$(fetch_gitlab_branch_with_fallback "$dir" "$remote" "$branch")"; then
    log "拉取 GitLab 失败：$gitlab_path@$branch"
    return 1
  fi
  branch="$resolved_branch"
  SYNC_RESOLVED_BRANCH="$branch"

  if (( DRY_RUN )); then
    return 0
  fi

  return 0
}

collect_queue() {
  local gitlab_path branch gh_repo dir head_sha base_sha score loc risk initial_ref

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local parsed repo_spec cadence_raw cadence
    local repo_created=0
    local tracking_ref
    local range_mode range_start_date range_end_date range_output
    parsed="$(parse_repo_line "$raw" || true)"
    [[ -z "$parsed" ]] && continue

    IFS=$'\t' read -r repo_spec cadence_raw <<< "$parsed"
    if ! cadence="$(normalize_cadence "$cadence_raw")"; then
      log "无效审计频率，跳过：$repo_spec $cadence_raw"
      continue
    fi

    gitlab_path="${repo_spec%@*}"
    branch="${repo_spec#*@}"
    if [[ "$gitlab_path" == "$branch" || -z "$branch" ]]; then
      branch="$DEFAULT_BRANCH"
    fi

    if ! should_run_cadence "$cadence" "$gitlab_path" "$branch"; then
      case "$cadence" in
        manual)
          log "$gitlab_path@$branch 为手动审计，跳过"
          ;;
        every3d|every5d)
          log "$gitlab_path@$branch 频率=$cadence 未到工作日间隔，跳过"
          ;;
        weekly)
          log "$gitlab_path@$branch 每周审计仅在周$WEEKLY_REVIEW_DOW 运行，跳过"
          ;;
      esac
      continue
    fi

    range_mode="$(review_range_for_cadence "$cadence")"
    if [[ "$range_mode" == "yesterday" || "$range_mode" == "workday" ]]; then
      if ! range_output="$(resolve_date_range "$range_mode")"; then
        continue
      fi
      read -r range_start_date range_end_date <<< "$range_output"
    fi

    gh_repo="$(github_repo "$gitlab_path")"
    dir="$(prepare_repo "$gh_repo")"

    SYNC_RESOLVED_BRANCH="$branch"
    if ! sync_from_gitlab "$dir" "$gitlab_path" "$branch"; then
      continue
    fi
    branch="$SYNC_RESOLVED_BRANCH"

    tracking_ref="$(tracking_ref_for_branch "$branch")"
    if ! head_sha="$(git -C "$dir" rev-parse "$tracking_ref" 2>/dev/null)"; then
      log "分支不存在，跳过：$gitlab_path@$branch"
      continue
    fi

    initial_ref="${INITIAL_BASE:-}"
    if [[ -z "$initial_ref" ]]; then
      initial_ref="${tracking_ref}~1"
    fi
    initial_ref="${initial_ref//\{branch\}/$branch}"
    if [[ "$tracking_ref" != "origin/$branch" ]]; then
      initial_ref="${initial_ref//origin\/$branch/$tracking_ref}"
    fi

    if [[ "${FORCE_REVIEW:-0}" == "1" ]]; then
      if (( repo_created )); then
        if base_sha="$(yesterday_base_sha "$dir" "$head_sha")"; then
          log "强制审计基线：$gitlab_path@$branch 使用昨日提交 $base_sha"
        else
          base_sha="$(resolve_initial_base "$dir" "$head_sha" "$initial_ref")"
        fi
      else
        base_sha="$(resolve_initial_base "$dir" "$head_sha" "$initial_ref")"
      fi
    elif [[ "$range_mode" == "yesterday" || "$range_mode" == "workday" ]]; then
      if read -r base_sha head_sha < <(range_shas_for_dates "$dir" "$tracking_ref" "$range_start_date" "$range_end_date"); then
        :
      else
        if [[ "$range_mode" == "workday" ]]; then
          log "$gitlab_path@$branch 工作日无提交"
        else
          log "$gitlab_path@$branch 昨日无提交"
        fi
        continue
      fi
    elif [[ -f "$(state_file "$gitlab_path" "$branch")" ]]; then
      base_sha="$(cat "$(state_file "$gitlab_path" "$branch")")"
    else
      if (( repo_created )); then
        if base_sha="$(yesterday_base_sha "$dir" "$head_sha")"; then
          log "新建仓库基线：$gitlab_path@$branch 使用昨日提交 $base_sha"
        else
          base_sha="$(resolve_initial_base "$dir" "$head_sha" "$initial_ref")"
        fi
      else
        base_sha="$(resolve_initial_base "$dir" "$head_sha" "$initial_ref")"
      fi
    fi

    if [[ "$LOG_YESTERDAY_COMMITS" == "1" ]]; then
      if [[ "$range_mode" == "yesterday" ]]; then
        log_yesterday_commits "$dir" "$tracking_ref" "$YESTERDAY_LOG_LIMIT" || true
      elif [[ "$range_mode" == "workday" ]]; then
        log_range_commits "$dir" "$tracking_ref" "$YESTERDAY_LOG_LIMIT" "$range_start_date" "$range_end_date" \
          "工作日提交 (${range_start_date}~${range_end_date})" || true
      fi
    fi

    if [[ "$base_sha" == "$head_sha" ]]; then
      if [[ "$range_mode" == "yesterday" ]]; then
        log "$gitlab_path@$branch 昨日无变更"
      elif [[ "$range_mode" == "workday" ]]; then
        log "$gitlab_path@$branch 工作日无变更"
      else
        log "$gitlab_path@$branch 无变更"
      fi
      mark_cadence_checked "$gitlab_path" "$branch" "$cadence"
      continue
    fi

    read -r score loc risk < <(compute_score "$dir" "$base_sha" "$head_sha")
    log "加入队列 $gitlab_path@$branch 频率=$cadence 评分=$score 行数=$loc 风险文件=$risk"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$score" "$gitlab_path" "$branch" "$base_sha" "$head_sha" "$cadence" >> "$QUEUE_FILE"
done < "$REPOS_FILE"
}

artifact_slug() {
  local gitlab_path="$1"
  local branch="$2"
  printf '%s-%s' "${gitlab_path//\//_}" "${branch//\//-}"
}

run_local_codex_review() {
  local gitlab_path="$1"
  local branch="$2"
  local gh_repo="$3"
  local dir="$4"
  local base_sha="$5"
  local head_sha="$6"
  local cadence="$7"
  local slug artifact_dir artifact_json artifact_md

  slug="$(artifact_slug "$gitlab_path" "$branch")"
  artifact_dir="$RUN_DIR/reviews/$TODAY"
  artifact_json="$artifact_dir/$slug.json"
  artifact_md="$artifact_dir/$slug.md"

  if (( DRY_RUN )); then
    log "DRY RUN: 将用 Codex SDK 本地审查 $gitlab_path@$branch ($base_sha -> $head_sha)"
    return 0
  fi

  if ! python3 "$SCRIPT_DIR/lib/local_codex_review.py" \
      --repo "$gitlab_path" \
      --branch "$branch" \
      --base-sha "$base_sha" \
      --head-sha "$head_sha" \
      --workdir "$dir" \
      --output-json "$artifact_json" \
      --output-markdown "$artifact_md" >/dev/null; then
    log "Codex SDK 审查失败：$gitlab_path@$branch"
    return 1
  fi

  log "Codex SDK 审查完成：$artifact_json"
  printf '%s\n' "$head_sha" > "$(state_file "$gitlab_path" "$branch")"
  mark_cadence_checked "$gitlab_path" "$branch" "$cadence"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$gitlab_path" "$branch" "$gh_repo" "$base_sha" "$head_sha" "$artifact_json" "$artifact_md" \
    >> "$RUN_FILE_TMP"
}

auto_send_report() {
  if (( DRY_RUN )); then
    log "DRY RUN: 跳过发送报告"
    return 0
  fi

  if [[ "${AUTO_SEND_LARK:-0}" != "1" ]]; then
    return 0
  fi

  if [[ -f "$RUN_SENT_FILE" ]]; then
    log "已发送报告，跳过"
    return 0
  fi

  if [[ "$TODAY_DOW" -ge 6 ]]; then
    log "周末日报延后到周一发送"
    return 0
  fi

  if [[ ! -s "$RUN_FILE" ]]; then
    log "无运行记录，跳过发送报告"
    return 0
  fi

  "$SCRIPT_DIR/send_lark_report.sh"
  touch "$RUN_SENT_FILE"
}

process_queue() {
  local count=0
  local score gitlab_path branch base_sha head_sha cadence gh_repo dir

  if [[ ! -s "$QUEUE_FILE" ]]; then
    log "无待处理变更"
    return 0
  fi

  sort -nr "$QUEUE_FILE" > "$QUEUE_FILE.sorted"

  while IFS=$'\t' read -r score gitlab_path branch base_sha head_sha cadence; do
    if (( MAX_REVIEWS_PER_RUN > 0 && count >= MAX_REVIEWS_PER_RUN )); then
      log "达到 MAX_REVIEWS_PER_RUN=$MAX_REVIEWS_PER_RUN 限制"
      break
    fi

    gh_repo="$(github_repo "$gitlab_path")"
    dir="$(repo_dir "$gh_repo")"
    if (( DRY_RUN )); then
      log "DRY RUN: 将本地 SDK 审查 $gitlab_path@$branch ($base_sha -> $head_sha)"
      count=$((count + 1))
      continue
    fi

    if run_local_codex_review "$gitlab_path" "$branch" "$gh_repo" "$dir" "$base_sha" "$head_sha" "$cadence"; then
      count=$((count + 1))
      sleep "$SLEEP_BETWEEN_SECONDS"
    fi
  done < "$QUEUE_FILE.sorted"
}

collect_queue
process_queue
if (( DRY_RUN )); then
  rm -f "$RUN_FILE_TMP"
else
  if [[ -s "$RUN_FILE_TMP" ]]; then
    mv -f "$RUN_FILE_TMP" "$RUN_FILE"
  else
    rm -f "$RUN_FILE_TMP"
    if [[ ! -f "$RUN_FILE" ]]; then
      : > "$RUN_FILE"
    fi
  fi
  auto_send_report
fi
