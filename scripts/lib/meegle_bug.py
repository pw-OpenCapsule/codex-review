#!/usr/bin/env python3
"""Create Meegle bug from a single review issue, with idempotency.

Usage:
  meegle_bug.py --project-key <pk> --work-item-type <type> \
                --state-file <path> [--dry-run] \
                --bug '<json>'   # single issue payload

Idempotency: state-file is a TSV "key\twork_item_id".
"""
import argparse, json, os, subprocess, sys, hashlib

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
    sev = b.get("severity")
    if sev and sev in SEV_MAP:
        fields.append({"field_key": "severity", "field_value": SEV_MAP[sev]})
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
