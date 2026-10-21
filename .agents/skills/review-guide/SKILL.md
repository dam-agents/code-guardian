---
name: review-guide
description: >-
  Build a short, visual, one-page HTML guide for the person who must review a
  pull request: why a person is needed, one before/after picture of what
  changed, the decisions only a person can judge, and where to read first —
  zooming from purpose to code one level at a time. It decides first whether a
  person must judge anything, and writes no page when nothing needs one. Use it
  when an automated review or an author wants a human reviewer's guide, a
  visual PR explainer, a "zooming review", a PR walkthrough page or a design
  doc for reviewers — "make a review guide for PR 42", "explain this PR
  visually", "what must a human check here".
argument-hint: "[PR number] [output .html path]"
metadata:
  code-guardian-output: guide
---

# Review guide — one page for the human reviewer

The reviewer's attention is the scarce resource, not your effort. Give them
**one self-contained HTML page** that answers in 15 seconds: what this PR does
for a user, **why a person must look**, and **where to look first**. Below
that, the page zooms in one level at a time — how it works now, the decisions
to judge, the reading order, the coupling — and the reader opens a level only
when they want it. The code itself stays on GitHub; the page links to it.

The page is a guide, not a review: it does not hunt for bugs and does not
repeat review findings. It shows the shape of the change and the questions a
person must settle.

## Under code-guardian

When a brief file started you, the brief owns the inputs, the output paths,
the reply and the time budget; this file owns the method and the page. Without
a brief: read the PR with `gh pr view <n> --json title,body,author,headRefOid,baseRefName,files,additions,deletions`
and `gh pr diff <n>`, write the page to the path you were given (else
`pr-<n>-guide.html`), and reply with the path and one line.

## Cost discipline

The guide must be cheap. Work in this order and stop early:

- **Gate first** (step 1) from the diff stat, the PR body and the brief's
  signals — before you open any file.
- **Read narrowly**: the diff, the PR body and its `author-decisions`, then
  only the code ranges that back a decision card or the diagram (about 5
  ranges, ±30 lines each). Never read whole large files, never run builds,
  tests or installs, never search the history.
- **Fill the template** in `assets/template.html` beside this file; do not
  design a page from scratch.
- **Write once.** Do not re-render the page to polish it.

## 1. Gate — does a person need to judge something?

A person is needed when the PR has at least one of these:

- a **design or architecture choice** — a new module, a boundary moved, a
  dependency added, a pattern introduced or changed;
- a **contract change** — a public API, schema, migration, config key, CLI
  flag, event or file format, or the behavior a caller relies on;
- a **product behavior change** a user or operator sees;
- a **risk the diff cannot settle** — security, auth, money, data loss,
  privacy, concurrency, an irreversible operation, a production rollout;
- a **trade-off the PR states** (its body, `author-decisions`, comments) that
  someone must accept;
- a changed path that the brief marks as **forced** (`human_review_paths`).

Not needed: a mechanical change (rename, format, imports, constants), docs
or tests only, a dependency bump with no code change, a small local fix whose
correctness the diff alone shows. Not needed → write no page; give the
not-needed line and stop.

## 2. Reconstruct the story — from evidence only

- **Purpose** — what a user, request or job does differently now. One
  sentence, from the application's view, not the code's.
- **The shape** — the one flow, contract or structure that changed: before and
  after. Read the base side with `git show origin/<base>:<path>`.
- **Decisions to judge** (1–4) — for each: the question a person must answer,
  the PR's choice, the alternatives it names or the code makes obvious, and the
  evidence as a `path:line` link. **Never invent a rationale**: when the PR
  does not say why, write "The PR does not say why." A trade-off the PR itself
  flags is reported as the PR frames it.
- **Reading order** (3–6 stops) — group related files (a change and its test
  together), riskiest group first, the place a design problem would show up
  before the details. Each stop: what to check there, and the minutes.
