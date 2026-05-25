# Codex Exec + Meegle 自动建缺陷 + 远程部署 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `send_lark_report.sh` 的外部 API 翻译换成本地 `codex exec` 复核+翻译，每个 issue 各自 git blame 定位责任人，飞书发送成功后自动调 meegle-cli 建缺陷；并把运行迁移到 `192.168.0.190`，本地通过 `scripts/deploy.sh` 推 GitHub 触发远程 pull。

**Architecture:**
- Bash 主流程不变，把复杂逻辑抽到 `scripts/lib/*.py` 三个独立 Python 脚本（codex_review / meegle_bug / blame_lookup），通过 stdin/stdout JSON 与 bash 通信，可以单独测试。
- `scripts/lib.sh` 加 3 个 shell 封装函数，`send_lark_report.sh` 末尾增加 webhook 成功后的 meegle 批建逻辑。
- 部署是单脚本 `scripts/deploy.sh`：local commit + push + ssh pull，含锁检测。

**Tech Stack:** bash (主流程) · python3 (stdlib only) · codex CLI · meegle CLI · git · ssh

**Spec:** `docs/specs/2026-05-25-codex-exec-meegle-deploy-design.html`

---

## 文件结构

| 路径 | 状态 | 职责 |
|---|---|---|
| `scripts/deploy.sh` | 新建 | 本地→远程部署（commit/push/ssh pull + 锁检测） |
| `scripts/lib/codex_review.py` | 新建 | 调用 `codex exec` 复核+翻译，输出 JSON |
| `scripts/lib/meegle_bug.py` | 新建 | 字段映射 + 调 meegle CLI + 幂等检测 |
| `scripts/lib/blame_lookup.py` | 新建 | `git blame` + LARK_USER_MAP → user_key |
| `scripts/lib.sh` | 修改 | 新增 `call_codex_review`、`create_meegle_bugs` shell 封装 |
| `scripts/send_lark_report.sh` | 修改 | 替换 `summarize_review_with_ai` 调用点；webhook 后调 meegle |
| `config/settings.env` | 修改 | 删 3 个旧变量，加 ~10 个新变量 |
| `tests/fixtures/codex_review_sample.txt` | 新建 | 真实 codex review 文本样本（脱敏） |
| `tests/fixtures/codex_exec_mock.sh` | 新建 | 替代 codex 二进制的 mock |
| `tests/test_codex_review.sh` | 新建 | codex_review.py 单测 |
| `tests/test_meegle_bug.sh` | 新建 | meegle_bug.py 单测（dry-run 模式） |
| `tests/test_blame_lookup.sh` | 新建 | blame_lookup.py 单测 |
| `README.md` | 修改 | 流程图 + 配置项更新 |

---

## Phase 1 — Deploy 基础设施（先打通部署，后面才能在远程验证）

### Task 1.1: 写 `scripts/deploy.sh`

**Files:**
- Create: `scripts/deploy.sh`

- [ ] **Step 1: 写脚本**

```bash
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
```

- [ ] **Step 2: 赋权**

Run: `chmod +x scripts/deploy.sh`

- [ ] **Step 3: dry-test（不带改动，只测试 SSH 路径）**

Run: `./scripts/deploy.sh "test deploy infra"`
Expected:
- `[deploy] checking remote working tree...`
- `[deploy] checking remote cron jobs...`
- `(nothing to commit)` 或一次 commit
- `[deploy] ✅ deployed...`
- 远程 `cd /Users/leo/codex-review && git log -1` 应能看到 HEAD 同步

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy.sh
git commit -m "feat(deploy): 新增 scripts/deploy.sh 本地→远程部署"
```

---

## Phase 2 — Codex Exec 复核 + 翻译

### Task 2.1: 写 mock codex（先固定输入输出，方便测试）

**Files:**
- Create: `tests/fixtures/codex_exec_mock.sh`
- Create: `tests/fixtures/codex_review_sample.txt`
- Create: `tests/fixtures/codex_review_expected.json`

- [ ] **Step 1: 抽一份真实 review 文本作样本**

把 `scripts/send_lark_report.sh` 里 normalize 函数处理过的某条样本（找一个最近 PR 的 review，去掉 GitHub URL 等噪音）放进 `tests/fixtures/codex_review_sample.txt`，含至少 1 个 P0、1 个 P2 和 1 个不该出现的幻觉（例如指向不存在的文件）。

- [ ] **Step 2: 写 mock 脚本**

```bash
#!/usr/bin/env bash
# Mock codex CLI for tests. Reads stdin, returns fixed JSON.
# Usage: codex_exec_mock.sh exec [--output-last-message PATH] -
set -euo pipefail

