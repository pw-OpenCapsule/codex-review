#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config/settings.env
source "$ROOT_DIR/config/settings.env"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_dirs

mode="all"
strategy="${GOGS_BRANCH_STRATEGY:-default}"
write_mode="merge"
output_path="$ROOT_DIR/config/repos.txt"
dry_run=0
orgs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --org) orgs+=("$2"); shift 2 ;;
    --strategy) strategy="$2"; shift 2 ;;
    --output) output_path="$2"; shift 2 ;;
    --overwrite) write_mode="overwrite"; shift ;;
    --append) write_mode="append"; shift ;;
    --merge) write_mode="merge"; shift ;;
    --dry-run) dry_run=1; shift ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

if [[ -z "${GOGS_BASE_URL:-}" ]]; then
  if [[ -n "${GITLAB_HOST:-}" ]]; then
    proto="${GITLAB_PROTOCOL:-https}"
    GOGS_BASE_URL="${proto}://${GITLAB_HOST}"
  else
    die "GOGS_BASE_URL 为空"
  fi
fi

if [[ -z "${GOGS_TOKEN:-}" ]]; then
  if [[ -n "${GITLAB_AUTH:-}" && "$GITLAB_AUTH" == *:* ]]; then
    GOGS_TOKEN="${GITLAB_AUTH#*:}"
  else
    die "GOGS_TOKEN 为空"
  fi
fi

if [[ "$mode" != "all" && "$mode" != "user" && "$mode" != "org" ]]; then
  die "mode 仅支持 all/user/org"
fi

if [[ "$strategy" != "default" && "$strategy" != "latest" ]]; then
  die "strategy 仅支持 default/latest"
fi

orgs_csv=""
if [[ "${#orgs[@]}" -gt 0 ]]; then
  orgs_csv="$(IFS=,; printf '%s' "${orgs[*]}")"
fi

repo_lines="$(
  GOGS_BASE_URL="$GOGS_BASE_URL" GOGS_TOKEN="$GOGS_TOKEN" GOGS_MODE="$mode" \
  GOGS_STRATEGY="$strategy" GOGS_ORGS="$orgs_csv" DEFAULT_BRANCH="$DEFAULT_BRANCH" \
  python3 - <<'PY'
import json
import os
import sys
import urllib.request
import urllib.parse
from datetime import datetime, timezone

base = os.environ["GOGS_BASE_URL"].rstrip("/")
token = os.environ["GOGS_TOKEN"]
mode = os.environ.get("GOGS_MODE", "all")
strategy = os.environ.get("GOGS_STRATEGY", "default")
orgs_csv = os.environ.get("GOGS_ORGS", "")
default_branch = os.environ.get("DEFAULT_BRANCH", "main")

def api_get(url: str):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"token {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))

def paged(url: str):
    page = 1
    limit = 50
    items = []
    while True:
        sep = "&" if "?" in url else "?"
        data = api_get(f"{url}{sep}page={page}&limit={limit}")
        if not isinstance(data, list):
            break
        items.extend(data)
        if len(data) < limit:
            break
        page += 1
    return items

def list_orgs():
    return paged(f"{base}/api/v1/user/orgs")

def list_user_repos():
    return paged(f"{base}/api/v1/user/repos")

def list_org_repos(org: str):
    return paged(f"{base}/api/v1/orgs/{urllib.parse.quote(org)}/repos")

def list_branches(owner: str, repo: str):
    return paged(f"{base}/api/v1/repos/{owner}/{repo}/branches")

def parse_date(value: str):
    if not value:
        return None
    value = str(value).strip()
    if value.isdigit():
        try:
            return datetime.fromtimestamp(int(value), tz=timezone.utc)
        except Exception:
            return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None

