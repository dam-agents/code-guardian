# Model benchmark — scoring the review configuration over time

Read this file when the worklist has `benchmark_due`, or when the operator asks
to create the fixture set, run the benchmark, or show its results.

It scores the production review configuration (session model, adopted
definition version, configured skills) on fixed synthetic review tasks against
known defects, with time and tokens per task. Results accumulate forever in
`work/benchmark/`; nothing goes to GitHub.

## Layout (`work/benchmark/`)

```
fixture/<slug>/          # one benchmark project (immutable once created)
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
judge.json               # the judge the agent pinned under benchmark_judge: auto (Choosing the judge)
RESULTS.md               # append-only index — one row per run × fixture, newest last
report.html              # the accumulated report, regenerated every run
trials/<id>/             # one trial's .run-lock, results/ and report.html (Trial runs)
```

`results/`, `results/raw/` and `RESULTS.md` are append-only: existing files and
rows never change. `report.html` is self-contained; its column help lives in
the `TIPS` dictionary of `benchmark-report.sh`. A fixture is immutable: one that
stops representing the target repo's stack gets a new sibling slug (the set may
grow past its minimum); retiring one is the operator's (**Retiring a fixture
set**).

## Task tiers

The benchmark judges **simple** and **complex** tasks apart. Difficulty lives
on two axes, both in `manifest.json` only:

- **Task tier** — the fixture's `tier`: `simple` (absent = simple) or
  `complex`. The set holds **≥ 5 simple and ≥ 3 complex** fixtures.
  - simple: `base/` 3–6 files, ~150–400 lines; 10–14 v1 defects, 2–3 hard.
  - complex: `base/` 8–15 files across ≥ 3 modules, ~800–1500 lines; 15–20
    v1 defects, **≥ 5 hard**; head-v2 fixes interact (one fix moves the
    precondition of another defect).
- **Defect difficulty** — `"difficulty": "hard"` on a defect that needs
  reasoning across files or control flow (a lock released on one path only, an
  invariant broken two calls away, a unit mismatch between producer and
  consumer), never a greppable pattern. Every other defect is easy. Hard
  defects feed `recall_hard`, the rest `recall_easy`.

The scorer copies the tier and counts `tp`/`gt` per difficulty; the report
pools each tier over its fixtures (**Sufficiency by tier**). The slug names
the shape of the change, never its tier: the sub-agents see the slug.

## Session separation

- `create_fixture` and `run` never share a session: the seeding session ends
  after creating fixtures; preflight emits `run` from the next benchmark tick
  on. The creation report offers the operator an on-demand run for an earlier
  baseline.
- In a `run`, Phase 1 runs in sub-agents that hold no ground truth
  (**Isolation**); `manifest.json`, `RESULTS.md` and past `results/` are read
  in the scoring phase only, after every raw review is written. Phase 1 inputs
  are exactly `pr.json`, the diff patches, the trees, `prior-review.md`, and
  the files a production review reads (docs/review.md, docs/finding-form.md,
  docs/skills.md, `work/MEMORY.md`, `work/LESSONS.md`).

## Creating the fixture set (`action: create_fixture`, or operator ask)

The entry carries `existing` (slugs on disk), `min` and `min_complex` (5 and
3) and `missing` (`{simple, complex}`). Create the **missing** fixtures only,
each to its tier's spec (**Task tiers**).

**The ground truth lives in `manifest.json` and nowhere else.** Every other
fixture file is a Phase-1 input, so a defect must look like an ordinary mistake
there: no defect ids (`D01`, `BUG-2`), no comment naming or explaining a
planted flaw, no "seeded"/"intentional"/"bait"/"false positive" notes, nothing
in the v2 inputs announcing the delta (`FIXED`, `still present`). Step 7
catches a labelled defect.

1. Inputs: the target repo's languages (`gh api "repos/$REPO/languages"`) and
   the `## Review skills` table. Cover **at least 5 clearly different shapes of
   change** in those languages (`ts-api`, `react-ui`, `py-cli`, `infra-ci`,
   `docs-mixed` — the slug names the shape) so that every extension-triggered
   skill receives ≥ 1 file from ≥ 1 fixture; a later uncovered skill trigger
   gets a new fixture the same way. A complex fixture is a larger change of one
   shape (a service with its client and migration) with `"tier": "complex"`.
2. Generate each `fixture/<slug>/`:
   - `base/` — plausible source files at the tier's size.
   - `head-v1/` — base plus the tier's count of seeded defects (severities
     `critical`/`warning`, spread across correctness / security / performance /
     tests / maintainability), the tier's count marked hard, plus a few
     clean-but-suspicious-looking hunks, unlabelled: they measure false
     positives.
   - `head-v2/` — head-v1 with roughly half the defects fixed, the rest kept,
     and 3–5 new ones.
   - Keep defects in one file ≥ 10 lines apart (the scorer matches on a ±3-line
     window) and make each a **distinct pattern**: the sibling sweep merges
     same-class occurrences into one finding.
3. Write `manifest.json`, verifying every `line_v1`/`line_v2` against the
   actual trees.
