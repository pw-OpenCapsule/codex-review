#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
load_settings "$ROOT_DIR"

ensure_dirs

usage() {
  cat <<'EOF'
Usage: build_review_dashboard.sh [--days N] [--repo PATTERN] [--output FILE] [--json FILE]
  --days N        读取最近 N 天 run-*.tsv（默认 30）
  --repo PATTERN  只展示仓库名匹配 PATTERN 的记录
  --output FILE   HTML 输出路径（默认 $RUN_DIR/review-dashboard.html）
  --json FILE     JSON 输出路径（默认 $RUN_DIR/review-dashboard.json）
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
from pathlib import Path

run_dir = Path(os.environ["RUN_DIR"])
days = int(os.environ["DAYS"])
repo_pattern = (os.environ.get("REPO_PATTERN") or "").lower()
output_file = Path(os.environ["OUTPUT_FILE"])
json_file = Path(os.environ["JSON_FILE"])
today = dt.date.today()
start_date = today - dt.timedelta(days=days - 1)


def parse_run_date(path: Path):
    m = re.fullmatch(r"run-(\d{4}-\d{2}-\d{2})\.tsv", path.name)
    if not m:
        return None
    try:
        return dt.date.fromisoformat(m.group(1))
    except ValueError:
        return None


def read_artifact(path: str) -> dict:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception as exc:
        return {"metadata": {}, "issues": [], "rejected": [], "_error": str(exc)}


def severity_rank(severity: str) -> int:
    if re.fullmatch(r"P[0-5]", severity or ""):
        return int(severity[1])
    return 99


def summarize_issues(issues: list[dict]):
    severities = [(issue.get("severity") or "P5").upper() for issue in issues]
    severities = [sev if re.fullmatch(r"P[0-5]", sev) else "P5" for sev in severities]
    max_severity = min(severities, key=severity_rank) if severities else ""
    return max_severity, len(issues)


def bucket_for(issue_count: int, sent: bool) -> str:
    if issue_count == 0:
        return "clean"
    if sent:
        return "reported"
    return "with_issues"


def bucket_label(bucket: str) -> str:
    return {
        "clean": "无风险",
        "reported": "已通知",
        "with_issues": "有风险",
    }.get(bucket, bucket)


rows = []
failures = []
for run_file in sorted(run_dir.glob("run-*.tsv")):
    file_date = parse_run_date(run_file)
    if file_date is None or file_date < start_date or file_date > today:
        continue
    for raw in run_file.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        parts = raw.split("\t")
        if len(parts) < 7:
            continue
        gitlab_path, branch, gh_repo, base_sha, head_sha, artifact_json, artifact_md = parts[:7]
        haystack = f"{gitlab_path} {branch} {gh_repo}".lower()
        if repo_pattern and repo_pattern not in haystack:
            continue
        artifact = read_artifact(artifact_json)
        if artifact.get("_error"):
            failures.append({"artifact": artifact_json, "error": artifact["_error"]})
        issues = artifact.get("issues") or []
        max_severity, issue_count = summarize_issues(issues)
        report_file = run_dir / f"report-{file_date.isoformat()}-{gitlab_path.replace('/', '_')}-{branch.replace('/', '-')}.txt"
        report_sent = report_file.exists()
        bucket = bucket_for(issue_count, report_sent)
        meta = artifact.get("metadata") or {}
        first_issue = issues[0] if issues else {}
        rows.append({
            "date": file_date.isoformat(),
            "gitlabPath": gitlab_path,
            "branch": branch,
            "ghRepo": gh_repo,
            "baseSha": base_sha,
            "headSha": head_sha,
            "artifactJson": artifact_json,
            "artifactMarkdown": artifact_md,
            "reviewBackend": meta.get("review_backend") or "codex_sdk",
            "model": meta.get("model") or "",
            "bucket": bucket,
            "bucketLabel": bucket_label(bucket),
            "reportSent": report_sent,
            "maxSeverity": max_severity,
            "issueCount": issue_count,
            "firstIssueSummary": first_issue.get("summary_zh") or first_issue.get("summary") or "",
            "firstIssueFile": first_issue.get("file") or "",
            "firstIssueLine": first_issue.get("line_start") or "",
        })

rows.sort(key=lambda row: (row["date"], severity_rank(row["maxSeverity"]), row["gitlabPath"]), reverse=True)

summary = {
    "generatedAt": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
    "days": days,
    "total": len(rows),
    "clean": sum(1 for row in rows if row["bucket"] == "clean"),
    "reported": sum(1 for row in rows if row["bucket"] == "reported"),
    "withIssues": sum(1 for row in rows if row["issueCount"] > 0),
    "failures": failures,
}

payload = {"summary": summary, "reviews": rows}
json_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

cards = []
for row in rows:
    severity = html.escape(row["maxSeverity"] or "OK")
    title = html.escape(f"{row['gitlabPath']}@{row['branch']}")
    summary_text = html.escape(row["firstIssueSummary"] or "未发现 P0-P5 风险项")
    location = ""
    if row["firstIssueFile"]:
        location = f"{row['firstIssueFile']}:{row['firstIssueLine']}" if row["firstIssueLine"] else row["firstIssueFile"]
    cards.append(f"""
      <article class="card {html.escape(row['bucket'])}">
        <div class="top">
          <span class="severity">{severity}</span>
          <span class="date">{html.escape(row['date'])}</span>
        </div>
        <h2>{title}</h2>
        <p>{summary_text}</p>
        <dl>
          <dt>范围</dt><dd>{html.escape(row['baseSha'][:8])}..{html.escape(row['headSha'][:8])}</dd>
          <dt>问题数</dt><dd>{row['issueCount']}</dd>
          <dt>位置</dt><dd>{html.escape(location or "-")}</dd>
          <dt>报告</dt><dd>{'已生成' if row['reportSent'] else '未生成'}</dd>
        </dl>
      </article>
    """)

cards_html = "\n".join(cards) or '<div class="empty">没有本地审查记录。</div>'
generated = html.escape(summary["generatedAt"])
output_file.write_text(f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex Review Dashboard</title>
  <style>
    body {{ margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f7f8fa; color: #1f2937; }}
    header {{ padding: 24px 32px; background: #fff; border-bottom: 1px solid #e5e7eb; }}
    h1 {{ margin: 0 0 8px; font-size: 24px; }}
    .summary {{ display: flex; gap: 16px; flex-wrap: wrap; color: #4b5563; }}
    main {{ padding: 24px 32px; display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }}
    .card {{ background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; }}
    .top {{ display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }}
    .severity {{ font-weight: 700; color: #b91c1c; }}
    .date {{ color: #6b7280; font-size: 13px; }}
    h2 {{ margin: 0 0 8px; font-size: 17px; }}
    p {{ min-height: 42px; margin: 0 0 12px; }}
    dl {{ display: grid; grid-template-columns: 72px 1fr; gap: 6px 12px; margin: 0; font-size: 13px; }}
    dt {{ color: #6b7280; }}
    dd {{ margin: 0; overflow-wrap: anywhere; }}
    .clean .severity {{ color: #15803d; }}
    .empty {{ grid-column: 1 / -1; padding: 40px; text-align: center; color: #6b7280; }}
  </style>
</head>
<body>
  <header>
    <h1>Codex Review Dashboard</h1>
    <div class="summary">
      <span>生成：{generated}</span>
      <span>总数：{summary['total']}</span>
      <span>有风险：{summary['withIssues']}</span>
      <span>无风险：{summary['clean']}</span>
      <span>已生成报告：{summary['reported']}</span>
    </div>
  </header>
  <main>
    {cards_html}
  </main>
</body>
</html>
""", encoding="utf-8")
PY

log "已生成 Review 状态页：$OUTPUT_FILE"
log "已生成 Review 状态 JSON：$JSON_FILE"
