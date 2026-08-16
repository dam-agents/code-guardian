#!/usr/bin/env bash
# benchmark end-to-end rehearsal — builds a real (tiny) fixture the way
# docs/benchmark.md prescribes, drives the whole chain over it (validate →
# build working repo → score a canned review → measure a phase → validate the
# assembled results → render the report and the index), and proves the gates
# reject the failure modes the first live run hit: ground truth leaked into the
# Phase-1 inputs, tree-prefixed diff paths, and an array-shaped `fixtures`.
# Offline and deterministic: no gh, no network, no agent.
. "$(dirname "$0")/helpers.sh"

VALIDATE="$REPO_ROOT/scripts/benchmark-validate.sh"
SCORE="$REPO_ROOT/scripts/benchmark-score.sh"
REPORT="$REPO_ROOT/scripts/benchmark-report.sh"
PHASE="$REPO_ROOT/scripts/benchmark-phase.sh"
G="git -c user.email=bench@local -c user.name=bench"

# A clean fixture: the defects are real (missing bounds check, string-built
# SQL, unawaited promise) and NOTHING in the code names them.
build_clean_fixture() { # <fixture-root> <slug>
  local F="$1/$2"
  mkdir -p "$F/base/src" "$F/head-v1/src" "$F/head-v2/src"

  cat > "$F/base/src/cart.ts" <<'EOF'
export interface Item { id: string; qty: number; price: number }

export function total(items: Item[]): number {
  let sum = 0;
  for (const it of items) {
    sum += it.qty * it.price;
  }
  return sum;
}

export function firstItem(items: Item[]): Item {
  return items[0];
}
EOF
  cat > "$F/base/src/store.ts" <<'EOF'
import type { Item } from "./cart";

export class Store {
  private rows: Item[] = [];

  async load(ids: string[]): Promise<Item[]> {
    return this.rows.filter((r) => ids.includes(r.id));
  }
}
EOF

  # head-v1: three planted defects, no marker of any kind
  cat > "$F/head-v1/src/cart.ts" <<'EOF'
export interface Item { id: string; qty: number; price: number }

export function total(items: Item[]): number {
  let sum = 0;
  for (const it of items) {
    sum += it.qty * it.price;
  }
  return sum;
}

export function applyDiscount(items: Item[], pct: number): number {
  return total(items) * (1 - pct);
}

export function firstItem(items: Item[]): Item {
  return items[0];
}
EOF
  # anchors: interpolated SQL on 7, unawaited persist on 21 — 14 apart, so the
  # scorer's ±3 windows cannot overlap (validated by manifest_spacing)
  cat > "$F/head-v1/src/store.ts" <<'EOF'
import type { Item } from "./cart";

export class Store {
  private rows: Item[] = [];

  async load(ids: string[]): Promise<Item[]> {
    const q = `SELECT * FROM items WHERE id IN ('${ids.join("','")}')`;
    return this.query(q);
  }

  async count(): Promise<number> {
    const all = await this.query("SELECT * FROM items");
    return all.length;
  }

  async clear(): Promise<void> {
    this.rows = [];
  }

  async save(item: Item): Promise<void> {
    this.persist(item);
  }

  private async query(_q: string): Promise<Item[]> { return this.rows; }
  private async persist(item: Item): Promise<void> { this.rows.push(item); }
}
EOF

  # head-v2: SQL fixed (parameterized), await still missing, one new defect
  cat > "$F/head-v2/src/cart.ts" <<'EOF'
export interface Item { id: string; qty: number; price: number }

export function total(items: Item[]): number {
  let sum = 0;
  for (const it of items) {
    sum += it.qty * it.price;
  }
  return sum;
}

export function applyDiscount(items: Item[], pct: number): number {
  return total(items) * (1 - pct);
}

export function firstItem(items: Item[]): Item {
  return items[0];
}

export function itemCount(items: Item[]): number {
  return items.length;
}

export function formatTotal(items: Item[]): string {
  return total(items).toFixed(2);
}

export function parseQty(raw: string): number {
  return parseInt(raw);
}
EOF
  # v2: the SQL fix lands on 7 (fix_line_v2), the persist defect stays on 21
  cat > "$F/head-v2/src/store.ts" <<'EOF'
import type { Item } from "./cart";

export class Store {
  private rows: Item[] = [];

  async load(ids: string[]): Promise<Item[]> {
    const marks = ids.map(() => "?").join(",");
    return this.query(`SELECT * FROM items WHERE id IN (${marks})`, ids);
  }

  async count(): Promise<number> {
    const all = await this.query("SELECT * FROM items");
    return all.length;
  }

  async clear(): Promise<void> {
    this.rows = [];
  }

  async save(item: Item): Promise<void> {
    this.persist(item);
  }

  private async query(_q: string, _p: string[] = []): Promise<Item[]> { return this.rows; }
  private async persist(item: Item): Promise<void> { this.rows.push(item); }
}
EOF

  # ground truth — the ONLY place the defects are named
  cat > "$F/manifest.json" <<'EOF'
{"fixture": "ts-cart", "created": "2026-08-14T00:00:00Z",
 "defects": [
  {"id": "D01", "file": "src/store.ts", "line_v1": 7, "line_v2": null, "fix_line_v2": 7,
   "class": "security", "severity": "critical", "summary": "SQL built by interpolation",
   "fixed_in_v2": true, "in_prior_review": true},
  {"id": "D02", "file": "src/store.ts", "line_v1": 21, "line_v2": 21,
   "class": "correctness", "severity": "warning", "summary": "promise not awaited",
   "fixed_in_v2": false, "in_prior_review": true},
  {"id": "D03", "file": "src/cart.ts", "line_v1": 12, "line_v2": 12,
   "class": "correctness", "severity": "warning", "summary": "discount not clamped",
   "fixed_in_v2": false, "in_prior_review": false},
  {"id": "D04", "file": "src/cart.ts", "line_v1": null, "line_v2": 28,
   "class": "correctness", "severity": "warning", "summary": "parseInt without radix",
   "fixed_in_v2": false, "in_prior_review": false}
 ]}
EOF

  # prior review: covers D01+D02 only, and never names an id
  cat > "$F/prior-review.md" <<'EOF'
🛡️ **Code Guardian** — ❌ Code Review @ `aaaaaaa`

### Summary
Adds a discount helper and a bulk load path.

### Findings
- 🔴 **Critical:** query text is built by string interpolation (`src/store.ts:7`)
  **Fix:** pass the ids as bound parameters.
- 🟡 **Warning:** the persist promise is not awaited (`src/store.ts:21`)
  **Fix:** await the call so failures propagate.

### Verdict
REQUEST_CHANGES — one critical finding is open.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/store.ts","line":7,"inline":true,"summary":"SQL by interpolation","fix":"bind the ids as parameters"},{"status":"new","severity":"warning","file":"src/store.ts","line":21,"inline":true,"summary":"promise not awaited","fix":"await the persist call"}] -->
<!-- cg:review headRefOid=1111111111111111111111111111111111111111 -->
EOF
  printf '{"number":0,"title":"Add discount helper and bulk load","body":"Cart totals and a batched item load.","author":"alice","head_ref":"feat/cart","base_ref":"main","head_sha_v1":"1111111111111111111111111111111111111111","head_sha_v2":"2222222222222222222222222222222222222222"}\n' > "$F/pr.json"
}