4. Write `prior-review.md` in the posted-review format (docs/review-mechanics.md
   → **Summary body format**, marker at `head_sha_v1`) whose findings-json
   carries ~70 % of the v1 defects; set `in_prior_review: true` on exactly those
   manifest entries.
5. Write `pr.json`:
   `{number: 0, title, body, author, head_ref, base_ref, head_sha_v1, head_sha_v2}`
   — synthetic, stable SHAs (`git hash-object --stdin` over a fixture-unique
   string per version).
6. Diffs — from a scratch git repo built exactly like Phase 1 step 1, so the
   patch paths are **repo-relative and match the manifest**:

   ```bash
   git -C "$PR_DIR" diff main..pr~1 > "fixture/<slug>/diff-v1.patch"
   git -C "$PR_DIR" diff pr~1..pr   > "fixture/<slug>/diff-v1-v2.patch"
   rm -rf "$PR_DIR"
   ```

7. **Validate the set before it is accepted** — fix a failing fixture in this
   session and re-run until it passes:

   ```bash
   bash "$HOME/scripts/benchmark-validate.sh" fixture "$HOME/work/benchmark/fixture"/*/
   ```

   Each `FAIL` line carries its own `fix:`. `leak_*` means the answers sit in
   the inputs; `diff_paths` means no finding can ever match the manifest.
8. Report the per-fixture defect tables (tier; id, file:line, class, severity,
   difficulty, fixed_in_v2, in_prior_review) plus the validation `PASS` line to
   the chat UI, log `benchmark fixtures created (<k> new, set now <n>, validated)`,
   and end the run (backup last).

### `manifest.json`

```json
{"fixture": "ts-api", "created": "<ISO>", "tier": "simple",
 "defects": [{"id": "D01", "file": "src/auth.ts", "line_v1": 42, "line_v2": 42,
              "class": "security", "severity": "critical",
              "summary": "token compared with ==",
              "fixed_in_v2": false, "in_prior_review": true,
              "difficulty": "hard"}]}
```

- `tier` is optional: `simple` or `complex`; the validator checks a complex
  fixture for ≥ 8 base files and ≥ 5 hard v1 defects.
- `difficulty` is optional and, when present, exactly `"hard"`; it only splits
  recall into `recall_easy` and `recall_hard`.
- Kept in v2 → both lines set, `fixed_in_v2: false`.
- Fixed in v2 → `line_v2: null`, `fixed_in_v2: true`, plus **`fix_line_v2`**,
  the line the fix landed on in `head-v2` (the scorer's `churn` metric matches
  re-flagged fixes against it).
- Introduced in v2 → `line_v1: null`.

## Running the benchmark (`action: run`, or operator ask)

The entry carries `fixtures`, `fixture_root`, `judge`, `judge_unavailable`
(null, or why this host cannot run the judge), `isolation_unavailable` (null,
or why the run cannot be isolated), `report` and `last_run`. An operator-asked
run takes `judge` and `judge_unavailable` from
`bash "$HOME/scripts/benchmark-judge.sh" resolve`, the object preflight reads.

**Gate first — never score an unvalidated set:**

```bash
bash "$HOME/scripts/benchmark-validate.sh" fixture "<fixture_root>"/*/
```

