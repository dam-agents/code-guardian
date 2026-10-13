# GitHub access — identity, trust, capabilities

Read this file when onboarding checks the token (ONBOARDING Step 4), when a
version upgrade or the audit's `github_identity` check reports a connection
change, and when the operator asks what the agent may do on GitHub. The agent
runs the same way with a **user token** (classic or fine-grained) and with a
**GitHub App** installation token. Nothing in `work/CONFIG.md` names the
connection.

## Identity

- The token's login comes from GraphQL `viewer`, else from REST `GET /user`
  (`scripts/lib/common.sh` → `gh_login`). REST `GET /user` refuses an App
  token, and the pod's proxy can refuse GraphQL for a user token. `kind` is
  `app` for a `<app>[bot]` login, else `user`.
- `$WORK/GITHUB.json` caches `{login, kind, checked_at}`. Preflight refreshes it
  hourly, and the audit refreshes it on every run. A failed read keeps the cache.
  A cache that is not one JSON object reads as absent, and the next read writes
  it again. A changed login also records
  `{previous, changed_at}` and logs a `github_identity` warn; the audit's
  `github_identity` check warns for 7 days after it.
- The worklist `config.github_identity` carries `{login, kind}`.
- `bot_login` is the account people mention, assign and request
  ([config.md](config.md)). It can differ from the token's login: an App
  token posts as the App while `bot_login` stays a user account.

## Triggers by identity

People start the agent's work with a label, a review request, an assignment or
a mention. A GitHub App cannot be requested or assigned, so each of those has
a label beside it:

| Request | User `bot_login` | GitHub App `bot_login` |
| --- | --- | --- |
| complete re-review | `rereview_label` | `rereview_label` |
| delta re-review | review request (`rereview_trigger`), `rereview_delta_label` | `rereview_delta_label` |
| visual artifact | assignment of `bot_login`, `artifact_label` | `artifact_label` |
| reply, feedback, on-demand review | `@<bot_login>` | `@<slug>` or `@<slug>[bot]` |

- Under a GitHub App `bot_login`, preflight and `review-pr.sh` read
  `rereview_trigger` as `label`.
- A mention of an App that posts for several agents in the same repository
  reaches each of them. Use the labels there: each agent has its own.
- The check run of the progress signal lists the triggers of this instance
  (**Progress signal channel**).

## Own content

- **A user `bot_login` is trusted by login**: its comments and threads are the
  agent's own.
- **A bot login is never trusted by login alone.** That includes a bot
  `bot_login`, and the token's login when it differs from `bot_login`. One App
  can post for several agents, so such content is the agent's own only through
  `review_marker`:
  - a review that carries the marker;
  - an inline comment of such a review;
  - an issue that carries the issue marker.
- An unmarked issue comment by a bot login is not attributed. The reaction
  feedback skips it, and a reply under it is not a mention.
- Reviews are always matched by the marker, whatever posted them, so a
  connection change orphans no past review.

## Own pull request

GitHub refuses an approval or a change request from the account that opened
the pull request. One GitHub App can open pull requests for one agent and
review them for another, so this happens in normal use:

- When the PR's author is the token's login, `review-pr.sh post` and `rapid`
  send the review as `COMMENT`. The body starts with a line that names the
  verdict, and the `REVIEWS.md` row keeps the verdict.
- When the identity cache is missing, GitHub's refusal (422, "own pull
  request") turns the one retry into a `COMMENT`.
- The outcome carries `event` beside `verdict`, and a `review_pr` warn logs
  the change.
- A `COMMENT` does not count as an approval, and it does not block a merge.
  Branch protection that requires an approval needs a person on such a PR.

## Progress signal channel

Under `review_progress: enabled` the channel follows the token, with no
configuration ([review-bookkeeping.md](review-bookkeeping.md) → **Progress
signal on GitHub**):

- An App token writes a **check run**. Only an App can create check runs.
- A user token writes a **commit status**.
- A refused write tries the other channel once. A second refusal is logged
  (`progress_status`, warn).

The check run carries more than the one-line status:

- **Title** — the latest progress line.
- **Summary** — one line per update with its UTC time, so the run shows the
  review's timeline. The terminal line links the review.
- **Text** — how a person requests the next round, from this instance's
  triggers (**Triggers by identity**). It replaces the "Re-request review"
  button that a GitHub App does not get.
- **Start and end times** — GitHub shows the review's duration from them.

An update completes the open run of the token's own App. An unreadable token
login matches no run, so the update creates a run of its own. The App that
GitHub names on the created run is the token's login from then on
(`work/GITHUB.json`), so the next update completes that run.

## Access check — `scripts/github-access.sh`

`bash "$HOME/scripts/github-access.sh"` prints one JSON report:

- `identity`: login, kind, token type, and the OAuth scopes of a classic token.
- `probes[]`: one entry per permission, with the state `granted`, `denied` or
  `unknown`.
- `progress_channel`: `check_run`, `status` or `none`.
- `features`: what the probes allow (**Feature map** below).
- `triggers`: which triggers `bot_login` and the configured labels serve
  (**Triggers by identity**), `mention_as` (the forms people type), and
  `missing` (the label keys a GitHub App `bot_login` has no trigger without).
- `unexpected`: the ids of probes that wrote something. It must be empty.

Rules:

- **Direct session, onboarding and upgrade only — never a scheduled run.** Its
  write probes send a body that GitHub must reject: 422 means granted, 403/404
  means denied, and nothing is written. Preflight and the audit stay
  read-only; they check the identity alone.
- A probe that answers 2xx is a defect. Report it to the operator and remove it
  from the script.
- Show the report to the operator. A `missing` feature that is enabled in
  `work/CONFIG.md` is **operator-only** to fix (grant the permission or scope).
  Never work around it.

## Feature map

| Feature | Needs |
| --- | --- |
| reviews, comments, labels | `repo_read`, `reviews_write`, `comments_write` |
| issues for findings of a closed PR | `issues_write` |
| `review_progress` | `checks_write` (App) or `statuses_write` (user) |
| `ci_triage` | `checks_read`, `actions_read` |
| `auto_merge` | `checks_read`, `contents_write` |
| `agent_fixes` | `contents_write` |
| `work_repo` backup | `work_repo_write` |
| definition PRs | `definition_push`, `definition_prs` |
| reviewer roster from teams | `org_teams_read` (onboarding only) |
| project profile required checks | `branch_protection_read`, else the branch rulesets (metadata read) |

A GitHub App needs these repository permissions:

- Pull requests, Issues and Contents: read and write.
- Checks: read and write.
- Actions and Metadata: read.
- Commit statuses: write, only if no check run is possible.
- Organization members: read, for the reviewer roster.

A user token needs the classic `repo` scope, or the same permissions as a
fine-grained token (README → **Token scopes**).

## After a connection change

1. Run the access check and show the report to the operator.
2. Keep `bot_login` when it is still the account people use. Change it only on
   the operator's decision ([config.md](config.md)).
3. A trigger that `bot_login` can no longer serve (`triggers`) and a `missing`
   feature go to the operator. For each key in `triggers.missing`, offer the
   label and write the key on a yes ([config.md](config.md)). The runtime needs
   no other change.
