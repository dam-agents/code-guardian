# Model benchmark — scoring the review configuration over time

Read this file when the worklist has `benchmark_due`, or when the operator
asks in the direct session to create the fixture, run the benchmark, or show
its results.

The benchmark measures the production review configuration as one unit — the
session model, the adopted definition version, and the configured skills — by
replaying a fixed synthetic review task and scoring the output against known
defects. Results accumulate forever in `work/benchmark/`, so any two runs are
comparable across model upgrades and definition releases. The feature is fully
local: it makes no GitHub writes and posts nothing.

## Layout (`work/benchmark/`)

```
fixture/fx-<YYYYMMDD>/   # one benchmark task, immutable once created
  base/                  # starting tree (the "main" branch)
  head-v1/               # PR state 1 — the seeded-defect version
  head-v2/               # PR state 2 — the iteration: some defects fixed, some kept, a few new
  manifest.json          # ground truth (schema below)
  prior-review.md        # canonical prior review for the re-review task
  pr.json                # simulated PR metadata (schema below)
  diff-v1.patch          # base → head-v1
  diff-v1-v2.patch       # head-v1 → head-v2
results/<ts>.json        # one scored run (ts = YYYYMMDDTHHMMSSZ, UTC)
results/raw/<ts>-first.md, <ts>-rereview.md
RESULTS.md               # append-only index, one row per run, newest last
```

`results/`, `results/raw/`, and `RESULTS.md` are append-only history: runs add
files and rows; existing ones stay untouched forever (the standard `work/`
backup carries them). A fixture is immutable after creation. When the target
repo's stack changes enough that the fixture stops representing it, create a
new `fx-<date>` alongside — preflight picks the newest — and keep the old one:
past results reference it.

## Session separation

A scored run is meaningful only while the reviewing session does not know the
answers:

- `create_fixture` and `run` never share a session. The session that seeds
  defects knows the ground truth, so it ends after creating the fixture;
  preflight emits `run` from the next heartbeat on.
- In a `run`, `manifest.json`, `RESULTS.md`, and past `results/` are read in
  the scoring phase only — after both raw reviews are written. Phase 1 inputs
  are exactly: `pr.json`, the diff patches, the trees, `prior-review.md`, and
  the files a production review reads (docs/review.md, docs/skills.md,
  `work/MEMORY.md`, `work/LESSONS.md`).

## Creating the fixture (`action: create_fixture`, or operator ask)

1. Inputs: the target repo's languages (`gh api "repos/$REPO/languages"`) and
   the `## Review skills` table. The fixture mirrors the repo's dominant
   stack, and its file extensions route ≥ 1 file to every extension-triggered
   skill.
2. Generate `fixture/fx-<YYYYMMDD>/`: `base/` = 3–6 plausible source files,
   ~150–400 lines total; `head-v1/` = base plus 10–14 seeded defects
   (severities `critical`/`warning`, spread across correctness / security /
   performance / tests / maintainability) plus a few clean hunks as
   false-positive bait; `head-v2/` = head-v1 with roughly half the defects
   fixed, the rest kept, and 3–5 new ones. Keep defects in the same file
   ≥ 10 lines apart — the scorer matches on a ±3-line window.
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
6. Diffs, from inside `work/benchmark/fixture/fx-<date>/` (the pod has no
   standalone `diff`; `git diff` exits 1 on a non-empty diff — that is the
   expected success path here):
   `git diff --no-index base head-v1 > diff-v1.patch`;
   `git diff --no-index head-v1 head-v2 > diff-v1-v2.patch`.
7. Report the defect table (id, file:line, class, severity, fixed_in_v2,
   in_prior_review) to the chat UI for the operator, log
   `benchmark fixture fx-<date> created (<n> defects)`, and end the run
   (backup last, as always).

### `manifest.json`

```json
{"fixture": "fx-20260801", "created": "<ISO>",
 "defects": [{"id": "D01", "file": "src/auth.ts", "line_v1": 42, "line_v2": 42,
              "class": "security", "severity": "critical",
              "summary": "token compared with ==",
              "fixed_in_v2": false, "in_prior_review": true}]}
```

Per defect: kept in v2 → both lines set, `fixed_in_v2: false`; fixed in v2 →
`line_v2: null`, `fixed_in_v2: true`; introduced in v2 → `line_v1: null`.

## Running the benchmark (`action: run`, or operator ask)

