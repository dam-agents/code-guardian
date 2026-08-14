# Model benchmark — scoring the review configuration over time

Read this file when the worklist has `benchmark_due`, or when the operator
asks in the direct session to create the fixture set, run the benchmark, or
show its results.

The benchmark measures the production review configuration as one unit — the
session model, the adopted definition version, and the configured skills — by
replaying a fixed set of synthetic review tasks and scoring the output
against known defects, with wall-clock time and token usage recorded per
task. Results accumulate forever in `work/benchmark/`, and every run
republishes one accumulated report artifact, so any two runs are comparable
across model upgrades and definition releases. The feature makes no GitHub
writes beyond that report artifact and posts nothing to any PR.

## Layout (`work/benchmark/`)

```
fixture/<slug>/          # one benchmark project (immutable once created); the set holds ≥5
  base/                  # starting tree (the "main" branch)
  head-v1/               # PR state 1 — the seeded-defect version
  head-v2/               # PR state 2 — the iteration: some defects fixed, some kept, a few new
  manifest.json          # ground truth (schema below)
  prior-review.md        # canonical prior review for the re-review task
  pr.json                # simulated PR metadata (schema below)
  diff-v1.patch          # base → head-v1
  diff-v1-v2.patch       # head-v1 → head-v2
results/<ts>.json        # one scored run, all fixtures (ts = YYYYMMDDTHHMMSSZ, UTC)
results/raw/<ts>-<slug>-first.md, <ts>-<slug>-rereview.md
RESULTS.md               # append-only index — one row per run × fixture, newest last
report.html              # the accumulated report, regenerated every run (script below);
                         # self-contained and interactive client-side — every table
                         # sorts by header click, filters by substring, and pages
```

`results/`, `results/raw/`, and `RESULTS.md` are append-only history: runs add
files and rows; existing ones stay untouched forever (the standard `work/`
backup carries them). A fixture is immutable after creation — that is what
keeps scores comparable in time. When the target repo's stack changes enough
that a fixture stops representing it, add a new slug alongside (the set may
grow past 5); retiring one is an operator decision in the direct session —
move its directory under `fixture/retired/`, past results keep referencing it.

## Session separation

A scored run is meaningful only while the reviewing session does not know the
answers:

- `create_fixture` and `run` never share a session. The session that seeds
  defects knows the ground truth, so it ends after creating fixtures;
  preflight emits `run` from the next benchmark tick on — a month out on the
  schedule, so the creation report invites the operator to ask for an
  on-demand run (a fresh session) when they want the first baseline now.
- In a `run`, `manifest.json` files, `RESULTS.md`, and past `results/` are
  read in the scoring phase only — after every raw review is written. Phase 1
  inputs are exactly: `pr.json`, the diff patches, the trees,
  `prior-review.md`, and the files a production review reads (docs/review.md,
  docs/skills.md, `work/MEMORY.md`, `work/LESSONS.md`).

## Creating the fixture set (`action: create_fixture`, or operator ask)

The worklist entry carries `existing` (slugs already on disk) and `min` (the
set size preflight requires, 5). Create the **missing** fixtures — existing
ones are immutable and stay as they are.

1. Inputs: the target repo's languages (`gh api "repos/$REPO/languages"`) and
   the `## Review skills` table. Pick project types so the set covers **at
   least 5 clearly different shapes of change** — e.g. a backend/service API,
   a UI component set, a CLI tool, an infrastructure/CI change (shell +
   config), and a docs-heavy mixed change — in the languages of the target
   repo, and so that every extension-triggered skill receives ≥ 1 file from
   ≥ 1 fixture. Name each slug after its type (`ts-api`, `react-ui`,
   `py-cli`, `infra-ci`, `docs-mixed`). When the skill table later gains an
   extension trigger no fixture covers, add a fixture for it the same way
   (the set grows past 5; existing fixtures stay untouched).