out_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out_path="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Drain stdin
cat >/dev/null

payload='{"issues":[
  {"severity":"P0","summary_zh":"`login()` 失败时未返回错误，调用方拿到 null","file":"src/auth.py","line_start":42,"line_end":48,"evidence":"src/auth.py:42 的 except 块吞掉异常"},
  {"severity":"P2","summary_zh":"`format_time()` 未处理 None 输入","file":"src/util.py","line_start":15,"line_end":17,"evidence":"util.py:15 直接 strftime"}
],"rejected":[
  {"severity":"P1","original":"foo.go 缺少错误处理","reason":"仓库无 foo.go"}
]}'

if [[ -n "$out_path" ]]; then
  echo "$payload" >"$out_path"
fi
echo "$payload"
```

- [ ] **Step 3: 预期输出**

写 `tests/fixtures/codex_review_expected.json` —— 上面 mock 输出原样复制，用作断言基准。

- [ ] **Step 4: 赋权 + commit**

```bash
chmod +x tests/fixtures/codex_exec_mock.sh
git add tests/fixtures/
git commit -m "test: 新增 codex review fixtures 与 mock"
```

---

### Task 2.2: 写 `scripts/lib/codex_review.py`

**Files:**
- Create: `scripts/lib/codex_review.py`

- [ ] **Step 1: 写测试（在 `tests/test_codex_review.sh`，与实现同步起步）**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/codex_review.py"
MOCK="$ROOT/tests/fixtures/codex_exec_mock.sh"
SAMPLE="$ROOT/tests/fixtures/codex_review_sample.txt"

# 用 mock 替代真实 codex
export CODEX_EXEC_BIN="$MOCK"
export CODEX_EXEC_TIMEOUT=10

# 调用并验证输出
out=$(python3 "$PY" \
  --repo dummy --branch main --pr 42 --sha HEAD \
  --workdir "$ROOT" \
  --review-file "$SAMPLE")

echo "$out" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert len(d["issues"]) == 2, f"want 2 issues, got {len(d[\"issues\"])}"
assert d["issues"][0]["severity"] == "P0"
assert d["issues"][0]["file"] == "src/auth.py"
assert len(d["rejected"]) == 1
print("OK")
'
```

- [ ] **Step 2: 跑测试，确认失败**

Run: `bash tests/test_codex_review.sh`
Expected: 文件不存在错误

- [ ] **Step 3: 实现 `scripts/lib/codex_review.py`**