# the run's own step 1: scratch git repo, base on main, v1 then v2 on pr
build_working_repo() { # <fixture-dir> <pr-dir>
  local B="$1" PR_DIR="$2"
  rm -rf "$PR_DIR"
  git init -q "$PR_DIR"
  cp -a "$B/base/." "$PR_DIR/"
  $G -C "$PR_DIR" add -A >/dev/null && $G -C "$PR_DIR" commit -qm base
  $G -C "$PR_DIR" branch -m main && $G -C "$PR_DIR" checkout -qb pr
  find "$PR_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cp -a "$B/head-v1/." "$PR_DIR/"
  $G -C "$PR_DIR" add -A >/dev/null && $G -C "$PR_DIR" commit -qm v1
  find "$PR_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cp -a "$B/head-v2/." "$PR_DIR/"
  $G -C "$PR_DIR" add -A >/dev/null && $G -C "$PR_DIR" commit -qm v2
}

# ---------------------------------------------------------------------------
new_case e2e_clean_fixture_validates
FIX="$SANDBOX/benchmark/fixture"
build_clean_fixture "$FIX" ts-cart
PR_DIR="$SANDBOX/pr-ts-cart"
build_working_repo "$FIX/ts-cart" "$PR_DIR"
# diffs the documented way — repo-relative, from the scratch repo
git -C "$PR_DIR" diff main..pr~1 > "$FIX/ts-cart/diff-v1.patch"
git -C "$PR_DIR" diff pr~1..pr   > "$FIX/ts-cart/diff-v1-v2.patch"
OUT="$(bash "$VALIDATE" fixture "$FIX/ts-cart"; printf 'rc=%s' "$?")"
assert_out_contains 'PASS — fixture validation clean' 'a clean fixture passes validation'
assert_out_contains 'rc=0' 'validation exits 0'
assert_out_absent '^FAIL' 'no check fails on the clean set'
assert_out_contains 'leak_ids.*no defect ids outside the manifest' 'leak scan covers the ids'
assert_out_contains 'diff_paths.*repo-relative' 'diff paths accepted'
# the routing list the run derives for extension skills
OUT="$(git -C "$PR_DIR" diff --name-only main..pr)"
assert_out_contains 'src/cart.ts' 'changed-file list routes the .ts files'