2. Generate each `fixture/<slug>/`: `base/` = 3–6 plausible source files,
   ~150–400 lines total; `head-v1/` = base plus 10–14 seeded defects
   (severities `critical`/`warning`, spread across correctness / security /
   performance / tests / maintainability) plus a few clean hunks as
   false-positive bait; `head-v2/` = head-v1 with roughly half the defects
   fixed, the rest kept, and 3–5 new ones. Keep defects in the same file
   ≥ 10 lines apart — the scorer matches on a ±3-line window — and make
   every defect a **distinct pattern**: the production sibling sweep merges
   same-class occurrences into one finding, which the scorer would count as
   a miss.
3. Write `manifest.json`, verifying every `line_v1`/`line_v2` against the
   actual trees (grep the seeded line).
4. Write `prior-review.md` in the posted-review format (docs/review.md →
   **Summary body format**, marker at `head_sha_v1`) whose findings-json
   carries ~70 % of the v1 defects; set `in_prior_review: true` on exactly
   those manifest entries.
5. Write `pr.json`:
   `{number: 0, title, body, author, head_ref, base_ref, head_sha_v1, head_sha_v2}`
   — the SHAs are synthetic and stable (`git hash-object --stdin` over a
   fixture-unique string per version).
6. Diffs — generate them from a scratch git repo built exactly like the
   run's Phase 1 step 1 (base committed on `main`, head-v1 then head-v2 as
   two commits on `pr`), so the patch paths are **repo-relative and match
   the manifest** (`git diff --no-index` would prefix them with `base/` /
   `head-v1/`, and nothing would ever score as matched):

   ```bash
   git -C "$PR_DIR" diff main..pr~1 > "fixture/<slug>/diff-v1.patch"
   git -C "$PR_DIR" diff pr~1..pr   > "fixture/<slug>/diff-v1-v2.patch"
   rm -rf "$PR_DIR"
   ```
7. Report the per-fixture defect tables (id, file:line, class, severity,
   fixed_in_v2, in_prior_review) to the chat UI for the operator, log
   `benchmark fixtures created (<k> new, set now <n>)`, and end the run
   (backup last, as always).

### `manifest.json`

```json
{"fixture": "ts-api", "created": "<ISO>",
 "defects": [{"id": "D01", "file": "src/auth.ts", "line_v1": 42, "line_v2": 42,
              "class": "security", "severity": "critical",
              "summary": "token compared with ==",
              "fixed_in_v2": false, "in_prior_review": true}]}
```

Per defect: kept in v2 → both lines set, `fixed_in_v2: false`; fixed in v2 →
`line_v2: null`, `fixed_in_v2: true`, plus **`fix_line_v2`** — the line the
fix landed on in `head-v2` (the scorer's `churn` metric matches re-flagged
fixes against it); introduced in v2 → `line_v1: null`.

## Running the benchmark (`action: run`, or operator ask)

The entry carries `fixtures` (slugs), `fixture_root`, `judge`, `report`, and
`last_run`. Take one timestamp `TS` (compact + ISO) for the whole run, and
one usage nonce for token deltas:

```bash
NONCE="bench-$(date -u +%s)-$$"
printf 'usage-nonce:%s\n' "$NONCE"   # the PRINTED value is what lands in the
                                     # transcript — command text stays unexpanded
snap() { bash "$HOME/scripts/harness/claude-code/usage-snapshot.sh" "$NONCE"; }
```

`snap` prints the session's cumulative token usage (same accounting as the
run-level `tokens` event; sidechain/subagent usage lands in the same
transcript, so skill fan-outs are included). On a harness without transcripts
it prints nothing — record `tokens: null` then; time is measured either way.

### Phase 1 — review replay, per fixture (before any ground-truth read)

First, **install/refresh every configured repo-sourced skill** per
docs/skills.md → Installation fallback (benchmark mode's preflight is purely
local and never installs them), and write each skill's source SHA to the
install cache (`$HOME/.claude/skills/.cache/<skill>.sha`) so `skill_sources`
provenance stays complete. A configured extension skill that routes zero
files across **all** fixtures is named in the run's chat summary as missing
fixture coverage (the operator tops the set up per fixture creation).

Then loop over the slugs sequentially; for each fixture:

