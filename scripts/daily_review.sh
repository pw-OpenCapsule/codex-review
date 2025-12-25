#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_TERMINAL_PROMPT=0

# shellcheck source=../config/settings.env
source "$ROOT_DIR/config/settings.env"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

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
LOG_YESTERDAY_COMMITS="${LOG_YESTERDAY_COMMITS:-1}"
YESTERDAY_LOG_LIMIT="${YESTERDAY_LOG_LIMIT:-20}"

: > "$RUN_FILE_TMP"
: > "$QUEUE_FILE"

ensure_gh_auth

if (( DRY_RUN )); then
  log "DRY RUN: 仅模拟执行，不创建 PR/评论"
fi

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

  if [[ "${SYNC_FROM_GITLAB:-0}" == "1" && "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s/%s' "$(gitlab_remote_name)" "$branch"
    return 0
  fi

  printf 'origin/%s' "$branch"
}

github_repo_exists() {
  local gh_repo="$1"
  gh repo view "$gh_repo" --json name >/dev/null 2>&1
}

github_repo_visibility_flag() {
  local visibility="${GITHUB_REPO_VISIBILITY:-private}"

  case "$visibility" in
    private|public|internal)
      printf '%s' "--$visibility"
      ;;
    "")
      printf ''
      ;;
    *)
      die "GITHUB_REPO_VISIBILITY 无效：$visibility"
      ;;
  esac
}

create_github_repo() {
  local gh_repo="$1"
  local visibility_flag

  visibility_flag="$(github_repo_visibility_flag)"
  log "创建 GitHub 仓库：$gh_repo"

  if ! gh repo create "$gh_repo" "$visibility_flag" >/dev/null; then
    return 1
  fi

  return 0
}

prepare_repo() {
  local gh_repo="$1"
  local dir
  dir="$(repo_dir "$gh_repo")"

  if [[ ! -d "$dir/.git" ]]; then
    log "正在克隆 $gh_repo"
    git clone "https://github.com/$gh_repo.git" "$dir"
  fi

  git -C "$dir" fetch origin --prune
  printf '%s' "$dir"
}

