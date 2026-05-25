#!/usr/bin/env python3
"""Create Meegle bug from a single review issue, with idempotency.

Usage:
  meegle_bug.py --project-key <pk> --work-item-type <type> \
                --state-file <path> [--dry-run] \
                --bug '<json>'   # single issue payload

Idempotency: state-file is a TSV "key\twork_item_id".
"""
import argparse, json, os, re, subprocess, sys, hashlib

# 启动时一次性加载 severity 映射
SEV_MAP = {}
_raw = os.environ.get("MEEGLE_SEVERITY_MAP", "")
for _tok in _raw.split():
    if ":" in _tok:
        _k, _v = _tok.split(":", 1)
        SEV_MAP[_k.strip()] = _v.strip()


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
        print(json.dumps({"work_item_id": existing[key], "skipped": True}, separators=(",", ":")))
        return

    payload = build_payload(bug)
    if args.dry_run:
        print(json.dumps({"dry_run": True, "payload": payload}, ensure_ascii=False, separators=(",", ":")))
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
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


_CODE_FENCE_RE = re.compile(r"```([a-zA-Z0-9_+-]*)\n(.*?)\n```", re.S)
_CODEX_NOISE_PATTERNS = [
    re.compile(r"(?ms)^###\s*💡\s*Codex Review.*$"),
    re.compile(r"(?ms)^Here are some automated review suggestions.*?$"),
    re.compile(r"(?ms)^\*\*Reviewed commit:\*\*.*?$"),
    re.compile(r"(?ms)^Codex has been enabled.*?(?=\n\n|\Z)"),
    re.compile(r"(?ms)^When you \[sign up for Codex.*?(?=\n\n|\Z)"),
    re.compile(r"(?ms)^CODEX_LOCATION\b.*$"),
    re.compile(r"(?ms)^疑似责任人:.*?（依据: review 行 blame）"),
    re.compile(r"(?ms)^【发现】\s*$"),
    re.compile(r"(?ms)^- Open a pull request for review\s*$"),
    re.compile(r"(?ms)^- Mark a draft as ready\s*$"),
    re.compile(r'(?ms)^- Comment "@codex review"\.\s*$'),
    re.compile(r"(?ms)^If Codex has suggestions.*?$"),
]


def extract_code_snippet(text: str) -> str:
    """Pull the FIRST non-trivial code block out of a codex review blob.
    Returns the block wrapped in fences ready to drop into Markdown."""
    if not text:
        return ""
    for lang, body in _CODE_FENCE_RE.findall(text):
        body = body.strip("\n")
        if not body or len(body.strip()) < 5:
            continue
        return f"```{lang or 'plaintext'}\n{body}\n```"
    return ""


def clean_codex_noise(text: str) -> str:
    """Strip GitHub PR template fluff (Codex intro, signup, etc.) from the
    original review so reviewers see actual findings, not Codex boilerplate."""
    if not text:
        return ""
    out = text
    for pat in _CODEX_NOISE_PATTERNS:
        out = pat.sub("", out)
    # Collapse 3+ blank lines, trim
    out = re.sub(r"\n{3,}", "\n\n", out).strip()
    return out


def classify_bug_end(file_path: str) -> str:
    """Guess bug_classification (ios/android/fe/server) from file extension."""
    f = (file_path or "").lower()
    if not f:
        return ""
    if f.endswith((".swift", ".m", ".mm")) or "/ios/" in f:
        return "ios"
    if f.endswith((".kt", ".java")) and "/android" in f:
        return "android"
    if f.endswith((".kt", ".kts")) or "/android" in f:
        return "android"
    if f.endswith((".vue", ".tsx", ".jsx", ".ts", ".js", ".html",
                   ".css", ".scss", ".less")):
        return "fe"
    if f.endswith((".java", ".go", ".py", ".rs", ".rb", ".php",
                   ".cs", ".cpp", ".c", ".h", ".hpp", ".sql", ".sh")):
        return "server"
    return ""


