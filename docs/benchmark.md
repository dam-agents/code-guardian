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
.run-notes-<ts>.md       # segmented-run ledger (Segmented run below); absent otherwise
RESULTS.md               # append-only index — one row per run × fixture, newest last
report.html              # the accumulated report, regenerated every run (script below);
                         # self-contained and interactive client-side — every table
                         # sorts by header click, filters by substring, and pages;
                         # follows the reader's light/dark setting, and every delta
                         # carries an arrow so direction never rests on color alone
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

**The ground truth lives in `manifest.json` and nowhere else.** `base/`,
`head-v1/`, `head-v2/`, both patches, and `prior-review.md` are all Phase-1
inputs the reviewing session reads, so a defect must be indistinguishable
from an ordinary mistake there: **no defect ids** (`D01`, `BUG-2`), no
comment naming or explaining a planted flaw, no "seeded"/"intentional"/
"bait"/"false positive" notes, and nothing in the v2 inputs announcing the
delta (`FIXED`, `still present`). A labelled defect is not a hard error —
the scorer never reads the code — which is exactly why it is dangerous: the
run still produces numbers, and they measure transcription instead of review
skill. `benchmark-validate.sh fixture` (step 7) is the gate that catches it.

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
   performance / tests / maintainability) plus a few clean-but-suspicious-looking
   hunks (unlabelled — they are what measures false positives); `head-v2/` = head-v1 with roughly half the defects
   fixed, the rest kept, and 3–5 new ones. Keep defects in the same file
   ≥ 10 lines apart — the scorer matches on a ±3-line window — and make
   every defect a **distinct pattern**: the production sibling sweep merges
   same-class occurrences into one finding, which the scorer would count as
   a miss. Mark 2–3 defects per fixture `"difficulty": "hard"` in the
   manifest — ones that require reasoning across files or control flow
   (a lock released on one path but not another, an invariant broken two
   calls away, a unit mismatch between producer and consumer), never a
   greppable pattern. They feed the scorer's `recall_hard` — the headroom
   that keeps the set challenging for stronger models — and when a model
   holds a fixture at `f1 = 1.0` for two consecutive runs, the fixture is
   saturated: add a harder sibling slug (the set grows past 5; the
   saturated fixture stays for continuity).
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
7. **Validate the set — before it is accepted, not after.** A fixture that
   fails this is not a fixture: fix it in this same session and re-run until
   it passes.

   ```bash
   bash "$HOME/scripts/benchmark-validate.sh" fixture "$HOME/work/benchmark/fixture"/*/
   ```

   Each `FAIL` line carries its own `fix:` instruction. A `leak_*` failure
   means the answers sit in the inputs; a `diff_paths` failure means no
   finding can ever match the manifest.
8. Report the per-fixture defect tables (id, file:line, class, severity,
   fixed_in_v2, in_prior_review) plus the validation `PASS` line to the chat
   UI for the operator, log `benchmark fixtures created (<k> new, set now
   <n>, validated)`, and end the run (backup last, as always).

### `manifest.json`

```json
{"fixture": "ts-api", "created": "<ISO>",
 "defects": [{"id": "D01", "file": "src/auth.ts", "line_v1": 42, "line_v2": 42,
              "class": "security", "severity": "critical",
              "summary": "token compared with ==",
              "fixed_in_v2": false, "in_prior_review": true,
              "difficulty": "hard"}]}
```

`difficulty` is optional and, when present, exactly `"hard"` (step 2); it
feeds `recall_hard` and nothing else — the index never reads it.

Per defect: kept in v2 → both lines set, `fixed_in_v2: false`; fixed in v2 →
`line_v2: null`, `fixed_in_v2: true`, plus **`fix_line_v2`** — the line the
fix landed on in `head-v2` (the scorer's `churn` metric matches re-flagged
fixes against it); introduced in v2 → `line_v1: null`.

## Running the benchmark (`action: run`, or operator ask)

The entry carries `fixtures` (slugs), `fixture_root`, `judge`, `report`, and
`last_run`.

**Gate first — never score an unvalidated set:**

```bash
bash "$HOME/scripts/benchmark-validate.sh" fixture "<fixture_root>"/*/
```

Non-zero exit → **abort the run before any review**: write no results, no
RESULTS.md row, no report, publish nothing; report the `FAIL` lines to the
operator (retiring and regenerating the set is their decision — **Retiring a
fixture set** below), log
`benchmark run aborted: fixture validation failed (<ids>)` as a `warn` event
([logging.md](logging.md)), release the run lock, and end the run. Scoring a leaky set is worse
than not scoring: its numbers enter the append-only history looking valid.

