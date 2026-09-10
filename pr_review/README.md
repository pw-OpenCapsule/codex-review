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
  "routing": "complexity",
  "codex_bin": "/opt/homebrew/bin/codex",
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

## Author-selected review level

The submitting session selects the level in the PR body. The service does not classify complexity or automatically upgrade models. `none` skips the model, `spark` uses only Spark low, and `deep` uses only GPT-6 low. Missing declarations default to Spark. Legacy `routing: complexity` configuration does not override this protocol.

Both models may request bounded source snippets. Insufficient context is an unavailable/incomplete review, not permission to upgrade or a clean pass. Exact-source caches include the effective model configuration and engine policy.

## Visible PR progress

A separate persistent status queue updates one robot-owned comment per PR without waiting for the review engine. New PRs and updated revisions show “queued, please hold merging”; running reviews show “reviewing”; completion links to the full report, and failures explicitly remain unapproved. A clean review still asks for human checks and two-person confirmation. Progress never sends a DM or group message, and unchanged text is not patched repeatedly. This is a visible warning, not an enforced merge lock.

## Cost bounds and cancellation

Both stages explicitly select the default service tier (not Fast). Spark receives the bounded patch with shell, unified exec, web and subagent access disabled: 0 tool operations, 40,000 cumulative context-work tokens, 45 seconds. Deep review has no native tool access. It may request up to 8 program-provided tracked-file snippets (160 lines / 10,000 characters each), across at most 4 model responses, with 250,000 cumulative context-work tokens and 180 seconds. Token caps include cached input and are workload caps, not a conversion to billable credits. Usage notifications are checkpointed while running, including interrupted work. Exceeding a limit is incomplete review, never a clean pass.

A closed/merged PR webhook cancels queued jobs. The worker checks this cancellation flag every 2 seconds while waiting for its child; it also checks the authoritative PR state and both Git refs every 5 seconds (subject to network latency). Closed, merged or replaced revisions terminate the SDK process group and become stale without a failure notification. Before publishing, the existing freshness check remains in place. There is also a 300-second parent watchdog.

## Isolated runtime profile

Set `codex_bin` to the real CLI executable (this deployment uses `/opt/homebrew/bin/codex`), not an interactive statebar/agent wrapper. Each SDK app-server starts with service-owned model context and compaction limits, and the same limits are passed to the thread. Spark: 128,000 context / 80,000 auto-compaction; deep: 256,000 / 180,000. These caps do not alter the user's personal config. Personal hooks, child-agent instructions and automatic project-doc injection are disabled at startup; reviewers read only the task-supplied scope and permitted relevant files.

This prevents a personal million-token context override and interactive runtime hooks from contaminating Spark review requests. Regression verification must include a real PR invocation, not only a tiny model smoke test.


## Exact-source reuse and settling

New heads wait `settle_seconds` (default 60) before model execution. Repeated webhooks do not extend the same-head deadline; a new head resets it. Closed PRs are skipped before invoking a model. The durable queue survives restarts.

The project cache key covers repository, full head commit, merge-base, and a hash of review engine/prompt/model configuration. PR number and target tip are excluded: an unchanged head and merge-base mean identical diff and identical available source. Running work survives unrelated target-tip updates; publication still checks current refs and creates a fresh confirmation identity. This is source review reuse, not certification of the target merge result. Changed head, merge-base or policy misses the cache.

Successful results and intermediate stages are shared across equivalent jobs. Failed scopes are also remembered, preventing target updates from repeatedly spending on a known failure; explicit `retry PR` clears that failure marker while retaining completed stages. Cache-hit artifacts have empty `usage_by_stage` and preserve historical usage separately as `cached_usage_by_stage`. No new model request is issued on a complete hit.

OpenAI prompt caching is separate from this disk cache and does not imply free repeated reviews. See https://developers.openai.com/api/docs/guides/prompt-caching . We rely on exact local result reuse for zero model calls, rather than sending an entire project repeatedly hoping for model-side cache hits.

## PR Review protocol v1

Only a top-level standalone declaration in the PR body selects the requested level:

```
[review:none] Nonempty reason
[review:spark] Nonempty reason
[review:deep] Nonempty reason
```

Absent declarations default to Spark. `[no-review] reason` aliases `none`. Quoted, fenced, indented-code and HTML-comment examples are ignored. Multiple declarations, unknown levels and missing reasons produce `invalid`, with no model call. `spark` calls only Spark low; `deep` calls only GPT-6 low; `none` produces `skipped`, never a clean review. A declaration/reason change gets a new confirmation identity; the same effective model configuration can still reuse exact-source results. Running/publishing jobs check declaration freshness.

Spark may ask for up to three bounded source snippets in one additional turn, within the existing 45-second/40k-token stage budget, before completing its review. There is no automatic model escalation. Deep remains bounded. Reports show the actual stage model path.

The single editable status includes `<!-- pr-review:v1 {JSON} -->` with `head`, `requested`, `status`, `models`, `cache_hit`, `findings`, and an additive `review_key` for machine-verified acknowledgements. Status values are queued/running/completed/skipped/unavailable/invalid/cancelled. Incomplete states have `findings: null`, not zero. No-review and unavailable states still require manual two-person confirmation. The checker verifies the latest known defect report before allowing a manual fallback; none cannot dismiss findings. The checker remains an optional integration, not a Gogs server-enforced lock.

The legacy routing module remains for historical artifact compatibility/tests, but the review execution entrypoint does not invoke it.

## Optional chatgpt-use backend

The read-only `ask --output-schema` adapter is implemented and offline-tested. It does not enable run/work/MCP/local tool execution. It requires a recent chatgpt-use build containing structured output, durable request IDs, resume and SIGTERM cancellation. Configure explicitly:

```json
{
  "backend": "chatgpt-use",
  "chatgpt_use": {
    "bin": "/absolute/path/chatgpt-use",
    "profile": "auto",
    "session": "chatgpt-web",
    "models": {"spark": "instant", "deep": "medium"}
  }
}
```

These are **web model mappings**, not the identically named Codex models. Operator approval of this mapping is required before switching a deployment. Results record `chatgpt-web:<selection>` and token usage is unavailable, not zero. Provider and mapping participate in the cache identity.

Each bounded context round has a deterministic request ID and a private JSON envelope. A duplicate ID invokes resume, never a second ask. Busy/unavailable/malformed/incomplete results stop without automatic retry, account switching or Codex fallback. A completed local envelope can be reused without any browser call.

On cancellation the parent sends SIGTERM and allows 30 seconds for upstream to stop its pinned conversation, before a last-resort kill. An unconfirmed remote cancellation is not a confirmed stop: retain upstream receipts and reconcile by request ID. Upstream explicitly has not live-verified the owner-SIGKILL cancellation path. This adapter was verified offline only; upstream forbids live browser testing to conserve the signed-in account's request budget. Integration activation and organic production observation must not be described as a successful synthetic end-to-end test.
