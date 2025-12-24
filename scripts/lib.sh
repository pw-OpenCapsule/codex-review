#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s %s\n' "$(date +'%F %T')" "$*"
}

die() {
  log "错误: $*"
  exit 1
}

ensure_dirs() {
  mkdir -p "$WORKDIR" "$STATE_DIR" "$RUN_DIR"
}

normalize_repo_name() {
  local gitlab_path="$1"
  local repo_name="${gitlab_path//\//-}"
  printf '%s%s' "$REPO_PREFIX" "$repo_name"
}

github_repo() {
  local gitlab_path="$1"
  printf '%s/%s' "$GITHUB_ORG" "$(normalize_repo_name "$gitlab_path")"
}

repo_dir() {
  local gh_repo="$1"
  printf '%s/%s' "$WORKDIR" "${gh_repo//\//_}"
}

state_file() {
  local gitlab_path="$1"
  local branch="$2"
  local key="${gitlab_path//\//__}__${branch//\//__}"
  printf '%s/%s.last' "$STATE_DIR" "$key"
}

strip_comment() {
  local line="$1"
  printf '%s' "${line%%#*}"
}

gitlab_remote_name() {
  printf '%s' "${GITLAB_REMOTE_NAME:-gitlab}"
}

gitlab_repo_url() {
  local gitlab_path="$1"
  local proto="${GITLAB_PROTOCOL:-https}"
  local host="${GITLAB_HOST:-}"

  if [[ -z "$host" ]]; then
    die "GITLAB_HOST 为空"
  fi

  if [[ -n "${GITLAB_AUTH:-}" ]]; then
    printf '%s://%s@%s/%s.git' "$proto" "$GITLAB_AUTH" "$host" "$gitlab_path"
  else
    printf '%s://%s/%s.git' "$proto" "$host" "$gitlab_path"
  fi
}