Non-zero exit → **abort before any review**, recording and publishing
nothing: report the `FAIL` lines (**Retiring a fixture set** is the
operator's), log `benchmark run aborted: fixture validation failed (<ids>)` as
a `warn` event, and end the run (no lock is held yet).

**Then take the run lock — one scored run at a time.** The lock file is
`$HOME/work/benchmark/.run-lock` (a trial's: **Trial runs**), first line
`<ISO> <nonce>`:

- Lock present with an ISO younger than **6 h** → a sibling run is live:
  **stand down**, report it, touch nothing of the sibling's (lock, `/tmp`
  trees, phase state), and end the run.
- Absent or older → write your own `<ISO> <NONCE>` line. **Every terminal path
  removes it**; a crash leaves it to expire by TTL.

Take one timestamp `TS` (compact + ISO) for the whole run and one usage nonce,
printed so the value lands in the transcript; the phase-state directory is
**keyed by the nonce**:

```bash
NONCE="bench-$(date -u +%s)-$$"
printf 'usage-nonce:%s\n' "$NONCE"   # the PRINTED value is what the snapshot
                                     # greps for — command text stays unexpanded
PSTATE="/tmp/benchmark-phase-$NONCE"
```

Bracket every phase with the measurement helper:

```bash
bash "$HOME/scripts/benchmark-phase.sh" begin "$PSTATE" "<slug>-first" "$NONCE"
# … the review …
bash "$HOME/scripts/benchmark-phase.sh" end "$PSTATE" "<slug>-first" "$NONCE"
```

`end` prints the `{"seconds":…,"tokens":…}` pair recorded verbatim (tokens =
the usage-snapshot difference, skill fan-outs included; `null` when the harness
gives no snapshot). **Never derive a duration by hand.**

First, **install or refresh every configured repo-sourced skill** —
`bash "$HOME/scripts/skill-install.sh"` ([skills.md](skills.md) →
**Installation**; benchmark preflight installs nothing). It records each
skill's source SHA for `skill_sources`, and the sub-agents get exactly these
installs. Name in the run summary any configured extension skill that routes
zero files across **all** fixtures — missing fixture coverage.

### Isolation

Phase 1 runs in **isolated platform sub-agents**, one per fixture and phase,
all at once, each with its own volume and no connection. A sub-agent gets the
definition at the seeded commit (this checkout's HEAD, or a trial's
`--commit`) and one bundle of its task's inputs, nothing else of this volume.
`start` snapshots the memory files and skills once per run and writes the
expected provenance to `$PSTATE/expect.json`. `benchmark-isolate.sh` refuses a
bundle or a definition history (every commit of every local ref and of the
seeded commit) that holds ground truth, and a public work repo.

1. `isolation_unavailable` is set, or
   `bash "$HOME/scripts/benchmark-isolate.sh" check` (a trial: `check --commit
   <SHA>`) prints a reason → **Isolation unavailable**.
2. Spawn every task:
   ```bash
   bash "$HOME/scripts/benchmark-isolate.sh" start [--effort <e>] --model <m> \
     "$PSTATE" "<TS compact>" "<fixture_root>" <slug>…
   ```
   `--effort` = this session's effort when the harness exposes one
   (`effort` of the provenance). `--model` = this session's exact model id,
   provider-qualified (Claude Code names it `claude/<provider>/<id>`; on pi
   `start` reads `PI_MODEL` when `--model` is absent), or the model the
   operator names for this run. The sub-agents run on that model only:
   `collect` reports any other as a `model` mismatch. A trial adds
   `--commit <SHA> --branch <branch>`. A refusal before the first `spawned`
   line → **Isolation unavailable**; after it → abort.
3. `bash "$HOME/scripts/benchmark-isolate.sh" wait "$PSTATE"` in the
   foreground until exit 0; exit 3 means call it again.
4. `bash "$HOME/scripts/benchmark-isolate.sh" collect "$PSTATE" "<raw dir>"`
   (`$HOME/work/benchmark/results/raw`) writes every raw review and skill
   archive — only when nothing failed or mismatched — and prints per task
   `seconds`, `tokens`, `suppressed` and `spawn`, plus the run's `model`,
   `harness_version` and `effort`. A `failed` task gets one retry — the same
   `start` command plus `--only <slug>-<phase>`, then `wait` and `collect`
   again; a second failure or any `mismatches` entry (other inputs than
   `start` snapshotted, or another model) → abort.

**Abort** = cleanup (step 11), nothing recorded, the reason in the chat UI.
Sub-agents still running end at their deadline.

### Isolation unavailable

- **Scheduled run:** stop before any review. Release the lock, record
  nothing, report the reason in the chat UI, and log
  `benchmark run stopped: isolation unavailable (<reason>)` as a `warn` event.
- **Direct session:** report the reason and ask the operator. Only on their
  explicit yes for this run, run **Phase 1** in this pod and record
  `isolation: "none"`, `isolation_reason` and
  `isolation_approved: "<ISO> operator"`.

### Isolated review (benchmark sub-agent)

Runs in the sub-agent that the prompt of
[`scripts/templates/benchmark-child.md`](../scripts/templates/benchmark-child.md)
names. `$HOME` holds the definition at the production commit; the bundle put
the fixture inputs (no manifest) under `$HOME/work/benchmark/fixture/<slug>/`,
`work/MEMORY.md`, `LESSONS.md`, `CONFIG.md` and the repo-sourced skills in
place, and the harness adapter is installed.

1. `NONCE` = the prompt's, `PSTATE="/tmp/benchmark-phase-$NONCE"`,
   `B="$HOME/work/benchmark/fixture/<slug>"`, `<ts>` = the prompt's, and
   `mkdir -p "$HOME/work/benchmark/results/raw"`. No gate, no lock, no skill
   install, no Phase 2.
2. Phase `first`: **Phase 1** step 1, then step 2. Phase `rereview`: step 1,
   then step 3. Write the phase helper's `end` output to
   `$HOME/work/benchmark/.measure-<slug>-<phase>.json`.
3. `bash "$HOME/scripts/benchmark-child.sh" report <slug> <phase> <ts> <model> <suppressed>`
   with this session's exact model id and the reviewer subagent's
   `suppressed`. End the turn once it is accepted.

### Phase 1 — review replay, per fixture (before any ground-truth read)

The steps a sub-agent runs for its one task (**Isolated review**), or this
session in-pod for every fixture after an approval (**Isolation
unavailable**).

**Review execution is delegated.** A fresh reviewer subagent composes each
phase's review; the session only orchestrates (trees, fan-outs, brackets,
paths, counts) and never loads fixture sources, diffs, skill outputs or review
bodies.