- **Coupling** — who depends on the changed parts (callers, consumers,
  dependents named in the brief's context pack), in one short list.
- **Already covered** — when the brief names what the automated review
  checks, one line; a person does not check it twice.

## 3. The page — zoom levels

Use `assets/template.html`. Keep every block that has content; delete a block
that has none rather than fill it with filler.

| Level | Block | Visible | Content |
|---|---|---|---|
| 0 | Header | always | `PR #<n>: <title>`, head SHA (7), chips: size `+A −D · F files`, effort `1–5`, read time |
| 0 | **Why a person** | always | 1–2 sentences: the question(s) only a person can settle. The most important line on the page. |
| 0 | **Start here** | always | One link: the first stop of the reading order, with what to check there. |
| 1 | How it works now | always | **One** before/after diagram of the changed flow or contract, delta loud. Plus the one-sentence purpose. |
| 2 | Decisions to judge | `<details open>` first card, others closed | Cards: question · PR's choice · alternatives · evidence links · what the choice puts at risk (only from evidence) |
| 3 | Reading order | `<details>` | Numbered table: stop, files (links), check, minutes, a read/skim tag and a CSS churn bar. Mechanical files fold into one last row. |
| 4 | Coupling | `<details>` | Who depends on the changed parts; one small diagram only when the list cannot show it. |

**Effort** (state the number, the rubric sits in the template's tooltip):
1 = one concern, under 10 min · 2 = about 15 min · 3 = several parts, about
30 min · 4 = cross-module design, about 1 h · 5 = more than 1 h or needs a
domain expert — consider asking for a split.

**The diagram** — hand-drawn inline SVG, no script: **two** SVGs in the
template's `.ba` figure, before and after, which sit side by side and stack on
a narrow screen. Keep each one about 340 units wide so its text stays legible
on a phone. At most 7 boxes per side, each box a real symbol or component name. The changed parts carry the accent color **and**
a dashed border or a "new"/"changed" label, so color is never the only signal.
A contract change shows the signature or schema before → after side by side
instead, with the verdict `additive`, `breaking` or `behind a flag`. No flow
changed (a pure algorithm or data fix) → no diagram; one before → after line.

**Size scales with the PR**: a small PR that still needs a person gets Level 0,
one diagram and one decision card. Never pad.

## 4. Page rules (checked before publish)

- **One file, no network**: inline `<style>` only; no `<script>`, no `on…=`
  event attributes, no `<iframe>`, `<object>`, `<embed>`, `<form>`, `<link>`,
  remote fonts or images, no `url(http…)`.
- **Links** go only to the PR's own repository on its host —
  `https://<host>/<owner>/<repo>/blob/<head-sha>/<path>#L<a>-L<b>`,
  `…/pull/<n>/files` — or to `#anchors` in the page.
- **Size**: at most 150 KB; at most about 300 words of visible prose on Level
  0–1 and 900 words in all; code snippets at most 3, at most 12 lines each,
  inside `<details>`.
- **No secrets** — never copy a credential, token, key or a value from an env
  or config file into the page; refer to it by name.
- **Language**: ASD-STE100 Simplified Technical English — one topic per
  sentence, active voice, sentences of 20 words or fewer, one term per concept.
- **Readable**: light and dark (`prefers-color-scheme`), 375 px wide with no
  horizontal scroll, headings in order, every link text says where it goes.

## 5. Do not

- narrate the diff file by file, or order it alphabetically;
- decorate: no poem, mascot, emoji rows, stock phrases or filler sections;
- speculate ("this may cause X") or judge style and naming;
- repeat the review's findings — the review carries them;
- give a score without its rubric;
- describe code you did not read.

## Self-check before you write the file

- The first screen answers what, why a person, and where to start.
- Every "why" has evidence or says the PR does not say why.
- Every box in the diagram is a real name; the delta is visible without color.
- Every link points into the PR's repository at the head SHA.
- No `<script>`, no remote load, no secret, under 150 KB.
