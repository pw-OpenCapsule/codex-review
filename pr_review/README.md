# Gogs PR automatic review

A separate event-driven service; existing daily/weekly jobs are unchanged.

- Subscribes to Gogs pull_request (opened/reopened/synchronized) and push.
- HMAC SHA256 validates the original body against X-Gogs-Signature.
- Only the configured same-owner repository and PRs targeting test are processed.
- SQLite coalesces events and deduplicates by repository, PR, source SHA and target SHA.
- Periodic discovery recovers missed deliveries. Both the target and source SHA are checked again before publication; obsolete results are discarded.
- Production uses a dedicated robot API token for Git fetches, PR metadata and comments. Gogs disables comment APIs when Issues is disabled; enable internal Issues for this integration. The PR branch names missing from its API are cached from signed Webhook metadata. Existing PRs must be seeded once during setup. Unknown metadata fails closed and needs PR webhook redelivery; the service never silently substitutes another user.
- Comments have a visible marker; uncertain comment responses are reconciled before retry.
- Zero findings never notify Lark. P3 and speculative/style feedback are suppressed. P0/P1 notify immediately; P2 uses a maximum 30-second batching window, independently of running reviews. Unchanged source-anchored findings are not re-notified; resolved then reintroduced findings and severity increases notify again. Mentions come only from the trusted author mapping file.
- Lark webhook responses must contain a successful application-level code, not merely HTTP 200. Notification retries do not repeat the review or confirmed PR comment.
- Lark custom webhooks do not supply an idempotency key: a lost response after server-side delivery can cause a repeated notification. The submission SHA makes these identifiable.
- Engine failures retry once, then report failure rather than a clean review. Manual retry is available below.
- SDK runs read-only in a detached checkout and is instructed not to execute repository scripts, tests, builds or deployments. MCP servers and web search are disabled. Reported file paths and lines are validated against the checkout.

## Install

Use Python 3.10+ and an authenticated local Codex CLI. A dedicated virtualenv is recommended.

```
pip install -r pr_review/requirements.txt
```

`review.py` explicitly selects the installed `codex` binary via CodexConfig; the configured model is explicitly gpt-6-astra with low reasoning by default. Set model/effort in the private service config for an intentional override. On hosts where the bundled CLI download is unavailable, install openai-codex with --no-deps plus requests/beautifulsoup4/pydantic, and keep the verified local CLI on PATH.

Put this JSON outside the checkout, chmod 600, in a private state directory (chmod 700):

```json
{
  "repo": "example/project",
  "model": "gpt-6-astra",
  "effort": "low",
  "gogs_credentials_file": "/private/gogs-credentials.json",
  "lark_user_map": "/private/lark_user_map.tsv",
  "digest_delay_seconds": 30,
  "notification_mode": "direct",
  "lark_cli": "/usr/local/bin/lark-cli",
  "reviewers": ["maintainer-a", "maintainer-b"],
  "gate_secret": "GENERATE-A-DIFFERENT-RANDOM-SECRET",
  "gogs_origin": "https://git.example.com",
  "state_dir": "/var/lib/pr-review",
  "webhook_secret": "GENERATE-A-RANDOM-SECRET",
  "lark_webhook": "CONFIGURE-PRIVATELY",
  "bind": "127.0.0.1",
  "port": 9847,
  "poll_seconds": 120,
  "review_timeout": 900
}
```

Run `python pr_review/service.py /private/config.json`. The daemon needs the same HOME, PATH and Git credential access as the configured user. Expose only this loopback service through a persistent Tunnel. Point Gogs to `https://YOUR-DOMAIN/hooks/gogs`, JSON, same webhook secret, PR + push events. GET /health is a public liveness endpoint; no configuration, logs or repository contents are exposed.

For macOS, use launchd with KeepAlive and RunAtLoad, the absolute virtualenv Python/script/config paths, a working directory pointing to this checkout, and stdout/stderr files under the private state directory. Service SIGTERM stops the active SDK process group. On restart, incomplete reviews become pending; outbox retries and idempotency state survive.

Retry failed reviews of one PR while the service is running:

```
python pr_review/service.py /private/config.json retry 123
```

Review artifacts and protected engine logs: STATE_DIR/results/. SQLite: STATE_DIR/state.sqlite. Back up the whole state directory to preserve deduplication. A sleeping/offline Mac cannot review immediately; periodic discovery resumes after it returns.

## Verify

```
python -m unittest discover -s tests -p test_pr_review.py -v
```

Test the Gogs delivery after service/Tunnel startup. Confirm 202 delivery, a single review per source/target revision, the PR comment permalink and Lark notification. Never run production acceptance scripts as an automatic check.

## Private notifications (production default)

Set `notification_mode` to `direct` and `lark_cli` to the absolute, authenticated lark-cli executable path. The existing trusted mapping resolves the **PR author**, not each blame author, to one open_id. The app bot sends a concise plain-text DM with issue summaries, priorities and the PR comment link. It never sends on behalf of the logged-in human.

Zero findings and unchanged findings remain quiet. Each delivery has a stable API idempotency key plus a durable message receipt. Partial failures retry per PR without re-sending successful messages or blocking other recipients. Missing mappings or inaccessible users stay pending; **there is no group fallback**. The app must have bot messaging permission and be available to each recipient. Existing group webhook configuration may be retained but is not used in direct mode.

## Robot credential file

Outside Git, chmod 600, containing `host`, `username` and `token`. The token belongs to the dedicated robot, with read access and comment permission for each enabled project. The daemon verifies its API identity. Git uses a host-scoped helper; the model process does not inherit this file path or token. Human account credentials are not used as a fallback.

## Two-person eligibility (not yet a native Gogs merge lock)

Each review contains an immutable review key binding source and target revisions. The author comments:

```
/review-resolve REVIEW_KEY
F1 fixed Concrete explanation of the fix
F2 false-positive Concrete evidence explaining the false positive
```

For a clean review, only the first line is needed. A different explicitly authorized maintainer then posts:

```
/review-approve REVIEW_KEY Concrete verification performed
```

Author self-approval, bot approval, unknown maintainers, missing findings, approvals preceding the author's resolution and edited resolutions after approval all fail. A new source or target revision invalidates the old key. AI findings can be rejected with evidence; they are not an absolute veto.

`POST /merge-gate/check` accepts `{repo, pr, head, base}` and an HMAC SHA256 in X-Gogs-Signature using the separate gate_secret. It queries current refs and authenticated comments before returning allowed/reason. Failures deny eligibility. This is a verification endpoint, **not an enforcement boundary by itself**.

This Gogs instance has no required-status-check setting and its Git hook management is unavailable. Until the server invokes this checker atomically at merge time, or permissions are redesigned so only an enforcing integration can merge, ordinary Gogs merges can bypass these acknowledgements. Do not claim the merge button is locked. Repository-administrator permissions and deployment boundaries remain outside this service.
