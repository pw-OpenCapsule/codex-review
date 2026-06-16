#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
load_settings "$ROOT_DIR"

if [[ "${SYNC_FROM_GITLAB:-0}" == "1" && "${GITLAB_USE_WARP:-0}" == "1" && "${GIT_WARP_BATCH_ACTIVE:-0}" != "1" ]]; then
  GIT_WARP_BATCH_ACTIVE=1 exec git-warp batch --host "$GITLAB_HOST" -- "$0" "$@"
fi

ensure_dirs

log "更新本地镜像（仅 fetch，不 push）"

while IFS= read -r raw || [[ -n "$raw" ]]; do
  parsed="$(parse_repo_line "$raw" || true)"
  [[ -z "$parsed" ]] && continue

  IFS=$'\t' read -r repo_spec cadence_raw <<< "$parsed"
  if [[ "$(normalize_cadence "$cadence_raw" || true)" == "manual" ]]; then
    log "手动审计项目，跳过更新：$repo_spec"
    continue
  fi

  gitlab_path="${repo_spec%@*}"
  branch="${repo_spec#*@}"
  if [[ "$gitlab_path" == "$branch" || -z "$branch" ]]; then
    branch="$DEFAULT_BRANCH"
  fi

  gh_repo="$(github_repo "$gitlab_path")"
  if [[ "${SYNC_FROM_GITLAB:-0}" == "1" ]]; then
    dir="$(gitlab_repo_dir "$gitlab_path")"
  else
    dir="$(repo_dir "$gh_repo")"
  fi

  if [[ ! -d "$dir/.git" ]]; then
    if [[ "${SYNC_FROM_GITLAB:-0}" == "1" ]]; then
      log "初始化 GitLab 本地镜像：$gitlab_path ($dir)"
      mkdir -p "$dir"
      git -C "$dir" init >/dev/null
    else
      log "本地未初始化，跳过：$gitlab_path@$branch ($dir)"
      continue
    fi
  fi

  log "更新 $gitlab_path@$branch ($gh_repo)"

  if [[ "${SYNC_FROM_GITLAB:-0}" == "1" ]]; then
    remote="$(gitlab_remote_name)"
    url="$(gitlab_repo_url "$gitlab_path")"
    if git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
      git -C "$dir" remote set-url "$remote" "$url"
    else
      git -C "$dir" remote add "$remote" "$url"
    fi

    if ! branch="$(fetch_gitlab_branch_with_fallback "$dir" "$remote" "$branch")"; then
      log "拉取 GitLab 失败：$gitlab_path@$branch"
    fi
  else
    git_retry git -C "$dir" fetch origin --prune
  fi
done < "$REPOS_FILE"