**Then take the run lock — one scored run at a time.** Two concurrent runs
share the `/tmp` trees and overwrite each other's phase stamps, which turns
both runs' measurements into garbage. The lock file is
`$HOME/work/benchmark/.run-lock`, first line `<ISO> <nonce>`:

- Lock present and its ISO younger than **6 h** → a sibling run is live:
  **stand down** — report it, touch nothing of the sibling's (its lock, its
  `/tmp/benchmark-pr-*` trees, its phase state), and end the run. The same
  applies to preflight-emitted and operator-asked runs alike.
- Absent or older → write your own `<ISO> <NONCE>` line. **Every terminal
  path of the run removes it** — the normal cleanup step, the
  fixture-validation abort, and the results-validation dead end. A crash
  leaves it to expire by TTL.

Then take one timestamp `TS` (compact + ISO) for the whole run, and one usage
nonce, printed so the value itself lands in the transcript. The phase-state
directory is **keyed by the nonce**, so even a stale-lock takeover can never
collide with a dying sibling's stamps:

```bash
NONCE="bench-$(date -u +%s)-$$"
printf 'usage-nonce:%s\n' "$NONCE"   # the PRINTED value is what the snapshot
                                     # greps for — command text stays unexpanded
PSTATE="/tmp/benchmark-phase-$NONCE"
```

Every phase is then bracketed by the measurement helper — never by hand:

```bash
bash "$HOME/scripts/benchmark-phase.sh" begin "$PSTATE" "<slug>-first" "$NONCE"
# … the review …
bash "$HOME/scripts/benchmark-phase.sh" end "$PSTATE" "<slug>-first" "$NONCE"
```

`end` prints the `{"seconds":…,"tokens":…}` pair the results file records
verbatim: wall-clock from the stamps, tokens as the difference between two
usage snapshots (same accounting as the run-level `tokens` event, skill
fan-outs included), or `tokens: null` when the harness gives no snapshot.
**Never derive a duration by hand** — from file mtimes, elapsed wall-clock
guesses, or arithmetic in your head. An estimate is indistinguishable from a
measurement once it is in the results file, and it silently breaks the
speed-regression comparison the field exists for.

### Phase 1 — review replay, per fixture (before any ground-truth read)

First, **install/refresh every configured repo-sourced skill** per
docs/skills.md → Installation fallback (benchmark mode's preflight is purely
local and never installs them), and write each skill's source SHA to the
install cache (`$HOME/.claude/skills/.cache/<skill>.sha`) so `skill_sources`
provenance stays complete. A configured extension skill that routes zero
files across **all** fixtures is named in the run's chat summary as missing
fixture coverage (the operator tops the set up per fixture creation).

Review execution is **delegated**: each phase's review is composed by a
fresh reviewer subagent (the same mechanism the skill fan-out uses), while
the session only orchestrates — builds trees, runs fan-outs, brackets
phases, and collects paths and counts. It never loads fixture sources,
diffs, skill outputs, or review bodies; that is what lets one session hold
every fixture at full depth, and it mirrors production, where every review
starts from a fresh context. **Every subagent prompt inside a phase bracket
— skill fan-out and reviewer alike — carries the usage nonce and the
instruction to print `usage-nonce:<NONCE>` as its first output line**: the
snapshot sums every transcript holding the nonce, so delegated work is
counted (a subagent spawned without it is work the token columns silently
miss). On a harness without subagents, review inline and fall back to
**Segmented run** when depth would degrade.