**Every subagent prompt inside a phase bracket — skill fan-out and reviewer
alike — carries the usage nonce and the instruction to print
`usage-nonce:<NONCE>` as its first output line.** The snapshot sums only the
transcripts holding the nonce. The subagent mechanism is the harness's
([logging.md](logging.md) → **Harness adapters** names its file). On a harness
with none, review inline and fall back to **Segmented run** when depth would
degrade.

In-pod, loop over the slugs sequentially — fixtures and phases never run
concurrently (`benchmark-phase.sh` refuses an overlapping `begin`). Per fixture:

1. Build the working repo in `/tmp` (fixtures hold no `.git`, and `work/` is
   NFS — [persistence.md](persistence.md)), with `origin/main` on the base
   commit — the base ref of every skill brief and of the run's own diffs, as
   in a `prepare` clone ([skills.md](skills.md) → **Clone, credential helper,
   cleanup**):

   ```bash
   B="<fixture_root>/<slug>"; PR_DIR="/tmp/benchmark-pr-<slug>"
   rm -rf "$PR_DIR" "$PR_DIR".out "$PR_DIR".s-* "$PR_DIR".prompts-* "$PR_DIR".reviewer-*
   git init -q "$PR_DIR" && cp -a "$B/base/." "$PR_DIR/"
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench add -A
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench commit -qm base
   git -C "$PR_DIR" branch -m main && git -C "$PR_DIR" checkout -qb pr
   git -C "$PR_DIR" update-ref refs/remotes/origin/main main
   find "$PR_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
   cp -a "$B/head-v1/." "$PR_DIR/"
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench add -A
   git -C "$PR_DIR" -c user.email=bench@local -c user.name=bench commit -qm v1
   ```

