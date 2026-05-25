#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
load_settings "$ROOT_DIR"

ensure_dirs
ensure_gh_auth

usage() {
  cat <<'EOF'
Usage: build_review_dashboard.sh [--days N] [--repo PATTERN] [--output FILE] [--json FILE]
  --days N       读取最近 N 天 run-*.tsv（默认 30）
  --repo PATTERN 只展示 GitLab/GitHub 仓库名匹配 PATTERN 的记录
  --output FILE  HTML 输出路径（默认 $RUN_DIR/review-dashboard.html）
  --json FILE    JSON 输出路径（默认 $RUN_DIR/review-dashboard.json）
EOF
}

DAYS="${REVIEW_DASHBOARD_DAYS:-30}"
REPO_PATTERN=""
OUTPUT_FILE="${REVIEW_DASHBOARD_OUTPUT:-$RUN_DIR/review-dashboard.html}"
JSON_FILE="${REVIEW_DASHBOARD_JSON:-$RUN_DIR/review-dashboard.json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      DAYS="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_PATTERN="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    --json)
      JSON_FILE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

if [[ ! "$DAYS" =~ ^[0-9]+$ || "$DAYS" -le 0 ]]; then
  die "--days 必须是正整数"
fi

mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$JSON_FILE")"

RUN_DIR="$RUN_DIR" DAYS="$DAYS" REPO_PATTERN="$REPO_PATTERN" OUTPUT_FILE="$OUTPUT_FILE" JSON_FILE="$JSON_FILE" \
python3 - <<'PY'
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

run_dir = Path(os.environ["RUN_DIR"])
days = int(os.environ["DAYS"])
repo_pattern = (os.environ.get("REPO_PATTERN") or "").lower()
output_file = Path(os.environ["OUTPUT_FILE"])
json_file = Path(os.environ["JSON_FILE"])
today = dt.date.today()
start_date = today - dt.timedelta(days=days - 1)


def sh(cmd):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def parse_date(path: Path):
    m = re.match(r"run-(\d{4}-\d{2}-\d{2})\.tsv$", path.name)
    if not m:
        return None
    try:
        return dt.date.fromisoformat(m.group(1))
    except ValueError:
        return None


def marker_sent(text: str) -> bool:
    return any(
        item in text
        for item in (
            "已发送日报",
            "已发送周报",
            "已发送3日节奏报告",
            "已发送5日节奏报告",
            "已发送手动报告",
        )
    )


