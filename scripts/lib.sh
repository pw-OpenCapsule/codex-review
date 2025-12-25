#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s %s\n' "$(date +'%F %T')" "$*" >&2
}

die() {
  log "错误: $*"
  exit 1
}

load_dotenv() {
  local root="${1:-}"

  if [[ -z "$root" ]]; then
    return 0
  fi

  if [[ -f "$root/.env" ]]; then
    set -a
    set +u
    # shellcheck source=/dev/null
    source "$root/.env"
    set -u
    set +a
  fi
}

ensure_dirs() {
  mkdir -p "$WORKDIR" "$STATE_DIR" "$RUN_DIR"
}

urlencode() {
  local raw="$1"
  local length=${#raw}
  local i c

  for ((i=0; i<length; i++)); do
    c="${raw:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

ensure_gh_auth() {
  if gh api user >/dev/null 2>&1; then
    return 0
  fi

  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -z "$token" ]]; then
    die "gh 未登录，请设置 GH_TOKEN/GITHUB_TOKEN 或先手动 gh auth login"
  fi

  if ! printf '%s' "$token" | gh auth login --with-token >/dev/null 2>&1; then
    die "gh 自动登录失败"
  fi

  gh auth setup-git >/dev/null 2>&1 || true
}

normalize_repo_name() {
  local gitlab_path="$1"
  local repo_name="${gitlab_path##*/}"
  printf '%s' "$repo_name"
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
    if [[ "$GITLAB_AUTH" != *:* ]]; then
      die "GITLAB_AUTH 格式应为 user:token"
    fi
    local user="${GITLAB_AUTH%%:*}"
    local token="${GITLAB_AUTH#*:}"
    user="$(urlencode "$user")"
    token="$(urlencode "$token")"
    printf '%s://%s:%s@%s/%s.git' "$proto" "$user" "$token" "$host" "$gitlab_path"
  else
    printf '%s://%s/%s.git' "$proto" "$host" "$gitlab_path"
  fi
}

if [[ -n "${ROOT_DIR:-}" ]]; then
  load_dotenv "$ROOT_DIR"
fi
