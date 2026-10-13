# GitHub access — identity, trust, capabilities

Read this file when onboarding checks the token (ONBOARDING Step 0.1), when a
version upgrade or the audit's `github_identity` check reports a connection
change, and when the operator asks what the agent may do on GitHub. The agent
runs the same way with a **user token** (classic or fine-grained) and with a
**GitHub App** installation token. Nothing in `work/CONFIG.md` names the
connection.

## Identity

- The token's login comes from GraphQL `viewer` — REST `GET /user` refuses an
  App token. `kind` is `app` for a `<app>[bot]` login, else `user`.
- `$WORK/GITHUB.json` caches `{login, kind, checked_at}`. Preflight refreshes it
  hourly, and the audit refreshes it on every run. A failed read keeps the cache.
  A changed login also records
  `{previous, changed_at}` and logs a `github_identity` warn; the audit's
  `github_identity` check warns for 7 days after it.
- The worklist `config.github_identity` carries `{login, kind}`.
- `bot_login` is the account people mention, assign and request
  ([config.md](config.md)). It can differ from the token's login: an App
  token posts as the App while `bot_login` stays a user account.

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

## Progress signal channel

Under `review_progress: enabled` the channel follows the token, with no
configuration ([review-bookkeeping.md](review-bookkeeping.md) → **Progress
signal on GitHub**):

- An App token writes a **check run**. Only an App can create check runs.
- A user token writes a **commit status**.
- A refused write tries the other channel once. A second refusal is logged
  (`progress_status`, warn).

## Access check — `scripts/github-access.sh`

`bash "$HOME/scripts/github-access.sh"` prints one JSON report:

- `identity`: login, kind, token type, and the OAuth scopes of a classic token.
- `probes[]`: one entry per permission, with the state `granted`, `denied` or
  `unknown`.
- `progress_channel`: `check_run`, `status` or `none`.
- `features`: what the probes allow (**Feature map** below).
- `triggers`: which re-review and artifact triggers `bot_login` can serve.
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
| reviews, comments, labels, issues | `repo_read`, `reviews_write`, `comments_write` |
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
   feature go to the operator. The runtime needs no other change.
