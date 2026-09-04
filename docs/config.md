# Runtime configuration — `work/CONFIG.md`

Read this file when a run has no preflight `config` object (the manual
fallback), when the operator asks to change or explain a configuration value,
or when a definition change adds a key ([self-modification.md](self-modification.md)
§2). Every instance-specific value lives in `work/CONFIG.md`, created at
onboarding (ONBOARDING Step 4); the runtime reads its `- <key>: <value>`
bullets and the `## Review skills` / `## Watch rules` tables.

## In the worklist

`config` — one object per run with work: every key below with its default
applied (`bot_login` / `review_marker` are `null` when missing),
`artifact_skill` / `artifact_targets` as effective for the target host,
`skills_table` (`[{skill, source, trigger, section}]`) and `watch_rules`
(`[{id, watch_for, notify, note}]`). Runs read their values from it; the
reader below is for the manual fallback and the direct session.

## Keys

**This definition is project-agnostic.** Every instance-specific value lives in `work/CONFIG.md` (created at onboarding), loaded once at run start. Each key is one `- <key>: <value>` bullet parsed by the `cfg()` reader below (surrounding backticks/quotes and trailing `#` comments are stripped); the rest of the file is prose the runtime ignores. Structure and connectivity are verified by `bash "$HOME/scripts/verify-onboarding.sh" [--live]` (ONBOARDING Step 7).

**Every repo reference — `github_repo`, `definition_repo`, `$GITHUB_REPO_WORK`, a skill source — is `[<host>/]<owner>/<repo>`.** Three segments name the GitHub host (`github.example.com/acme/widgets`), two use the ambient default (`$GH_HOST`, else `github.com`). Target, definition, skills, and work backup may each sit on a different host; `GH_HOST` is exported to the **target** host, so every unqualified `gh` call reviews the right repo and cross-host calls pass `--hostname` (`gh api`) or `[HOST/]OWNER/REPO` (`gh pr`/`gh issue`/`gh label -R`).

