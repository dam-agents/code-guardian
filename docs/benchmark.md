# Model benchmark — scoring the review configuration over time

Read this file when the worklist has `benchmark_due`, or when the operator asks
to create the fixture set, run the benchmark, or show its results.

The benchmark measures the production review configuration as one unit — the
session model, the adopted definition version and the configured skills. It
replays a fixed set of synthetic review tasks, scores the output against known
defects, and records wall-clock time and token usage per task. Results
accumulate forever in `work/benchmark/`, and every run republishes one
accumulated report, so any two runs are comparable across model upgrades and
definition releases. The feature writes nothing to GitHub beyond that report
and posts nothing to any PR.

## Layout (`work/benchmark/`)

```
fixture/<slug>/          # one benchmark project (immutable once created); the set holds ≥5
  base/                  # starting tree (the "main" branch)
  head-v1/               # PR state 1 — the seeded-defect version
  head-v2/               # PR state 2 — some defects fixed, some kept, a few new
  manifest.json          # ground truth (schema below)
  prior-review.md        # canonical prior review for the re-review task
  pr.json                # simulated PR metadata (schema below)
  diff-v1.patch          # base → head-v1
  diff-v1-v2.patch       # head-v1 → head-v2
results/<ts>.json        # one scored run, all fixtures (ts = YYYYMMDDTHHMMSSZ, UTC)
results/raw/<ts>-<slug>-first.md, <ts>-<slug>-rereview.md
.run-notes-<ts>.md       # segmented-run ledger (Segmented run below); absent otherwise
RESULTS.md               # append-only index — one row per run × fixture, newest last
report.html              # the accumulated report, regenerated every run
```

`results/`, `results/raw/` and `RESULTS.md` are append-only: runs add files and
rows, existing ones stay untouched forever. `report.html` is self-contained and
interactive — every table sorts by header click, filters by substring and
pages; it follows the reader's light/dark setting, and every delta carries an
arrow, so direction never rests on color alone.

A fixture is immutable after creation — that is what keeps scores comparable in
time. A fixture that stops representing the target repo's stack gets a new
sibling slug alongside it (the set may grow past 5). Retiring one is an
operator decision (**Retiring a fixture set**).

## Session separation

A scored run is meaningful only while the reviewing session does not know the
answers.

- `create_fixture` and `run` never share a session. The seeding session knows
  the ground truth, so it ends after creating fixtures; preflight emits `run`
  from the next benchmark tick on. The creation report invites the operator to
  ask for an on-demand run when they want the first baseline sooner than the
  monthly tick.
- In a `run`, `manifest.json`, `RESULTS.md` and past `results/` are read in the
  scoring phase only — after every raw review is written. Phase 1 inputs are
  exactly `pr.json`, the diff patches, the trees, `prior-review.md`, and the
  files a production review reads (docs/review.md, docs/finding-form.md,
  docs/skills.md, `work/MEMORY.md`, `work/LESSONS.md`).

## Creating the fixture set (`action: create_fixture`, or operator ask)

The entry carries `existing` (slugs on disk) and `min` (the required set size,
5). Create the **missing** fixtures only.

**The ground truth lives in `manifest.json` and nowhere else.** `base/`,
`head-v1/`, `head-v2/`, both patches and `prior-review.md` are Phase-1 inputs,
so a defect must be indistinguishable from an ordinary mistake there: no defect
ids (`D01`, `BUG-2`), no comment naming or explaining a planted flaw, no
"seeded"/"intentional"/"bait"/"false positive" notes, nothing in the v2 inputs
announcing the delta (`FIXED`, `still present`). A labelled defect still
produces numbers — they measure transcription instead of review skill — and
step 7 is the gate that catches it.