new_case e2e_leaky_fixture_is_rejected
FIX="$SANDBOX/benchmark/fixture"
build_clean_fixture "$FIX" leaky
PR_DIR="$SANDBOX/pr-leaky"
build_working_repo "$FIX/leaky" "$PR_DIR"
git -C "$PR_DIR" diff main..pr~1 > "$FIX/leaky/diff-v1.patch"
git -C "$PR_DIR" diff pr~1..pr   > "$FIX/leaky/diff-v1-v2.patch"
# reintroduce exactly what the first live run shipped: an id + description
# comment, and a v2 note announcing the delta
printf '// D01: SQL injection via string interpolation\n' >> "$FIX/leaky/head-v1/src/store.ts"
printf '// D01 FIXED: bound parameters now\n' >> "$FIX/leaky/head-v2/src/store.ts"
OUT="$(bash "$VALIDATE" fixture "$FIX/leaky"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL leak_ids' 'a labelled defect fails validation'
assert_out_contains 'FAIL leak_fixmarks' 'a v2 delta giveaway fails validation'
assert_out_contains 'rc=1' 'validation exits non-zero so the run aborts'
assert_out_contains 'ids belong in manifest.json only' 'the failure carries its fix'

new_case e2e_retired_container_and_anchor_spacing
FIX="$SANDBOX/benchmark/fixture"
build_clean_fixture "$FIX" ts-cart
PR_DIR="$SANDBOX/pr"
build_working_repo "$FIX/ts-cart" "$PR_DIR"
git -C "$PR_DIR" diff main..pr~1 > "$FIX/ts-cart/diff-v1.patch"
git -C "$PR_DIR" diff pr~1..pr   > "$FIX/ts-cart/diff-v1-v2.patch"
# a retired set sits beside the active one; the documented fixture/*/ glob
# matches its container, which must not read as a broken fixture
mkdir -p "$FIX/retired/old-ts-api"
OUT="$(bash "$VALIDATE" fixture "$FIX"/*/; printf 'rc=%s' "$?")"
assert_out_contains 'skip retired/' 'the retired container is skipped, not failed'
assert_out_absent 'structure\[retired\]' 'no spurious structure failure for retired/'
assert_out_contains 'rc=0' 'a set with retired fixtures beside it still passes'
assert_out_contains 'manifest_spacing\[ts-cart\].*≥10 lines apart' 'anchor spacing is checked'
# anchors closer than the ±3 matching window would overlap
jq '.defects[1].line_v1 = 9 | .defects[1].line_v2 = 9' "$FIX/ts-cart/manifest.json" \
  > "$FIX/ts-cart/manifest.tmp" && mv "$FIX/ts-cart/manifest.tmp" "$FIX/ts-cart/manifest.json"
