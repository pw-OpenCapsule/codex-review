#!/usr/bin/env python3
"""Run a local Codex SDK code review for a git range.

The script writes a stable JSON artifact and a readable Markdown artifact.
It does not create GitHub PRs, call codex exec, or call HTTP gateways.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_MODEL = "gpt-5.3-codex"
DEFAULT_MAX_DIFF_CHARS = 120_000


PROMPT_TEMPLATE = """\
你是代码审查员。请只审查下面 git diff 表示的变更范围，重点关注：
- 安全风险
- 逻辑正确性
- 数据一致性
- 破坏性变更
- 隐蔽缺陷

忽略格式化、文档、生成文件、小型重构。不要要求创建 PR，不要调用外部系统。

严格输出 JSON，不要任何额外文字：
{{
  "issues": [
    {{
      "severity": "P0|P1|P2|P3|P4|P5",
      "summary_zh": "中文问题描述",
      "file": "相对路径",
      "line_start": 1,
      "line_end": 1,
      "evidence": "为什么这是真实风险"
    }}
  ],
  "rejected": [
    {{"original": "候选问题或疑点", "reason": "为什么不作为风险项"}}
  ]
}}

PR 元信息：
repo={repo}
branch={branch}
base_sha={base_sha}
head_sha={head_sha}

git diff --stat:
{diff_stat}

git diff --find-renames --find-copies:
{diff_text}
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--branch", required=True)
    ap.add_argument("--base-sha", required=True)
    ap.add_argument("--head-sha", required=True)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--output-json", required=True)
    ap.add_argument("--output-markdown", required=True)
    ap.add_argument("--model", default=os.environ.get("CODEX_SDK_MODEL", DEFAULT_MODEL))
    ap.add_argument("--sandbox", default=os.environ.get("CODEX_SDK_SANDBOX", "read_only"))
    ap.add_argument("--timeout", type=int, default=int(os.environ.get("CODEX_SDK_TIMEOUT", "300")))
    ap.add_argument("--max-diff-chars", type=int,
                    default=int(os.environ.get("CODEX_SDK_MAX_DIFF_CHARS", str(DEFAULT_MAX_DIFF_CHARS))))
    args = ap.parse_args()

    workdir = Path(args.workdir)
    if not (workdir / ".git").exists():
      print(json.dumps({"issues": [], "rejected": [], "error": "workdir_not_git"}))
      return 2

    diff_stat = git_output(workdir, ["diff", "--stat", args.base_sha, args.head_sha])
    diff_text = git_output(workdir, [
        "diff", "--find-renames", "--find-copies",
        "--unified=80", args.base_sha, args.head_sha,
    ])
    diff_text = truncate(diff_text, args.max_diff_chars)

    prompt = PROMPT_TEMPLATE.format(
        repo=args.repo,
        branch=args.branch,
        base_sha=args.base_sha,
        head_sha=args.head_sha,
        diff_stat=diff_stat,
        diff_text=diff_text,
    )

    try:
        raw = run_codex_sdk(args.model, args.sandbox, prompt)
    except Exception as exc:
        print(json.dumps({"issues": [], "rejected": [], "error": "codex_sdk_failed",
                          "detail": str(exc)}, ensure_ascii=False))
        return 3

    parsed = extract_json(raw)
    if parsed is None:
        print(json.dumps({"issues": [], "rejected": [], "error": "parse_failed",
                          "raw": raw}, ensure_ascii=False))
        return 4

    metadata = {
        "repo": args.repo,
        "branch": args.branch,
        "base_sha": args.base_sha,
        "head_sha": args.head_sha,
        "model": args.model,
        "sandbox": args.sandbox,
        "review_backend": "codex_sdk",
        "review_date": today(),
        "artifact_json": str(Path(args.output_json).resolve()),
        "artifact_markdown": str(Path(args.output_markdown).resolve()),
    }

    artifact = normalize_artifact(parsed, metadata)
    write_json(Path(args.output_json), artifact)
    markdown = render_markdown(artifact)
    Path(args.output_markdown).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output_markdown).write_text(markdown, encoding="utf-8")
    print(json.dumps(artifact, ensure_ascii=False))
    return 0