1. Inputs: the target repo's languages (`gh api "repos/$REPO/languages"`) and
   the `## Review skills` table. Cover **at least 5 clearly different shapes of
   change** — for example a backend/service API, a UI component set, a CLI
   tool, an infrastructure/CI change (shell + config) and a docs-heavy mixed
   change — in the target repo's languages, and so that every
   extension-triggered skill receives ≥ 1 file from ≥ 1 fixture. Name each slug
   after its type (`ts-api`, `react-ui`, `py-cli`, `infra-ci`, `docs-mixed`).
   A later skill-table trigger no fixture covers gets a new fixture the same
   way.
2. Generate each `fixture/<slug>/`:
   - `base/` — 3–6 plausible source files, ~150–400 lines total.
   - `head-v1/` — base plus 10–14 seeded defects (severities
     `critical`/`warning`, spread across correctness / security / performance /
     tests / maintainability) plus a few clean-but-suspicious-looking hunks,
     unlabelled: they are what measures false positives.
   - `head-v2/` — head-v1 with roughly half the defects fixed, the rest kept,
     and 3–5 new ones.
   - Keep defects in one file ≥ 10 lines apart (the scorer matches on a ±3-line
     window) and make each a **distinct pattern**, because the production
     sibling sweep merges same-class occurrences into one finding the scorer
     would read as a miss.
   - Mark 2–3 defects per fixture `"difficulty": "hard"` — ones needing
     reasoning across files or control flow (a lock released on one path only,
     an invariant broken two calls away, a unit mismatch between producer and
     consumer), never a greppable pattern. They feed `recall_hard`.
   - A model holding a fixture at `f1 = 1.0` for two consecutive runs has
     saturated it: add a harder sibling slug, and keep the saturated fixture
     for continuity.
3. Write `manifest.json`, verifying every `line_v1`/`line_v2` against the
   actual trees.
4. Write `prior-review.md` in the posted-review format (docs/review.md →
   **Summary body format**, marker at `head_sha_v1`) whose findings-json
   carries ~70 % of the v1 defects; set `in_prior_review: true` on exactly
   those manifest entries.
5. Write `pr.json`:
   `{number: 0, title, body, author, head_ref, base_ref, head_sha_v1, head_sha_v2}`
   — synthetic, stable SHAs (`git hash-object --stdin` over a fixture-unique
   string per version).
6. Diffs — generate them from a scratch git repo built exactly like Phase 1
   step 1, so the patch paths are **repo-relative and match the manifest**
   (`git diff --no-index` would prefix them with `base/` / `head-v1/`, and
   nothing would ever score as matched):

   ```bash
   git -C "$PR_DIR" diff main..pr~1 > "fixture/<slug>/diff-v1.patch"
   git -C "$PR_DIR" diff pr~1..pr   > "fixture/<slug>/diff-v1-v2.patch"
   rm -rf "$PR_DIR"
   ```

7. **Validate the set before it is accepted.** A fixture that fails this is not
   a fixture: fix it in this session and re-run until it passes.

   ```bash
   bash "$HOME/scripts/benchmark-validate.sh" fixture "$HOME/work/benchmark/fixture"/*/
   ```

   Each `FAIL` line carries its own `fix:` instruction. `leak_*` means the
   answers sit in the inputs; `diff_paths` means no finding can ever match the
   manifest.
8. Report the per-fixture defect tables (id, file:line, class, severity,
   fixed_in_v2, in_prior_review) plus the validation `PASS` line to the chat
   UI, log `benchmark fixtures created (<k> new, set now <n>, validated)`, and
   end the run (backup last, as always).

### `manifest.json`

```json
{"fixture": "ts-api", "created": "<ISO>",
 "defects": [{"id": "D01", "file": "src/auth.ts", "line_v1": 42, "line_v2": 42,
              "class": "security", "severity": "critical",
              "summary": "token compared with ==",
              "fixed_in_v2": false, "in_prior_review": true,
              "difficulty": "hard"}]}
```

- `difficulty` is optional and, when present, exactly `"hard"`. It feeds
  `recall_hard` and nothing else.
