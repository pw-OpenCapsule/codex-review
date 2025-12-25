#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config/settings.env
source "$ROOT_DIR/config/settings.env"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY_RUN=0
REVIEW_RANGE="${REVIEW_RANGE:-yesterday}"
LOG_YESTERDAY_COMMITS="${LOG_YESTERDAY_COMMITS:-1}"
YESTERDAY_LOG_LIMIT="${YESTERDAY_LOG_LIMIT:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry|--dry-run|-n)
      DRY_RUN=1
      shift
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

ensure_dirs

TODAY="$(TZ="$TZ" date +%F)"
if [[ "$DRY_RUN" == "1" ]]; then
  RUN_FILE="$RUN_DIR/run-$TODAY.dry.tsv"
  QUEUE_FILE="$RUN_DIR/queue-$TODAY.dry.tsv"
else
  RUN_FILE="$RUN_DIR/run-$TODAY.tsv"
  QUEUE_FILE="$RUN_DIR/queue-$TODAY.tsv"
fi

: > "$RUN_FILE"
: > "$QUEUE_FILE"

if ! gh auth status >/dev/null 2>&1; then
  die "gh 未登录"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN=1，仅模拟执行，不创建 PR/评论"
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

yesterday_date() {
  if TZ="$TZ" date -d "yesterday" +%F >/dev/null 2>&1; then
    TZ="$TZ" date -d "yesterday" +%F
  else
    TZ="$TZ" date -v-1d +%F
  fi
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
  local base_sha="$2"
  local head_sha="$3"
  local gitlab_path="$4"
  local branch="$5"
  local limit="$YESTERDAY_LOG_LIMIT"
  local total=0

  if [[ "$LOG_YESTERDAY_COMMITS" != "1" ]]; then
    return 0
  fi

  if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
    limit=20
  fi

  total="$(git -C "$dir" rev-list --count "${base_sha}..${head_sha}" 2>/dev/null || printf '0')"
  if [[ "$total" -le 0 ]]; then
    return 0
  fi

  mapfile -t commits < <(git -C "$dir" log --max-count="$limit" --pretty=format:'%h %an %s' "${base_sha}..${head_sha}")
  for line in "${commits[@]}"; do
    log "昨日提交 $gitlab_path@$branch: $line"
  done
  if (( total > limit )); then
    log "昨日提交 $gitlab_path@$branch: ... 省略 $((total - limit)) 条"
  fi
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
  printf '%s\t%s\t%s' "$score" "$loc" "$risk_files"
}

github_repo_exists() {
  local gh_repo="$1"
  gh repo view "$gh_repo" --json name >/dev/null 2>&1
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

  if ! git -C "$dir" fetch "$remote" "$branch"; then
    log "拉取 GitLab 失败：$gitlab_path@$branch"
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，跳过推送 GitHub：$gitlab_path@$branch"
    return 0
  fi

  if ! git -C "$dir" push -f origin "$remote/$branch:refs/heads/$branch"; then
    log "推送到 GitHub 失败：$gitlab_path@$branch"
    return 1
  fi
}

collect_queue() {
  local gitlab_path branch gh_repo dir head_sha base_sha score loc risk initial_ref head_ref

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
    if ! github_repo_exists "$gh_repo"; then
      log "GitHub 仓库不存在，跳过：$gh_repo"
      continue
    fi
    dir="$(prepare_repo "$gh_repo")"

    if ! sync_from_gitlab "$dir" "$gitlab_path" "$branch"; then
      continue
    fi

    head_ref="origin/$branch"
    if [[ "$DRY_RUN" == "1" && "${SYNC_FROM_GITLAB:-0}" == "1" ]]; then
      head_ref="$(gitlab_remote_name)/$branch"
    fi

    if ! head_sha="$(git -C "$dir" rev-parse "$head_ref" 2>/dev/null)"; then
      log "分支不存在，跳过：$gitlab_path@$branch"
      continue
    fi

    initial_ref="${INITIAL_BASE:-origin/{branch}~1}"
    initial_ref="${initial_ref//\{branch\}/$branch}"
    if [[ "$head_ref" != "origin/$branch" ]]; then
      initial_ref="${initial_ref//origin\/$branch/$head_ref}"
    fi

    if [[ "$REVIEW_RANGE" == "yesterday" ]]; then
      if read -r base_sha head_sha < <(yesterday_range_shas "$dir" "$head_ref"); then
        :
      else
        log "$gitlab_path@$branch 昨日无提交"
        continue
      fi
    elif [[ -f "$(state_file "$gitlab_path" "$branch")" ]]; then
      base_sha="$(cat "$(state_file "$gitlab_path" "$branch")")"
    else
      base_sha="$(resolve_initial_base "$dir" "$head_sha" "$initial_ref")"
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
    if [[ "$REVIEW_RANGE" == "yesterday" ]]; then
      log_yesterday_commits "$dir" "$base_sha" "$head_sha" "$gitlab_path" "$branch"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$score" "$gitlab_path" "$branch" "$base_sha" "$head_sha" >> "$QUEUE_FILE"
  done < "$ROOT_DIR/config/repos.txt"
}

create_or_find_pr() {
  local gh_repo="$1"
  local dir="$2"
  local base_sha="$3"
  local head_sha="$4"
  local branch="$5"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，跳过创建 PR：$gh_repo ($branch)"
    printf '%s' "DRY_RUN"
    return 0
  fi
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
    --body "每日审计差异：$base_sha -> $head_sha，分支：$branch。" \
    >/dev/null

  pr_number="$(gh pr list --repo "$gh_repo" --head "$head_branch" --state open --json number --jq '.[0].number // empty')"
  printf '%s' "$pr_number"
}

ensure_codex_comment() {
  local gh_repo="$1"
  local pr_number="$2"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，跳过评论：$gh_repo#$pr_number"
    return 0
  fi
  local already
  already="$(gh pr view --repo "$gh_repo" "$pr_number" --json comments --jq '[.comments[].body | contains("@codex review")] | any')"
  if [[ "$already" == "true" ]]; then
    return 0
  fi

  gh pr comment --repo "$gh_repo" "$pr_number" --body "$CODEX_PROMPT" >/dev/null
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

    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY_RUN=1 将创建 PR：$gitlab_path@$branch base=$base_sha head=$head_sha"
      log "DRY_RUN=1 将评论：$CODEX_PROMPT"
      count=$((count + 1))
      sleep "$SLEEP_BETWEEN_SECONDS"
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

    printf '%s\n' "$head_sha" > "$(state_file "$gitlab_path" "$branch")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$gitlab_path" "$branch" "$gh_repo" "$pr_number" "$pr_url" >> "$RUN_FILE"

    count=$((count + 1))
    sleep "$SLEEP_BETWEEN_SECONDS"
  done < "$QUEUE_FILE.sorted"
}

collect_queue
process_queue