def make_idempotency_key(bug: dict) -> str:
    """Key on (pr_url, file, line_start). Summary text and line_end are
    excluded because codex paraphrases summaries and varies line ranges
    between runs; same PR + file + starting line = same issue."""
    raw = "|".join([bug.get("pr_url", ""), bug.get("file", ""),
                    str(bug.get("line_start", 0))])
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
    """Build a Meegle workitem.create payload, spreading content across
    discrete custom fields instead of one giant description.

    Custom field keys are env-configurable so a different Meegle project can
    rewire them without touching this file. Unset → that piece falls back
    into the description blob.
    """
    summary = (b.get("summary") or "").strip()
    name = summary[:80] if summary else "(无摘要)"

    file_line = f"{b.get('file','')}:{b.get('line_start','')}"
    if b.get("line_end") and b.get("line_end") != b.get("line_start"):
        file_line += f"-{b.get('line_end')}"
    introducer = b.get("blame_author") or "未知"
    blame_sha = b.get("blame_sha") or ""
    if blame_sha:
        introducer += f" @ {blame_sha}"

    code_snippet = extract_code_snippet(b.get("original", ""))
    evidence = b.get("evidence") or ""

    fields = [{"field_key": "name", "field_value": name}]

    # ---- structured fields (preferred) ----
    field_map = {
        "MEEGLE_FIELD_CODE_LOCATION":  ("code_location",      file_line),
        "MEEGLE_FIELD_PR_URL":         ("pr_url_link",        b.get("pr_url", "")),
        "MEEGLE_FIELD_INTRODUCER":     ("introducer",         introducer),
        "MEEGLE_FIELD_CODE_SNIPPET":   ("code_snippet",       code_snippet),
        "MEEGLE_FIELD_CODEX_VERIFY":   ("codex_verification", evidence),
    }
    used_keys = set()
    for env_name, (_label, value) in field_map.items():
        field_key = os.environ.get(env_name, "").strip()
        if field_key and value:
            fields.append({"field_key": field_key, "field_value": value})
            used_keys.add(env_name)

    # ---- description: only include what didn't make it into a custom field ----
    desc_parts = []
    if "MEEGLE_FIELD_CODE_LOCATION" not in used_keys:
        desc_parts += [f"**位置**: `{file_line}`"]
    if "MEEGLE_FIELD_PR_URL" not in used_keys and b.get("pr_url"):
        desc_parts += [f"**PR**: {b.get('pr_url')}"]
    if "MEEGLE_FIELD_INTRODUCER" not in used_keys:
        desc_parts += [f"**引入**: {introducer}"]
    if desc_parts:
        desc_parts.append("")
    desc_parts += ["## 问题", summary, ""]
    if "MEEGLE_FIELD_CODE_SNIPPET" not in used_keys and code_snippet:
        desc_parts += ["## 代码片段", code_snippet, ""]
    if "MEEGLE_FIELD_CODEX_VERIFY" not in used_keys and evidence:
        desc_parts += ["## codex 核实结论", evidence, ""]
    desc = "\n".join(desc_parts).strip()
    if desc:
        fields.append({"field_key": "description", "field_value": desc})

    # ---- built-in fields ----
    sev = b.get("severity")
    if sev and sev in SEV_MAP:
        fields.append({"field_key": "severity", "field_value": SEV_MAP[sev]})
    classification = classify_bug_end(b.get("file", ""))
    if classification:
        fields.append({"field_key": "bug_classification",
                       "field_value": classification})
    # Meegle current_status_operator wants its own numeric user_key.
    # Lark open_id (ou_xxx) and display names are NOT accepted and cause API errors.
    # If the resolver returns something that's not a numeric user_key,
    # leave the field unset and let Meegle default to the creator.
    assignee = (b.get("assignee") or "").strip()
    if assignee.isdigit():
        fields.append({"field_key": "current_status_operator",
                       "field_value": [assignee]})
    return {"fields": fields}


if __name__ == "__main__":
    main()
