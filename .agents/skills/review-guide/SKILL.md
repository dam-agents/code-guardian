---
name: review-guide
description: >-
  Build a short, picture-first, one-page HTML guide for the person who must
  review a pull request: why a person is needed and where to start, a map of
  the project with the change marked, the grounded risks and the review's
  verified findings, then one visual per section — why the PR exists, the
  dependency chain, the decisions and their alternatives, the problems met
  and how they were solved, where the churn landed, the technical impact, and
  the limits and open points. It decides first whether a person must judge anything and
  writes no page when nothing needs one, and it keeps maps of the project's
  areas to reuse. Use it when an automated review or an author wants a human
  reviewer's guide, a visual PR explainer, a "zooming review", a PR artifact or
  walkthrough page, or a design doc for reviewers — "make a review guide for PR
  42", "explain this PR visually", "what must a human check here".
argument-hint: "[PR number] [output .html path]"
metadata:
  code-guardian-output: guide
---

# Review guide — one page, pictures first

The reviewer's attention is the scarce resource, not your effort. Give them
**one self-contained HTML page** they understand by looking: every section
leads with a picture and carries only the words the picture cannot. The first
screen answers in 15 seconds what the PR does, **why a person must look**, and
**where to look first**. Below it, the reader zooms in one section at a time,
in the order understanding builds: why the PR exists → the chain it runs
through → the decisions → the problems met → where the churn landed → the
impact. The code stays on GitHub; the page links to it.

The page is a guide, not a review: it does not hunt for bugs and does not
repeat review findings. It tells the PR's story the way a colleague explains
their PR — from the application's view, grounded in evidence — and shows the
questions a person must settle.

## Under code-guardian

When a brief file started you, the brief owns the inputs, the output paths,
the reply and the time budget; this file owns the method and the page. Without
a brief: read the PR with `gh pr view <n> --json title,body,author,headRefOid,baseRefName,files,additions,deletions,commits`
and `gh pr diff <n>`, write the page to the path you were given (else
`pr-<n>-guide.html`), and reply with the path and one line.

## Cost discipline

The guide must be cheap — a few minutes, not a reading of the repository.

- **Gate first** (step 1) from the diff stat, the PR body and the brief's
  signals — before you open any file.
- **Read narrowly**: the diff, the PR body with its `author-decisions`, the
  comments, the commit list, then only the code ranges that back a picture or
  a decision (about 5 ranges, ±30 lines). Never read whole large files, never
  run builds, tests or installs.
- **Reuse before you draw**: a project diagram the brief hands you is already
  marked; use it. Draw a new project map only where the brief asks, at most
  one per run.
- **Fill the templates** in `assets/` beside this file; do not design from
  scratch, and write each file once. Cards, tiles, bars and mini diffs are
  cheap HTML — prefer them to a new SVG; draw an SVG only for a map, a flow,
  a sequence or the rings.

## 1. Gate — does a person need to judge something?

A person is needed when the PR has at least one of these:

- a **design or architecture choice** — a new module, a boundary moved, a
  dependency added, a pattern introduced or changed;
- a **contract change** — a public API, schema, migration, config key, CLI
  flag, event or file format, or the behavior a caller relies on;
- a **product behavior change** a user or operator sees;
- a **risk the diff cannot settle** — security, auth, money, data loss,
  privacy, concurrency, an irreversible operation, a production rollout;
- a **trade-off or open point the PR states** (its body, `author-decisions`,
  comments) that someone must accept;
- a changed path that the brief marks as **forced** (`human_review_paths`).

Not needed: a mechanical change (rename, format, imports, constants), docs
or tests only, a dependency bump with no code change, a small local fix whose
correctness the diff alone shows. Not needed → write no page; give the
not-needed line and stop.

## 2. Reconstruct the story — from evidence only

Read the changed code in the tree, not only the hunks: an honest picture needs
the code around the change.

- **Why this PR exists** — what was broken or missing before, and what a user,
  request or job does differently now. Name the flows and subsystems the
  reader knows.