2. **First review** — bracket it `"<slug>-first"`. Inside the bracket: run the
   [skills.md](skills.md) fan-out from the session (outputs in `$PR_DIR.out`;
   routing list = `git -C "$PR_DIR" diff --name-only origin/main..pr`; briefs
   rendered by you from `scripts/templates/skill-brief.md`, its base ref
   `main`, its scratch directory `$PR_DIR.out/<skill>.scratch`, its checkout a detached worktree per skill
   (`git -C "$PR_DIR" worktree add -q --detach "$PR_DIR.s-<skill>"`), its
   severity rubric the bullets under **Severity:** of
   [finding-form.md](finding-form.md), its time budget the `SKILL_BUDGET_MIN`
   of `review-pr.sh`, its Orientation paragraph the no-map form `prepare`
   writes — a fixture has no profile and no live PR, so no `review-pr.sh`
   helper applies; each subagent's prompt is the one line `prepare` would
   write, naming the skill, PR #0 and that brief). A guide skill
   ([skills.md](skills.md) → **Guide skills**) does not run: nothing scores
   it, and a fixture has no PR to guide. Then spawn **one fresh reviewer
   subagent**, without a model or effort override, whose prompt is
   [`scripts/templates/reviewer-brief.md`](../scripts/templates/reviewer-brief.md)
   rendered verbatim — nothing added, nothing cut, each value substituted
   expanded (absolute paths, the SHA itself): `{{NONCE}}` = the printed
   `$NONCE`, `{{SLUG}}` = `<slug>`, `{{PHASE}}` = `first`, `{{DIFF}}` =
   `` `$B/diff-v1.patch` ``, `{{PR_JSON}}` = `$B/pr.json`, `{{WORKDIR}}` =
   `$PR_DIR`, `{{SKILLS_OUT}}` = `$PR_DIR.out`, `{{HEAD_SHA}}` = `head_sha_v1`
   of `$B/pr.json`, `{{REREVIEW_BLOCK}}` = empty, `{{OUTPUT}}` = `first-review
   **Output format**`, `{{OUT_FILE}}` =
   `$HOME/work/benchmark/results/raw/<ts>-<slug>-first.md`. The orchestrator
   never reads the body: a count the subagent does not return is not recorded.
   Never pass it `manifest.json`, past results, or anything
   ground-truth-adjacent. Archive the skill outputs beside it:
   `cp -a "$PR_DIR.out" "$HOME/work/benchmark/results/raw/<ts>-<slug>-first-skills"`.
3. **Re-review** — bracket it `"<slug>-rereview"`. Clear the first review's
   skill state
   (`rm -rf "$PR_DIR".out "$PR_DIR".s-* "$PR_DIR".prompts-* "$PR_DIR".reviewer-*`,
   then `git -C "$PR_DIR" worktree prune`), advance the tree to v2 (repeat the
   swap-and-commit on `pr` with `head-v2/`), re-run the fan-out per
   docs/review-rereview.md → **Re-review output** (routing from
   `git -C "$PR_DIR" diff --name-only pr~1..pr`), then spawn a **separate**
   fresh reviewer subagent — never the first review's, so it knows only the
   posted prior review. Same template, with
   `{{PHASE}}` = `rereview`, `{{DIFF}}` = `` `git -C "$PR_DIR" diff origin/main..pr` ``,
   `{{HEAD_SHA}}` = `head_sha_v2` of `$B/pr.json`, `{{OUTPUT}}` = `delta
   re-review`, `{{OUT_FILE}}` =
   `$HOME/work/benchmark/results/raw/<ts>-<slug>-rereview.md`, and
   `{{REREVIEW_BLOCK}}` = this line, paths expanded the same way:
   ``- Re-review: follow docs/review-rereview.md; prior review = `$B/prior-review.md`; scope = delta (request-equivalent trigger); findings-json with `new`/`still`/`fixed`; changes-since-prior = `$B/diff-v1-v2.patch`, which stands in for the compare call (prior HEAD = `pr~1`, range `ahead`) — make no compare call.``
   Archive its skill outputs the same way.
4. Record per task the `seconds` and `tokens` the phase helper printed,
   verbatim, plus `suppressed` from the reviewer subagent (0 when none).

### Phase 2 — scoring, report, publish (ground truth now)

5. Per fixture, the deterministic scores (field meanings in the script header).
   A prediction matches on any of its anchors — its own `file:line` plus every
   `also` location ([review-mechanics.md](review-mechanics.md) → **Summary body
   format**) — so one sibling-swept finding scores every defect it names:

   ```bash
   bash "$HOME/scripts/benchmark-score.sh" first    "<raw first>"    "$B/manifest.json"
   bash "$HOME/scripts/benchmark-score.sh" rereview "<raw rereview>" "$B/manifest.json"
   ```

6. **Judge** — only when `judge` is not `off` and `judge_unavailable` is null;
   with a reason, make no judge call, keep every phase's `judge` null and make
   that reason the run's `judge_reason`. `judge` is picked per **Choosing the
   judge**; use it for every call of this run and record it as the run's
   `judge`, also when no call runs. One call per raw review, never a subagent;
   the script calls `claude -p`, or `pi` on the same model where that CLI is
   missing or not signed in:

   ```bash
   bash "$HOME/scripts/benchmark-judge.sh" first    "<judge>" "<raw first>"    "$B/manifest.json" "<first scorer json>"
   bash "$HOME/scripts/benchmark-judge.sh" rereview "<judge>" "<raw rereview>" "$B/manifest.json" "<rereview scorer json>" "$B/prior-review.md"
   ```

   Write the scorer output to a file first. Copy the printed `judge` into the
   phase's `judge` verbatim, and `judge_model_used` and `judge_harness` into
   the run level. A status other than `ok` keeps that phase's `judge` null; the
   first such `reason` becomes the run's `judge_reason`, reported once in the
   chat summary. After `unavailable`, or a reason that the host does not serve
   the model, make no further judge call this run. Rubric:
   [`scripts/templates/judge-brief.md`](../scripts/templates/judge-brief.md).
   **Judge scores stay beside the deterministic metrics, never inside them**:
   the quality index is scorer output only. High f1 beside a low `find-acc`
   (`finding_accuracy`) marks true positives matched by position, not
   mechanism.
7. Assemble `results/<ts>.json` (schema below). The development-tracking and
   input-provenance fields (`prev_version`, `changes_since_prev`,
   `harness_version`, `effort`, `memory_sha`, `skill_sources`,
   `definition_ref`) come from one deterministic call — merge its object in
   verbatim and add what only the session knows (`model`, `trigger`, `judge`,
   `judge_model_used` and `judge_reason` from step 6). An isolated run merges
   `$PSTATE/expect.json` instead — the seeded commit's provenance — adds
   `isolation: "platform-subagent"` and each phase's `spawn`, and takes
   `model`, `harness_version` and `effort` from `collect`. In-pod:

   ```bash
   bash "$HOME/scripts/benchmark-provenance.sh" "$HOME/work/benchmark"
   ```

8. **Validate the assembled results before anything reads them**:

   ```bash
   bash "$HOME/scripts/benchmark-validate.sh" results "$HOME/work/benchmark/results/<ts>.json"
   ```

   Non-zero exit → fix the file (each `FAIL` names its remedy) and re-validate;
   nothing is appended, regenerated or published until it passes. Unfixable →
   delete the file, report why, release the run lock, and end the run with
   nothing recorded.
9. Append one RESULTS.md row per fixture, then **regenerate and republish the
   accumulated report**:

   ```bash
   bash "$HOME/scripts/benchmark-report.sh" "$HOME/work/benchmark" \
     > "$HOME/work/benchmark/report.html"
   ```

   Publish per `report` (`benchmark_report`: `dam` | `off`): `dam` — the DAM
   Artifact Library, created once then updated in place (stable URL), the id
   in the RESULTS.md header marker `<!-- benchmark-dam: <id> -->`.
   Best-effort as in [artifact.md](artifact.md): tools absent or a failed
   publish → log and skip, never fail the run.
10. Report to the chat UI, each delta against the previous comparable run
    (schema notes below; "baseline" without one), read from
    `bash "$HOME/scripts/benchmark-report.sh" index "$HOME/work/benchmark"`
    (one JSON row per run with `cost_usd`; weights and price lookup live only
    there):
    - the run's **quality index** and per-fixture headline scores;
    - the **sufficiency line** — the verdict per tier with its pooled counts,
      from `tiers` of the same `index` row (**Sufficiency by tier**), e.g.
      `simple: sufficient (rec 0.91, 20/22) · complex: insufficient (rec 0.60, 12/20; hard 1/5)`;
    - run totals — seconds, output tokens, estimated cost when the price table
      covers the model (**Model prices**);
    - any non-zero `churn`/`false_fixed`, named (the going-in-circles
      signals);
    - the **style line** — `ste.sentences_over_20` of `ste.sentences` and
      `ste.avg_sentence_words` over the first reviews
      ([review.md](review.md) → **The sentence bar is 20 words**); its delta
      needs a previous run of the same `ste.v`;
    - any skill with no fixture coverage, any **saturated fixture** (`f1 =
      1.0` in this and the previous run of the same model and effort —
      recommend a harder sibling slug, keeping the saturated one), and the
      report URL when published.
11. Clean up every `/tmp/benchmark-pr-*` directory (`rm -rf` with `.out` and
    `.s-*` variants), your phase-state directory, your nonce cache
    (`${TMPDIR:-/tmp}/.bench-usage-$NONCE`) and temp payload files; **remove
    the run lock**; log `benchmark run scored (avg f1=<x> over <n> fixtures)`;
    back up `work/` last.

### `results/<ts>.json`

```json
{"ts": "<ISO>", "trigger": "scheduled|manual", "model": "<exact session model id>",
 "judge": "<resolved judge or off>", "judge_model_used": "<model or null>",
 "judge_harness": "<claude|pi or null>", "judge_reason": "<first non-ok reason or null>",
 "definition_version": "...", "prev_version": "...", "changes_since_prev": [],
 "harness_version": "...", "effort": "<low|medium|high|xhigh|max|unknown>",
 "memory_sha": "...", "skill_sources": {},
 "definition_ref": {"branch": "...", "sha": "..."},
 "isolation": "platform-subagent|none", "isolation_reason": "<none only>",
 "isolation_approved": "<ISO> operator (none only)",
 "fixtures": {
   "<slug>": {
     "skills": {"<skill>": "ran (findings=N) | skipped (<reason>)"},
     "first":    {"<scorer output>": "...", "seconds": 0, "suppressed": 0, "spawn": "<id>",
                  "tokens": {"input":0,"output":0,"cache_read":0,"cache_creation":0,"msgs":0},
                  "judge": null},
     "rereview": {"<scorer output>": "...", "seconds": 0, "suppressed": 0, "tokens": null, "judge": null}
   }
 },
 "raw_dir": "results/raw/"}
```

- `judge_model_used` — the model that answered, as `benchmark-judge.sh`
  printed it from the judge CLI's own usage record, or null when no call
  answered `ok`; `judge_harness` — the CLI that answered. The report shows
  judge scores only for a run whose `judge_model_used` the pinned `judge`
  matches.
- `model` — the **exact model id** the reviews ran on as the harness names it
  (the sub-agents' from `collect`, in-pod the session's); unavailable →
  `unknown`, and log it.
- `effort` — the reasoning effort the reviews ran at, from the harness
  (`scripts/lib/harness.sh`: `CLAUDE_EFFORT` on Claude Code,
  `PI_REASONING_LEVEL` on pi), else `unknown`; reviewer and skill subagents run
  without an effort override.
- Deltas compare runs of the same harness, model, effort **and** isolation; a
  run without `effort` matches only another run without it, a run without
  `isolation` counts as `none`, and a run at effort `unknown` gets no delta —
  report it as `effort unknown`.

### `RESULTS.md`

```markdown
# Benchmark results
<!-- benchmark-dam: <id> -->

| ts | model | version | fixture | trigger | f1 | sev | fixed | new | words | sec | out-tok |
|----|-------|---------|---------|---------|----|-----|-------|-----|-------|-----|---------|
```

One row per fixture per run (create the file with this header when missing; the
publish markers are added when the first publish succeeds):
`| <ISO> | <model> | <definition_version> | <slug> | <trigger> | <first.f1> | <first.severity_accuracy> | <rereview.fixed_recall> | <rereview.new_recall> | <first.length.words_total> | <first.seconds + rereview.seconds> | <summed tokens.output or —> |`

## Segmented run (operator, direct session)

An approved in-pod run (**Isolation unavailable**) on a harness without
subagents, when one session cannot give every fixture the same depth, splits
**one fixture per session**. Operator-only; a scheduled run is never segmented.

- **One identity across segments.** Segment 1 takes `TS` + `trigger` and
  creates the ledger `$HOME/work/benchmark/.run-notes-<TS>.md` (definition
  version, effort, and per measured fixture the phase helper's
  `seconds`/`tokens`/`suppressed` verbatim) — the single source of truth for
  what is done. Raw reviews and skill archives are written per segment.
- **Each segment**: verify the definition version and the effort still match
  the ledger (drift → stop and report; never mix them inside one run), take the
  run lock, run Phase 1 for exactly **one** unmeasured fixture (skill
  install/refresh included, its own printed nonce), append its numbers to the
  ledger, clean the segment's `/tmp` trees, phase state and nonce cache,
  **release the lock**, back up `work/`. Never re-run a fixture the ledger
  lists as measured; a measured fixture with missing raw files → stop and
  report.
- **Final segment**: every fixture measured → continue in the same session
  with Phase 2 unchanged, recording the ledger's numbers verbatim; the cleanup
  also deletes the ledger. `manifest.json` is read only here, after this
  segment's raw reviews are written.
- **Between segments** the ledger marks the run live: preflight's benchmark
  mode emits `nothing_to_do` while any `.run-notes-*.md` is younger than
  **7 days**. An older ledger is an abandoned run — the tick is emitted over
  it and the ledger is reported, not deleted.

## Choosing the judge (`benchmark_judge: auto`)

Under `auto` the agent picks the judge once, and every later run uses that
pick; it changes only when the host stops serving it. `resolve` prints the
exact id this host serves as `judge`; with `source` `unpicked` or `repick` that
is its `candidate`, pinned after its first `ok` reply; `judge` is `auto` only
while the host's model list is unknown — then pick one first.

- **Names**: `benchmark_judge` and the pin need not be exact. `resolve` reads
  this host's model list (`benchmark-judge.sh models`: the claude endpoint's
  `/v1/models`, or `pi --list-models`) and takes the served id the name
  matches — the same id, else the same model under another provider prefix,
  else the newest id the name matches (`opus-5` → `…/claude-opus-5`, never
  `…/claude-opus-5-5`; `opus` → the newest Opus). A name the host does not
  serve is `judge_unavailable` with `cause: not_served` before the run, and
  the monitor alerts it. An unknown list blocks nothing: the name is used as
  written.
