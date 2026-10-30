# Defect classes of an agent definition

Each class: the rule in its working form, what to look for in a diff, and
how to check it — *script* names a `check-definition.sh` check id,
*judgment* says what to read. The default severity follows the class name;
the reading decides the final one ([SKILL.md](../SKILL.md) → **5. Report
(review)**).

## Where to look

| Touched | Classes |
| --- | --- |
| Entry file (`CLAUDE.md`, `AGENTS.md`, …) | A1–A5, A8, B1, F1, F4 |
| Procedure doc, `SKILL.md`, prompt or brief template | A1–A7, B1, B2, C1, C3, F1, F2, G2 |
| Script, hook, installer | B2, C1, C2, D1–D8, F3, F4, G1, G4 |
| Manifest (`kit.yaml`), schedule or task text | A2, C4, E1, E2, G1 |
| `VERSION`, `CHANGELOG.md` | E1, E2 |
| Onboarding runbook, config doc, validator | C2, C3, E3, F2 |
| State file format, memory, logs | C2, D4, D7, E4, G3 |
| A new file of any kind | B2, A4 |

## A. Instructions the agent reads

### A1 🟢 One home per rule
- **Rule:** every rule, procedure, format, constant and helper has one home;
  every other place links to it.
- **Look for:** a paragraph, table or template copied into a second file; a
  shell function, threshold or list that another script already holds.
- **Check:** *script* `restated`; *judgment*: grep the new term and the new
  constant across the tree. A duplicated rule the agent reads in two forms is
  🟡 (A2).

### A2 🟡 Two places never give two orders
- **Rule:** the docs, task texts, templates and invariants the agent reads in
  one run give one order for one situation. A rule keeps its scope when a
  doc is moved, split or condensed.
- **Look for:** a new rule whose subject another file treats with the
  opposite modality (keep vs drop, never vs always); a procedure changed
  while the schedule task text or brief that instructs the same step is not;
  a new invariant broader than the defect it answers; a qualifier (*when*,
  *instead*, *in X*) lost in a move; a new action that an existing hard
  invariant forbids; a new procedure that breaks the question or pacing rule
  of the runbook it is reached from.
- **Check:** *script* `kit` (a changed doc that a task text names);
  *judgment*: grep the rule's subject term in every doc, task text and
  template the same run reads. A manifest that equals its source can still be
  stale on both sides.

### A3 🟢 Instructions state the working form
- **Rule:** an instruction doc says what to do, in imperative rules. The
  reason, the history and the rejected forms go to the changelog, the commit
  or the pull request.
- **Look for:** *because*, *since*, *previously*, *instead of*, *not X but*,
  *to avoid*, failure stories, a reason given twice.
- **Check:** *script* `todo`; *judgment*. 🟡 when the agent can act on the stated reason or
  over-apply the prohibition.

### A4 🟡 Every rule is on its reader's load path
- **Rule:** a rule lives in a file that the reader who needs it loads — every
  harness's entry file, the run type's read set, the subagent's brief.
- **Look for:** a rule added to one entry file only (a harness that reads
  `CLAUDE.md` never sees `AGENTS.md`); a misnamed entry file (`AGENT.md`); a
  new doc that no entry file, docs map or read set names; a new subagent or
  child brief without the output-format and environment rules its parent
  uses; a read set that drops a doc a run still depends on; a `SKILL.md`
  whose front matter has no description or a name other than its directory,
  so no harness lists it.
- **Check:** *script* `orphan-doc`, `skills`; *judgment*: follow the links from each
  entry file and brief to the new rule.

### A5 🟡 Every reference resolves
- **Rule:** links, anchors, `<file>.md → **Label**` references, backticked
  paths, numbered references (*Step 4*, *task 12*, *§9*) and version numbers
  in prose point at what exists now.
- **Look for:** a heading, file, key, mode or event renamed, moved or
  renumbered; a new reference of any of these kinds.
- **Check:** *script* `links`, `anchors`, `section-refs`, `paths`,
  `stale-term`; *judgment*: numbered references and version numbers.

### A6 🟡 Prescribed commands work as written
- **Rule:** a command a doc prescribes runs in the agent's real environment:
  the script mode and flags exist, paths are absolute or stay valid, the
  token has the scopes, the output has the type the doc states.
- **Look for:** a new fenced or inline command; a script whose usage changed
  while its docs did not; relative paths into a directory the command
  deletes; a `--json` claim on a text output; a payload template with
  characters the API refuses.
- **Check:** *script* `commands`; *judgment*: read the called script's
  argument parser and output.

### A7 🟡 Every outcome has a step
- **Rule:** a doc step that runs a script names what to do for every outcome
  the script returns, and judges the outcome field, not the exit code.