OUT="$(bash "$VALIDATE" fixture "$FIX/ts-cart"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL manifest_spacing' 'colliding anchors fail validation'
assert_out_contains 'rc=1' 'the run would abort before scoring an ambiguous fixture'

new_case e2e_prefixed_diffs_are_rejected
FIX="$SANDBOX/benchmark/fixture"
build_clean_fixture "$FIX" prefixed
# the wrong way — git diff --no-index prefixes every path with the tree name
( cd "$FIX/prefixed" && git diff --no-index base head-v1 > diff-v1.patch 2>/dev/null || true
  git diff --no-index head-v1 head-v2 > diff-v1-v2.patch 2>/dev/null || true )
OUT="$(bash "$VALIDATE" fixture "$FIX/prefixed"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL diff_paths' 'tree-prefixed diff paths fail validation'
assert_out_contains 'rc=1' 'the unmatched-findings trap is caught before scoring'

new_case e2e_scores_a_review_against_the_clean_fixture
build_clean_fixture "$SANDBOX/benchmark/fixture" ts-cart   # fresh sandbox per case
FIX="$SANDBOX/benchmark/fixture/ts-cart"
# a plausible first review: finds D01 and D03, misses D02, invents one FP
cat > "$SANDBOX/first.md" <<'EOF'
## PR #0: Add discount helper and bulk load
### Summary
Adds a discount helper and a batched load path.

### Findings
- 🔴 **Critical:** the query text is built by interpolating ids (`src/store.ts:7`)
  **Fix:** bind the ids as parameters instead of splicing them in.
- 🟡 **Warning:** the discount factor is not clamped to 0..1 (`src/cart.ts:12`)
  **Fix:** clamp pct before applying it.
- 🟡 **Warning:** filter allocates a new array per call (`src/store.ts:33`)
  **Fix:** reuse a map keyed by id.

### Verdict
REQUEST_CHANGES — one critical finding is open.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/store.ts","line":7,"inline":true,"summary":"SQL by interpolation","fix":"bind the ids as parameters"},{"status":"new","severity":"warning","file":"src/cart.ts","line":12,"inline":true,"summary":"discount not clamped","fix":"clamp pct to 0..1"},{"status":"new","severity":"warning","file":"src/store.ts","line":33,"inline":false,"summary":"allocation per call","fix":"reuse a map"}] -->
<!-- cg:review headRefOid=1111111111111111111111111111111111111111 -->
EOF
OUT="$(bash "$SCORE" first "$SANDBOX/first.md" "$FIX/manifest.json")"
assert_jq '.gt == 3' 'three v1 defects are the ground truth'
assert_jq '.tp | length == 2' 'the two real findings match'
assert_jq '.fn == ["D02"]' 'the missed defect is named'
assert_jq '.fp | length == 1' 'the invented finding is a false positive'
assert_jq '.recall_critical == 1 and .severity_accuracy == 1' 'critical found, severities agree'
assert_jq '.format.verdict_consistent == true and .format.fix_lines == true' 'format checks pass on a well-formed review'

# a delta re-review: D01 fixed, D02 still, D04 new, plus one churn finding
# sitting on the line where the D01 fix landed
cat > "$SANDBOX/rr.md" <<'EOF'
### Summary
Delta re-review of two new commits.
### Changes since last review
Previous HEAD: 1111111 (2026-08-01T00:00:00Z) — verdict REQUEST_CHANGES
- ✅ **Fixed:** query now binds its parameters (`src/store.ts:7`)
- 🔁 **Still present:** persist promise not awaited (`src/store.ts:21`)
- 🆕 **New:** parseInt without radix (`src/cart.ts:28`)
- 🆕 **New:** placeholder string is rebuilt per call (`src/store.ts:7`)
### Findings
- 🟡 **Warning:** parseInt without an explicit radix (`src/cart.ts:28`)
  **Fix:** pass 10 as the radix.
- 🟡 **Warning:** the placeholder list is rebuilt on every load (`src/store.ts:7`)
  **Fix:** cache the joined marks.
### Verdict
COMMENT — warnings only.