yesterday_date() {
  if TZ="$TZ" date -d "yesterday" +%F >/dev/null 2>&1; then
    TZ="$TZ" date -d "yesterday" +%F
  else
    TZ="$TZ" date -v-1d +%F
  fi
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

yesterday_range_shas() {
  local dir="$1"
  local ref="$2"
  local yesterday
  local start_ts
  local end_ts
  local head_sha
  local base_sha

  yesterday="$(yesterday_date)"
  start_ts="${yesterday} 00:00:00"
  end_ts="${yesterday} 23:59:59"

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

sync_from_gitlab() {
  local dir="$1"
  local gitlab_path="$2"
  local branch="$3"
  local remote
  local url

  if [[ "${SYNC_FROM_GITLAB:-0}" != "1" ]]; then
    return 0
  fi

  remote="$(gitlab_remote_name)"
  url="$(gitlab_repo_url "$gitlab_path")"

  if git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
    git -C "$dir" remote set-url "$remote" "$url"
  else
    git -C "$dir" remote add "$remote" "$url"
  fi

  if ! git -C "$dir" -c credential.helper= fetch "$remote" "$branch"; then
    log "拉取 GitLab 失败：$gitlab_path@$branch"
    return 1
  fi

  if (( DRY_RUN )); then
    return 0
  fi

  if ! git -C "$dir" push -f origin "$remote/$branch:refs/heads/$branch"; then
    log "推送到 GitHub 失败：$gitlab_path@$branch"
    return 1
  fi

  if ! git -C "$dir" fetch origin "$branch" >/dev/null 2>&1; then
    log "更新 GitHub 远端分支失败：$gitlab_path@$branch"
    return 1
  fi
}

collect_queue() {
  local gitlab_path branch gh_repo dir head_sha base_sha score loc risk initial_ref

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line
    local repo_created=0
    local tracking_ref
    line="$(strip_comment "$raw")"
    line="$(printf '%s' "$line" | awk '{$1=$1; print}')"
    [[ -z "$line" ]] && continue

    gitlab_path="${line%@*}"
    branch="${line#*@}"
    if [[ "$gitlab_path" == "$branch" || -z "$branch" ]]; then
      branch="$DEFAULT_BRANCH"
    fi

    gh_repo="$(github_repo "$gitlab_path")"
    if ! github_repo_exists "$gh_repo"; then
      log "GitHub 仓库不存在，自动创建：$gh_repo"
      if ! create_github_repo "$gh_repo"; then
        log "GitHub 仓库创建失败，跳过：$gh_repo"
        continue
      fi
      repo_created=1
    fi
    dir="$(prepare_repo "$gh_repo")"

    if ! sync_from_gitlab "$dir" "$gitlab_path" "$branch"; then
      continue
    fi

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
    elif [[ "$REVIEW_RANGE" == "yesterday" ]]; then
      if read -r base_sha head_sha < <(yesterday_range_shas "$dir" "$tracking_ref"); then
        :
      else
        log "$gitlab_path@$branch 昨日无提交"
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

    if [[ "$REVIEW_RANGE" == "yesterday" && "$LOG_YESTERDAY_COMMITS" == "1" ]]; then
      log_yesterday_commits "$dir" "$tracking_ref" "$YESTERDAY_LOG_LIMIT" || true
    fi

    if [[ "$base_sha" == "$head_sha" ]]; then
      if [[ "$REVIEW_RANGE" == "yesterday" ]]; then
        log "$gitlab_path@$branch 昨日无变更"
      else
        log "$gitlab_path@$branch 无变更"
      fi
      continue
    fi

    read -r score loc risk < <(compute_score "$dir" "$base_sha" "$head_sha")
    log "加入队列 $gitlab_path@$branch 评分=$score 行数=$loc 风险文件=$risk"
    printf '%s\t%s\t%s\t%s\t%s\n' "$score" "$gitlab_path" "$branch" "$base_sha" "$head_sha" >> "$QUEUE_FILE"
  done < "$ROOT_DIR/config/repos.txt"
}

create_or_find_pr() {
  local gh_repo="$1"
  local dir="$2"
  local base_sha="$3"
  local head_sha="$4"
  local branch="$5"
  local branch_slug="${branch//\//-}"
  local base_branch="audit/base/$TODAY-$branch_slug"
  local head_branch="audit/head/$TODAY-$branch_slug"
  local pr_number=""

  pr_number="$(gh pr list --repo "$gh_repo" --head "$head_branch" --state open --json number --jq '.[0].number // empty')"
  if [[ -n "$pr_number" ]]; then
    printf '%s' "$pr_number"
    return 0
  fi

  local existing_any
  existing_any="$(gh pr list --repo "$gh_repo" --head "$head_branch" --state all --json number --jq '.[0].number // empty')"
  if [[ -n "$existing_any" ]]; then
    printf '%s' "$existing_any"
    return 0
  fi

  git -C "$dir" branch -f "$base_branch" "$base_sha"
  git -C "$dir" branch -f "$head_branch" "$head_sha"
  git -C "$dir" push -f origin "$base_branch" "$head_branch"

  gh pr create \
    --repo "$gh_repo" \
    --base "$base_branch" \
    --head "$head_branch" \
    --title "【每日审计】$TODAY ($branch)" \
    --body "每日审计差异：${base_sha} -> ${head_sha}，分支：${branch}。" \
    >/dev/null

  pr_number="$(gh pr list --repo "$gh_repo" --head "$head_branch" --state open --json number --jq '.[0].number // empty')"
  printf '%s' "$pr_number"
}

ensure_codex_comment() {
  local gh_repo="$1"
  local pr_number="$2"

  if (( DRY_RUN )); then
    log "DRY RUN: 跳过评论 $gh_repo#$pr_number"
    return 0
  fi

  if [[ "${FORCE_COMMENT:-0}" == "1" ]]; then
    gh pr comment --repo "$gh_repo" "$pr_number" --body "$CODEX_PROMPT (re-run $(date +'%F %T'))" >/dev/null
    return 0
  fi

  local already
  already="$(gh pr view --repo "$gh_repo" "$pr_number" --json comments --jq '[.comments[].body | contains("@codex review")] | any')"
  if [[ "$already" == "true" ]]; then
    return 0
  fi

  gh pr comment --repo "$gh_repo" "$pr_number" --body "$CODEX_PROMPT" >/dev/null
}

pr_review_ready() {
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
    sys.exit(1)

data = json.loads(raw)
author = os.environ.get("CODEX_REVIEW_AUTHOR") or ""
prompt = os.environ.get("CODEX_PROMPT") or ""

comments = data.get("comments") or []
reviews = data.get("reviews") or []

def body_text(item):
    return item.get("body") if isinstance(item, dict) else None

ready = False
if author:
    for item in comments:
        if (item.get("author") or {}).get("login") == author:
            ready = True
            break
    if not ready:
        for item in reviews:
            if (item.get("author") or {}).get("login") == author:
                ready = True
                break
else:
    for item in comments:
        text = body_text(item) or ""
        if not text:
            continue
        if prompt and text.startswith(prompt):
            continue
        ready = True
        break
    if not ready:
        for item in reviews:
            text = body_text(item) or ""
            if text:
                ready = True
                break

sys.exit(0 if ready else 1)
PY
}

wait_for_reviews() {
  local run_file="$1"
  local timeout="${REVIEW_WAIT_SECONDS:-0}"
  local interval="${REVIEW_POLL_INTERVAL:-60}"
  local start_ts
  local pending

  if (( timeout <= 0 )); then
    return 0
  fi

  start_ts="$(date +%s)"

  while :; do
    pending=0
    while IFS=$'\t' read -r gitlab_path branch gh_repo pr_number pr_url; do
      [[ -z "$gitlab_path" ]] && continue
      if ! pr_review_ready "$gh_repo" "$pr_number" >/dev/null 2>&1; then
        pending=1
        break
      fi
    done < "$run_file"

    if (( pending == 0 )); then
      return 0
    fi

    if (( $(date +%s) - start_ts >= timeout )); then
      log "等待审查超时，仍发送报告"
      return 1
    fi

    sleep "$interval"
  done
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

  if [[ ! -s "$RUN_FILE" ]]; then
    log "无运行记录，跳过发送报告"
    return 0
  fi

  wait_for_reviews "$RUN_FILE" || true
  "$SCRIPT_DIR/send_lark_report.sh" "$TODAY"
  touch "$RUN_SENT_FILE"
}

process_queue() {
  local count=0
  local score gitlab_path branch base_sha head_sha gh_repo dir pr_number pr_url

  if [[ ! -s "$QUEUE_FILE" ]]; then
    log "无待处理变更"
    return 0
  fi

  sort -nr "$QUEUE_FILE" > "$QUEUE_FILE.sorted"

  while IFS=$'\t' read -r score gitlab_path branch base_sha head_sha; do
    if (( MAX_REVIEWS_PER_RUN > 0 && count >= MAX_REVIEWS_PER_RUN )); then
      log "达到 MAX_REVIEWS_PER_RUN=$MAX_REVIEWS_PER_RUN 限制"
      break
    fi

    gh_repo="$(github_repo "$gitlab_path")"
    dir="$(repo_dir "$gh_repo")"

    if (( DRY_RUN )); then
      local branch_slug head_branch pr_existing
      branch_slug="${branch//\//-}"
      head_branch="audit/head/$TODAY-$branch_slug"
      pr_existing="$(gh pr list --repo "$gh_repo" --head "$head_branch" --state all --json number --jq '.[0].number // empty')"
      if [[ -n "$pr_existing" ]]; then
        pr_url="$(gh pr view --repo "$gh_repo" "$pr_existing" --json url --jq '.url')"
        log "DRY RUN: 复用 PR $pr_url"
      else
        log "DRY RUN: 将创建 PR $gh_repo $branch ($base_sha -> $head_sha)"
      fi
      log "DRY RUN: 将评论 @codex ($gitlab_path@$branch)"
      count=$((count + 1))
      continue
    fi

    pr_number="$(create_or_find_pr "$gh_repo" "$dir" "$base_sha" "$head_sha" "$branch")"
    if [[ -z "$pr_number" ]]; then
      log "创建拉取请求失败：$gitlab_path@$branch"
      continue
    fi

    local pr_state
    pr_state="$(gh pr view --repo "$gh_repo" "$pr_number" --json state --jq '.state')"
    if [[ "$pr_state" != "OPEN" ]]; then
      log "拉取请求 $pr_number 状态为 $pr_state，跳过评论"
      printf '%s\n' "$head_sha" > "$(state_file "$gitlab_path" "$branch")"
      continue
    fi

    ensure_codex_comment "$gh_repo" "$pr_number"
    pr_url="$(gh pr view --repo "$gh_repo" "$pr_number" --json url --jq '.url')"
    log "PR 已创建/复用：$pr_url"

    printf '%s\n' "$head_sha" > "$(state_file "$gitlab_path" "$branch")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$gitlab_path" "$branch" "$gh_repo" "$pr_number" "$pr_url" >> "$RUN_FILE_TMP"

    count=$((count + 1))
    sleep "$SLEEP_BETWEEN_SECONDS"
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
