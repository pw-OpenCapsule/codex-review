#!/usr/bin/env bash
# Usage: ./scripts/deploy.sh ["commit message"]
# Commits local changes, pushes to GitHub, then triggers remote git pull.
set -euo pipefail

REMOTE="${DEPLOY_REMOTE:-leo@192.168.0.190}"
REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/Users/leo/codex-review}"
BRANCH="${DEPLOY_BRANCH:-main}"

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. 远程脏工作区检查
log "checking remote working tree..."
remote_dirty=$(ssh "$REMOTE" "cd '$REMOTE_DIR' && git status --porcelain 2>/dev/null | wc -l | tr -d ' '")
[[ "$remote_dirty" == "0" ]] || fail "remote has $remote_dirty uncommitted file(s); resolve before deploy"

# 2. 撞 cron 检查（avoid mid-run code swap）
log "checking remote cron jobs..."
if ssh "$REMOTE" "pgrep -f 'daily_review.sh|send_lark_report.sh' >/dev/null 2>&1"; then
  fail "a cron job is currently running on remote; retry later"
fi

# 3. 本地 commit + push
if ! git diff --cached --quiet || ! git diff --quiet; then
  log "committing local changes..."
  git add -A
  msg="${1:-deploy: $(date +%F\ %T)}"
  git commit -m "$msg"
fi
log "pushing to origin/$BRANCH..."
git push origin "$BRANCH"

# 4. 远程 pull
log "pulling on remote..."
ssh "$REMOTE" "cd '$REMOTE_DIR' && git fetch origin && git pull --ff-only origin '$BRANCH'"
log "✅ deployed to $REMOTE:$REMOTE_DIR"