```python
#!/usr/bin/env python3
"""Invoke codex exec to verify+translate a codex review.

Reads the original review text + PR metadata, runs `codex exec` in the
synced mirror repo, returns JSON {issues, rejected} on stdout.

Usage:
  codex_review.py --repo <repo> --branch <b> --pr <n> --sha <sha> \
                  --workdir <path> --review-file <path>
"""
import argparse, json, os, subprocess, sys, tempfile, textwrap

PROMPT = textwrap.dedent("""\
    你是代码审查复核员。下面是 codex 对 PR 的原始审查输出。
    任务：
    1. 在当前工作目录读取被指出的代码，验证每个问题是否真实存在
    2. 剔除幻觉/误报（描述与代码不符、文件不存在、行号无意义等）
    3. 保留下来的问题翻译成中文，按 P0-P5 分级

    严格输出 JSON（不要任何额外文字）：
    {
      "issues": [
        {"severity":"P0|P1|P2|P3|P4|P5",
         "summary_zh":"中文问题描述（保留反引号包裹的标识符）",
         "file":"相对路径","line_start":<int>,"line_end":<int>,
         "evidence":"复核理由"}
      ],
      "rejected": [
        {"severity":"P?","original":"原文摘录","reason":"为什么判为误报"}
      ]
    }

    PR 元信息：仓库={repo} 分支={branch} PR={pr} HEAD={sha}

    原始审查：
    {review_text}
    """)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--branch", required=True)
    ap.add_argument("--pr", required=True)
    ap.add_argument("--sha", default="HEAD")
    ap.add_argument("--workdir", required=True, help="path to synced mirror repo")
    ap.add_argument("--review-file", required=True)
    args = ap.parse_args()

    bin_ = os.environ.get("CODEX_EXEC_BIN", "codex")
    timeout = int(os.environ.get("CODEX_EXEC_TIMEOUT", "300"))
    model = os.environ.get("CODEX_EXEC_MODEL", "").strip()
    extra = os.environ.get("CODEX_EXEC_EXTRA_ARGS", "").strip()

    with open(args.review_file, "r", encoding="utf-8") as f:
        review_text = f.read()

    prompt = PROMPT.format(
        repo=args.repo, branch=args.branch, pr=args.pr, sha=args.sha,
        review_text=review_text,
    )

    cmd = [bin_, "exec", "--skip-git-repo-check"]
    if model:
        cmd += ["--model", model]
    if extra:
        cmd += extra.split()
    with tempfile.NamedTemporaryFile("r", delete=False, suffix=".txt") as tmp:
        out_path = tmp.name
    cmd += ["--output-last-message", out_path, "-"]

    try:
        proc = subprocess.run(
            cmd, input=prompt, capture_output=True, text=True,
            cwd=args.workdir, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        print(json.dumps({"issues": [], "rejected": [],
                          "error": "codex_timeout"}))
        sys.exit(2)

    raw = ""
    if os.path.exists(out_path):
        with open(out_path, "r", encoding="utf-8") as f:
            raw = f.read()
    if not raw.strip():
        raw = (proc.stdout or "").strip()

    parsed = extract_json(raw)
    if not parsed:
        # log to stderr for debugging, but still exit non-zero
        sys.stderr.write("codex_review: failed to parse JSON\n")
        sys.stderr.write("---raw---\n" + raw + "\n")
        print(json.dumps({"issues": [], "rejected": [],
                          "error": "parse_failed"}))
        sys.exit(3)

    # Normalize: ensure required keys exist
    parsed.setdefault("issues", [])
    parsed.setdefault("rejected", [])
    print(json.dumps(parsed, ensure_ascii=False))


def extract_json(raw: str):
    raw = raw.strip()
    if not raw:
        return None
    if raw.startswith("```"):
        # strip code fences
        raw = raw.split("\n", 1)[-1] if "\n" in raw else raw
        if raw.endswith("```"):
            raw = raw[:-3].rstrip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    start, end = raw.find("{"), raw.rfind("}")
    if start != -1 and end > start:
        try:
            return json.loads(raw[start:end + 1])
        except json.JSONDecodeError:
            return None
    return None


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 跑测试**

Run: `bash tests/test_codex_review.sh`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/codex_review.py tests/test_codex_review.sh
git commit -m "feat(codex): 新增 codex_review.py（复核+翻译）"
```

---

### Task 2.3: 改 `scripts/send_lark_report.sh` 调用点

**Files:**
- Modify: `scripts/send_lark_report.sh:942-1180` (替换 `summarize_review_with_ai`)
- Modify: `scripts/send_lark_report.sh:1541` (调用点适配)
- Modify: `scripts/lib.sh` (加 shell 封装)

- [ ] **Step 1: 在 `scripts/lib.sh` 末尾加封装**

```bash
# Invoke codex_review.py and return TSV lines: severity<TAB>summary<TAB>file<TAB>line_start<TAB>line_end
# Args: repo branch pr_number sha workdir review_text
call_codex_review() {
  local repo="$1" branch="$2" pr="$3" sha="$4" workdir="$5" review_text="$6"
  local review_file
  review_file=$(mktemp); printf '%s' "$review_text" >"$review_file"
  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  python3 "$script_dir/lib/codex_review.py" \
    --repo "$repo" --branch "$branch" --pr "$pr" --sha "$sha" \
    --workdir "$workdir" --review-file "$review_file"
  local rc=$?
  rm -f "$review_file"
  return $rc
}
```

- [ ] **Step 2: 删掉旧 `summarize_review_with_ai`（line 942-end-of-function）**

定位起止行后用 Edit 删除整个函数体。

- [ ] **Step 3: 改调用点**

```bash
# Was:
# summary_lines="$(summarize_review_with_ai "$gitlab_path" "$branch" "$pr_number" "$block_text" "$location" 2>/dev/null)"
# Becomes:
mirror_dir="${WORKDIR}/${repo_basename}"  # ${WORKDIR}/<mirror-repo>
codex_json="$(call_codex_review "$repo_basename" "$branch" "$pr_number" "$head_sha" "$mirror_dir" "$block_text" 2>/dev/null || echo '')"