- **The dependency chain** — the path the change threads through: entry point
  → the components it passes → where it ends (a call chain, a request through
  services, a job's steps, a data flow). Mark the links the PR adds or changes.
- **Decisions and alternatives** (1–4) — for each: the question a person must
  answer, the PR's choice, the alternatives it names or the code makes
  obvious, why the choice won, and the evidence as a `path:line` link. **Never
  invent a rationale**: when the PR does not say why, write "The PR does not
  say why." Call a pragmatic compromise one.
- **Problems encountered → how resolved** — bugs, dead ends, edge cases and
  things that fought back, from the commit list, the comments and the PR body:
  each problem with its fix. The most valuable and most-skipped part. Nothing
  in the evidence → leave the section out; never invent one.
- **Where the churn landed** — added and deleted lines per area, split into
  logic, tests, docs and mechanical, and the reading order: riskiest group
  first, a change and its test together.
- **Technical impact** — coupling and blast radius: which parts now depend on
  the change or are affected by it (the brief's context pack names the
  dependents), and what a caller sees differently.
- **Risks** (2–4) — what a person must watch, each grounded in a fact
  (**Risks from facts** below): the brief's risk prescan and forced paths, a
  changed code file the context pack lists with no test, a contract change, an
  open point the PR names.
- **Limits and open points** — what the PR does not do: what it delivers,
  what it leaves for later (the linked issue's open parts, a follow-up the PR
  names), and what it does not do on purpose (a scope cut or a rejected
  option in its `author-decisions`). From the PR body, the linked issue and
  the comments only; nothing there → leave the section out.

## 3. The page — short at a glance, deep on demand, pictures at every level

Use `assets/template.html`. The page is a **zoom ladder**: each level adds
pictures, not paragraphs, and the reader goes down only where they want.

| Level | What the reader sees | The pictures |
|---|---|---|
| **0 — the PR** (no click) | header chips, **Why a person must look**, **Risks — what to watch**, **Verified by the review**, **Start here**, **Where it lands** | risk cards with a level edge, the review's findings, the project map with the touched nodes marked |
| **1 — overview** (no click) | the seven sections as **closed lines**: name · main point in ≤ 15 words · badge (`3 to judge`, `2 solved`, `+386 −10`, `breaking`) | the closed page reads as the PR's story |
| **2 — a section** (open a line) | its main visual and at most about 60 words | before/after, chain, compare cards, timeline, treemap, rings |
| **3 — zoom in** (a 🔍 zoom) | the parts behind the visual | file tiles sized by churn, component cards with before → after, risk dot and churn bar |
| **4 — code** (the innermost zoom) | the line that matters | a mini diff (≤ 12 lines, colored +/−) and the GitHub link |

Under **Where it lands**, give each marked map node (at most 3, most churn
first) its zoom: level 3 shows that node's files as tiles, level 4 one file's
mini diff. Each zoom starts with a breadcrumb (`Map › <node> › <file>`).

| Section | Its closed line | Level 2 visual | Its zooms (3 → 4) |
|---|---|---|---|
| Why this PR exists | the problem and the fix | before → after: two SVGs, the delta loud | the user flow as step cards, the changed step marked |
| The dependency chain | entry → … → end · `N links changed` | flow or sequence diagram (pick by the change: **sequence** for a protocol or request order, **flow** for a call chain or pipeline, **state** for a lifecycle, **schema** for a data contract) | a card per component (risk dot, before → after, churn bar) → the riskiest step's mini diff |
| Decisions and alternatives | the first question · `K to judge` | per decision: the question, then the PR's choice vs. the alternative with ✓/✗ consequences | why, with its source → the line that carries the choice |
| Problems encountered | the hardest one · `K solved` | a timeline: ⚠ problem → ✓ fix, with the commit link | the hardest one: the dead end and the comment → the fix as a mini diff |
| Where the churn landed | where most lines went · `+A −D` | a treemap of areas sized by changed lines, colored by kind | the reading order: numbered rows, churn bars, read/skim tags |
| Technical impact | who is affected · `additive`/`breaking`/`behind a flag` | blast-radius rings: changed part, direct dependents, consumers | the contract before → after as a mini diff, a card per dependent |
| Limits and open points | the main thing it does not do · `K open` | a scope board: ✓ in this PR · ⏸ left for later · ✗ not done on purpose | each known limit: when a user meets it, and where it shows |

**The first screen answers the reviewer's questions.** Why was it done and
what does it do — the callout and the map. What must a person decide — the
callout. What is risky — **Risks — what to watch**. What did the automated
review already find — **Verified by the review**: code-guardian renders the
review's open blocking findings into the page where the template's
`<!-- cg:findings -->` mark sits. Keep the mark; never write findings
yourself and never restate them as risks. Where to look first — **Start
here**.

### Risks from facts

A risk card names a **fact** and what the fact exposes. The kinds of fact:
`irreversible` (a migration, a delete, a send, a publish), `contract` (an API,
schema, config key, event or file format others use), `untested` (changed
logic whose file the context pack lists with no test), `sensitive path` (the
risk prescan or `human_review_paths`), `concurrency` (shared state, ordering,
retries), `security` (auth, secrets, input that reaches a query or a shell),
`data` (a write or a format of stored data), `rollout` (no flag, no fallback),
`open point` (what the PR itself marks open).

- **Level**: `hi` — irreversible, security, data loss, or a contract other
  code calls; `md` — untested changed logic, concurrency, a sensitive path;
  `lo` — the rest worth a look. Highest first, at most 4.
- Each card: what can go wrong in at most 12 words, the tag, the link to the
  line, and the fact in at most 15 words. Its `data-ref` ties it to the map
  node it lives in.
- Never a guess: "this may cause X" is a risk only when the mechanism is in
  the code you read. No fact → no card. No risk → leave the section out.

Keep a section, a zoom or a card only when it has content; delete it rather
than fill it.

### Interactions — attributes, never script

The page may be fully interactive, but **you write no script**: code-guardian
inserts the vetted `assets/guide.js` before `</body>` once the page passed its
checks (standalone use: paste that file in a `<script>` there yourself). It
adds a sticky **zoom bar** (Overview · Sections · Zoom · Code, and the `+`/`−`
keys) and reads these attributes:

- `data-zoom="<id>"` — a click or Enter opens `<details id="<id>">` and its
  parents, and scrolls to it. code-guardian's marked map copies already carry
  `data-zoom="z-n<i>"` on the marked nodes: give the matching zoom
  `id="z-n<i>"`.
- `data-ref="<key>"` — hovering one element highlights every element with the
  same key: give a map node, its tiles, its cards and its reading-order rows
  one key (`n<i>` for a marked node).
- `data-tip="<text>"` — a tooltip on hover or tap: the role and churn of a
  node, what changed in a tile, why a card is high risk.
- `data-kind="logic|test|docs|mech"` — on treemap boxes and tiles; the legend
  filters by kind.
- `href="#<id>"` — a link to a closed section or zoom opens it.

**Effort** (state the number, the rubric sits in the template's tooltip):
1 = one concern, under 10 min · 2 = about 15 min · 3 = several parts, about
30 min · 4 = cross-module design, about 1 h · 5 = more than 1 h or needs a
domain expert — consider asking for a split.

**Drawing rules** — hand-drawn inline SVG, no script.

- Every box is a real symbol, component, service or file name; at most 7
  boxes in one picture. No "process data" boxes.
- Changed parts carry the accent color **and** a dashed border or a
  `NEW`/`CHANGED` tag, so color is never the only signal.
- A before/after pair is two SVGs in the template's `.ba` figure, each about
  340 units wide, so they stack legibly on a phone.
- A picture that would repeat another one is left out.
- **Size scales with the PR**: a small PR that still needs a person gets the
  first screen, the map and one or two sections. Never pad.

## 4. Project diagrams — the maps you keep

A project diagram is a map of one area of the repository — its components and
how they connect — as it is on the **base branch**. code-guardian stores it in
`work/diagrams/` and hands later guides a copy with the PR's nodes marked, so
the map is drawn once and reused.

When the brief asks for one, draw it from `assets/project-diagram.svg`:

- The root `<svg>` carries `data-cg-diagram="<id>"` (lower-case letters,
  digits, hyphens; the file name), `data-title`, `data-paths` (the directory
  prefixes the map covers, comma-separated), `data-base` (the base SHA, 7
  characters) and `data-drawn` (`YYYY-MM-DD`).
- Every node is `<g class="node" data-paths="<prefix>[,<prefix>…]">` **on its
  own line**, holding its box and its label; `data-paths` names the files or
  directories the node stands for, so a later PR's changes mark it.
- 5–15 nodes, the edges between them, no PR marks, no link. Read the area's
  tree (`git ls-tree`) and its entry points; do not read every file.
- Save it where the brief says, then put a marked copy in this page: add
  ` hl` to the class of each node the PR touches.

## 5. Page rules (checked before publish)

- **One file, no network**: inline `<style>` only; no `<script>` of your own
  (the vetted one is added for you), no `on…=` event attributes, no
  `<iframe>`, `<object>`, `<embed>`, `<form>`, `<link>`, `<foreignObject>`,
  remote fonts or images, no `url(http…)`.
- **Links** go only to the PR's own repository on its host —
  `https://<host>/<owner>/<repo>/blob/<head-sha>/<path>#L<a>-L<b>`,
  `…/commit/<sha>`, `…/pull/<n>/files` — or to `#anchors` in the page.
- **Size**: at most 150 KB; at most about 600 words of prose in all; mini
  diffs at most 8, at most 12 lines each, always inside a zoom.
- **No secrets** — never copy a credential, token, key or a value from an env
  or config file into the page or a diagram; refer to it by name.
- **Language**: ASD-STE100 Simplified Technical English — one topic per
  sentence, active voice, sentences of 20 words or fewer, one term per concept.
- **Readable**: light and dark (`prefers-color-scheme`), 375 px wide with no
  horizontal scroll, headings in order, every SVG with an `aria-label`, every
  link text says where it goes.

## 6. Quality bar

- **Stay at altitude**: consequences and coupling, not naming, style or
  micro-optimizations.
- **Describe decisions, ground risks**: present each decision and problem
  neutrally; name a risk only from a fact (**Risks from facts**). Report a risk
  the PR itself flags as its authors framed it.
- **Do not** narrate the diff file by file, decorate (no poem, mascot, emoji
  rows, filler), repeat the review's findings, give a score without its
  rubric, or describe code you did not read.

## Self-check before you write the file

- The first screen answers why, what, what a person must decide, what is
  risky and where to start; the `<!-- cg:findings -->` mark is in place; the
  map shows where the change lands; the closed section lines alone tell the PR's
  story; every level below adds a picture, and the innermost one is code.
- Every marked map node has its zoom with the matching id; related elements
  share a `data-ref`.
- Every section leads with its picture; every picture has real names and a
  delta visible without color.
- Every "why" has evidence or says the PR does not say why.
- Every link points into the PR's repository; no `<script>`, no remote load,
  no secret, under 150 KB.
