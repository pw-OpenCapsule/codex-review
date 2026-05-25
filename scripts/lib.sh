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

load_settings() {
  local root="${1:-}"
  local settings_path

  if [[ -z "$root" ]]; then
    die "load_settings requires repository root"
  fi

  settings_path="${CODEX_REVIEW_SETTINGS:-$root/config/settings.env}"
  if [[ ! -f "$settings_path" ]]; then
    die "配置文件不存在：$settings_path。请复制 config/settings.env.example，或设置 CODEX_REVIEW_SETTINGS 指向私有配置文件。"
  fi

  set -a
  set +u
  # shellcheck source=/dev/null
  source "$settings_path"
  set -u
  set +a

  # Let deployment-local .env override settings.env when both exist.
  load_dotenv "$root"

  REPOS_FILE="${REPOS_FILE:-$root/config/repos.txt}"
  LARK_USER_MAP="${LARK_USER_MAP:-$root/config/lark_user_map.tsv}"
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

parse_repo_line() {
  local raw="$1"
  local line repo_spec cadence

  line="$(strip_comment "$raw")"
  line="$(printf '%s' "$line" | awk '{$1=$1; print}')"
  [[ -z "$line" ]] && return 1

  read -r repo_spec cadence _ <<< "$line"
  [[ -z "$repo_spec" ]] && return 1

  printf '%s\t%s\n' "$repo_spec" "$cadence"
}

normalize_cadence() {
  local raw="${1:-}"

  case "$raw" in
    ""|weekly|week)
      printf 'weekly'
      return 0
      ;;
    daily|day)
      printf 'daily'
      return 0
      ;;
    every3d|3d|third-day)
      printf 'every3d'
      return 0
      ;;
    every5d|5d|fifth-day)
      printf 'every5d'
      return 0
      ;;
    manual|skip|none|off)
      printf 'manual'
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

cadence_title_label() {
  local cadence="${1:-}"

  case "$cadence" in
    daily)
      printf '每日'
      ;;
    every3d)
      printf '每3工作日'
      ;;
    every5d)
      printf '每5工作日'
      ;;
    weekly)
      printf '每周'
      ;;
    manual)
      printf '手动'
      ;;
    *)
      printf '每周'
      ;;
  esac
}

cadence_report_label() {
  local cadence="${1:-}"

  case "$cadence" in
    daily)
      printf '日报'
      ;;
    every3d)
      printf '3日节奏报告'
      ;;
    every5d)
      printf '5日节奏报告'
      ;;
    weekly)
      printf '周报'
      ;;
    manual)
      printf '手动报告'
      ;;
    *)
      printf '周报'
      ;;
  esac
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

# Run codex exec on a single review block. Outputs TSV one issue per line:
# severity\tsummary_zh\tfile\tline_start\tline_end\tevidence
# Args: repo branch pr sha workdir review_text
call_codex_review() {
  local repo="$1" branch="$2" pr="$3" sha="$4" workdir="$5" review_text="$6"
  local review_file
  review_file=$(mktemp)
  printf '%s' "$review_text" >"$review_file"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local json
  if ! json=$(python3 "$script_dir/lib/codex_review.py" \
        --repo "$repo" --branch "$branch" --pr "$pr" --sha "$sha" \
        --workdir "$workdir" --review-file "$review_file" 2>/dev/null); then
    rm -f "$review_file"
    return 1
  fi
  rm -f "$review_file"
  printf '%s' "$json" | python3 -c '
import json, sys
try:
  d = json.loads(sys.stdin.read() or "{}")
except Exception:
  sys.exit(0)
for i in d.get("issues", []):
  print("\t".join([
    i.get("severity","P5"),
    i.get("summary_zh",""),
    i.get("file",""),
    str(i.get("line_start",0)),
    str(i.get("line_end",0)),
    i.get("evidence",""),
  ]))
'
}

# Drain ISSUES_FOR_MEEGLE array and create one Meegle bug per entry.
# Args: workdir
create_meegle_bugs() {
  local workdir="$1"
  [[ "${MEEGLE_AUTO_CREATE:-0}" == "1" ]] || { log "MEEGLE_AUTO_CREATE != 1，跳过建单"; return 0; }
  [[ ${#ISSUES_FOR_MEEGLE[@]} -gt 0 ]] || return 0

  local meegle_bin="${MEEGLE_BIN:-meegle}"
  if ! command -v "$meegle_bin" >/dev/null 2>&1; then
    log "meegle CLI 不存在 ($meegle_bin)，跳过建单"
    return 0
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local state_dir="${STATE_DIR:-/tmp}"
  local state_file="$state_dir/meegle-created.tsv"
  local user_map="${LARK_USER_MAP:-$ROOT_DIR/config/lark_user_map.tsv}"
  local dry_flag=""
  [[ "${LARK_DRY_RUN:-0}" == "1" ]] && dry_flag="--dry-run"
  mkdir -p "$state_dir" 2>/dev/null || true

  local issue_json
  for issue_json in "${ISSUES_FOR_MEEGLE[@]}"; do
    [[ -z "$issue_json" ]] && continue
    local file line_start line_end summary
    file=$(printf '%s' "$issue_json"       | python3 -c 'import json,sys;print(json.load(sys.stdin).get("file",""))')
    line_start=$(printf '%s' "$issue_json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("line_start",0))')
    line_end=$(printf '%s' "$issue_json"   | python3 -c 'import json,sys;print(json.load(sys.stdin).get("line_end",0))')
    summary=$(printf '%s' "$issue_json"    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("summary",""))')

    if [[ -z "$file" || "$line_start" == "0" ]]; then
      log "meegle: 跳过 file/line 缺失的 issue: $summary"
      continue
    fi

    local blame_json
    blame_json=$(python3 "$script_dir/lib/blame_lookup.py" \
      --workdir "$workdir" --file "$file" \
      --line-start "$line_start" --line-end "$line_end" \
      --user-map "$user_map" \
      --default-meegle "${MEEGLE_DEFAULT_ASSIGNEE:-}" 2>/dev/null || echo '{}')

    local enriched
    enriched=$(python3 -c '
import json, sys
issue = json.loads(sys.argv[1])
blame = json.loads(sys.argv[2] or "{}")
issue["assignee"]     = blame.get("meegle_user_key", "")
issue["blame_author"] = blame.get("author_name", "")
issue["blame_sha"]    = (blame.get("sha", "") or "")[:8]
issue["blame_date"]   = blame.get("date", "")
print(json.dumps(issue, ensure_ascii=False))
' "$issue_json" "$blame_json")

    python3 "$script_dir/lib/meegle_bug.py" \
      --project-key "${MEEGLE_PROJECT_KEY}" \
      --work-item-type "${MEEGLE_WORK_ITEM_TYPE:-issue}" \
      --state-file "$state_file" \
      $dry_flag \
      --bug "$enriched" \
      >>"$state_dir/meegle-created.log" 2>&1 \
      || log "meegle: create failed for [$file:$line_start] $summary"
  done
  log "meegle: 处理 ${#ISSUES_FOR_MEEGLE[@]} 条 issue 完毕"
}

if [[ -n "${ROOT_DIR:-}" ]]; then
  load_dotenv "$ROOT_DIR"
fi