### Phase 1 — review replay (before any ground-truth read)

1. Build the working repo in `/tmp` (the fixture holds no `.git`; `work/` is
   NFS — docs/persistence.md):

   ```bash
   B="$HOME/work/benchmark/fixture/<id>"; PR_DIR=/tmp/benchmark-pr
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

2. **First review**: perform docs/review.md steps c–d against this tree —
   diff = `diff-v1.patch`, PR context = `pr.json` (title/body/author), skill
   fan-out per docs/skills.md against `$PR_DIR` with base branch `main` (one
   audit line per configured skill, exactly as in production), full-file
   verification, merge findings across sources — and compose the
   **first-review Output format** with the marker line at `head_sha_v1` and
   its findings-json. Write it verbatim to `results/raw/<ts>-first.md`.
3. **Re-review**: advance the tree to v2 (repeat the swap-and-commit on `pr`
   with `head-v2/`), take `prior-review.md` as the prior review, scope =
   delta (request-equivalent trigger), changes since prior =
   `diff-v1-v2.patch`, skills run again with carryovers condensed per
   docs/review.md → **Re-review output** — and compose the delta re-review
   (marker at `head_sha_v2`, findings-json with `new`/`still`/`fixed`
   statuses) → `results/raw/<ts>-rereview.md`.

### Phase 2 — scoring

4. Deterministic scores (field meanings in the script header):

   ```bash
   bash "$HOME/scripts/benchmark-score.sh" first    "<raw first>"    "$B/manifest.json"
   bash "$HOME/scripts/benchmark-score.sh" rereview "<raw rereview>" "$B/manifest.json"
   ```

5. **Judge** (when `benchmark_judge` is a model id): one subagent per raw
   review, pinned to that model when the harness supports a per-agent model
   override, else the session model — record what actually judged as
   `judge_model_used`. Input: the raw review, the manifest, and the scorer's
   tp/fp/fn. Output, integers 1–5 plus a one-line `notes`:
   `finding_accuracy` (do TP descriptions state the real defect?),
   `fix_quality` (does each Fix line resolve its class?),
   `fp_defensibility` (are FPs defensible readings or fabrications?),
   `language` (STE: short sentences, active voice, one term per concept).
6. Assemble `results/<ts>.json` (schema below), append the RESULTS.md row,
   and report the headline scores to the chat UI with the delta against the
   previous row (first run: "baseline").
7. Cleanup `rm -rf /tmp/benchmark-pr /tmp/benchmark-pr.out /tmp/benchmark-pr.s-*`,
   log `benchmark run scored (f1=<x> sev=<y>)`, back up `work/` last.

### `results/<ts>.json`

```json
{"ts": "<ISO>", "trigger": "scheduled|manual", "model": "<session model id>",
 "definition_version": "<head -1 $HOME/VERSION>", "fixture": "fx-<date>",
 "judge": "<benchmark_judge value>", "judge_model_used": "<model or null>",
 "skills": {"<skill>": "ran (findings=N) | skipped (<reason>)"},
 "first": {"<scorer output>": "...", "judge": null},
 "rereview": {"<scorer output>": "...", "judge": null},
 "raw": {"first": "results/raw/<ts>-first.md",
         "rereview": "results/raw/<ts>-rereview.md"}}
```

`model` is the session model as the harness names it (Claude Code states it
in the system prompt); when unavailable, write `unknown` and log it.

### `RESULTS.md`

```markdown
# Benchmark results

| ts | model | version | fixture | trigger | f1 | sev | fixed | new | words |
|----|-------|---------|---------|---------|----|-----|-------|-----|-------|
```

Append per run (create the file with this header when missing):
`| <ISO> | <model> | <definition_version> | <fixture> | <trigger> | <first.f1> | <first.severity_accuracy> | <rereview.fixed_recall> | <rereview.new_recall> | <first.length.words_total> |`

## On-demand (operator, direct session)

- "Create the benchmark fixture" → the creation steps above.
- "Run the benchmark" → the run steps with `trigger: manual`; the monthly
  gate applies to scheduled runs only. To benchmark a specific model, the
  operator switches the session model first — a run measures the session it
  runs in.
- "Show benchmark results" → read `RESULTS.md` (and `results/*.json` for
  detail) and summarize the trend; reading results is free of the session
  separation rule when no `run` follows in the same session.