- **Recommendation**: `resolve`'s `candidate` — the newest Opus this host
  serves, else the newest Sonnet. With the list unknown, pick the most capable
  model you know the host serves.
- **Pin it** after its first `ok` reply, before step 7:

  ```bash
  bash "$HOME/scripts/benchmark-judge.sh" pin "<model id>" "<one line: why this model>"
  ```

  The pick lives in `work/benchmark/judge.json`. A candidate without an `ok`
  reply stays unpinned: the run records it as `judge`, keeps every phase's
  `judge` null with its `judge_reason`, and the next run picks again.
- **Re-pick** only when the host's model list no longer names the pinned
  model: `resolve` then prints `source: repick` and the `candidate` as
  `judge`. `pin` keeps the old pick under `replaced`; the new judge starts a new
  comparability window for the judge columns, and the chat summary says so.
- An operator's model id in `benchmark_judge` always wins: `pin` refuses, and
  the agent never changes that id.

## Sufficiency by tier

The report's **Sufficiency by task tier** table shows the latest run of each
configuration (harness, model, effort, isolation) with one verdict per tier:
the tier's first reviews pooled (summed `tp`, `gt` and `fp`) and checked
against the operator's bar in `work/CONFIG.md`:

```markdown
## Benchmark sufficiency

| tier | recall | precision | min_defects |
|---|---|---|---|
| simple | 0.8 | 0.7 | 20 |
| complex | 0.8 | 0.7 | 20 |
```