# Parse JSON → 同样的 TSV 流（severity\tsummary\tfile\tline_start\tline_end）
summary_lines="$(echo "$codex_json" | python3 -c '
import json,sys
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
  ]))
')"
```

- [ ] **Step 4: 适配下游 `while IFS=$'\t' read -r severity summary; do`**

把 read 改成 5 个字段（多出 file/line_start/line_end，备 Phase 3 用），但本步只读前两个：

```bash
while IFS=$'\t' read -r severity summary file line_start line_end; do
  [[ -z "$severity" || "$severity" == "NONE" ]] && continue
  ...  # 原逻辑保留
done <<< "$summary_lines"
```

把每条解析出的 issue 同时 append 到 bash 数组 `ISSUES_FOR_MEEGLE+=("$severity|$summary|$file|$line_start|$line_end|$repo|$pr_number|$pr_url")`，Phase 3 用。

- [ ] **Step 5: 本地 dry 测试**

```bash
# 临时把 CODEX_EXEC_BIN 指向 mock
CODEX_EXEC_BIN=$(pwd)/tests/fixtures/codex_exec_mock.sh \
LARK_WEBHOOK_URL_DRY="dry" \
./scripts/send_lark_report.sh --dry 2>&1 | tail -40
```
Expected: 输出含 `P0` 红色标签 + `P2` 黄色标签 + 不含被 rejected 的内容。

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh scripts/send_lark_report.sh
git commit -m "refactor(send-report): 用 codex exec 替换外部翻译 API"
```

---

### Task 2.4: `config/settings.env` 配置换血

**Files:**
- Modify: `config/settings.env`

- [ ] **Step 1: 删旧加新**

```diff
- # CODEX_SUMMARY_API=""
- # CODEX_SUMMARY_TOKEN=""
- # CODEX_SUMMARY_MODEL="gpt-4o-mini"
+ # codex exec (本地复核+翻译)
+ CODEX_EXEC_BIN="codex"
+ CODEX_EXEC_TIMEOUT=300
+ CODEX_EXEC_MODEL=""            # 留空走默认
+ CODEX_EXEC_EXTRA_ARGS=""
```

- [ ] **Step 2: Commit**

```bash
git add config/settings.env
git commit -m "config: 切换到本地 codex exec 配置"
```

---

## Phase 3 — Meegle 自动建缺陷

### Task 3.1: 写 `scripts/lib/blame_lookup.py`

**Files:**
- Create: `scripts/lib/blame_lookup.py`
- Create: `tests/test_blame_lookup.sh`

- [ ] **Step 1: 测试先行**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/blame_lookup.py"

# 用本仓库自身做测试：blame 一行已知存在的代码
out=$(python3 "$PY" --workdir "$ROOT" --file README.md --line-start 1 --line-end 1 2>/dev/null || echo "{}")
echo "$out" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read())
assert "author_email" in d, "no author_email"
print("OK")
'
```

- [ ] **Step 2: 实现**

```python
#!/usr/bin/env python3
"""git blame 一段行范围，输出 author info + 可选映射到 lark/meegle user_key.

Usage:
  blame_lookup.py --workdir <repo> --file <path> --line-start <n> --line-end <n>
                  [--user-map <tsv>] [--default-meegle <user_key>]
"""
import argparse, json, os, subprocess, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--line-start", type=int, required=True)
    ap.add_argument("--line-end", type=int, required=True)
    ap.add_argument("--user-map", default="")
    ap.add_argument("--default-meegle", default="")
    args = ap.parse_args()

    line_start = max(1, args.line_start)
    line_end = max(line_start, args.line_end)
    rel = args.file

    try:
        out = subprocess.check_output(
            ["git", "blame", "--porcelain",
             f"-L{line_start},{line_end}", "--", rel],
            cwd=args.workdir, stderr=subprocess.DEVNULL, text=True,
            timeout=15,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError):
        print(json.dumps({"author_email": "", "author_name": "",
                          "sha": "", "date": "", "meegle_user_key": args.default_meegle}))
        return

    author_name = author_email = sha = date = ""
    for line in out.splitlines():
        if line.startswith("author "):
            author_name = line[len("author "):].strip()
        elif line.startswith("author-mail "):
            author_email = line[len("author-mail "):].strip().strip("<>")
        elif line.startswith("author-time "):
            date = line.split()[-1]
        elif sha == "" and not line.startswith("\t") and len(line.split()) >= 4:
            sha = line.split()[0]

    meegle_key = args.default_meegle
    if args.user_map and os.path.exists(args.user_map) and author_email:
        meegle_key = lookup_user_map(args.user_map, author_email) or args.default_meegle

    print(json.dumps({
        "author_name": author_name,
        "author_email": author_email,
        "sha": sha,
        "date": date,
        "meegle_user_key": meegle_key,
    }, ensure_ascii=False))