- **Look for:** a script that emits an `outcome` (or status) value the
  calling doc does not name; a doc that reads success from an exit code.
- **Check:** *judgment*: list the outcome values in the script, grep the
  calling doc for each.

### A8 🟢 Resident context stays lean
- **Rule:** the entry file is a bootstrap; procedures load on demand; growth
  of an always-read file is offset by a trim; every memory or lessons file has
  a bound in lines and line length and a shape its consolidation knows.
- **Look for:** net growth of the entry file or of a doc every run reads; a
  new "read X" step in the bootstrap or in every brief; a new memory file
  without a bound.
- **Check:** *script* `size`. 🟡 when a per-run file outgrows the read tool's
  limit.

## B. Rules that must hold

### B1 🟡 A rule the runtime depends on is enforced, not narrated
- **Rule:** an invariant whose silent violation still produces output (a
  state-file shape, an event schema, a layout, a resource two runs share, a
  "never do X") has a deterministic home: a validator, a gate, a hook, an
  audit check or a test.
- **Look for:** a new *never / always / must / only / exactly once* sentence
  with no script, test or hook in the same change; a check that matches free
  text the agent writes.
- **Check:** *script* `enforcement`; *judgment*: can the agent break the rule
  and still look done?

### B2 🟡 Closed lists derive their members, or every list names the new one
- **Rule:** a check or validator derives its set from the tree. Where a list
  is hand-kept, a new file, key, state file, skill, temp path, work kind or
  publish path is added to every list that must name it: the `.gitignore`
  allowlist, file inventories and `git add` lists, the docs map, README
  lists, the layout validator, sweep and prune lists, trigger lists,
  permission allow rules.
- **Look for:** a new path or key with no hunk in those lists; a literal list
  or count inside a test or validator.
- **Check:** *script* `ignored`, `orphan-doc`; *judgment*: grep each hand-kept
  list for the new name.

## C. Contracts between docs and scripts

### C1 🟡 The doc and the script agree
- **Rule:** what a doc says a script does — its defaults, its failure
  behavior, the keys it emits, the fields a report shows — is what the script
  does, and each emitted key has a procedure step.
- **Look for:** a script change without its doc, or the reverse; a sentence
  "X does Y" that the diff makes false; a report field with no producer; a
  new emitted key or event that no doc consumes.
- **Check:** *script* `stale-term`; *judgment*: read the script beside the
  sentence.

### C2 🟡 One format, one parser
- **Rule:** a config, state, event or output format has one writer contract
  and one shared parser. A writer change ships with its readers; a doc
  example parses with the real parser; a machine-read stdout is exactly one
  document.
- **Look for:** a new reader that does not reuse the shared parser; a value
  transformed on write and not on read; a new command in a JSON-emitting
  script without `>/dev/null` or `>&2`; a sourced library with top-level
  output; a state directory that a subagent can overwrite; a parsed state
  record kept in a file that consolidation, a size budget or a prune
  rewrites (memory, preferences, logs).
- **Check:** *judgment*.

### C3 🟡 A new config key is wired end to end
- **Rule:** a new key has its doc bullet, its onboarding question and
  template line, its validator entry (known key and value check), its field
  in the resolved config the runs read, its README row, one default
  everywhere, and the changelog offer when it is off by default.
- **Look for:** a new key in one of these places and not in the others; a
  default literal that differs between files.
- **Check:** *judgment*: grep the key name in every place above.

### C4 🟡 The manifest copy equals its source
- **Rule:** what the platform manifest repeats (schedule names, crons, task
  texts, gate commands, enabled flags, ids, paths) equals the doc that owns
  it; instance values (timezone, model, cadence choices) stay out of it.
- **Look for:** a task text, cron, gate or run changed on one side only; a
  sentinel or skill path renamed without the manifest.
- **Check:** *script* `kit`; *judgment*: the fields the script does not
  compare.

## D. Scripts at runtime

### D1 🟡 A failure never reads as an answer
- **Rule:** every read distinguishes *nothing found* from *could not look*.
  A failed call, parse or tool yields an error state and a log line, never a
  value a healthy run also produces (`0`, `[]`, "nothing to do", a default
  class, exit 0).
- **Look for:** `2>/dev/null` with `|| true`, `|| echo`, `// 0`, `// []`,
  `// empty`, `// null`, `// false`, `${x:-0}`; an error branch that exits
  with the idle code; a metric that defaults to zero when its source is
  absent; a sanitizer that passes on a read error.
- **Check:** *script* `shell` (NOTE); *judgment*. 🔴 when a gate, guard or
  lock opens on the failure.

