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
    ap.add_argument("--sha", default="",
                    help="blame at this revision instead of HEAD; falls back to HEAD if invalid")
    ap.add_argument("--user-map", default="")
    ap.add_argument("--default-meegle", default="")
    args = ap.parse_args()

    line_start = max(1, args.line_start)
    line_end = max(line_start, args.line_end)
    rel = args.file

    cmd = ["git", "blame", "--porcelain", f"-L{line_start},{line_end}"]
    sha = args.sha.strip()
    if sha:
        # Verify the SHA is reachable; fall back to HEAD if not
        try:
            subprocess.check_output(
                ["git", "cat-file", "-e", f"{sha}^{{commit}}"],
                cwd=args.workdir, stderr=subprocess.DEVNULL, timeout=5,
            )
            cmd.append(sha)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
                FileNotFoundError):
            pass  # fall through to HEAD
    cmd += ["--", rel]

    try:
        out = subprocess.check_output(
            cmd,
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
    """TSV: git_identifier\tlark_open_id\tdisplay_name (col 3 is name, not ID).

    Returns col 2 (lark_open_id like ou_xxx) which is what scripts consume.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if parts and parts[0].lower() == email.lower() and len(parts) >= 2:
                    return parts[1]
    except Exception:
        pass
    return ""


if __name__ == "__main__":
    main()