1. Build the working repo in `/tmp` (fixtures hold no `.git`; `work/` is NFS
   — docs/persistence.md):

   ```bash
   B="<fixture_root>/<slug>"; PR_DIR="/tmp/benchmark-pr-<slug>"
   rm -rf "$PR_DIR" "$PR_DIR".out "$PR_DIR".s-*
   git init -q "$PR_DIR" && cp -a "$B/base/." "$PR_DIR/"
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench add -A
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench commit -qm base
   git -C "$PR_DIR" branch -m main && git -C "$PR_DIR" checkout -qb pr
   find "$PR_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
   cp -a "$B/head-v1/." "$PR_DIR/"
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench add -A
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench commit -qm v1
   ```

2. **First review** — bracket it with `T0=$(date -u +%s)` + `S0=$(snap)`
   before and `T1` + `S1` after: perform docs/review.md steps c–d and the
   docs/skills.md fan-out **as written there**, with the benchmark
   substitutions: diff = `diff-v1.patch`, PR context = `pr.json`
   (title/body/author), working tree = `$PR_DIR` with base branch `main`,
   and the changed-file list that routes extension triggers =
   `git -C "$PR_DIR" diff --name-only main..pr` (the benchmark's equivalent
   of the production `gh pr diff` list). Compose the **first-review Output
   format** with the marker line at `head_sha_v1` and its findings-json, and
   write it verbatim to `results/raw/<ts>-<slug>-first.md` — nothing is
   posted. Archive the skill outputs beside it:
   `cp -a "$PR_DIR.out" "$HOME/work/benchmark/results/raw/<ts>-<slug>-first-skills"`
   (when the fan-out ran).
3. **Re-review** — bracket with `T1/S1` → `T2/S2`: advance the tree to v2
   (repeat the swap-and-commit on `pr` with `head-v2/`), take
   `prior-review.md` as the prior review, scope = delta (request-equivalent
   trigger), changes since prior = `diff-v1-v2.patch`, skills per
   docs/review.md → **Re-review output** (routing from the same
   `git diff --name-only main..pr`, now at v2). Compose the delta re-review
   (marker at `head_sha_v2`, findings-json with `new`/`still`/`fixed`
   statuses) → `results/raw/<ts>-<slug>-rereview.md`, archiving the skill
   outputs the same way (`…/<ts>-<slug>-rereview-skills`).
4. Record per task: `seconds` = `T1-T0` / `T2-T1`; `tokens` = the per-field
   difference `S1-S0` / `S2-S1` over all five snapshot fields, `msgs`
   included (null when `snap` printed nothing); and `suppressed` = the
   count from the review's suppression audit note (docs/review.md → PR
   context; 0 when none) — a memory preference that suppresses a seeded
   defect is a scoring confound, and this field is what makes it visible.

### Phase 2 — scoring, report, publish (ground truth now)

5. Per fixture, deterministic scores (field meanings in the script header):

   ```bash
   bash "$HOME/scripts/benchmark-score.sh" first    "<raw first>"    "$B/manifest.json"
   bash "$HOME/scripts/benchmark-score.sh" rereview "<raw rereview>" "$B/manifest.json"
   ```

6. **Judge** (when `judge` is a model id): one subagent per raw review,
   pinned to that model when the harness supports a per-agent model
   override, else the session model — record what actually judged as
   `judge_model_used`. Input: the raw review, the fixture's manifest
   (defect `class` included), and the scorer's tp/fp/fn. Output, integers
   1–5 plus a one-line `notes`:
   `finding_accuracy` (do TP descriptions state the real defect?),
   `category_accuracy` (does each TP describe the defect as its manifest
   `class` — a security issue named as security, not as style?),
   `fix_quality` (does each Fix line resolve its class?),
   `fp_defensibility` (are FPs defensible readings or fabrications?),
   `clarity` (would the author know what to change and why without reading
   the diff again — structure, ordering, no filler?),
   `language` (STE: short sentences, active voice, one term per concept).
   Re-review judges additionally receive `prior-review.md` and score
   `loop_risk` (5 = no circling: fixes acknowledged, never re-flagged or
   asked to be reverted; reads the scorer's `churn`/`false_fixed` as
   evidence). **Judge scores stay beside the deterministic metrics, never
   inside them** — the quality index is computed from scorer output only
   ([benchmark-report.sh](../scripts/benchmark-report.sh)), so the
   deterministic set is the comparison baseline whatever the judge does.