- Kept in v2 → both lines set, `fixed_in_v2: false`.
- Fixed in v2 → `line_v2: null`, `fixed_in_v2: true`, plus **`fix_line_v2`**,
  the line the fix landed on in `head-v2` (the scorer's `churn` metric matches
  re-flagged fixes against it).
- Introduced in v2 → `line_v1: null`.

## Running the benchmark (`action: run`, or operator ask)

The entry carries `fixtures`, `fixture_root`, `judge`, `report` and `last_run`.

**Gate first — never score an unvalidated set:**

```bash
bash "$HOME/scripts/benchmark-validate.sh" fixture "<fixture_root>"/*/
```

Non-zero exit → **abort before any review**: write no results, no RESULTS.md
row, no report, publish nothing. Report the `FAIL` lines (retiring the set is
the operator's decision — **Retiring a fixture set**), log
`benchmark run aborted: fixture validation failed (<ids>)` as a `warn` event,
release the run lock, and end the run. A leaky set's numbers would enter the
append-only history looking valid.

**Then take the run lock — one scored run at a time.** Two concurrent runs
share the `/tmp` trees and overwrite each other's phase stamps. The lock file
is `$HOME/work/benchmark/.run-lock`, first line `<ISO> <nonce>`:

- Lock present, its ISO younger than **6 h** → a sibling run is live: **stand
  down**, report it, touch nothing of the sibling's (its lock, its
  `/tmp/benchmark-pr-*` trees, its phase state), and end the run. This holds
  for preflight-emitted and operator-asked runs alike.
- Absent or older → write your own `<ISO> <NONCE>` line. **Every terminal path
  removes it** — the normal cleanup, the fixture-validation abort, the
  results-validation dead end. A crash leaves it to expire by TTL.

Then take one timestamp `TS` (compact + ISO) for the whole run and one usage
nonce, printed so the value itself lands in the transcript. The phase-state
directory is **keyed by the nonce**, so a stale-lock takeover cannot collide
with a dying sibling's stamps:

```bash
NONCE="bench-$(date -u +%s)-$$"
printf 'usage-nonce:%s\n' "$NONCE"   # the PRINTED value is what the snapshot
                                     # greps for — command text stays unexpanded
PSTATE="/tmp/benchmark-phase-$NONCE"
```

Bracket every phase with the measurement helper, never by hand:

```bash
bash "$HOME/scripts/benchmark-phase.sh" begin "$PSTATE" "<slug>-first" "$NONCE"
# … the review …
bash "$HOME/scripts/benchmark-phase.sh" end "$PSTATE" "<slug>-first" "$NONCE"
```

`end` prints the `{"seconds":…,"tokens":…}` pair the results file records
verbatim: wall-clock from the stamps, tokens as the difference between two
usage snapshots (skill fan-outs included), or `tokens: null` when the harness
gives no snapshot. **Never derive a duration by hand** — from file mtimes,
elapsed guesses or arithmetic. An estimate is indistinguishable from a
measurement once it is in the results file, and it breaks the speed-regression
comparison the field exists for.

### Phase 1 — review replay, per fixture (before any ground-truth read)

First, **install or refresh every configured repo-sourced skill** per
[skills.md](skills.md) → **Installation** (benchmark preflight is purely local
and installs nothing), and write each skill's source SHA to
`$HOME/.claude/skills/.cache/<skill>.sha` so `skill_sources` provenance stays
complete. Name in the run summary any configured extension skill that routes
zero files across **all** fixtures — that is missing fixture coverage.

**Review execution is delegated.** Each phase's review is composed by a fresh
reviewer subagent (the mechanism the skill fan-out uses); the session only
orchestrates — builds trees, runs fan-outs, brackets phases, collects paths and
counts. It never loads fixture sources, diffs, skill outputs or review bodies.
That is what lets one session hold every fixture at full depth, and it mirrors
production, where every review starts from a fresh context.

