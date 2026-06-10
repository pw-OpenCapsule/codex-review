#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
load_settings "$ROOT_DIR"

ensure_dirs

log "更新本地镜像（仅 fetch，不 push）"

while IFS= read -r raw || [[ -n "$raw" ]]; do
  parsed="$(parse_repo_line "$raw" || true)"
  [[ -z "$parsed" ]] && continue

  IFS=$'\t' read -r repo_spec _ <<< "$parsed"
  gitlab_path="${repo_spec%@*}"
  branch="${repo_spec#*@}"
  if [[ "$gitlab_path" == "$branch" || -z "$branch" ]]; then
    branch="$DEFAULT_BRANCH"
  fi

  gh_repo="$(github_repo "$gitlab_path")"
  dir="$(repo_dir "$gh_repo")"

  if [[ ! -d "$dir/.git" ]]; then
    log "本地未初始化，跳过：$gitlab_path@$branch ($dir)"
    continue
  fi

  log "更新 $gitlab_path@$branch ($gh_repo)"
  git -C "$dir" fetch origin --prune

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
  fi
done < "$REPOS_FILE"