<!-- findings-json: [{"status":"fixed","severity":"critical","file":"src/store.ts","line":7,"inline":false,"summary":"SQL by interpolation","fix":null},{"status":"still","severity":"warning","file":"src/store.ts","line":21,"inline":false,"summary":"promise not awaited","fix":"await the persist call"},{"status":"new","severity":"warning","file":"src/cart.ts","line":28,"inline":true,"summary":"parseInt without radix","fix":"pass radix 10"},{"status":"new","severity":"warning","file":"src/store.ts","line":7,"inline":true,"summary":"marks rebuilt per call","fix":"cache the joined marks"}] -->
<!-- cg:review headRefOid=2222222222222222222222222222222222222222 -->
EOF
OUT="$(bash "$SCORE" rereview "$SANDBOX/rr.md" "$FIX/manifest.json")"
assert_jq '.fixed_recall == 1 and .still_recall == 1 and .new_recall == 1' 'all three delta buckets matched'
assert_jq '.false_fixed == 0' 'no kept defect claimed fixed'
assert_jq '.churn == 1' 'the finding on the fix site is counted as churn'
assert_jq '.format.delta_section == true' 'the delta section is present'

new_case e2e_phase_state_is_per_nonce
# two runs measuring the same slug never collide: the state dir is keyed by
# the nonce, so the sibling's begin cannot overwrite this run's stamp
HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" begin "$SANDBOX/benchmark-phase-A" slug-first NONCE-A >/dev/null
HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" begin "$SANDBOX/benchmark-phase-B" slug-first NONCE-B >/dev/null
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" end "$SANDBOX/benchmark-phase-A" slug-first NONCE-A)"
assert_jq '.seconds | type == "number"' 'run A ends its phase despite run B measuring the same slug'
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" end "$SANDBOX/benchmark-phase-B" slug-first NONCE-B)"
assert_jq '.seconds | type == "number"' 'run B still holds its own stamp'

new_case e2e_phases_never_overlap
# within one run, a second begin while any phase is open is refused: the
# token delta spans the whole session, so overlapping phases would each
# absorb the other's usage
HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" begin "$SANDBOX/benchmark-phase-OV" slug-first NONCE-OV >/dev/null
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" begin "$SANDBOX/benchmark-phase-OV" slug-rereview NONCE-OV 2>&1; echo "rc=$?")"
assert_out_contains 'rc=2' 'a second begin while a phase is open is refused'
assert_out_contains 'phases never overlap' 'the refusal names the rule'
assert_out_contains 'slug-first' 'the refusal names the open phase'
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" end "$SANDBOX/benchmark-phase-OV" slug-first NONCE-OV)"
assert_jq '.seconds | type == "number"' 'the open phase still ends normally'
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" begin "$SANDBOX/benchmark-phase-OV" slug-rereview NONCE-OV)"
assert_out_contains 'phase slug-rereview started' 'the next phase begins once the first ended'
HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" end "$SANDBOX/benchmark-phase-OV" slug-rereview NONCE-OV >/dev/null

new_case e2e_phase_measurement_and_results_validation
mkdir -p "$SANDBOX/bench/results"
# a measured phase (no transcript here, so tokens is honestly null)
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" begin "$SANDBOX/pstate" ts-cart-first NONCE-E2E)"
assert_out_contains 'phase ts-cart-first started' 'phase begin stamps the start'
PHASE_JSON="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PHASE" end "$SANDBOX/pstate" ts-cart-first NONCE-E2E)"
OUT="$PHASE_JSON"
assert_jq '.seconds | type == "number"' 'phase end yields a measured duration'
assert_jq '.tokens == null' 'tokens is null when no snapshot exists, never estimated'

# assemble the results file in the documented shape and validate it
jq -n --argjson ph "$PHASE_JSON" '{
  ts: "2026-09-01T06:00:00Z", trigger: "scheduled", model: "test-model",
  definition_version: "3.12.0", judge: "off",
  fixtures: {"ts-cart": {
    first:    {f1: 0.8, precision: 0.667, recall: 0.667, recall_critical: 1,
               severity_accuracy: 1, fp: [{}], length: {words_total: 120},
               seconds: $ph.seconds, tokens: $ph.tokens, judge: null},
    rereview: {fixed_recall: 1, still_recall: 1, new_recall: 1, churn: 1,
               false_fixed: 0, late_finds: 0,
               seconds: $ph.seconds, tokens: $ph.tokens, judge: null}}}}' \
  > "$SANDBOX/bench/results/20260901T060000Z.json"