**Every subagent prompt inside a phase bracket — skill fan-out and reviewer
alike — carries the usage nonce and the instruction to print
`usage-nonce:<NONCE>` as its first output line.** The snapshot sums every
transcript holding the nonce, so a subagent spawned without it is work the
token columns silently miss. On a harness without subagents, review inline and
fall back to **Segmented run** when depth would degrade.

Loop over the slugs sequentially — fixtures and phases never run concurrently
(`benchmark-phase.sh` refuses an overlapping `begin`, because the token delta
spans the whole session and contention would distort `seconds`). Per fixture:

1. Build the working repo in `/tmp` (fixtures hold no `.git`, and `work/` is
   NFS — [persistence.md](persistence.md)):

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

2. **First review** — bracket it `"<slug>-first"`. Inside the bracket: run the
   [skills.md](skills.md) fan-out from the session (outputs in `$PR_DIR.out`;
   routing list = `git -C "$PR_DIR" diff --name-only main..pr`; briefs rendered
   by you from `scripts/templates/skill-brief.md`, because no live PR means no
   `review-pr.sh` helper applies). Then spawn **one fresh reviewer subagent**
   whose prompt says: perform docs/review.md steps c–d without `review-pr.sh`
   (verify against `$PR_DIR` directly), reading `work/MEMORY.md` +
   `work/LESSONS.md`, with diff = `diff-v1.patch`, PR context = `pr.json`,
   working tree = `$PR_DIR` on base branch `main`, skill outputs =
   `$PR_DIR.out`, marker SHA = `head_sha_v1`. It composes the **first-review
   Output format** with its findings-json, writes it verbatim to
   `results/raw/<ts>-<slug>-first.md`, and returns only the path, the finding
   counts and its `suppressed` count (step 4) — the orchestrator never reads
   the body, so a count it does not return is a count nobody records. Never
   pass it `manifest.json`, past results, or anything ground-truth-adjacent.
   Archive the skill outputs beside it:
   `cp -a "$PR_DIR.out" "$HOME/work/benchmark/results/raw/<ts>-<slug>-first-skills"`.
3. **Re-review** — bracket it `"<slug>-rereview"`. Advance the tree to v2
   (repeat the swap-and-commit on `pr` with `head-v2/`), re-run the fan-out per
   docs/review.md → **Re-review output** (routing from
   `git -C "$PR_DIR" diff --name-only pr~1..pr`), then spawn a **separate**
   fresh reviewer subagent — never the one that wrote the first review, so it
   knows only the posted prior review, as in production. Same prompt shape
   with `prior-review.md` as the prior review, diff =
   `git -C "$PR_DIR" diff main..pr`, scope = delta (request-equivalent
   trigger), and changes-since-prior = `diff-v1-v2.patch`, which stands in for
   the compare call (prior HEAD = `pr~1`, range `ahead`), so no compare call is
   made. It composes the delta re-review (marker at `head_sha_v2`,
   findings-json with `new`/`still`/`fixed`) into
   `results/raw/<ts>-<slug>-rereview.md` and archives its skill outputs the
   same way.
4. Record per task the `seconds` and `tokens` the phase helper printed,
   verbatim, plus `suppressed` from the reviewer subagent (0 when none). A
   memory preference that suppresses a seeded defect is a scoring confound, and
   this field makes it visible. A preference scoped to the target repository is
   **not applied** to fixtures; a finding withheld under one counts into
   `suppressed` the same way.

### Phase 2 — scoring, report, publish (ground truth now)

5. Per fixture, the deterministic scores (field meanings in the script header).
   A prediction matches on any of its anchors — its own `file:line` plus every
   `also` location ([review.md](review.md) → **Summary body format**) — so one
   sibling-swept finding scores every defect it names:

   ```bash
   bash "$HOME/scripts/benchmark-score.sh" first    "<raw first>"    "$B/manifest.json"
   bash "$HOME/scripts/benchmark-score.sh" rereview "<raw rereview>" "$B/manifest.json"
   ```

