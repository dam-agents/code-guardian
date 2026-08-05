---
name: issue-fit
description: >
  Review-time check that a pull request delivers what its linked GitHub issue
  asked: resolves the issue from the PR (closing keywords, branch name), reads
  the issue body and comments for the actual ask, and flags missing scope and
  undeclared scope creep as severity-ranked findings. REST-only and
  repo-agnostic. Use when reviewing a PR to verify it does what was asked —
  "issue fit", "does this PR deliver the issue", "check the PR against its
  issue", "scope check" — or as a configured always-on review skill of an
  automated review agent.
---

# Issue Fit

Checks a pull request against the issue it implements. The issue is what was
asked; the PR description is the author's claim about what was done. When the
two disagree, the issue wins — a diff can look correct line by line and still
not deliver the ask, and no per-file review catches that. The output is a
findings section for the caller's review; this skill never posts, comments,
or edits anything itself.

## Inputs

- **Repo slug** and **PR number** (required).
- **PR title, body, head branch, and diff** — reuse them when the caller
  already fetched them (a review pipeline has); otherwise fetch:
  `gh api "repos/<repo>/pulls/<n>"` and `gh pr diff <n> --repo <repo>`.

Use plain REST (`gh api`) for every call — some deployments sit behind an
auth proxy that rewrites only REST paths, so GraphQL (and `gh` subcommands
that use it) can fail with 401 even when REST works.

## Resolving the linked issue

1. **Closing keywords in the PR body**: `close`/`closes`/`closed`,
   `fix`/`fixes`/`fixed`, `resolve`/`resolves`/`resolved`, each followed by
   `#<n>` or a full issue URL of the same repo. These are the references that
   will actually close the issue on merge — note which numbers came this way.
2. **Plain references** in the PR body (`#<n>` without a keyword) and a head
   branch starting with an issue number (`123-add-retries`) are **inferred**
   links: use them when step 1 found nothing, and say the link was inferred.
3. For each candidate: `gh api "repos/<repo>/issues/<n>"`. A response
   carrying a `pull_request` key is a PR, not an issue — drop it. Cross-repo
   references are out of scope — drop them.
4. Several distinct issues → check each (they rarely exceed two). None → see
   **No linked issue** below.

## Reading the ask

Fetch the discussion: `gh api "repos/<repo>/issues/<n>/comments?per_page=100"`
(one page is enough — later comments matter most and giant threads have
diminishing returns).

The ask is the issue **body as amended by the comments**. Requirements get
dropped, added, and re-scoped in discussion, so a comment like "let's skip
the UI part for now" removes that item from what this PR owes — judging
against the stale body alone produces false findings. When comments
conflict, the latest decision by the issue author or a maintainer wins.
Distill the result into concrete deliverables: acceptance criteria, named
behaviors, files or surfaces the issue explicitly mentions.

## Judging fit

Compare the deliverables against the diff — what the code actually does, not
what the PR body says it does:

- **Missing scope** — a deliverable with no corresponding change in the diff.
  Check the diff for it by behavior, not by filename: the fix may live
  somewhere the issue didn't predict.
- **Undeclared scope creep** — a substantial change in the diff that neither
  the issue asks for nor the PR body declares. Declared extras ("also fixes
  the flaky retry test") are fine — the author said so, reviewers can judge;
  it's the silent unrelated changes that hide risk. Mechanical fallout of the
  asked change (renames, imports, lockfiles, generated files) is never creep.
- **Partial delivery** — the deliverable is attempted but visibly incomplete
  against the issue's own words (e.g. the issue names three endpoints, the
  diff covers one).

Anchor every finding in the issue's or the discussion's words and in the
diff. Do not re-review code quality here — correctness, style, and tests
belong to the main review; this skill judges scope only.

## Severity

- 🔴 **Critical** — the PR closes the issue (a step-1 closing keyword) but
  the core ask is not delivered: merging closes the issue with the work
  undone.
- 🟡 **Warning** — a named requirement or a decision from the discussion is
  missing (without the closing keyword making it 🔴), or substantial
  undeclared scope creep.
- 🟢 **Suggestion** — minor gaps: a secondary deliverable missing, an
  inferred-link mismatch worth a look.

## Report

The output is a markdown section body for the caller to include verbatim —
findings only, no methodology narration, no restating the diff:

```
Linked issue: #<n> "<title>" (closing keyword | inferred from <branch name / plain reference>)

- 🔴 **Critical:** <what the issue asked, in its words> — not delivered; merging closes #<n> with this undone.
- 🟡 **Warning:** <undeclared change> (`file:line`) — not in #<n> and not declared in the PR body.
- 🟢 **Suggestion:** <minor gap>.
```

One or two sentences per finding, `file:line` where a finding anchors to
code. Clean run:

```
Linked issue: #<n> "<title>" (closing keyword)

✅ Delivers the issue's ask; no undeclared scope.
```

### No linked issue

Open with `_No linked issue — scope checked against the PR description
only._` and judge the diff against what the PR body promises: undeclared
substantial changes are still 🟡 findings; a PR body that promises something
the diff doesn't contain is too. Missing-scope checks against an issue don't
apply.

## Cost bounds

Typical run: 2–4 REST calls (PR + issue + comments; +1 for the diff when not
provided). Read the diff and the issue thread — do not walk the repository
tree, read unrelated files, or fetch more comment pages; when the ask cannot
be judged from issue + discussion + diff, say so in one line instead of
digging (`_Issue #<n> is too vague to judge scope against; reviewed the diff
as-is._`).
