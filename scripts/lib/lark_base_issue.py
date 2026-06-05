#!/usr/bin/env python3
"""Upsert local Codex review issues into a Lark Base table via lark-cli."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


DEFAULT_FIELDS = {
    "issue_key": "issue_key",
    "repo": "repo",
    "branch": "branch",
    "severity": "severity",
    "status": "status",
    "summary": "summary",
    "evidence": "evidence",
    "file": "file",
    "line_start": "line_start",
    "line_end": "line_end",
    "introduced_by": "introduced_by",
    "lark_owner": "lark_owner",
    "base_sha": "base_sha",
    "head_sha": "head_sha",
    "artifact_path": "artifact_path",
    "review_date": "review_date",
    "last_seen_at": "last_seen_at",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--base-token", default=os.environ.get("LARK_BASE_TOKEN", ""))
    ap.add_argument("--table-id", default=os.environ.get("LARK_BASE_TABLE_ID", ""))
    ap.add_argument("--cli", default=os.environ.get("LARK_CLI_BIN", "lark-cli"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    artifact = json.loads(Path(args.artifact).read_text(encoding="utf-8"))
    if not args.base_token or not args.table_id:
        print(json.dumps({"processed": 0, "skipped": True, "reason": "lark_base_not_configured"},
                         ensure_ascii=False))
        return 0

    records = []
    for issue in artifact.get("issues") or []:
        fields = build_fields(artifact, issue)
        if args.dry_run:
            records.append({"issue_key": fields["issue_key"], "dry_run": True, "fields": fields})
            continue

        existing_id = find_record_id(args.cli, args.base_token, args.table_id, fields["issue_key"])
        result = upsert_record(args.cli, args.base_token, args.table_id, fields, existing_id)
        records.append({
            "issue_key": fields["issue_key"],
            "record_id": existing_id or extract_record_id(result),
            "created": not bool(existing_id),
            "updated": bool(existing_id),
            "result": result,
        })

    print(json.dumps({"processed": len(records), "records": records}, ensure_ascii=False, indent=2))
    return 0


def build_fields(artifact: dict, issue: dict) -> dict:
    meta = artifact.get("metadata") or {}
    review_date = meta.get("review_date") or ""
    fields = {
        DEFAULT_FIELDS["issue_key"]: issue.get("issue_key", ""),
        DEFAULT_FIELDS["repo"]: meta.get("repo", ""),
        DEFAULT_FIELDS["branch"]: meta.get("branch", ""),
        DEFAULT_FIELDS["severity"]: issue.get("severity", "P5"),
        DEFAULT_FIELDS["status"]: issue.get("status", "待处理"),
        DEFAULT_FIELDS["summary"]: issue.get("summary_zh") or issue.get("summary", ""),
        DEFAULT_FIELDS["evidence"]: issue.get("evidence", ""),
        DEFAULT_FIELDS["file"]: issue.get("file", ""),
        DEFAULT_FIELDS["line_start"]: issue.get("line_start", 0),
        DEFAULT_FIELDS["line_end"]: issue.get("line_end", 0),
        DEFAULT_FIELDS["introduced_by"]: issue.get("blame_author", ""),
        DEFAULT_FIELDS["base_sha"]: meta.get("base_sha", ""),
        DEFAULT_FIELDS["head_sha"]: meta.get("head_sha", ""),
        DEFAULT_FIELDS["artifact_path"]: meta.get("artifact_json", ""),
        DEFAULT_FIELDS["review_date"]: review_date,
        DEFAULT_FIELDS["last_seen_at"]: review_date,
    }
    owner = issue.get("owner_lark_id") or issue.get("lark_owner") or ""
    if owner:
        fields[DEFAULT_FIELDS["lark_owner"]] = [{"id": owner}]
    return fields


def find_record_id(cli: str, base_token: str, table_id: str, issue_key: str) -> str:
    try:
        raw = subprocess.check_output(
            [
                cli, "base", "+record-search",
                "--base-token", base_token,
                "--table-id", table_id,
                "--keyword", issue_key,
                "--search-field", DEFAULT_FIELDS["issue_key"],
                "--field-id", DEFAULT_FIELDS["issue_key"],
                "--limit", "1",
                "--format", "json",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    try:
        data = json.loads(raw or "{}")
    except json.JSONDecodeError:
        return ""
    records = (
        data.get("records")
        or data.get("items")
        or data.get("data", {}).get("records")
        or data.get("data", {}).get("items")
        or []
    )
    if not records:
        return ""
    record = records[0]
    return str(record.get("record_id") or record.get("recordId") or record.get("id") or "")


def upsert_record(cli: str, base_token: str, table_id: str, fields: dict, record_id: str) -> dict:
    cmd = [
        cli, "base", "+record-upsert",
        "--base-token", base_token,
        "--table-id", table_id,
    ]
    if record_id:
        cmd += ["--record-id", record_id]
    cmd += ["--json", json.dumps(fields, ensure_ascii=False)]
    raw = subprocess.check_output(cmd, text=True, timeout=30)
    try:
        return json.loads(raw or "{}")
    except json.JSONDecodeError:
        return {"raw": raw}


def extract_record_id(result: dict) -> str:
    record = result.get("record") if isinstance(result, dict) else None
    if isinstance(record, dict):
        return str(record.get("record_id") or record.get("recordId") or "")
    return ""


if __name__ == "__main__":
    sys.exit(main())
