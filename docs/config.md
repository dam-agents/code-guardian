# Runtime configuration — `work/CONFIG.md`

Read this file when a run has no preflight `config` object (the manual
fallback), when the operator asks to change or explain a value, or when a
definition change adds a key ([self-modification.md](self-modification.md) §2).

**This definition is project-agnostic.** Every instance-specific value lives in
`work/CONFIG.md`, created at onboarding (ONBOARDING Step 4) and loaded once at
run start. Each key is one `- <key>: <value>` bullet parsed by the `cfg()`
reader below (surrounding backticks or quotes and trailing `#` comments are
stripped); the rest of the file is prose the runtime ignores. Structure and
connectivity are verified by
`bash "$HOME/scripts/verify-onboarding.sh" [--live]` (ONBOARDING Step 7).

**Every repo reference — `github_repo`, `definition_repo`,
`$GITHUB_REPO_WORK`, a skill source — is `[<host>/]<owner>/<repo>`.** Three
segments name the GitHub host (`github.example.com/acme/widgets`), two use the
ambient default (`$GH_HOST`, else `github.com`). Target, definition, skills and
work backup may each sit on a different host. `GH_HOST` is exported to the
**target** host, so every unqualified `gh` call reviews the right repo, and
cross-host calls pass `--hostname` (`gh api`) or `[HOST/]OWNER/REPO`
(`gh pr`/`gh issue`/`gh label -R`).

## In the worklist

`config` — one object per run with work: every key below with its default
applied (`bot_login` / `review_marker` are `null` when missing),
`artifact_skill` / `artifact_targets` as effective for the target host,
`skills_table` (`[{skill, source, trigger, section}]`) and `watch_rules`
(`[{id, watch_for, notify, note}]`). Runs read their values from it; the reader
below is for the manual fallback and the direct session.

## Keys

### Identity & repositories

- **`github_repo`** — stored target-repo reference, written at onboarding so a
  fresh scheduled shell resolves the target without an env var. `$GITHUB_REPO`
  always wins when set.
- **`definition_repo`** — the repo this definition was installed from
  (fork-aware). Outer-repo `origin`, target of definition PRs, review-footer
  link. Fallback: `git -C "$HOME" remote get-url origin`.
- **`definition_branch`** — the branch of `definition_repo` this instance runs
  from ([persistence.md](persistence.md) → **Tracked branch**). **Missing =
  `main`.** Operator-only to change.
- **`bot_login`** — the GitHub login this agent acts as. **Required.** Missing
  → log
  `bot_login missing — artifact gate, shepherd, and mention handling disabled this run`
  once and skip those features.
- **`bot_display_name`** — signature name (default `Code Guardian`). Cosmetic
  only, never used for dedup.
- **`review_marker`** — prefix of the hidden dedup marker
  `<!-- <review_marker> headRefOid=<full-sha> -->` in every posted review.
  **Required, and immutable once the first review is posted** — a later change
  request is refused with the reason.

### Review triggers & delivery

- **`rereview_label`** — the GitHub label a human adds to request a
  **complete** re-review of the whole PR (default `code-guardian-review`). The
  other triggers get a delta re-review ([review.md](review.md) →
  **Re-review output**). First reviews never need it; the agent removes it once
  the request is served. A trigger is also served when only the PR description
  changed (review.md → **Description-only re-review**). New commits without a
  trigger flip the tracking row to `awaiting_label`.
- **`rereview_trigger`** — what requests a re-review: `label` |
  `review-request` (a pending GitHub review request for `bot_login`) | `both`.
  **Missing = `label`.** `review-request` needs `bot_login`, and the bot as a
  repo collaborator to be requestable; `bot_login` missing → label-only with
  one log line. A served review request clears itself when the review posts.
- **`urgent_label`** — a **human-managed** label marking a PR urgent; the agent
  never adds or removes it. While present, the PR's due reviews jump the queue
  and run **rapid-first** (review.md → **Urgent PRs**). **Missing = off.** Not
  a review trigger — it only modifies how an already-due review is delivered.
- **`review_progress`** — `enabled` | `disabled`. **Missing = `disabled`.**
  Publishes each review's progress as a commit status on the reviewed SHA
  (`context` = `review_marker`): started, in progress with an ETA, terminal
  outcome (review.md → **Progress signal on GitHub**). Best-effort — a failed
  write never affects the review.
- **`mention_replies`** — `enabled` | `disabled`. **Missing = `enabled`.**
  GitHub comments addressed to the bot are answered, their review feedback
  recorded, and review requests in them served
  ([mentions.md](mentions.md)). Needs `bot_login`.
- **`stall_alert_threshold`** — stalled reviews (locked, never posted) within
  24 h that trigger one alert, at most once per UTC day. **Missing = `4`**;
  `0`/`off` disables; an unparseable value falls back to `4` (review.md →
  **Stalled-review rate alert**).

### Skills, artifacts, watches

- **`## Review skills` table** — the per-PR review skills; semantics in
  [skills.md](skills.md). Missing or empty → no review skills run (log once).
- **`artifact_skill`** — `<skill>@<[host/]owner/repo>`, or `none`/missing = the
  artifact feature is off entirely.
- **`artifact_targets`** — comma-separated publish surfaces: any of `gist`,
  `dam`. **Missing or empty = `gist`.** `gist` requires the target repo on
  `github.com` and is dropped elsewhere; with no surface left the feature is
  off for the run. `dam` is always best-effort — its MCP tools exist only under
  the owner's experimental flag, so `dam` listed-but-unavailable logs and is
  skipped, never failing the run ([artifact.md](artifact.md)). Unrelated to
  `artifact_skill`, which gates the feature as a whole.
