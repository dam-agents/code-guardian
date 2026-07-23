# Per-PR review skills

Read this file together with [review.md](review.md) on every review run.
Every reviewed PR is additionally checked by the review skills configured in
the `## Review skills` table of `work/CONFIG.md`. Each row: **skill** (name
invoked via the Skill tool), **source** (`harness`, or the `owner/repo` it
installs from), **trigger**, **section** (exact `###` heading for its
output). Table order = routing priority for extension triggers **and**
section order in the output.

## Installation — done by preflight

`scripts/preflight.sh review` installs/refreshes every repo-sourced skill
(and the artifact skill when a generation is due) **only when a review or
artifact is actually due**, mirroring `.agents/skills/<skill>/` from `main`
of the skill's source repo and caching by that repo's HEAD SHA (unchanged
source → no re-download). The worklist's `skills` object reports per-skill
status: `installed (N files)` / `cached` / `harness` / `install-failed`.

- `install-failed` → that skill is skipped for every PR this run (section
  omitted, audit line `skipped (install-failed)`); never abort the run.
- `harness` skills need no install — just invoke them.
- Fallback (no preflight status for a configured skill): install it yourself
  — `rm -rf ~/.claude/skills/<skill>`, enumerate
  `gh api "repos/<src>/git/trees/main?recursive=1"` for paths under
  `.agents/skills/<skill>/`, fetch each raw file preserving subdirectories.

## Mandatory — not skippable

Running each configured skill per its trigger is not optional, not
pre-filterable, not your judgement call — the skill decides what's worth
reporting; you only invoke it and surface the result. The **only** valid
skips: `no-matching-files` (extension trigger, empty routed list) and the
technical failures (`install-failed`, `clone-failed`, `skill-errored`).
Never skip an `always` skill (or an extension skill with a non-empty list)
because the PR is "CI-only / docs-only / trivial", "the skill would obviously
return nothing", "I already know what it would say", or "the previous review
didn't include the section". A clean-run section for a trivial PR is the
correct output, not waste.

## Triggers & file routing

- **`always`** — runs on every reviewed PR, against the whole clone
  (`$PR_DIR`) with the PR's base branch for diffing.
- **extension list** (e.g. `.ts,.js`) — runs iff ≥1 changed file routes to
  it; receives the routed file list (paths relative to `$PR_DIR`) + base
  branch. Build the changed-file list from the diff (fresh `headRefOid`).
  Each changed file goes to **at most one** extension-triggered skill:
  scanning the table top-down, the first row whose trigger list contains the
  file's extension claims it (first-match-wins — e.g. `.tsx` goes only to
  the React skill, never also to the TypeScript one).

## Invocation & audit log

Invoke each skill in table order via the Skill tool (arguments per its
`SKILL.md` — typically working dir + base branch, plus the file list for
extension triggers). Capture output verbatim → becomes that skill's
`### <section>` (on re-reviews the section is condensed per
[review.md](review.md) → **Re-review output** — unchanged carryover findings
collapse to one line). A skill error at invocation = `skill-errored`: omit
its section, log, continue.

**A skill's output is an intermediate artifact of the review, never a
stopping point.** Some skills (notably `doc-drift`) shape their result as a
standalone "report to the user" ending in a verdict — that framing is for the
skill's own direct use. Inside a review run it is **only** this PR's
`### <section>` content: capture it, log the audit line, and **immediately
continue the per-PR sequence** (remaining skills → Check 2 → post → lock
`done` → cleanup) and then the next PR. Never treat a skill's report/verdict
as the run's deliverable and end the turn on it — the review run is finished
only when every `reviews_due` PR is posted-or-aborted with its lock resolved
([review.md](review.md) → per-PR sequence & self-check).

Before posting any review, exactly **one audit line per configured skill**
must exist in the chat UI:

- `PR #<n>: <skill> ran (findings=<N>)` — `always` skill.
- `PR #<n>: <skill> ran (findings=<N>, files=<M>)` — extension-triggered.
- `PR #<n>: <skill> skipped (no-matching-files)` — extension triggers only.
- `PR #<n>: <skill> skipped (install-failed | clone-failed | skill-errored)`
  — no other reasons accepted.

Missing lines = the skill step isn't done; do not proceed to posting.

## Inclusion rule (all channels: chat UI, GitHub body, `reviews/pr-<n>.md`)

- ✅ **Include the section** whenever the skill ran — even with zero findings
  (its clean-run line, e.g. `✅ No findings.`, appears under the heading).
- ❌ **Omit the section entirely** on any skip — no placeholder; the audit
  line is the only trace.

## Verdict integration

Skill findings feed the overall Verdict like your own: 🔴 Critical →
`REQUEST_CHANGES`, 🟡 Warning → `COMMENT`, 🟢 Suggestion alone doesn't move
it. Combine across your review + all skill sections.

## Clone, credential helper, cleanup

Per-PR working directory: `PR_DIR="/tmp/review-pr-<number>"`.

Once per run, before any clone (idempotent; preflight also sets this up):

```bash
git config --global --replace-all credential."https://github.com".helper "" \
  && git config --global --add credential."https://github.com".helper "!gh auth git-credential"
```

```bash
rm -rf "$PR_DIR"
gh repo clone "$REPO" "$PR_DIR" -- --depth 50 --branch "<headRefName>" --single-branch
```

- No `http.extraHeader` flags; `--depth 50` suffices unless a skill needs
  deeper history.
- Fork PRs: clone the fork, or fetch the PR ref into a base-repo clone.
- **Clone failure** → every skill for this PR is `clone-failed` (sections
  omitted, failure logged); the rest of the review continues.
- **Cleanup** — after the review is posted and REVIEWS.md updated,
  `rm -rf "$PR_DIR"` exactly once (all skills share the clone; never delete
  between skills). Mandatory regardless of skill outcomes.