A tier the table does not name keeps these defaults. The verdict:

- **sufficient** — pooled recall and precision meet the bar, and no re-review
  of the tier reported a present defect fixed (`false_fixed` 0);
- **borderline** — no false-fixed, and both values within 0.05 under the bar;
- **too few defects** — fewer pooled defects than `min_defects`;
- **insufficient** — anything else; a false-fixed re-review makes the tier
  insufficient at any sample size.

The cell carries the pooled counts (`rec 0.91 (20/22) · prec 0.95 · hard 3/5`).
Verdict and easy/hard recall stay beside the index, never inside it. Bar and
rule live in `scripts/lib/sufficiency.sh`; `benchmark-report.sh index` carries
them per run as `tiers`. The operator changes the table in the direct session.

## Model prices (cost column)

The report prices each run's summed token counters into an `est $` column.
Prices are operator-maintained in `work/CONFIG.md` as one table that every
consumer reads through `scripts/lib/prices.sh`; an absent table, an unmatched
model or unmeasured tokens render "—", never a guess:

```markdown
## Benchmark model prices

| model substring | input | output | cache_read | cache_write |
|---|---|---|---|---|
| claude-opus-5-5 | 4 | 20 | 0.2 | 5 |
```

- USD per MTok. A row matches when its first cell is part of the run's
  recorded model id, in any letter case; a provider path (`bedrock/`) or a
  `[…]` suffix in the cell is ignored. The longest matching cell prices the
  run, the first of equal ones.
- After a cell that ends in a digit, a dash plus one or two digits reads as a
  later version: `claude-opus-5` leaves `claude-opus-5-5` unpriced, so each
  production model needs its own row. Other suffixes (`.1`, `50`, `4o`, a date
  `-20260401`) still match the shorter cell.
- The table holds the **current** prices and prices all history, so cost
  deltas reflect token usage. The operator changes it in the direct session.