OUT="$(bash "$VALIDATE" results "$SANDBOX/bench/results/20260901T060000Z.json"; printf 'rc=%s' "$?")"
assert_out_contains 'PASS — results validation clean' 'the documented shape validates'
assert_out_contains 'rc=0' 'validation exits 0'

new_case e2e_bad_results_shapes_are_rejected
mkdir -p "$SANDBOX/bad"
# the exact drift the first live run shipped: fixtures as an array, trigger
# outside the enum, judge under the wrong key
jq -n '{ts: "2026-08-14T13:42:35Z", trigger: "operator", model: "m",
        definition_version: "3.11.0", benchmark_judge: "off",
        fixtures: [{fixture: "ts-api", first: {seconds: 180, tokens: null},
                    rereview: {seconds: 190, tokens: null}}]}' > "$SANDBOX/bad/r.json"
OUT="$(bash "$VALIDATE" results "$SANDBOX/bad/r.json"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL fixtures_shape' 'an array-shaped fixtures map is rejected'
assert_out_contains 'FAIL trigger' 'a trigger outside the enum is rejected'
assert_out_contains 'FAIL judge_key' 'the drifted judge key is rejected'
assert_out_contains 'rc=1' 'the run would stop before writing history'
# estimated/absent timings are caught too
jq -n '{ts: "2026-09-01T06:00:00Z", trigger: "manual", model: "m",
        definition_version: "3.12.0",
        fixtures: {"ts-cart": {first: {tokens: null}, rereview: {seconds: "about 190", tokens: {input: 1}}}}}' \
  > "$SANDBOX/bad/r2.json"
OUT="$(bash "$VALIDATE" results "$SANDBOX/bad/r2.json"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL per_fixture' 'missing/non-numeric seconds and malformed tokens are caught'

new_case e2e_report_renders_and_normalizes_legacy_shape
mkdir -p "$SANDBOX/rep/results"
cp "$SANDBOX/bench/results/20260901T060000Z.json" "$SANDBOX/rep/results/" 2>/dev/null \
  || jq -n '{ts:"2026-09-01T06:00:00Z",trigger:"scheduled",model:"test-model",definition_version:"3.12.0",
             fixtures:{"ts-cart":{first:{f1:0.8,recall_critical:1,precision:0.667,recall:0.667,severity_accuracy:1,fp:[{}],length:{words_total:120},seconds:5,tokens:null},
                                  rereview:{fixed_recall:1,still_recall:1,new_recall:1,churn:1,false_fixed:0,late_finds:0,seconds:4,tokens:null}}}}' \
       > "$SANDBOX/rep/results/20260901T060000Z.json"
# a legacy array-shaped run already in the append-only history
jq -n '{ts: "2026-08-14T13:42:35Z", trigger: "manual", model: "old-model",
        definition_version: "3.11.0",
        fixtures: [{fixture: "ts-api", first: {f1: 0.4, seconds: 180, tokens: null},
                    rereview: {fixed_recall: 0, seconds: 190, tokens: null}}]}' \
  > "$SANDBOX/rep/results/20260814T134235Z.json"
OUT="$(bash "$REPORT" "$SANDBOX/rep")"
assert_out_contains '2 run(s) on record' 'both runs render'
assert_out_contains '<h2>ts-api</h2>' 'a legacy array run is keyed back to its slug'
assert_out_absent '<h2>0</h2>' 'no run renders its fixtures as 0,1,2…'
assert_out_contains '<h2>ts-cart</h2>' 'the current-shape run renders too'
OUT="$(bash "$REPORT" index "$SANDBOX/rep")"
assert_jq 'length == 2' 'index mode covers both runs'
assert_jq '.[1].fixtures["ts-cart"] != null' 'index mode keys fixtures by slug'
assert_jq '.[0].fixtures["ts-api"] != null' 'index mode survives the legacy shape'

finish