def commit_date_from_branch(owner: str, repo: str, branch: dict):
    commit = branch.get("commit") if isinstance(branch, dict) else None
    if isinstance(commit, dict):
        inner = commit.get("commit")
        if isinstance(inner, dict):
            author = inner.get("author") or {}
            date = author.get("date") or (inner.get("committer") or {}).get("date")
            parsed = parse_date(date)
            if parsed:
                return parsed
        for key in ("committed_date", "created", "created_at", "timestamp"):
            parsed = parse_date(commit.get(key))
            if parsed:
                return parsed
    sha = None
    if isinstance(commit, dict):
        sha = commit.get("id") or commit.get("sha")
    if not sha:
        sha = branch.get("commit", {}).get("id") if isinstance(branch, dict) else None
    if not sha:
        return None
    try:
        data = api_get(f"{base}/api/v1/repos/{owner}/{repo}/commits/{sha}")
    except Exception:
        return None
    commit2 = data.get("commit") if isinstance(data, dict) else {}
    if isinstance(commit2, dict):
        author = commit2.get("author") or {}
        date = author.get("date") or (commit2.get("committer") or {}).get("date")
        parsed = parse_date(date)
        if parsed:
            return parsed
    for key in ("created", "created_at", "timestamp", "committed_date"):
        parsed = parse_date(data.get(key) if isinstance(data, dict) else None)
        if parsed:
            return parsed
    return None

repos = []
if mode == "user":
    repos = list_user_repos()
elif mode == "org":
    if not orgs_csv:
        print("ORG 为空，无法拉取 org 仓库", file=sys.stderr)
        sys.exit(2)
    for org in [o for o in orgs_csv.split(",") if o.strip()]:
        repos.extend(list_org_repos(org.strip()))
else:
    repos = list_user_repos()
    for org in list_orgs():
        username = org.get("username") or org.get("name")
        if not username:
            continue
        repos.extend(list_org_repos(username))

seen = set()
lines = []
for repo in repos:
    owner = (repo.get("owner") or {}).get("username") or repo.get("owner", {}).get("login")
    name = repo.get("name")
    if not owner or not name:
        continue
    key = f"{owner}/{name}"
    if key in seen:
        continue
    seen.add(key)

    branch = repo.get("default_branch") or default_branch
    if strategy == "latest":
        try:
            branches = list_branches(owner, name)
        except Exception:
            branches = []
        best_branch = None
        best_date = None
        for b in branches:
            date = commit_date_from_branch(owner, name, b)
            if not date:
                continue
            if best_date is None or date > best_date:
                best_date = date
                best_branch = b.get("name")
        if best_branch:
            branch = best_branch

    lines.append(f"{owner}/{name}@{branch}")

for line in sorted(lines):
    print(line)
PY
)"

if [[ -z "$(printf '%s' "$repo_lines" | tr -d '[:space:]')" ]]; then
  log "未获取到任何 Gogs 仓库"
  exit 0
fi

if [[ "$dry_run" == "1" ]]; then
  printf '%s\n' "$repo_lines"
  exit 0
fi

tmp_file="$RUN_DIR/gogs-repos.$$.$RANDOM.txt"
printf '%s\n' "$repo_lines" > "$tmp_file"

OUTPUT_PATH="$output_path" NEW_PATH="$tmp_file" WRITE_MODE="$write_mode" python3 - <<'PY'
import os

output_path = os.environ["OUTPUT_PATH"]
new_path = os.environ["NEW_PATH"]
mode = os.environ.get("WRITE_MODE", "merge")

header = []
existing = []
if os.path.exists(output_path):
    header_done = False
    with open(output_path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not header_done and (not stripped or stripped.startswith("#")):
                header.append(line)
                continue
            header_done = True
            if stripped and not stripped.startswith("#"):
                existing.append(stripped)

if not header:
    header = [
        "# 每行一个 GitLab 仓路径（group/project@branch）。",
        "# 分支可选，不写则使用 DEFAULT_BRANCH。",
        "# GitHub 镜像仓名根据 settings.env 的命名规则生成。",
        "# platform/auth-service@main",
        "# platform/payment-core@release",
    ]

with open(new_path, "r", encoding="utf-8") as fh:
    new_entries = [line.strip() for line in fh if line.strip()]

if mode == "overwrite":
    merged = sorted(set(new_entries))
elif mode == "append":
    merged = existing[:]
    for entry in new_entries:
        if entry not in merged:
            merged.append(entry)
else:
    merged = sorted(set(existing).union(new_entries))

with open(output_path, "w", encoding="utf-8") as fh:
    for line in header:
        fh.write(line + "\n")
    for entry in merged:
        fh.write(entry + "\n")
PY

rm -f "$tmp_file"
log "已写入 $output_path（${write_mode}）"