7. Assemble `results/<ts>.json` (schema below) and append one RESULTS.md row
   per fixture. The development-tracking and input-provenance fields
   (`prev_version`, `changes_since_prev`, `harness_version`, `memory_sha`,
   `skill_sources`, `definition_ref`) come from one deterministic call —
   merge its object in verbatim and add what only the session knows
   (`model`, `trigger`, `judge`, `judge_model_used`):

   ```bash
   bash "$HOME/scripts/benchmark-provenance.sh" "$HOME/work/benchmark"
   ```

   Field meanings and sources live in that script's header.
8. **Regenerate and republish the accumulated report** — the always-current
   artifact holding every run and the complete comparison table:

   ```bash
   bash "$HOME/scripts/benchmark-report.sh" "$HOME/work/benchmark" \
     > "$HOME/work/benchmark/report.html"
   ```

   Publish per the entry's `report` surfaces (`benchmark_report` key —
   `gist` | `dam` | `gist,dam` | `off`; `gist` only reaches `github.com`
   target hosts and is dropped elsewhere, `dam` is best-effort like
   [artifact.md](artifact.md)):
   - **gist** — one persistent secret gist, updated in place so its URL never
     changes. Its id lives in the RESULTS.md header marker
     `<!-- benchmark-gist: <id> -->`: marker present → update
     (`jq -n --rawfile c report.html '{files:{"report.html":{content:$c}}}' > /tmp/bench-gist.json`
     then `gh api -X PATCH "gists/<id>" --input /tmp/bench-gist.json`,
     remove the payload file); absent →
     `gh gist create --desc "Review benchmark report" "$HOME/work/benchmark/report.html"`
     and write the marker. The viewable link (same renderer as
     [artifact.md](artifact.md)):
     `https://htmlpreview.github.io/?https://gist.githubusercontent.com/$BOT_LOGIN/<id>/raw/report.html`.
   - **dam** — the DAM Artifact Library via its MCP tools when registered
     this session (`<!-- benchmark-dam: <id> -->` marker, same
     create-once-then-update pattern the tools offer). Tools absent → log
     and skip, never fail the run.
   A failed publish is logged; the local `report.html` is always current
   regardless.
9. Report to the chat UI: the run's **quality index** with its delta against
   the previous run — read both from
   `bash "$HOME/scripts/benchmark-report.sh" index "$HOME/work/benchmark"`
   (one JSON row per run; the weights live only in that script) —
   per-fixture headline scores, run totals (seconds, output tokens) with
   their deltas, any non-zero `churn`/`false_fixed` called out by name (the
   going-in-circles signals), any skill with no fixture coverage, and the
   report URL when published. First run: "baseline".
10. Cleanup every `/tmp/benchmark-pr-*` directory (`rm -rf` with `.out` and
    `.s-*` variants), the nonce cache
    (`rm -f "${TMPDIR:-/tmp}"/.bench-usage-*`), and temp payload files; log
    `benchmark run scored (avg f1=<x> over <n> fixtures)`; back up `work/`
    last.

### `results/<ts>.json`

```json
{"ts": "<ISO>", "trigger": "scheduled|manual", "model": "<exact session model id>",
 "judge": "<benchmark_judge value>", "judge_model_used": "<model or null>",
 "definition_version": "...", "prev_version": "...", "changes_since_prev": [],
 "harness_version": "...", "memory_sha": "...", "skill_sources": {},
 "definition_ref": {"branch": "...", "sha": "..."},
 "fixtures": {
   "<slug>": {
     "skills": {"<skill>": "ran (findings=N) | skipped (<reason>)"},
     "first":    {"<scorer output>": "...", "seconds": 0, "suppressed": 0,
                  "tokens": {"input":0,"output":0,"cache_read":0,"cache_creation":0,"msgs":0},
                  "judge": null},
     "rereview": {"<scorer output>": "...", "seconds": 0, "suppressed": 0, "tokens": null, "judge": null}
   }
 },
 "raw_dir": "results/raw/"}
```

