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
    {{
      "issues": [
        {{"severity":"P0|P1|P2|P3|P4|P5",
         "summary_zh":"中文问题描述（保留反引号包裹的标识符）",
         "file":"相对路径","line_start":<int>,"line_end":<int>,
         "evidence":"复核理由"}}
      ],
      "rejected": [
        {{"severity":"P?","original":"原文摘录","reason":"为什么判为误报"}}
      ]
    }}

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
        sys.stderr.write("codex_review: failed to parse JSON\n")
        sys.stderr.write("---raw---\n" + raw + "\n")
        print(json.dumps({"issues": [], "rejected": [],
                          "error": "parse_failed"}))
        sys.exit(3)

    parsed.setdefault("issues", [])
    parsed.setdefault("rejected", [])
    print(json.dumps(parsed, ensure_ascii=False))


def extract_json(raw: str):
    raw = raw.strip()
    if not raw:
        return None
    if raw.startswith("```"):
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