def lookup_user_map(path: str, email: str) -> str:
    """TSV: git_email\tlark_user_id\tmeegle_user_key (第3列可选)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if parts[0].lower() == email.lower():
                    if len(parts) >= 3:
                        return parts[2]
                    if len(parts) >= 2:
                        return parts[1]
    except Exception:
        pass
    return ""


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: 跑测试**

Run: `bash tests/test_blame_lookup.sh`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/blame_lookup.py tests/test_blame_lookup.sh
git commit -m "feat(blame): 新增 blame_lookup.py（per-issue 责任人定位）"
```

---

### Task 3.2: 写 `scripts/lib/meegle_bug.py`

**Files:**
- Create: `scripts/lib/meegle_bug.py`
- Create: `tests/test_meegle_bug.sh`

- [ ] **Step 1: 测试先行（用 dry-run，不真建 bug）**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/scripts/lib/meegle_bug.py"

export MEEGLE_BIN="$ROOT/tests/fixtures/meegle_mock.sh"
chmod +x "$MEEGLE_BIN"

state=$(mktemp)
out=$(python3 "$PY" --project-key 6a13e31e9407c20a72ed6e82 \
  --work-item-type issue --state-file "$state" \
  --dry-run \
  --bug '{"severity":"P0","summary":"测试缺陷","file":"a.py","line_start":1,"line_end":1,"repo":"r","pr":"1","pr_url":"http://x","assignee":"u1","blame_author":"foo","blame_sha":"abc","blame_date":"2026-01-01","evidence":"e","original":"o"}')
echo "$out" | grep -q '"dry_run":true' && echo OK
rm -f "$state"
```

`tests/fixtures/meegle_mock.sh`:
```bash
#!/usr/bin/env bash
# Mock meegle CLI: echo args + stdin, return fake work_item_id
exec >&1
echo '{"work_item_id":99999999,"url":"http://example.com/mock/99999999"}'
```

- [ ] **Step 2: 实现 `meegle_bug.py`**

```python
#!/usr/bin/env python3
"""Create Meegle bug from a single review issue, with idempotency.

Usage:
  meegle_bug.py --project-key <pk> --work-item-type <type> \
                --state-file <path> [--dry-run] \
                --bug '<json>'   # single issue payload