`model` is the **exact model id** of the session as the harness names it
(Claude Code states it in the system prompt); when unavailable, write
`unknown` and log it. Every run therefore pins the full provenance triple —
definition version, model id, harness version — and the report shows what
changed in the definition between tested versions.

### `RESULTS.md`

```markdown
# Benchmark results
<!-- benchmark-gist: <id> -->
<!-- benchmark-dam: <id> -->

| ts | model | version | fixture | trigger | f1 | sev | fixed | new | words | sec | out-tok |
|----|-------|---------|---------|---------|----|-----|-------|-----|-------|-----|---------|
```

Append one row per fixture per run (create the file with this header when
missing; the publish markers are added when the first publish succeeds):
`| <ISO> | <model> | <definition_version> | <slug> | <trigger> | <first.f1> | <first.severity_accuracy> | <rereview.fixed_recall> | <rereview.new_recall> | <first.length.words_total> | <first.seconds + rereview.seconds> | <summed tokens.output or —> |`

## Trial runs (PR development — scored, never recorded)

A trial run scores the definition **as currently checked out** (typically a
feature branch under development) without touching the permanent history:
its results live only under the trial's own folder and never enter
`RESULTS.md`, `report.html`, or the published artifact, so the monthly
baseline stays clean while a PR is tuned in cycles — run, adjust, run again.

- **Trigger: operator only, in the direct session** — "run a trial
  benchmark" (optionally naming the PR/branch). Repeatable at will; each
  run appends one more result to the same trial.
- **Procedure**: exactly the run steps above, with these substitutions:
  - `TRIAL="$HOME/work/benchmark/trials/<id>"` where `<id>` =
    `pr-<n>` or the branch slug; results go to `$TRIAL/results/<ts>.json`,
    raw reviews and skill archives to `$TRIAL/results/raw/…`.
  - `trigger: "trial"`; provenance comes from the same
    `benchmark-provenance.sh` call — its `definition_ref: {branch, sha}` is
    what identifies the feature-branch code (`VERSION` alone does not).
  - **Skip entirely**: RESULTS.md rows, `report.html` regeneration,
    publishing, and `prev_version`/`changes_since_prev` (a trial compares
    to the baselines below, not to released versions).
  - The monthly gate and trials ignore each other: the gate reads only the
    official `results/*.json` (and only `trigger: scheduled` entries), and a
    trial writes only under `trials/<id>/`.
- **Compare**: render the trial's own mini report —
  `bash "$HOME/scripts/benchmark-report.sh" "$TRIAL" > "$TRIAL/report.html"`
  (the script reads any directory holding `results/`) — and report to the
  chat UI the index delta against **(a)** the previous run of the same trial
  (the tuning cycle) and **(b)** the latest official run (the production
  baseline), reading both from `benchmark-report.sh index` over the trial
  dir and over `$HOME/work/benchmark`.
- **Session separation applies unchanged**: a session that read any
  `manifest.json` (tuning fixtures, inspecting scores) does not run the
  trial — score it from a fresh session.
- **Cleanup**: a merged or abandoned PR's `trials/<id>/` is removed when the
  operator asks; the `work/` backup keeps every version in git history
  either way, so nothing is ever truly lost.

## On-demand (operator, direct session)

- "Create the benchmark fixtures" → the creation steps above (top-up to the
  full set).
- "Run the benchmark" → the run steps with `trigger: manual`. The monthly
  gate and manual runs ignore each other completely: a manual run is never
  gated, and only `trigger: scheduled` results feed the gate — a scheduled
  run still lands on the 1st even after a mid-month manual run, so the
  official monthly series stays unbroken. To benchmark a specific model, the
  operator switches the session model first — a run measures the session it
  runs in.
- "Show benchmark results" → read `RESULTS.md` / `report.html` (and
  `results/*.json` for detail) and summarize the trend; reading results is
  free of the session separation rule when no `run` follows in the same
  session.