def prompt_or_marker(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    if marker_sent(stripped):
        return True
    if "@codex review" in stripped:
        return True
    if stripped in ("审查结果已发送。", "审查结果已发送"):
        return True
    return False


def collect_review_text(pr: dict) -> str:
    texts = []
    for item in pr.get("comments") or []:
        body = item.get("body") or ""
        if not prompt_or_marker(body):
            texts.append(body)
    for item in pr.get("reviews") or []:
        body = item.get("body") or ""
        if not prompt_or_marker(body):
            texts.append(body)
    return "\n".join(texts)


def severity_summary(text: str):
    found = [m.group(0).upper() for m in re.finditer(r"\bP[0-5]\b|P[0-5]\s*Badge", text, re.I)]
    cleaned = [re.search(r"P[0-5]", item, re.I).group(0).upper() for item in found]
    if not cleaned:
        return None, 0
    max_sev = sorted(cleaned, key=lambda s: int(s[1]))[0]
    return max_sev, len(cleaned)


def bucket_for(pr_state: str, has_review: bool, report_sent: bool) -> str:
    if pr_state in ("MERGED", "CLOSED"):
        return "done"
    if not has_review:
        return "waiting"
    if report_sent:
        return "open_reported"
    return "open_unreported"


def bucket_label(bucket: str) -> str:
    return {
        "done": "已处理",
        "waiting": "等待审查",
        "open_reported": "未处理(已通知)",
        "open_unreported": "未处理(待通知)",
    }.get(bucket, bucket)


entries = {}
for run_file in sorted(run_dir.glob("run-*.tsv")):
    file_date = parse_date(run_file)
    if file_date is None or file_date < start_date or file_date > today:
        continue
    with run_file.open("r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 5:
                continue
            gitlab_path, branch, gh_repo, pr_number, pr_url = parts[:5]
            haystack = f"{gitlab_path} {branch} {gh_repo} {pr_number}".lower()
            if repo_pattern and repo_pattern not in haystack:
                continue
            key = f"{gh_repo}#{pr_number}"
            entry = entries.setdefault(
                key,
                {
                    "firstDate": file_date.isoformat(),
                    "lastDate": file_date.isoformat(),
                    "gitlabPath": gitlab_path,
                    "branch": branch,
                    "ghRepo": gh_repo,
                    "prNumber": pr_number,
                    "prUrl": pr_url,
                },
            )
            entry["lastDate"] = max(entry["lastDate"], file_date.isoformat())

rows = []
failures = []
for key, entry in sorted(entries.items(), key=lambda item: (item[1]["lastDate"], item[0]), reverse=True):
    result = sh(
        [
            "gh",
            "pr",
            "view",
            entry["prNumber"],
            "--repo",
            entry["ghRepo"],
            "--json",
            "number,title,state,url,createdAt,updatedAt,closedAt,mergedAt,comments,reviews,additions,deletions,changedFiles,reviewDecision",
        ]
    )
    if result.returncode != 0:
        failures.append({"key": key, "error": result.stderr.strip()})
        continue
    pr = json.loads(result.stdout)
    comments = pr.get("comments") or []
    reviews = pr.get("reviews") or []
    all_bodies = "\n".join((item.get("body") or "") for item in comments + reviews)
    review_text = collect_review_text(pr)
    has_review = bool(review_text.strip())
    report_sent = marker_sent(all_bodies)
    max_severity, issue_count = severity_summary(review_text)
    state = pr.get("state") or "UNKNOWN"
    bucket = bucket_for(state, has_review, report_sent)
    rows.append(
        {
            **entry,
            "title": pr.get("title") or "",
            "state": state,
            "bucket": bucket,
            "bucketLabel": bucket_label(bucket),
            "createdAt": pr.get("createdAt") or "",
            "updatedAt": pr.get("updatedAt") or "",
            "closedAt": pr.get("closedAt") or "",
            "mergedAt": pr.get("mergedAt") or "",
            "reviewDecision": pr.get("reviewDecision") or "",
            "additions": pr.get("additions") or 0,
            "deletions": pr.get("deletions") or 0,
            "changedFiles": pr.get("changedFiles") or 0,
            "hasReview": has_review,
            "reportSent": report_sent,
            "maxSeverity": max_severity or "",
            "issueCount": issue_count,
        }
    )

summary = {
    "generatedAt": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
    "days": days,
    "total": len(rows),
    "done": sum(1 for row in rows if row["bucket"] == "done"),
    "waiting": sum(1 for row in rows if row["bucket"] == "waiting"),
    "openReported": sum(1 for row in rows if row["bucket"] == "open_reported"),
    "openUnreported": sum(1 for row in rows if row["bucket"] == "open_unreported"),
    "failures": failures,
}

json_file.write_text(json.dumps({"summary": summary, "reviews": rows}, ensure_ascii=False, indent=2), encoding="utf-8")

data_json = json.dumps({"summary": summary, "reviews": rows}, ensure_ascii=False).replace("</", "<\\/")
generated = html.escape(summary["generatedAt"])
html_text = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Code Review 状态</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f6f7f9;
      --panel: #ffffff;
      --text: #20242a;
      --muted: #667085;
      --line: #d9dee7;
      --blue: #2563eb;
      --green: #11845b;
      --orange: #b45309;
      --red: #b42318;
      --slate: #475467;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    header {{
      padding: 20px 24px 14px;
      background: var(--panel);
      border-bottom: 1px solid var(--line);
      position: sticky;
      top: 0;
      z-index: 2;
    }}
    h1 {{
      margin: 0 0 12px;
      font-size: 22px;
      font-weight: 700;
      letter-spacing: 0;
    }}
    .toolbar {{
      display: grid;
      grid-template-columns: minmax(220px, 1fr) auto;
      gap: 12px;
      align-items: center;
    }}
    input {{
      width: 100%;
      height: 36px;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 0 11px;
      font: inherit;
      background: #fff;
    }}
    .filters {{
      display: flex;
      gap: 6px;
      flex-wrap: wrap;
      justify-content: flex-end;
    }}
    button {{
      height: 36px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #fff;
      color: var(--text);
      padding: 0 10px;
      font: inherit;
      cursor: pointer;
    }}
    button.active {{
      border-color: var(--blue);
      color: var(--blue);
      background: #eff6ff;
    }}
    main {{ padding: 18px 24px 32px; }}
    .meta {{
      display: grid;
      grid-template-columns: repeat(5, minmax(120px, 1fr));
      gap: 10px;
      margin-bottom: 16px;
    }}
    .stat {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
      min-height: 74px;
    }}
    .stat span {{
      color: var(--muted);
      display: block;
      font-size: 12px;
    }}
    .stat strong {{
      display: block;
      font-size: 24px;
      margin-top: 4px;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      overflow: hidden;
    }}
    th, td {{
      padding: 10px 12px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
    }}
    th {{
      color: var(--muted);
      font-size: 12px;
      font-weight: 600;
      background: #fbfcfe;
      white-space: nowrap;
    }}
    tr:last-child td {{ border-bottom: 0; }}
    a {{ color: var(--blue); text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
    .repo {{ font-weight: 650; }}
    .sub {{ color: var(--muted); font-size: 12px; margin-top: 2px; }}
    .badge {{
      display: inline-flex;
      align-items: center;
      min-height: 24px;
      border-radius: 999px;
      padding: 2px 8px;
      font-size: 12px;
      font-weight: 650;
      white-space: nowrap;
    }}
    .done {{ background: #ecfdf3; color: var(--green); }}
    .waiting {{ background: #f2f4f7; color: var(--slate); }}
    .open_reported {{ background: #fff7ed; color: var(--orange); }}
    .open_unreported {{ background: #fef3f2; color: var(--red); }}
    .severity {{ margin-left: 6px; background: #eef2ff; color: #3730a3; }}
    .empty {{
      display: none;
      padding: 28px;
      text-align: center;
      color: var(--muted);
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
    }}
    @media (max-width: 900px) {{
      header {{ position: static; }}
      .toolbar {{ grid-template-columns: 1fr; }}
      .filters {{ justify-content: flex-start; }}
      .meta {{ grid-template-columns: repeat(2, minmax(120px, 1fr)); }}
      table, thead, tbody, th, td, tr {{ display: block; }}
      thead {{ display: none; }}
      tr {{ border-bottom: 1px solid var(--line); }}
      td {{ border-bottom: 0; padding: 7px 12px; }}
      td::before {{
        content: attr(data-label);
        display: block;
        color: var(--muted);
        font-size: 12px;
      }}
    }}
  </style>
</head>
<body>
  <header>
    <h1>Code Review 状态</h1>
    <div class="toolbar">
      <input id="search" type="search" placeholder="搜索仓库、分支、PR、标题">
      <div class="filters">
        <button class="active" data-filter="all">全部</button>
        <button data-filter="open_reported">未处理(已通知)</button>
        <button data-filter="open_unreported">未处理(待通知)</button>
        <button data-filter="waiting">等待审查</button>
        <button data-filter="done">已处理</button>
      </div>
    </div>
  </header>
  <main>
    <section class="meta">
      <div class="stat"><span>总数</span><strong id="stat-total">0</strong></div>
      <div class="stat"><span>未处理(已通知)</span><strong id="stat-open-reported">0</strong></div>
      <div class="stat"><span>未处理(待通知)</span><strong id="stat-open-unreported">0</strong></div>
      <div class="stat"><span>等待审查</span><strong id="stat-waiting">0</strong></div>
      <div class="stat"><span>已处理</span><strong id="stat-done">0</strong></div>
    </section>
    <div class="sub" style="margin-bottom: 10px;">生成时间：{generated}，范围：最近 {days} 天</div>
    <table>
      <thead>
        <tr>
          <th>项目</th>
          <th>状态</th>
          <th>风险</th>
          <th>PR</th>
          <th>更新时间</th>
          <th>变更</th>
        </tr>
      </thead>
      <tbody id="rows"></tbody>
    </table>
    <div id="empty" class="empty">没有匹配的 review。</div>
  </main>
  <script id="data" type="application/json">{data_json}</script>
  <script>
    const data = JSON.parse(document.getElementById("data").textContent);
    const rowsEl = document.getElementById("rows");
    const emptyEl = document.getElementById("empty");
    const searchEl = document.getElementById("search");
    let filter = "all";

    function esc(value) {{
      return String(value ?? "").replace(/[&<>"']/g, ch => ({{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}}[ch]));
    }}

    function matches(row, query) {{
      if (filter !== "all" && row.bucket !== filter) return false;
      if (!query) return true;
      const text = [row.gitlabPath, row.branch, row.ghRepo, row.prNumber, row.title, row.state, row.bucketLabel].join(" ").toLowerCase();
      return text.includes(query);
    }}

    function render() {{
      const query = searchEl.value.trim().toLowerCase();
      const visible = data.reviews.filter(row => matches(row, query));
      const counts = {{total: visible.length, done: 0, waiting: 0, open_reported: 0, open_unreported: 0}};
      for (const row of visible) counts[row.bucket] = (counts[row.bucket] || 0) + 1;
      document.getElementById("stat-total").textContent = counts.total;
      document.getElementById("stat-done").textContent = counts.done;
      document.getElementById("stat-waiting").textContent = counts.waiting;
      document.getElementById("stat-open-reported").textContent = counts.open_reported;
      document.getElementById("stat-open-unreported").textContent = counts.open_unreported;

      rowsEl.innerHTML = visible.map(row => `
        <tr>
          <td data-label="项目">
            <div class="repo">${{esc(row.gitlabPath)}}</div>
            <div class="sub">${{esc(row.branch)}} · ${{esc(row.ghRepo)}}</div>
          </td>
          <td data-label="状态"><span class="badge ${{esc(row.bucket)}}">${{esc(row.bucketLabel)}}</span></td>
          <td data-label="风险">
            ${{row.maxSeverity ? `<span class="badge severity">${{esc(row.maxSeverity)}} · ${{row.issueCount}}</span>` : `<span class="sub">未标注</span>`}}
          </td>
          <td data-label="PR">
            <a href="${{esc(row.prUrl)}}" target="_blank" rel="noreferrer">#${{esc(row.prNumber)}}</a>
            <div class="sub">${{esc(row.title)}}</div>
          </td>
          <td data-label="更新时间">
            <div>${{esc(row.updatedAt || row.lastDate)}}</div>
            <div class="sub">运行：${{esc(row.lastDate)}}</div>
          </td>
          <td data-label="变更">
            <div>${{esc(row.changedFiles)}} files</div>
            <div class="sub">+${{esc(row.additions)}} / -${{esc(row.deletions)}}</div>
          </td>
        </tr>
      `).join("");
      emptyEl.style.display = visible.length ? "none" : "block";
    }}

    searchEl.addEventListener("input", render);
    document.querySelectorAll("button[data-filter]").forEach(button => {{
      button.addEventListener("click", () => {{
        document.querySelectorAll("button[data-filter]").forEach(item => item.classList.remove("active"));
        button.classList.add("active");
        filter = button.dataset.filter;
        render();
      }});
    }});
    render();
  </script>
</body>
</html>
"""

output_file.write_text(html_text, encoding="utf-8")
print(f"wrote {output_file}")
print(f"wrote {json_file}")
if failures:
    print(f"warning: failed to load {len(failures)} PRs", file=sys.stderr)
PY
