---
name: issue-fit
description: >
  Review-time check that a pull request delivers what its linked GitHub issue
  asked: resolves the issue from the PR (closing keywords, branch name), reads
  the issue body and comments for the actual ask, and flags missing scope and
  undeclared scope creep. REST-only and repo-agnostic. Use when reviewing a PR
  to verify it does what was asked — "issue fit", "does this PR deliver the
  issue", "check the PR against its issue", "scope check" — or as a configured
  always-on review skill of an automated review agent.
---

# Issue Fit

Checks a pull request against the issue it implements. The issue is what was
asked; the PR description is the author's claim about what was done — when
they disagree, the issue wins. The output is a findings section for the
caller's review; this skill never posts, comments, or edits anything.

## Inputs

- **Repo slug** and **PR number** (required).
- **PR title, body, head branch, and diff** — reuse them when the caller
  already fetched them; otherwise `gh api "repos/<repo>/pulls/<n>"` and
  `gh pr diff <n> --repo <repo>`.

Use plain REST (`gh api`) everywhere — some deployments' auth proxies
rewrite only REST paths, so GraphQL-backed `gh` subcommands can 401.

## Resolving the linked issue

1. **Closing keywords** in the PR body — `closes`/`fixes`/`resolves` and
   their tense variants, followed by `#<n>` or a same-repo issue URL. These
   close the issue on merge; note which numbers came this way.
2. **Plain references** (`#<n>` without a keyword) and a head branch starting
   with an issue number (`123-add-retries`) are **inferred** links: use them
   when step 1 found nothing, and say the link was inferred.
3. For each candidate: `gh api "repos/<repo>/issues/<n>"`. A response with a
   `pull_request` key is a PR — drop it; cross-repo references too.
4. Several distinct issues → check each. None → **No linked issue** below.

## Reading the ask

Fetch the discussion:
`gh api "repos/<repo>/issues/<n>/comments?per_page=100"` (one page).

The ask is the issue **body as amended by the comments** — requirements get
dropped, added, and re-scoped in discussion ("let's skip the UI part for
now" removes that item from what this PR owes). When comments conflict, the
latest decision by the issue author or a maintainer wins. Distill the result
into concrete deliverables: acceptance criteria, named behaviors, named
files or surfaces.

## Judging fit

Compare the deliverables against the diff — what the code actually does, not
what the PR body says it does:

- **Missing scope** — a deliverable with no corresponding change in the
  diff. Check by behavior, not filename: the fix may live somewhere the
  issue didn't predict. Critical when a step-1 closing keyword will close
  the issue with that work undone; a warning otherwise.
- **Undeclared scope creep** — a substantial change that neither the issue
  asks for nor the PR body declares — a warning. Declared extras ("also
  fixes the flaky retry test") are fine. Mechanical fallout of the asked
  change (renames, imports, lockfiles, generated files) is never creep.
- **Partial delivery** — attempted but visibly incomplete against the
  issue's own words (three endpoints named, one covered) — severity as
  missing scope.
- Minor gaps — a secondary deliverable, an inferred-link mismatch — are
  suggestions.

Anchor every finding in the issue's or the discussion's words and in the
diff. Do not re-review code quality — correctness, style, and tests belong
to the main review; this skill judges scope only.

## Report

The output is a markdown section body for the caller to include verbatim.
Findings use the caller's standard format — severity levels, finding
bullets, and verdict weight are the caller's, not redefined here; one or two
sentences per finding, `file:line` where it anchors to code. No methodology
narration, no restating the diff. Open with the link line; a clean run ends
after one ✅ line:

```
Linked issue: #<n> "<title>" (closing keyword | inferred from <branch name / plain reference>)

✅ Delivers the issue's ask; no undeclared scope.
```

### No linked issue

Open with `_No linked issue — scope checked against the PR description
only._` and judge the diff against what the PR body promises: undeclared
substantial changes are still warnings; a PR body that promises something
the diff doesn't contain is too.

## Cost bounds

Typical run: 2–4 REST calls (PR + issue + comments; +1 for the diff). Judge
from issue + discussion + diff only — no repository-tree walks, no extra
comment pages. When that isn't enough, say so in one line instead of
digging: `_Issue #<n> is too vague to judge scope against; reviewed the diff
as-is._`
