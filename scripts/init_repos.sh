#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_TERMINAL_PROMPT=0

# shellcheck source=../config/settings.env
source "$ROOT_DIR/config/settings.env"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_dirs
ensure_gh_auth

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

  if ! git -C "$dir" push -f origin "$remote/$branch:refs/heads/$branch"; then
    log "推送到 GitHub 失败：$gitlab_path@$branch"
    return 1
  fi

  if ! git -C "$dir" fetch origin "$branch" >/dev/null 2>&1; then
    log "更新 GitHub 远端分支失败：$gitlab_path@$branch"
    return 1
  fi
}

total=0
created=0
synced=0
failed=0

while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="$(strip_comment "$raw")"
  line="$(printf '%s' "$line" | awk '{$1=$1; print}')"
  [[ -z "$line" ]] && continue

  total=$((total + 1))
  gitlab_path="${line%@*}"
  branch="${line#*@}"
  if [[ "$gitlab_path" == "$branch" || -z "$branch" ]]; then
    branch="$DEFAULT_BRANCH"
  fi

  gh_repo="$(github_repo "$gitlab_path")"
  if ! github_repo_exists "$gh_repo"; then
    if ! create_github_repo "$gh_repo"; then
      log "GitHub 仓库创建失败，跳过：$gh_repo"
      failed=$((failed + 1))
      continue
    fi
    created=$((created + 1))
  fi

  dir="$(prepare_repo "$gh_repo")"
  if ! sync_from_gitlab "$dir" "$gitlab_path" "$branch"; then
    failed=$((failed + 1))
    continue
  fi

  if ! git -C "$dir" rev-parse "origin/$branch" >/dev/null 2>&1; then
    log "分支不存在，跳过：$gitlab_path@$branch"
    failed=$((failed + 1))
    continue
  fi

  log "初始化完成：$gitlab_path@$branch"
  synced=$((synced + 1))
done < "$ROOT_DIR/config/repos.txt"

log "完成：总计=$total 创建=$created 同步=$synced 失败=$failed"