6. **Judge** (when `judge` is a model id): one subagent per raw review, pinned
   to that model where the harness supports a per-agent override, else the
   session model — record what actually judged as `judge_model_used`. Input:
   the raw review, the fixture's manifest (defect `class` included) and the
   scorer's tp/fp/fn. Output: integers 1–5 plus a one-line `notes` —
   `finding_accuracy` (do TP descriptions state the real defect?),
   `category_accuracy` (is each TP described as its manifest `class`?),
   `fix_quality` (does each Fix line resolve its class?), `fp_defensibility`
   (are FPs defensible readings or fabrications?), `clarity` (would the author
   know what to change and why without reading the diff again?), `language`
   (STE). A re-review judge also receives `prior-review.md` and scores
   `loop_risk` (5 = no circling: fixes acknowledged, never re-flagged or asked
   to be reverted; reads `churn`/`false_fixed` as evidence). **Judge scores
   stay beside the deterministic metrics, never inside them** — the quality
   index comes from scorer output only
   ([benchmark-report.sh](../scripts/benchmark-report.sh)), so the
   deterministic set is the comparison baseline whatever the judge does. The
   report prints `finding_accuracy` in its own `find-acc` column: high f1 beside
   a low `find-acc` marks true positives matched by position, not by mechanism.
7. Assemble `results/<ts>.json` (schema below). The development-tracking and
   input-provenance fields (`prev_version`, `changes_since_prev`,
   `harness_version`, `memory_sha`, `skill_sources`, `definition_ref`) come
   from one deterministic call — merge its object in verbatim and add what only
   the session knows (`model`, `trigger`, `judge`, `judge_model_used`):

   ```bash
   bash "$HOME/scripts/benchmark-provenance.sh" "$HOME/work/benchmark"
   ```

8. **Validate the assembled results before anything reads them** — the history
   is append-only, so a wrong shape is permanent:

   ```bash
   bash "$HOME/scripts/benchmark-validate.sh" results "$HOME/work/benchmark/results/<ts>.json"
   ```

   Non-zero exit → fix the file (each `FAIL` names its remedy) and re-validate.
   Append no rows, regenerate no report and publish nothing until it passes. If
   it cannot be fixed: delete the file, report why, release the run lock, and
   end the run with nothing recorded.
9. Append one RESULTS.md row per fixture, then **regenerate and republish the
   accumulated report**:

   ```bash
   bash "$HOME/scripts/benchmark-report.sh" "$HOME/work/benchmark" \
     > "$HOME/work/benchmark/report.html"
   ```

   Publish to the entry's `report` surfaces (`benchmark_report`: `gist` |
   `dam` | `gist,dam` | `off`; `gist` reaches `github.com` target hosts only,
   `dam` is best-effort as in [artifact.md](artifact.md)):
   - **gist** — one persistent secret gist, updated in place so its URL never
     changes. Its id lives in the RESULTS.md header marker
     `<!-- benchmark-gist: <id> -->`. Marker present → update
     (`jq -n --rawfile c report.html '{files:{"report.html":{content:$c}}}' > /tmp/bench-gist.json`,
     then `gh api -X PATCH "gists/<id>" --input /tmp/bench-gist.json`, then
     remove the payload file); absent →
     `gh gist create --desc "Review benchmark report" "$HOME/work/benchmark/report.html"`
     and write the marker. Viewable link:
     `https://htmlpreview.github.io/?https://gist.githubusercontent.com/$BOT_LOGIN/<id>/raw/report.html`.
   - **dam** — the DAM Artifact Library via its MCP tools when registered
     (`<!-- benchmark-dam: <id> -->` marker, same create-once-then-update
     pattern). Tools absent → log and skip, never fail the run.

   A failed publish is logged; the local `report.html` is current regardless.