- **A stale row is silent.** Verify a row against current published prices
  when you add or change it; the audit's drift warning ([audit.md](audit.md) →
  task 27) checks it weekly.

## Retiring a fixture set (operator decision, direct session)

An invalid set (validation fails, or it no longer represents the repo) is
**retired and replaced**, never edited in place — the operator decides, the
agent reports and waits. A live run lock (`.run-lock`, `trials/*/.run-lock`)
must finish or expire first.

1. `mkdir -p fixture/retired && mv fixture/<slug> fixture/retired/<slug>` per
   retired slug. Retired fixtures stay on disk forever — past results
   reference them. Preflight counts only `fixture/*/` directories holding a
   `manifest.json`, so `create_fixture` becomes due.
2. Mark the affected history **non-comparable**: one line under the RESULTS.md
   header naming the timestamps and the reason, e.g.
   `_Runs <ts>… scored fixture set 1, retired <date> (ground truth leaked into the inputs) — not comparable with later runs._`
   Never delete a row, a `results/*.json` or a raw review.
3. Create the replacement set in a fresh session (**Creating the fixture
   set**), and take the first scored run in yet another session. The new
   series starts at that run.

## Trial runs (PR development — scored, never recorded)

A trial scores one commit of the definition remote (typically a feature
branch's head) with results only under its own folder — never the permanent
history or the `$HOME` checkout. Trials run in parallel with each other and a
scored run.

- **Trigger: operator only, in the direct session** — "run a trial benchmark
  of <branch>", one or more branches or PRs. That session **dispatches and
  never runs a trial itself**:
  1. Per branch: `<SHA>` = `git ls-remote <definition repo URL>
     refs/heads/<branch>` (not on the remote → the operator pushes it first),
     `<id>` = `pr-<n>` or the branch slug.
  2. One `mcp__platform-outbound__schedule_once` call per trial — `model`
     = this session's exact model id, or the model the operator names — with
     `name` `code-guardian-trial-<id>`, `sessionTitle`
     `Run trial benchmark of <branch>` and this task, values filled in:

     ```
     Run trial benchmark of <branch> — dispatched by the operator's direct session.
     trial: <id>, commit: <SHA>, branch: <branch>
     Follow docs/benchmark.md → **Trial runs** → In the trial session, then back up work/ (`scripts/work-backup.sh persist`).
     ```

  3. Report each trial's id, commit and session. A refused call or a missing
     tool → report it; that trial runs only when the operator opens a fresh
     direct session with the same task.
- **In the trial session**: the run steps above, with these substitutions:
  - `TRIAL="$HOME/work/benchmark/trials/<id>"`; the run lock is
    `$TRIAL/.run-lock` under the same rules — a live trial of the same `<id>`
    makes this one stand down (repeat with another `<id>`, such as
    `<branch>-r2`). Results to `$TRIAL/results/<ts>.json`, raw reviews and
    skill archives to `$TRIAL/results/raw/…` (`collect`'s raw dir).
  - `check --commit <SHA>` and `start --commit <SHA> --branch <branch>`
    (**Isolation**); `trigger: "trial"`. `$PSTATE/expect.json` carries the
    commit's `definition_version` and `definition_ref: {branch, sha}`, which
    identify feature-branch code (`VERSION` alone does not).
  - **Isolation unavailable** → stop as a scheduled run does. An approved
    in-pod trial runs only in a fresh direct session, with `<SHA>` checked
    out in `$HOME`, and takes the global `.run-lock` too: in-pod Phase 1
    reads the checkout and shares the `/tmp` trees.
  - **Skip entirely**: the skill install or refresh (`start` snapshots the
    installed skills), RESULTS.md rows, `report.html` regeneration,
    publishing, and `prev_version`/`changes_since_prev`.
  - Phase 2 runs the `$HOME` checkout's scorer, judge and report (a change to
    them is not measured by its own trial). The monthly gate reads only
    official `trigger: scheduled` results, never `trials/`.
- **Compare**: render the trial's own report —
  `bash "$HOME/scripts/benchmark-report.sh" "$TRIAL" > "$TRIAL/report.html"`
  (the script reads any directory holding `results/`) — and report the index
  delta against **(a)** the previous run of the same trial and **(b)** the
  latest official run, both from `benchmark-report.sh index`.
- **Cleanup**: a merged or abandoned PR's `trials/<id>/` is removed when the
  operator asks; the `work/` backup keeps its git history either way.

## On-demand (operator, direct session)

- "Create the benchmark fixtures" → the creation steps above (top-up to the
  full set).
- "Run the benchmark" → the run steps with `trigger: manual`. A manual run is
  never gated and never feeds the gate, so the scheduled run still lands on the
  1st. The reviews run on this session's model; to benchmark another model,
  pass it to `start` as `--model` (**Isolation**). An approved in-pod run
  measures the session it runs in, and on request splits one fixture per
  session (**Segmented run**).
- "Show benchmark results" → read `RESULTS.md` / `report.html` (and
  `results/*.json` for detail) and summarize the trend. Reading results is free
  of the session-separation rule when no `run` follows in the same session.