- **`## Watch rules` table** — instance-local "when a PR does X, give a
  heads-up in Y" rules, evaluated during reviews and delivered to a closed set
  of vetted targets (`chat`, `slack[:<chat-id>]`, `pr-comment`) —
  [watches.md](watches.md). Missing or empty = no watches; Slack targets
  require `slack_notifications: enabled`.
- **`project_profile`** — `enabled` (default) | `disabled`. Keeps
  `work/PROFILE.md` — the generated map of the reviewed repository — current on
  every heartbeat with a review due, and gives each `reviews_due` entry its
  classified file list, profile slice, history rows, area-memory files and
  skill routing ([profile.md](profile.md)). Orientation only, never evidence;
  its absence never blocks a review.

### Slack, audit, benchmark

- **`slack_notifications`** — `enabled` | `disabled`. Gates everything Slack.
  **Missing file or key = `disabled`** — never send Slack messages without a
  recorded opt-in.
- **`escalation_owner`** — roster login widened to at nudge level 4, and the DM
  target of the stalled-review alert. Slack-only key, legitimately absent when
  Slack is disabled.
- **`audit_report`** — `enabled` (default) | `disabled`. Gates the weekly audit
  run. The report goes to Slack only under `slack_notifications: enabled`,
  otherwise to the chat UI.
- **`benchmark`** — `enabled` | `disabled`. **Missing = `disabled`.** The
  monthly self-benchmark: replays ≥5 synthetic review fixtures through the full
  pipeline, scores each output against its known defects, and records time and
  token usage per task; results accumulate forever in `work/benchmark/`
  ([benchmark.md](benchmark.md)).
- **`benchmark_judge`** — pinned model id for the benchmark's LLM-judged
  quality scores; `off`/missing = deterministic scoring only. A changed judge
  starts a new comparability window (the model that actually judged is recorded
  per result).
- **`benchmark_report`** — publish surfaces for the accumulated report
  artifact, updated in place so its URL stays stable: `gist` (default) | `dam`
  | `gist,dam` | `off`. Same host and best-effort semantics as
  `artifact_targets`.
- **`## Benchmark model prices` table** — optional per-MTok USD prices keyed by
  model-id substring; powers the report's `est $` column
  ([benchmark.md](benchmark.md) → **Model prices**). Missing = costs render
  "—".

### Cadence & diagnostics

- **`active_hours`**, **`active_days`**, **`review_interval_active`**,
  **`review_interval_quiet`** — the review heartbeat's two cadences.
  `active_hours` (`HH-HH`, platform timezone, both ends inclusive; **missing =
  `00-23`**) and `active_days` (`Mon-Fri` | `Mon-Sun` | a comma list;
  **missing = `Mon-Sun`**) delimit the **active window**; every hour outside it
  is a quiet hour. Inside the window the heartbeat runs every
  `review_interval_active` minutes (**missing = `5`**), in quiet hours every
  `review_interval_quiet` minutes (**missing = `60`**). Both intervals are
  divisors of 60, so `*/N` fires at an even spacing all hour. The active
  default is 5 to stay under the harness prompt-cache TTL: consecutive idle
  ticks then re-read the cached prefix instead of paying to write it again,
  which makes the faster cadence cheaper than a slower one that always misses
  the cache. These four keys are the **source of truth for the registered cron
  schedules** (ONBOARDING Step 6a) and for the audit's cadence check; an edited
  key takes effect once the schedules are re-registered.
- **`log_level`** — `info` (default) | `debug`. Verbosity of
  `work/logs/events-*.jsonl` ([logging.md](logging.md)); `debug` additionally
  records successful external tool calls. Diagnostic only, never gating
  behavior.

## Reader (manual fallback and direct session)

```bash
CONFIG=/home/agent/work/CONFIG.md
# awk is not available in the pod — sed/grep/cut only
cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }
DEFAULT_HOST="${GH_HOST:-github.com}"   # capture before the re-export below
refhost() { case "$1" in (*/*/*) printf '%s' "${1%%/*}";; (*) printf '%s' "$DEFAULT_HOST";; esac; }
refslug() { case "$1" in (*/*/*) printf '%s' "${1#*/}";;  (*) printf '%s' "$1";; esac; }
TARGET="${GITHUB_REPO:-$(cfg github_repo)}"; TARGET="${TARGET:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
REPO_HOST="$(refhost "$TARGET")"; REPO="$(refslug "$TARGET")"; export GH_HOST="$REPO_HOST"
BOT_LOGIN="$(cfg bot_login)"; BOT_NAME="$(cfg bot_display_name)"; BOT_NAME="${BOT_NAME:-Code Guardian}"
REVIEW_MARKER="$(cfg review_marker)"
DEF_REF="$(cfg definition_repo)"; DEF_HOST="$(refhost "$DEF_REF")"; DEFINITION_REPO="$(refslug "$DEF_REF")"
REREVIEW_LABEL="$(cfg rereview_label)"; REREVIEW_LABEL="${REREVIEW_LABEL:-code-guardian-review}"
ARTIFACT_TARGETS="$(cfg artifact_targets)"; ARTIFACT_TARGETS="${ARTIFACT_TARGETS:-gist}"
```

All `gh` commands use `--repo "$REPO"`. `REPO` resolving empty → stop and ask
the operator for the slug, never guess.

## Changing a value (direct session)

- Update the file and confirm — except `review_marker` after the first posted
  review, which is refused.
- On first Slack enablement, build the roster and register the shepherd
  schedule per ONBOARDING; on disablement, remove or disable that schedule. The
  benchmark schedule follows the same rule on `benchmark`
  enablement/disablement.
- **Missing `work/CONFIG.md`** = not onboarded, or state lost: apply per-key
  defaults (Slack disabled, skills disabled, artifact and shepherd off), log it
  once, and continue with what still works.