Idempotency: state-file is a TSV "pr_url\\tissue_index\\twork_item_id".
"""
import argparse, json, os, subprocess, sys, hashlib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-key", required=True)
    ap.add_argument("--work-item-type", default="issue")
    ap.add_argument("--state-file", required=True)
    ap.add_argument("--bug", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    bug = json.loads(args.bug)
    key = make_idempotency_key(bug)

    existing = load_state(args.state_file)
    if key in existing:
        print(json.dumps({"work_item_id": existing[key], "skipped": True}))
        return

    payload = build_payload(bug)
    if args.dry_run:
        print(json.dumps({"dry_run": True, "payload": payload}, ensure_ascii=False))
        return

    bin_ = os.environ.get("MEEGLE_BIN", "meegle")
    cmd = [bin_, "workitem", "create",
           "--project-key", args.project_key,
           "--work-item-type", args.work_item_type,
           "--params", json.dumps(payload, ensure_ascii=False)]
    try:
        out = subprocess.check_output(cmd, text=True, timeout=30)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"meegle create failed: {e}\n")
        sys.exit(2)

    try:
        result = json.loads(out)
    except json.JSONDecodeError:
        sys.stderr.write(f"meegle returned non-JSON: {out}\n")
        sys.exit(3)

    wid = result.get("work_item_id")
    if wid:
        save_state(args.state_file, key, wid)
    print(json.dumps(result, ensure_ascii=False))


def make_idempotency_key(bug: dict) -> str:
    raw = "|".join([bug.get("pr_url", ""), bug.get("file", ""),
                    str(bug.get("line_start", 0)),
                    bug.get("summary", "")[:80]])
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]


def load_state(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    out = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) >= 2:
                out[parts[0]] = parts[1]
    return out


def save_state(path: str, key: str, wid):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"{key}\t{wid}\n")


def build_payload(b: dict) -> dict:
    name = f"[{b.get('repo','?')}#{b.get('pr','?')}] {b.get('summary','')[:60]}"
    desc = (
        f"## 来源\n"
        f"- 仓库: {b.get('repo','')}\n"
        f"- PR: {b.get('pr_url','')}\n"
        f"- 文件: {b.get('file','')}:{b.get('line_start','')}-{b.get('line_end','')}\n"
        f"- 引入: {b.get('blame_author','?')} @ {b.get('blame_sha','?')} ({b.get('blame_date','?')})\n\n"
        f"## 复核结论\n{b.get('evidence','')}\n\n"
        f"## 原始审查摘录\n{b.get('original','')}\n"
    )
    fields = [
        {"field_key": "name",        "field_value": name},
        {"field_key": "description", "field_value": desc},
    ]
    assignee = b.get("assignee")
    if assignee:
        fields.append({"field_key": "current_status_operator",
                       "field_value": [assignee]})
    return {"fields": fields}


if __name__ == "__main__":
    main()
```

> NOTE: severity / tags 字段映射故意暂不放进 payload —— 因为 Meegle severity 是 select 类型，option_id 需要先 query meta-fields。下一个任务 (3.3) 加 severity 映射加载。

- [ ] **Step 3: 跑测试**

Run: `bash tests/test_meegle_bug.sh`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/meegle_bug.py tests/test_meegle_bug.sh tests/fixtures/meegle_mock.sh
git commit -m "feat(meegle): 新增 meegle_bug.py（字段映射+幂等+dry-run）"
```

---

### Task 3.3: 加 severity option_id 映射

**Files:**
- Modify: `scripts/lib/meegle_bug.py` (加 `--severity-map`)

- [ ] **Step 1: 跑一次 meta-fields 拿真实 option_id**

```bash
meegle workitem meta-fields --project-key 6a13e31e9407c20a72ed6e82 --work-item-type issue \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)
for f in d["list"]:
  if f["field_key"] in ("severity","priority"):
    print(f["field_key"], "===")
    for o in f.get("options", []):
      print(" ", o.get("label"), "->", o.get("value") or o.get("option_id") or o.get("key"))
'
```

记下每个 P0-P5 对应的 option_id（或 Meegle 习惯叫 `value`），写到 `config/settings.env`：

```bash
MEEGLE_SEVERITY_MAP="P0:<id> P1:<id> P2:<id> P3:<id> P4:<id> P5:<id>"
```

- [ ] **Step 2: 在 `meegle_bug.py` 的 `build_payload` 里支持 severity 字段**

```python
# 在文件顶部加：
import os
SEV_MAP = {}
raw = os.environ.get("MEEGLE_SEVERITY_MAP", "")
for tok in raw.split():
    if ":" in tok:
        k, v = tok.split(":", 1); SEV_MAP[k.strip()] = v.strip()

# build_payload 里加：
sev = b.get("severity")
if sev and sev in SEV_MAP:
    fields.append({"field_key": "severity", "field_value": SEV_MAP[sev]})
```

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/meegle_bug.py config/settings.env
git commit -m "feat(meegle): 加 severity 字段映射（env 配置）"
```

---

### Task 3.4: 在 `send_lark_report.sh` webhook 成功后批量建 bug

**Files:**
- Modify: `scripts/lib.sh` (新增 `create_meegle_bugs`)
- Modify: `scripts/send_lark_report.sh` (webhook 后调用)

- [ ] **Step 1: 在 `scripts/lib.sh` 加封装**

```bash
# Create one Meegle bug per accumulated issue.
# Reads global array ISSUES_FOR_MEEGLE (pipe-separated).
# Args: workdir (for git blame)
create_meegle_bugs() {
  local workdir="$1"
  [[ "${MEEGLE_AUTO_CREATE:-0}" == "1" ]] || { log "meegle auto-create disabled, skipping"; return 0; }
  [[ -x "$(command -v "${MEEGLE_BIN:-meegle}")" ]] || { log "meegle CLI missing, skipping"; return 0; }
  [[ ${#ISSUES_FOR_MEEGLE[@]} -eq 0 ]] && return 0

  local script_dir; script_dir="$(dirname "${BASH_SOURCE[0]}")"
  local state_file="${STATE_DIR:-/tmp}/meegle-created.tsv"
  local user_map="${LARK_USER_MAP:-config/lark_user_map.tsv}"

  for spec in "${ISSUES_FOR_MEEGLE[@]}"; do
    IFS='|' read -r severity summary file line_start line_end repo pr pr_url evidence original <<<"$spec"
    [[ -z "$summary" || "$file" == "" ]] && continue

    # 1. blame
    local blame_json
    blame_json=$(python3 "$script_dir/lib/blame_lookup.py" \
      --workdir "$workdir" --file "$file" \
      --line-start "$line_start" --line-end "$line_end" \
      --user-map "$user_map" \
      --default-meegle "${MEEGLE_DEFAULT_ASSIGNEE:-}")

    local assignee blame_author blame_sha blame_date
    assignee=$(echo "$blame_json"     | python3 -c 'import json,sys;print(json.load(sys.stdin).get("meegle_user_key",""))')
    blame_author=$(echo "$blame_json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("author_name",""))')
    blame_sha=$(echo "$blame_json"    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("sha","")[:8])')
    blame_date=$(echo "$blame_json"   | python3 -c 'import json,sys;print(json.load(sys.stdin).get("date",""))')

    # 2. 拼 bug payload
    local bug_json
    bug_json=$(python3 -c "
import json,sys
print(json.dumps({
  'severity': '$severity', 'summary': '''$summary''',
  'file': '$file', 'line_start': $line_start, 'line_end': $line_end,
  'repo': '$repo', 'pr': '$pr', 'pr_url': '$pr_url',
  'assignee': '$assignee',
  'blame_author': '''$blame_author''', 'blame_sha': '$blame_sha', 'blame_date': '$blame_date',
  'evidence': '''$evidence''', 'original': '''$original''',
}, ensure_ascii=False))")

    # 3. 调建单
    local dry_flag=""
    [[ "${DRY_RUN:-0}" == "1" ]] && dry_flag="--dry-run"
    python3 "$script_dir/lib/meegle_bug.py" \
      --project-key "${MEEGLE_PROJECT_KEY}" \
      --work-item-type "${MEEGLE_WORK_ITEM_TYPE:-issue}" \
      --state-file "$state_file" \
      $dry_flag \
      --bug "$bug_json" \
      || log "meegle create failed for: $summary"
  done
}
```

- [ ] **Step 2: 在 `send_lark_report.sh` 顶部声明数组**

```bash
declare -a ISSUES_FOR_MEEGLE=()
```

放到主流程开始处（变量初始化区）。

- [ ] **Step 3: webhook 成功后调用**

找到 webhook POST 之后的位置（搜 `curl.*LARK_WEBHOOK_URL`），在 HTTP 200 后调：

```bash
if [[ "$http_code" == "200" ]]; then
  create_meegle_bugs "$WORKDIR/$repo_basename" || log "meegle batch had errors"
fi
```

- [ ] **Step 4: 加配置**

`config/settings.env`：

```bash
# Meegle 自动建缺陷
MEEGLE_PROJECT_KEY="6a13e31e9407c20a72ed6e82"
MEEGLE_WORK_ITEM_TYPE="issue"
MEEGLE_BIN="meegle"
MEEGLE_DEFAULT_ASSIGNEE=""
MEEGLE_AUTO_CREATE=1
MEEGLE_SEVERITY_MAP=""    # 见 Task 3.3 步骤 1
```

- [ ] **Step 5: 本地 dry 端到端测试**

```bash
DRY_RUN=1 \
CODEX_EXEC_BIN=$(pwd)/tests/fixtures/codex_exec_mock.sh \
MEEGLE_BIN=$(pwd)/tests/fixtures/meegle_mock.sh \
MEEGLE_AUTO_CREATE=1 \
LARK_WEBHOOK_URL_DRY="dry" \
./scripts/send_lark_report.sh --dry 2>&1 | tail -40
```
Expected: 看到 `dry_run":true` 行；state file 未写入；无报错。

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh scripts/send_lark_report.sh config/settings.env
git commit -m "feat(send-report): webhook 成功后批量建 Meegle 缺陷"
```

---

## Phase 4 — 收尾

### Task 4.1: README 更新

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 把 CODEX_SUMMARY_* 段落换成 codex exec 说明**
- [ ] **Step 2: 新增「Meegle 自动建缺陷」段落**
- [ ] **Step 3: 新增「远程部署」段落，明确 `/Users/leo/codex-review` 与 `./scripts/deploy.sh`**
- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: 更新流程与配置说明（codex exec + meegle + deploy）"
```

---

### Task 4.2: 远程引导

**Files:**
- None（远程命令）

- [ ] **Step 1: SSH 到远程检查**

```bash
ssh leo@192.168.0.190 'cd /Users/leo/codex-review && git log -3 --oneline && which codex && which meegle'
```
Expected: 看到 deploy 出去的最新 commit；codex / meegle 都存在。

- [ ] **Step 2: 远程登录 meegle（必要时）**

```bash
ssh -t leo@192.168.0.190 'meegle auth login --device-code --phase init --host project.larksuite.com'
```
（按返回 URL 浏览器授权，再跑 `--phase poll`；这一步必须用户操作）

- [ ] **Step 3: 远程 dry 测试**

```bash
ssh leo@192.168.0.190 'cd /Users/leo/codex-review && \
  DRY_RUN=1 LARK_WEBHOOK_URL_DRY="dry" ./scripts/send_lark_report.sh --dry' | tail -40
```
Expected: dry 输出含 codex 复核 + meegle dry 输出。

---

### Task 4.3: 真实试跑 + 验收

- [ ] **Step 1: 找一个最近 1-2 天有 codex review 的 PR**
- [ ] **Step 2: 远程 `FORCE_REVIEW=1 ./scripts/send_lark_report.sh`** —— 观察：
  - 飞书群是否收到中文 P0-P5 卡片
  - Meegle Code Review 项目是否多了 N 条 bug（N = issue 数）
  - bug 的 assignee 是否符合预期
  - `${STATE_DIR}/meegle-created.tsv` 是否有写入
- [ ] **Step 3: 同一 PR 再跑一次** —— 观察：
  - 飞书可能重发（原行为），但 Meegle 不应该再建（幂等命中）
- [ ] **Step 4: 故障注入** —— 把 `CODEX_EXEC_BIN` 改成不存在的路径，跑一次：
  - 应该退到「发原文不分级」，不应崩溃，不应建 bug

---

### Task 4.4: 收口

- [ ] **Step 1: 把 `scripts/lib.sh` 里旧 `summarize_review_with_ai` 残骸彻底删干净（如有）**
- [ ] **Step 2: 跑一次完整测试套件**

```bash
bash tests/test_codex_review.sh && \
bash tests/test_blame_lookup.sh && \
bash tests/test_meegle_bug.sh
```
Expected: 3 个 `OK`

- [ ] **Step 3: 最终 commit（如有零碎）**
- [ ] **Step 4: deploy**

```bash
./scripts/deploy.sh "feat: 完成 codex exec + meegle + deploy 改造"
```

---

## 风险 / 回滚

| 风险 | 触发条件 | 回滚 |
|---|---|---|
| codex exec 在远程行为不一致 | 远程 codex 版本旧 | `CODEX_EXEC_BIN=/path/to/old/codex` 或 git revert codex_review 相关 commit |
| Meegle 把测试 bug 建到生产项目了 | 试跑期 | 在 Meegle UI 手动批量改状态为「废弃」；幂等表保留 |
| Deploy 撞 cron | 06:00 / 09:00 附近 | deploy.sh 已加 pgrep 检测；手动等到 cron 结束 |
| 远程 meegle token 过期 | 90 天后 | `meegle auth login --device-code` 再走一次 |

---

## 不在本计划

- Meegle bug 状态回写到 PR 评论
- 跨 Meegle 项目分流
- 严重度阈值过滤（用户明确要全量建单）
- Meegle CLI 升级 / 包管理（用 npm 全局，远程已有）
