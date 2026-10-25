---
name: agent-engineering
description: >
  Engineering rules for the definition of an autonomous LLM agent — the
  Markdown it executes (CLAUDE.md, AGENTS.md, docs/, ONBOARDING.md, SKILL.md),
  the scripts it runs, its platform manifest (kit.yaml), VERSION and
  CHANGELOG — and the review that holds a change to them. Repo-agnostic: a
  deterministic script checks the mechanical rules even where the repository
  has no CI or self-modification rules for them, and a catalogue of defect
  classes from real agent incidents drives the judgment. Use it whenever
  reviewing, writing or changing an agent definition or a skill — "review
  this agent PR", "check the agent docs", "is this CLAUDE.md change safe",
  "agent engineering" — or as a configured review skill of an automated
  review agent for a repository of agent instructions.
---

# Agent Engineering

An agent definition is a program written in prose. An unattended model
executes every line of its Markdown, so a defect in a doc is a defect in
behavior. Hold the definition to the rules of a program: one home per rule,
invariants that a script enforces, docs and scripts that agree, tested
scripts, releases that deployed instances can adopt, and safe defaults.

Paths below are relative to this skill's directory.

## 1. Pick the mode

| Mode | Signal |
| --- | --- |
| **review** | A pull request, branch or diff of an agent definition; a configured review skill; "review", "check", "audit" |
| **write** | Creating or changing definition files or a skill: apply the same rules before the change is done |

## 2. Find the definition

- **Entry files**: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, the Copilot
  instructions file. Procedures: the files they link. Skills:
  every `SKILL.md`. Manifest: `kit.yaml` or the platform's equivalent.
- **The repository's own rules for changes** (for example
  `docs/self-modification.md`, `CONTRIBUTING.md`): read the parts that the
  touched files reach. They add checks, and they decide the conventions this
  skill leaves open — a repository with no `VERSION` file needs no bump.
- No entry file and no agent Markdown in scope → report
  `✅ No findings.` and stop.

## 3. Run the script

```bash
bash scripts/check-definition.sh --base <base-ref> <checkout>   # a change, normally origin/<base-branch>
bash scripts/check-definition.sh <checkout>                     # the whole tree
```

It needs `bash`, `git`, `jq`, `grep`, `sed`, `xargs`, `find`, `cmp`,
coreutils and, with `--base`, `tar` (a missing one exits 2), takes under a
minute, and prints `<FAIL|WARN|NOTE>  <check-id>  <path[:line]>  <message>`
lines and one summary line. `--list-checks` prints what each check holds.
With `--base` it reports only what the change adds: the diff starts at the
merge base, and the version checks compare with the base tip, so a number
that another change released meanwhile fails.

- **FAIL** — a defect. Read the line and report it.
- **WARN** — a probable defect. Read the line; report it when the reading
  confirms it.
- **NOTE** — a lead for a judgment class of
  [references/checks.md](references/checks.md). Check the class; most NOTEs
  end as no finding.

Every finding comes from the file you read, never from a script line alone.
The script does not depend on the repository's CI: it runs the same checks
whether the repository has them or not. A script that cannot run → one line
`check-definition not run: <reason>`, then do the checks marked *script* in
the catalogue by reading.

## 4. Judge against the catalogue

Read [references/checks.md](references/checks.md) once. Its **Where to look**
table maps each touched file kind to the classes it can carry; check those
classes against the diff and the files a class names. Untouched, pre-existing
defects are out of scope in a review of a change.

## 5. Report (review)

One finding per root cause, every location of that cause in it; a class with
several unrelated causes gives several findings:

- 🔴 **Critical:** a secret in the tree or in an output; a weakened trust
  boundary; a destructive operation on the agent's home or on shared state;
  a gate, lock or guard that fails open on a reachable path; an outward
  action that is on by default and publishes private data.
- 🟡 **Warning:** the agent does the wrong thing on a reachable path — a
  reference it follows is dead, two instructions contradict, a doc and its
  script disagree, the manifest drifts from its source, a release has no
  migration step, a new file is not registered, changed script logic has no
  test, a failure reads as an answer, a payload passes through argv, a tool
  is absent from the runtime.
- 🟢 **Suggestion:** context growth, a restated rule, rationale in an
  instruction doc, style.

Each finding: what is wrong, the input or state that triggers it and what
the running agent then does, `path:line`, and a **Fix:** line stated as a
rule for the whole class. Findings in severity order; a dismissed script
line is not reported. No finding → `✅ No findings.`

## 6. Finish (write)

Before the change is done: run the script without `--base` on the tree and
with `--base` on the branch, and walk the catalogue for every class the
change touches. Fix each FAIL and WARN, or state in the pull request body why
it does not apply.

## Cost bounds

The script once; the diff; the catalogue once; the files a finding names;
`git grep` of the terms, keys and steps the change touches. No other walk of
the tree.