- **`github_repo`** — stored target-repo reference, written at onboarding so a fresh scheduled shell resolves the target without an env var (`$GITHUB_REPO` always wins when set).
- **`definition_repo`** — the repo this definition was installed from (fork-aware). Outer-repo `origin`, target of definition PRs, review-footer link. Fallback: `git -C "$HOME" remote get-url origin`.
- **`definition_branch`** — branch of `definition_repo` **this instance runs from**: its update source and the branch the checkout is kept on ([docs/persistence.md](docs/persistence.md) → **Tracked branch**). **Missing = `main`.** A per-agent deployment choice, not a repo convention — definition PRs are still based on `main`, and `main` still owns the changelog. Operator-only to change, in the direct session.
- **`bot_login`** — the GitHub login this agent acts as. **Required** — if missing, log `bot_login missing — artifact gate, shepherd, and mention handling disabled this run` once and skip those features.
- **`bot_display_name`** — signature name (default `Code Guardian`). Cosmetic only — never used for dedup.
- **`review_marker`** — prefix of the hidden dedup marker `<!-- <review_marker> headRefOid=<full-sha> -->` in every posted review. **Required and immutable once the first review is posted** — if asked to change it after reviews exist, refuse and explain.
- **`rereview_label`** — GitHub label a human adds to an already-reviewed PR to request a **complete** re-review of the whole PR (default `code-guardian-review`); the other triggers (review request, on-demand ask) get a delta re-review (docs/review.md → **Re-review output**). First reviews never need it; the agent removes it once the request is served. A trigger is also served when only the PR description changed since the review (docs/review.md → **Description-only re-review**). New commits without a re-review trigger flip the tracking row to `awaiting_label`.
- **`rereview_trigger`** — what requests a re-review: `label` | `review-request` (a pending GitHub review request for `bot_login` — the "Re-request review" button) | `both`. **Missing = `label`** (the historical default). `review-request` needs `bot_login` (and the bot as a repo collaborator to be requestable); `bot_login` missing → label-only with one log line. A served review request clears itself when the review posts.
- **`urgent_label`** — **human-managed** GitHub label marking a PR urgent (the agent never adds or removes it). While present, the PR's due reviews jump the queue and run **rapid-first**: a fast preliminary review posts immediately, the full review follows ([docs/review.md](docs/review.md) → **Urgent PRs**). **Missing = off.** Not a review trigger — it only modifies how an already-due review is delivered.
- **`review_progress`** — `enabled` | `disabled`. **Missing = `disabled`.** Publishes each review's progress as a commit status on the reviewed SHA (`context` = `review_marker`): started / in progress with an ETA from past reviews / terminal outcome ([docs/review.md](docs/review.md) → **Progress signal on GitHub**). Best-effort — a failed write never affects the review.
- **`mention_replies`** — `enabled` | `disabled`. **Missing = `enabled`.** GitHub comments addressed to the bot (@-mention of `bot_login`, or a reply in one of its inline review threads) are answered, their review feedback recorded, and review requests in them served ([docs/mentions.md](docs/mentions.md)). Needs `bot_login`.
- **`artifact_skill`** — `<skill>@<[host/]owner/repo>`, or `none`/missing = the artifact feature is off entirely.
- **`artifact_targets`** — comma-separated publish surfaces for the artifact: any of `gist`, `dam`. **Missing/empty = `gist`** (the historical default). `gist` requires the target repo on `github.com`; elsewhere it is dropped, and with no surface left the feature is off for the run ([docs/artifact.md](docs/artifact.md)). `dam` (DAM Artifact Library) is always best-effort — its MCP tools exist only under the owner's experimental flag, so `dam` listed-but-unavailable logs and is skipped, never failing the run ([docs/artifact.md](docs/artifact.md)). No relation to `artifact_skill`, which gates the feature as a whole.
- **`## Review skills` table** — per-PR review skills; semantics in [docs/skills.md](docs/skills.md). Missing/empty → no review skills run (log once).
- **`## Watch rules` table** — instance-local "when a PR does X, give a heads-up in Y" rules, evaluated during reviews and delivered to a closed set of vetted targets (`chat`, `slack[:<chat-id>]`, `pr-comment`) — semantics in [docs/watches.md](docs/watches.md). Missing/empty = no watches; Slack targets require `slack_notifications: enabled`.
- **`slack_notifications`** — `enabled` | `disabled`. Gates everything Slack. **Missing file/key = `disabled`** — never send Slack messages without recorded opt-in.
- **`audit_report`** — `enabled` (default) | `disabled`. Gates the weekly audit run. The report goes to Slack only under `slack_notifications: enabled`; otherwise to the chat UI.
- **`benchmark`** — `enabled` | `disabled`. **Missing = `disabled`.** Monthly self-benchmark: replays a fixed set of ≥5 synthetic review fixtures (different project types, immutable once created) through the full pipeline (skills included) and scores each output against the fixture's known defects, recording wall-clock time and token usage per task; results accumulate forever in `work/benchmark/` for over-time comparison across models and definition versions ([docs/benchmark.md](docs/benchmark.md)).
- **`benchmark_judge`** — pinned model id for the benchmark's LLM-judged quality scores; `off`/missing = deterministic scoring only. A changed judge starts a new comparability window (the model that actually judged is recorded per result).
- **`benchmark_report`** — publish surfaces for the benchmark's accumulated report artifact (regenerated every run, updated in place so its URL stays stable): `gist` (default) | `dam` | `gist,dam` | `off`; same host/best-effort semantics as `artifact_targets`.
- **`## Benchmark model prices` table** — optional per-MTok USD prices keyed by model-id substring; powers the benchmark report's `est $` cost column ([docs/benchmark.md](docs/benchmark.md) → **Model prices**). Missing = costs render "—".
- **`escalation_owner`** — roster login widened to at nudge level 4, and the DM target of the stalled-review alert (Slack-only key; legitimately absent when Slack is disabled).
- **`stall_alert_threshold`** — stalled reviews (locked, never posted) within 24h that trigger one alert, at most once per UTC day. **Missing = `4`**; `0`/`off` disables; an unparseable value falls back to `4` (docs/review.md → **Stalled-review rate alert**).
- **`active_hours`**, **`active_days`**, **`review_interval_active`**, **`review_interval_quiet`** — the review heartbeat's two cadences. `active_hours` (`HH-HH`, platform timezone, both ends inclusive; **missing = `00-23`**) and `active_days` (`Mon-Fri` | `Mon-Sun` | a comma list; **missing = `Mon-Sun`**) delimit the **active window**; every hour outside it is a **quiet hour**. Inside the window the heartbeat runs every `review_interval_active` minutes (**missing = `5`**), in quiet hours every `review_interval_quiet` minutes (**missing = `60`**). Both intervals are divisors of 60, so `*/N` fires at an even spacing all hour. The active default is 5 to stay under the harness prompt-cache TTL — consecutive idle ticks then re-read the cached prefix instead of paying to write it again, which makes the faster cadence cheaper than a slower one that always misses the cache. These four keys are the **source of truth for the registered cron schedules** (ONBOARDING Step 6a) and for the audit's cadence check: an edited key takes effect once the schedules are re-registered.
- **`log_level`** — `info` (default when missing) | `debug`. Verbosity of the structured events log `work/logs/events-*.jsonl` ([docs/logging.md](docs/logging.md)); `debug` additionally records successful external tool calls. Diagnostic only — never gates behavior.
- **`project_profile`** — `enabled` (default when missing) | `disabled`. Keeps `work/PROFILE.md` — the generated map of the reviewed repository (modules, docs ↔ code paths, decisions, conventions, ownership, checks, noise globs, the agent's finding history) — current on every heartbeat with a review due, and gives each `reviews_due` entry its classified file list, profile slice, history rows, area-memory files and skill routing ([profile.md](profile.md)). Orientation only, never evidence for a finding; its absence never blocks a review.

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

All `gh` commands use `--repo "$REPO"`. If `REPO` resolves empty, stop and ask the operator for the slug — never guess. When the operator asks in chat to change a config value, update the file and confirm — except `review_marker` after the first posted review (refuse). On first Slack enablement, build the roster and register the shepherd schedule per ONBOARDING; on disablement, remove/disable that schedule. The benchmark schedule follows the same rule on `benchmark` enablement/disablement.

**Missing `work/CONFIG.md`** = not onboarded or state lost: apply per-key defaults (Slack disabled, skills disabled, artifact/shepherd off), log it once, continue with what still works.