Then loop over the slugs sequentially — fixtures and phases never run
concurrently (`benchmark-phase.sh` refuses an overlapping `begin`: the
token delta spans the whole session, so parallel phases would absorb each
other's usage, and contention would distort `seconds`). For each fixture:

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

2. **First review** — bracket it with `benchmark-phase.sh begin/end
   "$PSTATE" "<slug>-first"`. Inside the bracket: run the docs/skills.md
   fan-out from the session (outputs in `$PR_DIR.out`; routing list =
   `git -C "$PR_DIR" diff --name-only main..pr`, the benchmark's equivalent
   of the production `gh pr diff` list; the briefs rendered by you from
   `scripts/templates/skill-brief.md` — there is no live PR, so none of the
   `review-pr.sh` helpers apply here), then spawn **one fresh reviewer
   subagent** whose prompt carries: perform docs/review.md steps c–d without
   `review-pr.sh` (verify against `$PR_DIR` directly),
   reading `work/MEMORY.md` + `work/LESSONS.md`, with diff =
   `diff-v1.patch`, PR context = `pr.json` (title/body/author), working
   tree = `$PR_DIR` with base branch `main`, skill outputs = `$PR_DIR.out`,
   and marker SHA = `head_sha_v1`. The subagent composes the **first-review
   Output format** with its findings-json and itself writes it verbatim to
   `results/raw/<ts>-<slug>-first.md` — nothing is posted — returning only
   the path, the finding counts, and its `suppressed` count (step 4; the
   orchestrator never reads the review body, so a count the subagent does
   not return is a count nobody records). Never pass it `manifest.json`,
   past results, or anything ground-truth-adjacent. Archive the skill outputs
   beside it:
   `cp -a "$PR_DIR.out" "$HOME/work/benchmark/results/raw/<ts>-<slug>-first-skills"`
   (when the fan-out ran).
3. **Re-review** — bracket it the same way (`"<slug>-rereview"`): advance the tree to v2
   (repeat the swap-and-commit on `pr` with `head-v2/`), re-run the fan-out
   per docs/review.md → **Re-review output** (routing from the same
   `git diff --name-only main..pr`, now at v2), then spawn a **separate
   fresh reviewer subagent** — never the one that wrote the first review,
   so it knows only the posted prior review, as in production: same prompt
   shape with `prior-review.md` as the prior review, scope = delta
   (request-equivalent trigger), changes since prior = `diff-v1-v2.patch`.
   It composes the delta re-review (marker at `head_sha_v2`, findings-json
   with `new`/`still`/`fixed` statuses) →
   `results/raw/<ts>-<slug>-rereview.md`, archiving the skill outputs the
   same way (`…/<ts>-<slug>-rereview-skills`).
4. Record per task the `seconds` and `tokens` the phase helper printed,
   verbatim — plus `suppressed`, the count the reviewer subagent returned
   (from its suppression audit note, docs/review.md → PR context; 0 when
   none): a memory
   preference that suppresses a seeded defect is a scoring confound, and
   this field is what makes it visible. A preference scoped to the target
   repository (a repo convention, a CI-enforced rule) is **not applied** to
   fixtures; findings withheld under one count into `suppressed` the same
   way.

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
7. Assemble `results/<ts>.json` (schema below) — the RESULTS.md rows follow
   only after it validates (step 9). The development-tracking and input-provenance fields
   (`prev_version`, `changes_since_prev`, `harness_version`, `memory_sha`,
   `skill_sources`, `definition_ref`) come from one deterministic call —
   merge its object in verbatim and add what only the session knows
   (`model`, `trigger`, `judge`, `judge_model_used`):

   ```bash
   bash "$HOME/scripts/benchmark-provenance.sh" "$HOME/work/benchmark"
   ```

   Field meanings and sources live in that script's header.
8. **Validate the assembled results before anything reads them** — the
   history is append-only, so a wrong shape is permanent:

   ```bash
   bash "$HOME/scripts/benchmark-validate.sh" results "$HOME/work/benchmark/results/<ts>.json"
   ```

   Non-zero exit → fix the file (each `FAIL` names its own remedy) and
   re-validate. Do not append the RESULTS.md rows, regenerate the report, or
   publish until it passes; if it cannot be fixed, delete the file, report
   why, release the run lock, and end the run with nothing recorded.
9. Append one RESULTS.md row per fixture, then **regenerate and republish the
   accumulated report** — the always-current
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
10. Report to the chat UI: the run's **quality index** with its delta against
   the previous run **of the same model** — read both from
   `bash "$HOME/scripts/benchmark-report.sh" index "$HOME/work/benchmark"`
   (one JSON row per run with `cost_usd`; the weights and the price lookup
   live only in that script) — per-fixture headline scores, run totals
   (seconds, output tokens, estimated cost when the CONFIG price table
   covers the model — **Model prices** below) with their deltas, any
   non-zero `churn`/`false_fixed` called out by name (the going-in-circles
   signals), any skill with no fixture coverage, any **saturated fixture**
   (`f1 = 1.0` in this and the same model's previous run — recommend a
   harder sibling, step 2 of fixture creation), and the report URL when
   published. First run of a model: "baseline".
11. Cleanup every `/tmp/benchmark-pr-*` directory (`rm -rf` with `.out` and
    `.s-*` variants), your phase-state directory (`rm -rf "$PSTATE"`), your
    nonce cache (`rm -f "${TMPDIR:-/tmp}/.bench-usage-$NONCE"`), and temp
    payload files; **remove the run lock**
    (`rm -f "$HOME/work/benchmark/.run-lock"`); log
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

## Segmented run (operator, direct session)

The fallback when delegated execution is unavailable (a harness without
subagents) and one session cannot give every fixture the same review depth —
a baseline with a depth gradient across fixtures measures the context
budget, not the configuration: a manual run split into segments, **one
fixture per session**. Operator-triggered only; a scheduled run is never
segmented.

- **One identity across segments**: segment 1 takes the run's `TS` +
  `trigger` and creates the ledger
  `$HOME/work/benchmark/.run-notes-<TS>.md`, recording the adopted
  definition version and, per measured fixture, the phase-helper
  `seconds`/`tokens`/`suppressed` verbatim. The ledger is the single source
  of truth for what is done; raw reviews and skill archives are written per
  segment exactly as in a single-session run.
- **Each segment**: verify the adopted definition version still matches the
  ledger (drift → stop and report; never mix versions inside one run), take
  the run lock, run Phase 1 for exactly **one** unmeasured fixture (skill
  install/refresh included, its own printed nonce), append the fixture's
  numbers to the ledger, clean the segment's `/tmp` trees / phase state /
  nonce cache, **release the lock**, back up `work/`. Never re-run a
  fixture the ledger lists as measured; a measured fixture with missing raw
  files → stop and report.
- **Final segment**: the ledger shows every fixture measured → continue in
  the same session with Phase 2 unchanged (score → validate → RESULTS.md →
  report → publish), recording the ledger's numbers verbatim; the cleanup
  step additionally deletes the ledger (superseded by `results/<TS>.json`;
  the backup keeps its history).
- **Between segments** the lock is released and the ledger marks the run
  live: preflight's benchmark mode emits `nothing_to_do` while any
  `.run-notes-*.md` is younger than **7 days**, so a scheduled tick never
  starts a second run mid-pause. An older ledger is an abandoned run — the
  tick is emitted over it and the ledger is reported, not deleted (operator
  decides).
- Session separation holds unchanged: `manifest.json` is read only in the
  final segment, after that segment's raw reviews are written.

## Model prices (cost column)

The report prices each run's summed token counters into an `est $` column —
the money side of the time/cost/quality comparison. Prices are
operator-maintained in `work/CONFIG.md` as a table the report reads directly
(`benchmark-report.sh`; absent table, unmatched model, or unmeasured tokens
render "—", never a guess):

```markdown
## Benchmark model prices

| model substring | input | output | cache_read | cache_write |
|---|---|---|---|---|
| claude-opus-5 | 15 | 75 | 1.5 | 18.75 |
```

USD per MTok; a row matches when its first cell is a substring of the run's
recorded model id. Prices change over time — the table holds the **current**
prices and the report prices all history with them (a constant-price view:
cost deltas then reflect token usage, not price moves). Update the table in
the direct session like any other config change.

## Retiring a fixture set (operator decision, direct session)

A fixture is immutable, so a set that turns out invalid — validation fails,
or it stopped representing the repo — is **retired and replaced**, never
edited in place. Only the operator decides this; the agent reports the
finding and waits. Check the run lock first — a live run reads the fixture
trees, so it finishes (or its lock expires) before anything moves.

1. `mkdir -p fixture/retired && mv fixture/<slug> fixture/retired/<slug>` for
   every retired slug. Retired fixtures stay on disk forever: past results
   reference them, and `fixture/retired/` is outside the `fixture/*/` glob
   preflight counts, so the set reads as incomplete and `create_fixture`
   becomes due again.
2. Mark the affected history **non-comparable** — the rows and result files
   stay (append-only), they only stop being read as a baseline: add one line
   under the RESULTS.md header naming the timestamps and the reason, e.g.
   `_Runs <ts>… scored fixture set 1, retired <date> (ground truth leaked into the inputs) — not comparable with later runs._`
   Never delete a row, a `results/*.json`, or a raw review.
3. Create the replacement set in a fresh session (**Creating the fixture
   set**), which validates it, and take the first scored run in yet another
   session (session separation). The new series starts at that run.

## Trial runs (PR development — scored, never recorded)

A trial run scores the definition **as currently checked out** (typically a
feature branch under development) without touching the permanent history:
its results live only under the trial's own folder and never enter
`RESULTS.md`, `report.html`, or the published artifact, so the monthly
baseline stays clean while a PR is tuned in cycles — run, adjust, run again.

- **Trigger: operator only, in the direct session** — "run a trial
  benchmark" (optionally naming the PR/branch). Repeatable at will; each
  run appends one more result to the same trial. A trial takes the **same
  run lock** as a scored run — the /tmp trees are shared, so one at a time
  applies to both kinds alike.
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
  runs in. On request the run is split one-fixture-per-session
  (**Segmented run**).
- "Show benchmark results" → read `RESULTS.md` / `report.html` (and
  `results/*.json` for detail) and summarize the trend; reading results is
  free of the session separation rule when no `run` follows in the same
  session.