10. Report to the chat UI: the run's **quality index** with its delta against
    the previous run **of the same model** — read both from
    `bash "$HOME/scripts/benchmark-report.sh" index "$HOME/work/benchmark"`
    (one JSON row per run with `cost_usd`; the weights and the price lookup
    live only in that script) — per-fixture headline scores, run totals
    (seconds, output tokens, estimated cost when the price table covers the
    model — **Model prices**) with their deltas, any non-zero
    `churn`/`false_fixed` named explicitly (the going-in-circles signals), any
    skill with no fixture coverage, any **saturated fixture** (`f1 = 1.0` in
    this and the same model's previous run — recommend a harder sibling), and
    the report URL when published. First run of a model: "baseline".
11. Clean up every `/tmp/benchmark-pr-*` directory (`rm -rf` with `.out` and
    `.s-*` variants), your phase-state directory, your nonce cache
    (`${TMPDIR:-/tmp}/.bench-usage-$NONCE`) and temp payload files; **remove
    the run lock**; log
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

`model` is the **exact model id** of the session as the harness names it; when
unavailable, write `unknown` and log it. Every run therefore pins the full
provenance triple — definition version, model id, harness version — and the
report shows what changed in the definition between tested versions.

### `RESULTS.md`

```markdown
# Benchmark results
<!-- benchmark-gist: <id> -->
<!-- benchmark-dam: <id> -->

| ts | model | version | fixture | trigger | f1 | sev | fixed | new | words | sec | out-tok |
|----|-------|---------|---------|---------|----|-----|-------|-----|-------|-----|---------|
```

One row per fixture per run (create the file with this header when missing; the
publish markers are added when the first publish succeeds):
`| <ISO> | <model> | <definition_version> | <slug> | <trigger> | <first.f1> | <first.severity_accuracy> | <rereview.fixed_recall> | <rereview.new_recall> | <first.length.words_total> | <first.seconds + rereview.seconds> | <summed tokens.output or —> |`

## Segmented run (operator, direct session)

The fallback when delegated execution is unavailable (a harness without
subagents) and one session cannot give every fixture the same review depth: a
manual run split into segments, **one fixture per session**. A baseline with a
depth gradient across fixtures measures the context budget, not the
configuration. Operator-triggered only — a scheduled run is never segmented.

- **One identity across segments.** Segment 1 takes the run's `TS` + `trigger`
  and creates the ledger `$HOME/work/benchmark/.run-notes-<TS>.md`, recording
  the adopted definition version and, per measured fixture, the phase helper's
  `seconds`/`tokens`/`suppressed` verbatim. The ledger is the single source of
  truth for what is done; raw reviews and skill archives are written per
  segment exactly as in a single-session run.
- **Each segment**: verify the adopted definition version still matches the
  ledger (drift → stop and report; never mix versions inside one run), take the
  run lock, run Phase 1 for exactly **one** unmeasured fixture (skill
  install/refresh included, its own printed nonce), append the fixture's
  numbers to the ledger, clean the segment's `/tmp` trees, phase state and
  nonce cache, **release the lock**, back up `work/`. Never re-run a fixture
  the ledger lists as measured; a measured fixture with missing raw files →
  stop and report.
- **Final segment**: the ledger shows every fixture measured → continue in the
  same session with Phase 2 unchanged (score → validate → RESULTS.md → report →
  publish), recording the ledger's numbers verbatim; the cleanup additionally
  deletes the ledger.
- **Between segments** the lock is released and the ledger marks the run live:
  preflight's benchmark mode emits `nothing_to_do` while any
  `.run-notes-*.md` is younger than **7 days**. An older ledger is an abandoned
  run — the tick is emitted over it and the ledger is reported, not deleted.
- Session separation holds unchanged: `manifest.json` is read only in the final
  segment, after that segment's raw reviews are written.

## Model prices (cost column)

The report prices each run's summed token counters into an `est $` column.
Prices are operator-maintained in `work/CONFIG.md` as a table the report reads
directly (`benchmark-report.sh`); an absent table, an unmatched model or
unmeasured tokens render "—", never a guess:

```markdown
## Benchmark model prices

| model substring | input | output | cache_read | cache_write |
|---|---|---|---|---|
| claude-opus-5 | 15 | 75 | 1.5 | 18.75 |
```

USD per MTok. A row matches when its first cell is a substring of the run's
recorded model id. The table holds the **current** prices and the report prices
all history with them, so cost deltas reflect token usage, not price moves.
Update it in the direct session like any other config change.

## Retiring a fixture set (operator decision, direct session)

A fixture is immutable, so a set that turns out invalid — validation fails, or
it stopped representing the repo — is **retired and replaced**, never edited in
place. Only the operator decides; the agent reports and waits. Check the run
lock first: a live run reads the fixture trees, so it finishes or its lock
expires before anything moves.

1. `mkdir -p fixture/retired && mv fixture/<slug> fixture/retired/<slug>` per
   retired slug. Retired fixtures stay on disk forever — past results
   reference them, and `fixture/retired/` is outside the `fixture/*/` glob
   preflight counts, so the set reads as incomplete and `create_fixture`
   becomes due.
2. Mark the affected history **non-comparable**: add one line under the
   RESULTS.md header naming the timestamps and the reason, e.g.
   `_Runs <ts>… scored fixture set 1, retired <date> (ground truth leaked into the inputs) — not comparable with later runs._`
   Never delete a row, a `results/*.json` or a raw review.
3. Create the replacement set in a fresh session (**Creating the fixture
   set**), which validates it, and take the first scored run in yet another
   session. The new series starts at that run.

## Trial runs (PR development — scored, never recorded)

A trial run scores the definition **as currently checked out**, typically a
feature branch, without touching the permanent history: its results live only
under the trial's own folder and never enter `RESULTS.md`, `report.html` or the
published artifact, so the monthly baseline stays clean while a PR is tuned in
cycles.

- **Trigger: operator only, in the direct session** — "run a trial benchmark",
  optionally naming the PR/branch. Repeatable at will. A trial takes the
  **same run lock** as a scored run.
- **Procedure**: the run steps above, with these substitutions:
  - `TRIAL="$HOME/work/benchmark/trials/<id>"`, `<id>` = `pr-<n>` or the branch
    slug; results to `$TRIAL/results/<ts>.json`, raw reviews and skill archives
    to `$TRIAL/results/raw/…`.
  - `trigger: "trial"`; provenance from the same `benchmark-provenance.sh`
    call, whose `definition_ref: {branch, sha}` is what identifies
    feature-branch code (`VERSION` alone does not).
  - **Skip entirely**: RESULTS.md rows, `report.html` regeneration, publishing,
    and `prev_version`/`changes_since_prev`.
  - The monthly gate and trials ignore each other: the gate reads only the
    official `results/*.json` (and only `trigger: scheduled` entries), and a
    trial writes only under `trials/<id>/`.
- **Compare**: render the trial's own mini report —
  `bash "$HOME/scripts/benchmark-report.sh" "$TRIAL" > "$TRIAL/report.html"`
  (the script reads any directory holding `results/`) — and report the index
  delta against **(a)** the previous run of the same trial and **(b)** the
  latest official run, reading both from `benchmark-report.sh index`.
- **Session separation applies unchanged**: a session that read any
  `manifest.json` does not run the trial — score it from a fresh session.
- **Cleanup**: a merged or abandoned PR's `trials/<id>/` is removed when the
  operator asks; the `work/` backup keeps its git history either way.

## On-demand (operator, direct session)

- "Create the benchmark fixtures" → the creation steps above (top-up to the
  full set).
- "Run the benchmark" → the run steps with `trigger: manual`. A manual run is
  never gated, and only `trigger: scheduled` results feed the gate, so a
  scheduled run still lands on the 1st after a mid-month manual run. To
  benchmark a specific model, the operator switches the session model first — a
  run measures the session it runs in. On request, split it one fixture per
  session (**Segmented run**).
- "Show benchmark results" → read `RESULTS.md` / `report.html` (and
  `results/*.json` for detail) and summarize the trend. Reading results is free
  of the session-separation rule when no `run` follows in the same session.
