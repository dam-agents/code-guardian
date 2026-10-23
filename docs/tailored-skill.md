# Tailored review skill

Read this file when onboarding offers the tailored skill (ONBOARDING Step 7),
when the operator asks for a review skill made for the reviewed repository or
asks to change one, or when the audit finds an `open` or `pending` tailored skill.

The definition holds no opinion about how a repository is built. The tailored
skill turns the rules the reviewed repository states about itself, and the
choices its operator makes in a short interview, into review checks. Every rule
in the skill cites its source: an in-tree path, or the operator's answer.

## When

- Onboarding offers it once, after the profile is built. The state is the
  `Tailored skill:` line in `work/MEMORY.md` → `## Review Style`: `open
  <YYYY-MM-DD>` (written when the offer starts), then
  `<skill> (<source>) pending <PR url>`, `<skill> (<source>) active`, or
  `declined <YYYY-MM-DD>`. No line → offer; `open` → offer again on the
  operator's next ask; any other line → no offer.
- The operator can ask for it, or for a change, in any direct session.
- Inputs: `work/PROFILE.md` (`bash "$HOME/scripts/profile.sh" generate` when
  absent), the `## Review skills` table, and a shallow clone of the default
  branch in a fresh `mktemp -d /tmp/cg-tailor.XXXXXX`, removed by that path at
  the end.
- A failed profile build → take the signals from the clone alone. A failed
  clone → tell the operator and stop; the `open` line keeps the offer.

## Asking

- Each round is one native platform chat form: follow the platform's
  `platform-chat-forms` skill — its capabilities gate, the operator's
  preferences (pacing, recommendation), the check before sending and its
  plain-text fallback. Without the skill, or in a conversation with no form
  capabilities, ask the same round in plain text: numbered questions,
  lettered options with the same line and example, the operator answers
  `1a,c 2b`.
- One `ChoicePicker` per question (`multipleSelection` for a multi-select),
  with a free-text `TextField` for "Other" where the round allows own rules.
  Directly under each picker, a caption `Text` with one bullet per option, in
  option order: what it checks, and an example finding **from this
  repository** — a real path of the clone, phrased as the review would print
  it.
- The recommended options follow the skill's recommendation rules; the
  caption under the picker says why.
- Ask only what the signals support. A round's `event` action returns every
  answer of the round in its `context`.

## Round 1 — areas

One multi-select question per group that has at least one offered area, all
in one form. An area is offered only when its signal is in the repository. An
area that a `## Review skills` row already covers (for example a `doc-drift`
row covers `docs`) shows `(covered by <skill>)` and is never recommended.
Recommend at most 4 areas over all groups: the ones with the strongest signal.

| Group | Area | Checks | Signal |
| --- | --- | --- | --- |
| Docs & comments | `docs` | Documents that describe the changed code still tell the truth | `## Docs` rows with mapped paths; a README that names commands or paths |
| | `comments` | Code comments next to the change still match it | Source files (always offered) |
| | `changelog` | Release notes follow the change | `CHANGELOG*`, `CHANGES*`, `HISTORY*`, `.changeset/`, `newsfragments/`, `release-notes/` |
| Interfaces & data | `contract` | No undeclared breaking change in a public surface | `openapi*`, `swagger*`, `*.proto`, `*.graphql`; a library manifest with exports; a CLI entry (`bin`, `console_scripts`, `cmd/`) |
| | `migrations` | Schema changes are complete and safe to roll out | `migrations/`, `db/migrate/`, `alembic/`, `prisma/migrations/`, Flyway or Liquibase files |
| | `config` | A new or changed key reaches every place that declares keys | `.env.example`, `.env.sample`, Helm `values*.yaml`, `docker-compose*`, a config schema |
| | `generated` | Generated files follow their source | `linguist-generated` in `## Noise`; a codegen config (`buf.gen.yaml`, `sqlc.yaml`, `codegen.yml`, OpenAPI generator) |
| Structure | `boundaries` | Imports respect the module and layer borders | ≥2 rows in `## Modules`; layer directories; a layering ADR |
| | `conventions` | Written house rules that no linter enforces | `## Conventions` not empty |
| | `dependencies` | New dependencies are needed and complete | Any manifest |
| Behavior | `tests` | The change has the kind of test the repository uses there | Test directories or files (`test*/`, `__tests__/`, `*_test.*`, `*.spec.*`, `*.test.*`) |
| | `observability` | New paths log and measure like their neighbors | A logging, metrics, tracing or error-reporting library in a manifest |
| | `invariants` | Domain rules the code cannot show | Always offered |

## Round 2 — details

One question per chosen area (two for `contract` and `tests`), at most 4
questions per form. Options derived from the tree list only what the clone has. Each
chosen option becomes one rule; the rule names the paths it applies to.

- **`docs`** (multi) — a document mapped to the changed code states the old
  behavior *(Recommended)* · a command, flag or path in the README or a guide
  no longer exists · a code example in the docs no longer matches the changed
  API · a new public feature has no page or section.
