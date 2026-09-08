# Gogs PR automatic review

A separate event-driven service; existing daily/weekly jobs are unchanged.

- Subscribes to Gogs pull_request (opened/reopened/synchronized) and push.
- HMAC SHA256 validates the original body against X-Gogs-Signature.
- Only the configured same-owner repository and PRs targeting test are processed.
- SQLite coalesces events and deduplicates by repository, PR, source SHA and target SHA.
- Periodic discovery recovers missed deliveries. Both the target and source SHA are checked again before publication; obsolete results are discarded.
- Gogs web login uses the existing Git credential helper. HTML forms support installations without a pull-request API.
- Comments have a visible marker; uncertain comment responses are reconciled before retry.
- Lark webhook responses must contain a successful application-level code, not merely HTTP 200. Notification retries do not repeat the review or confirmed PR comment.
- Lark custom webhooks do not supply an idempotency key: a lost response after server-side delivery can cause a repeated notification. The submission SHA makes these identifiable.
- Engine failures retry once, then report failure rather than a clean review. Manual retry is available below.
- SDK runs read-only in a detached checkout and is instructed not to execute repository scripts, tests, builds or deployments. MCP servers and web search are disabled. Reported file paths and lines are validated against the checkout.

## Install

Use Python 3.10+ and an authenticated local Codex CLI. A dedicated virtualenv is recommended.

```
pip install -r pr_review/requirements.txt
```

`review.py` explicitly selects the installed `codex` binary via CodexConfig; it does not force an old model. Set CODEX_REVIEW_MODEL only for an intentional model override. On hosts where the bundled CLI download is unavailable, install openai-codex with --no-deps plus requests/beautifulsoup4/pydantic, and keep the verified local CLI on PATH.

Put this JSON outside the checkout, chmod 600, in a private state directory (chmod 700):

```json
{
  "repo": "example/project",
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