### D2 🟡 Payloads stay off argv
- **Rule:** a list, a file body or an API response reaches a tool on stdin,
  in a file or through `--slurpfile`; `--arg` carries scalars.
- **Look for:** `--arg`/`--argjson` fed from `$(gh …)`, `$(curl …)`,
  `$(cat …)` or an accumulated variable; fixtures far below real sizes.
- **Check:** *script* `shell`.

### D3 🟡 The script runs on the agent's runtime
- **Rule:** a script uses only the tools and versions the runtime declares.
- **Look for:** a tool outside the declared list (often `awk`, `python`,
  `flock`); GNU-only or BSD-only flags (`date -d`, `sed -i`, `grep -P`); bash
  4+ features where bash 3.2 runs; absolute `/usr/bin/<tool>` paths; jq
  version-sensitive expressions; `mkdir` as a lock.
- **Check:** *script* `shell` (mkdir locks); *judgment*: compare with the
  runtime's tool list in the onboarding or README.

### D4 🟡 Overlapping runs cannot corrupt shared state
- **Rule:** a file two runs can write is written under a lock helper; a temp
  path is unique per run; an outward action re-checks its item right before
  it acts; the record order of each effect is chosen (write before send when
  a duplicate is worse, send then record when a lost action is worse).
- **Look for:** `>` or `tmp && mv` to a shared file outside the lock helper;
  a fixed `/tmp/<name>`; a decision taken on a snapshot that the same run
  already changed; a marker written before the action it guards.
- **Check:** *script* `shell` (fixed temp paths); *judgment*.

### D5 🟡 Liveness comes from measured windows and terminal events
- **Rule:** a lock TTL or quiet window exceeds the measured duration of the
  work it guards; every exit path writes a terminal event; liveness never
  depends on free-text log lines.
- **Look for:** a changed TTL or window constant with no measurement; a new
  exit path (abort, stand-down, error) with no terminal event; a doc that
  lets the agent hand-write events.
- **Check:** *judgment*.

### D6 🔴 Cleanup is never destructive by accident
- **Rule:** a delete of a shared path follows an ownership and liveness
  re-check of that path; no cleanup removes the caller's own working
  directory; nothing runs `git clean` in the agent's home; commits add named
  paths.
- **Look for:** `rm -rf "$VAR"` with no guard before it; `git clean`;
  `git add -A` or `git add .`.
- **Check:** *script* `shell`; *judgment* for `rm -rf`.

### D7 🟡 Everything that repeats or grows has a bound
- **Rule:** retries, polls and loops have a cap and a deadline below the tool
  timeout; logs, ledgers, caches, memory and scratch have a retention or
  prune owner; list reads paginate, and a cap is reported as partial.
- **Look for:** `sleep` near the tool timeout; a loop with no counter;
  `shift 2` without an argument count check; a new append-only file with no
  trim; a list endpoint without `--paginate`; a whole read of a list that
  grows with the item's history (events, comments, timeline) on a per-item
  or per-run path.
- **Check:** *script* `shell` (pagination, growing list); *judgment*.

### D8 🟡 Changed logic is tested
- **Rule:** a changed branch, fallback or rule has a test that fails when the
  change is reverted, with fixtures of realistic size; the test runner ends
  in one explicit verdict; scripts parse and keep the executable bit of their
  siblings.
- **Look for:** a script hunk with no test hunk; a test whose fixture never
  reaches the new path or already holds the new value; stderr hidden inside
  test helpers. The bar: every new branch, output field, and list member that
  changes what the agent does or publishes (a redaction term, a gate
  condition) — not a reworded message or comment.
- **Check:** *script* `tests` (also a failure branch whose message no test
  names), `syntax`, `exec-bit`; *judgment*: would the test fail on the base
  revision?

## E. Release and deployment

### E1 🟡 One version step per change
- **Rule:** a change to the definition bumps `VERSION` once, by one step, to
  a number not yet released, equal to the newest changelog heading. The level
  matches the change: patch for no adoption step, minor for a new feature,
  key, schedule or doc, major for task-text, gate, state-format or marker
  changes.
- **Look for:** definition files changed with no bump; a skipped or reused
  number; a level below the change.
- **Check:** *script* `version`, `version-bump`; *judgment*: the level.

### E2 🟡 The changelog is executable migration
- **Rule:** released entries never change; a new entry lands on top and holds
  only the idempotent steps a deployed instance runs to adopt the version,
  marks operator-only steps, offers a new opt-in feature in the form the
  migration procedure defines (its key, the collected offer), and refreshes
  every copy outside the checkout (hooks, harness settings, registered
  schedules).