- **`comments`** (multi) — a comment next to changed code contradicts it
  *(Recommended)* · a new TODO or FIXME has no issue link · commented-out code
  is added · a new public symbol has no doc comment where its neighbors have one
  (in the repository's style: JSDoc, docstring, godoc, …).
- **`changelog`** (single) — an entry for every user-visible change: public
  API, CLI, configuration, UI, behavior *(Recommended)* · an entry for every PR
  that changes non-test code · an entry only when the version file changes.
  The entry follows the form of the existing entries.
- **`contract`** — (multi) which surfaces are public: up to 4 of the detected
  schema files, exported API, CLI commands and flags, configuration keys,
  event payloads · (single) a breaking change is acceptable when the PR
  declares it in the way the repository uses (major version, changelog entry,
  `BREAKING` note) *(Recommended)* · never.
- **`migrations`** (multi) — a model or schema change has its migration
  *(Recommended)* · a migration that the default branch has is not edited · a
  destructive step (drop, rename, type change) has a safe sequence or declared
  downtime · a new migration has a rollback where its neighbors have one.
- **`config`** (multi) — the detected places that declare keys (sample env
  file, deploy values, configuration docs, schema or validation code): a new or
  renamed key appears in each chosen place, and a removed key is gone from all
  of them.
- **`generated`** (single) — the generated output changes with its source, with
  the repository's generate command, and nobody edits it by hand
  *(Recommended)* · only: nobody edits a generated file by hand.
- **`boundaries`** (single) — learned from the default branch: an import
  between top-level modules that does not exist there yet *(Recommended)* ·
  rules the operator writes now (`ui/` never imports `db/`) · only the rules
  that ADRs or docs state.
- **`conventions`** (multi) — the detected instruction files (`CONTRIBUTING*`,
  `CLAUDE.md`, `AGENTS.md`, Copilot or Cursor rules, a style guide). Take only
  rules that the diff can show and that no linter or CI check of `## Checks`
  already enforces.
- **`dependencies`** (multi) — the PR body names and explains a new dependency
  *(Recommended)* · a new dependency does a job that an existing one already
  does · the lockfile changes with its manifest · licenses on a list the
  operator gives.
- **`tests`** — (single) the level: a change needs a test of the kind its
  module already has *(Recommended)* · a path-to-level map that you propose from
  the tree and the operator confirms (`src/api/**` → `tests/integration/`) ·
  any test that runs the changed code · (multi) the hygiene: a test waits on
  time or reads the real clock · a unit test calls a real network or service ·
  a focused or skipped test is committed without a reason · a test asserts
  nothing.
- **`observability`** (multi) — a new error path logs through the repository's
  logger *(Recommended)* · log levels follow the repository's use · a new
  endpoint, job or external call gets the metric or trace its neighbors have ·
  a new error carries the context its neighbors carry.
- **`invariants`** (single) — the invariants found in the code, up to 3, each
  with its evidence (`every query in src/repo/ filters by tenant_id`)
  *(Recommended when found)* · only rules the operator writes · both.

## Round 3 — shape and home

- **Shape** (single) — one combined skill *(Recommended)*: one run per reviewed
  PR, one review section · one skill per chosen group, at most 4: one run each
  per reviewed PR, each with its own section. The caption states the runs per
  PR of each option.
- **Home** (single) — the reviewed repository, through a pull request
  *(Recommended)*: the team keeps it beside the code · a skills repository the
  operator names, through a pull request · the files in chat, and the operator
  commits them. Offer the reviewed repository only when
  `scripts/github-access.sh` reports `features.tailored_skill` `ok`
  ([github-access.md](github-access.md) → **Feature map**); a refused push or
  PR falls back to the files in chat.
- Then show the draft in one form: the name (default `<repo-name>-checks`, per
  group `<repo-name>-<group>-checks`), the trigger and the section, each
  generated `SKILL.md` in a `CodeBlock`, a `TextField` for corrections, and the
  buttons to write it (primary) or to apply the corrections. Write the skill
  only on the operator's yes; apply a correction and show the draft again.

## The generated skill

One `SKILL.md` per skill, at most 80 lines, at most 5 rules per area, in
English. No rule restates a criterion of the general review
([review.md](review.md) → **Criteria & review style**): a rule names this
repository's paths, files or commands. Trigger: the extension list of the
code, test, docs and config files the rules read (profile classes,
[profile.md](profile.md) → **In the worklist**); `always` when the list is
empty. Section: `<Repo> Checks` (per group `<Repo> <Group> Checks`).

```markdown
---
name: <skill>
description: >
  Review checks for <owner>/<repo>: <areas>. Each check is a rule the
  repository states or its maintainers chose. Use when reviewing a pull
  request of <repo> — "<repo> checks", "repository rules" — or as a
  configured review skill of an automated review agent.
---
<!-- code-guardian-row: | <skill> | <source> | <trigger> | <section> | -->

# <Repo> checks

Checks a pull request against the rules below. Read the diff
(`git diff origin/<base>...HEAD`) and only the files a rule names. Report
only a rule that the diff breaks; the general review covers the rest.

## Rules

### <Area>
- <what must hold, for which paths> (source: `<path>` | operator <YYYY-MM-DD>)

## Report

One bullet per broken rule: what is wrong, where (`path:line`), the fix.
No broken rule → `✅ No findings.`

## Cost bounds

The diff and the files a rule names; no walk of the tree.
```

## Delivery

- **Pull request** — branch `code-guardian/tailored-skill` from the default
  branch, the files at `.agents/skills/<skill>/SKILL.md`, a body in ASD-STE100
  that says what the skill checks, its trigger, and that it adds one skill run
  per reviewed PR. Record the line `pending <PR url>`.
- **Files in chat** — print each `SKILL.md` in a fenced block with its path,
  ask in which repository the operator commits it (its `source`), and record
  `pending` without a URL.
- **Activation** — when the operator says the skill is on the default branch,
  validate it as ONBOARDING Step 4 item 7 validates a row, add the row from its
  `code-guardian-row` comment to `## Review skills`, and record `active`. A
  closed, unmerged PR → ask whether to record `declined`.
- **Change** — the same rounds with the current rules pre-selected, delivered
  as a pull request on the same path.
- A no at the offer records `declined <YYYY-MM-DD>`. Every recorded line ends
  with a backup of `work/` (`scripts/work-backup.sh persist`).