def run_codex_sdk(model: str, sandbox_name: str, prompt: str) -> str:
    from openai_codex import Codex, Sandbox

    sandbox = getattr(Sandbox, sandbox_name, Sandbox.read_only)
    with Codex() as codex:
        thread = codex.thread_start(model=model, sandbox=sandbox)
        result = thread.run(prompt, sandbox=sandbox)
    return getattr(result, "final_response", str(result))


def git_output(workdir: Path, args: list[str]) -> str:
    try:
        return subprocess.check_output(
            ["git", *args],
            cwd=str(workdir),
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except subprocess.CalledProcessError:
        return ""


def truncate(text: str, limit: int) -> str:
    if limit <= 0 or len(text) <= limit:
        return text
    return text[:limit] + "\n\n[diff truncated]\n"


def extract_json(raw: str):
    raw = (raw or "").strip()
    if not raw:
        return None
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*", "", raw)
        raw = re.sub(r"\s*```$", "", raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    start = raw.find("{")
    end = raw.rfind("}")
    if start != -1 and end > start:
        try:
            return json.loads(raw[start:end + 1])
        except json.JSONDecodeError:
            return None
    return None


def normalize_artifact(parsed: dict, metadata: dict) -> dict:
    issues = []
    for item in parsed.get("issues") or []:
        issue = {
            "severity": clean_severity(item.get("severity")),
            "summary_zh": str(item.get("summary_zh") or item.get("summary") or "").strip(),
            "file": str(item.get("file") or "").strip(),
            "line_start": to_int(item.get("line_start"), 0),
            "line_end": to_int(item.get("line_end"), to_int(item.get("line_start"), 0)),
            "evidence": str(item.get("evidence") or "").strip(),
        }
        if not issue["summary_zh"]:
            continue
        issue["issue_key"] = issue_key(metadata, issue)
        issues.append(issue)

    return {
        "metadata": metadata,
        "issues": issues,
        "rejected": parsed.get("rejected") or [],
        "markdown": "",
    }


def issue_key(metadata: dict, issue: dict) -> str:
    raw = "|".join([
        metadata.get("repo", ""),
        metadata.get("branch", ""),
        metadata.get("base_sha", ""),
        metadata.get("head_sha", ""),
        issue.get("file", ""),
        str(issue.get("line_start", "")),
        issue.get("summary_zh", ""),
    ])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def render_markdown(artifact: dict) -> str:
    meta = artifact["metadata"]
    lines = [
        f"# 代码审查报告 - {meta['repo']}@{meta['branch']}",
        "",
        f"- 范围: `{meta['base_sha'][:8]}..{meta['head_sha'][:8]}`",
        f"- Backend: `{meta['review_backend']}`",
        f"- Model: `{meta['model']}`",
        "",
    ]
    issues = artifact.get("issues") or []
    if not issues:
        lines.append("未发现 P0-P5 风险项。")
        return "\n".join(lines) + "\n"
    for issue in issues:
        loc = issue.get("file") or ""
        if issue.get("line_start"):
            loc += f":{issue['line_start']}"
            if issue.get("line_end") and issue["line_end"] != issue["line_start"]:
                loc += f"-{issue['line_end']}"
        lines.extend([
            f"## {issue['severity']} {issue['summary_zh']}",
            "",
            f"- 位置: `{loc}`",
            f"- 证据: {issue.get('evidence', '')}",
            "",
        ])
    return "\n".join(lines)


def clean_severity(value) -> str:
    sev = str(value or "P5").upper()
    return sev if re.fullmatch(r"P[0-5]", sev) else "P5"


def to_int(value, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def today() -> str:
    tz = os.environ.get("TZ")
    if tz:
        return dt.datetime.now().strftime("%F")
    return dt.date.today().isoformat()


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    copy = dict(data)
    copy["markdown"] = render_markdown(data)
    path.write_text(json.dumps(copy, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