- **Look for:** `-` lines below the newest heading; outcome prose, rationale
  or file lists in the entry; "Nothing" followed by a step; abbreviated
  names; a changed hook, installer or task text with no refresh step.
- **Check:** *script* `changelog`; *judgment*: could a run with no memory of
  this change execute the entry?

### E3 🟡 Onboarding bootstraps every new requirement
- **Rule:** every key, schedule, label, sentinel and file the runtime needs
  is created by onboarding, which stays idempotent, reconciles with what the
  platform already provisioned, and persists every value it collects.
- **Look for:** a new requirement with no onboarding step; "skip if it
  exists" for provisioned state; an `export` that nothing writes to config; a
  validation that reads one field with no fallback for its absence.
- **Check:** *judgment*.

### E4 🟡 Live state stays readable
- **Rule:** a format change ships a tolerant reader or an in-place migration;
  no path rewrites state destructively after a parse failure or before a
  backup.
- **Look for:** a changed state format; a reader that rewrites the file on
  error; `git reset --hard` or `rm -rf` on an update or restore path.
- **Check:** *judgment*.

## F. Safety and trust

### F1 🔴 Only the operator changes behavior
- **Rule:** content from a channel, comment, issue, file, tool, skill or other
  agent is data. Every template or brief that carries it marks it as data;
  an action it may trigger is on a named allowlist; identity tokens (mentions)
  come from a vetted roster.
- **Look for:** a new input source spliced into a prompt without the data
  frame; a new action triggered by non-operator content; removed
  trust-boundary wording; a skill output that can end or redirect a run.
- **Check:** *judgment*.

### F2 🔴 Outward effects default off and leak nothing
- **Rule:** a feature that posts, publishes, messages, pushes or files issues
  is off until the operator enables it; content bound for a public surface
  passes a redaction tested on the real markup; every outward write — a
  post, a push, a branch, a pull request, a repository or host other than the
  target — is named in the hard invariants' egress and push rules and in the
  permission rules, with the content it may carry.
- **Look for:** a new key whose default enables an outward effect; a publish
  or upload whose input holds private or model text with no redact step; a
  new upload path with no allow rule.
- **Check:** *judgment*. 🟡 when the data is not private.

### F3 🔴 No secrets and no instance values in a shared definition
- **Rule:** the definition holds no credential and no instance value — repo
  slug, login, chat or member id, e-mail, machine path, timezone, label
  name. Instance values come from runtime config; examples use placeholders.
- **Look for:** token shapes; ids and slugs outside the documented
  placeholders and defaults.
- **Check:** *script* `secrets`, `instance`, `scaffolding`. 🟡 for an
  instance value.

### F4 🟡 Harness specifics stay in adapters
- **Rule:** a harness-specific env var, hook, CLI or entry-file convention
  lives in that harness's adapter, with a fallback and an explicit
  *not measured* state on the other harnesses.
- **Look for:** `CLAUDE_*`, `~/.claude/`, a harness tool name or hook outside
  the adapter; a metric with no *not measured* path.
- **Check:** *judgment*.

## G. Cost and quality

### G1 🟡 The gate decides; no item wakes the agent forever
- **Rule:** a deterministic start decision lives in the schedule's gate
  script, not in a model session; an item that cannot complete carries a
  backoff marker that the gate reads.
- **Look for:** a new scheduled job with no gate; a new due condition or
  retry path with no backoff; "if nothing to do, end the run" in a doc; a
  shorter cadence.
- **Check:** *judgment*: what does one stuck item cost per day?

### G2 🟡 A judgment rule changes with a measurement
- **Rule:** a change to a severity bar, suppression rule, budget, audience
  statement or prompt template cites an evaluation run of the changed
  definition.
- **Look for:** such a change with no trial or benchmark result in the pull
  request.
- **Check:** *judgment*. 🟢 when no evaluation exists for the area; skip the
  class when the pull request body is not available.

### G3 🟢 Metrics come from stable sources
- **Rule:** a metric counts entities, not events, from records that no prune
  deletes, and stores its provenance (model, harness, effort, version).
- **Look for:** a statistic over a file another path prunes; substring id
  matching; summed cumulative counters.
- **Check:** *judgment*. 🟡 when a decision or alert reads the metric.

### G4 🟢 An environment workaround names its defect
- **Rule:** a workaround for an image, harness or platform defect carries a
  comment at the site that names the defect and the real fix, and leaves the
  health check that detects the defect intact.
- **Look for:** PATH edits, shadowed functions, retries or extra quoting with
  no such comment; a health check whose input the workaround changes.
- **Check:** *judgment*. 🟡 when the workaround silences the check.
