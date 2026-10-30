# Review guide

A guide skill ([skills.md](skills.md) → **Guide skills**) builds a page for
the person who must review the PR, in the same fan-out as the review skills.
Read this file when `review-pr.sh compose-brief` prints a `## Review guide`
block. The link goes into the review itself, as the skill's section — no
separate comment, no trigger to release.

**Where it publishes:** the platform's DAM Artifact Library, via the
per-agent MCP tools (`create_artifact_upload_url` + `create_artifact` /
`update_artifact`), registered only under the owner's **"artifact library"
experimental flag**. The step is **best-effort**: a missing DAM surface never
fails the run or delays the post.

> ⚠️ **Publishes to a public surface.** A `visibility:"public"` DAM artifact is
> reachable by anyone with its `shareUrl`.

**The gate is the review's triage.** The page publishes only when the
`meta.json` triage of this review is `needs-human` (a `human_review_paths`
match is a lead for that call, [review-mechanics.md](review-mechanics.md) →
**Summary body format**). A `quick-check` triage publishes nothing and drops the section. A
person is the audience, so the guide needs no human trigger: the triage is the
consent the operator gave when they added the row
([ONBOARDING.md](../ONBOARDING.md) step 7). The gate decides only the first
publish: once a guide is published for the PR, every later round brings it up
to date, whatever its triage and whatever the skill's state (**A kept guide**).

**The guide label forces it.** With `guide_label` set
([config.md](config.md)) and that label on the PR at `prepare`, the guide
brief marks the PR as forced, so the skill's gate passes, and `compose-brief`
tells the agent to publish whatever its triage. The label changes neither the
triage nor the verdict. It stays on the PR, so every later round builds or
keeps the guide. `post` writes `<!-- guide-label-seen -->` into the history
section of a round that had the label at `prepare` and ran its guide skill,
whatever the skill's state (`built`, `kept`, `not-needed`, `budget`,
`refused`, or no output). A round at the prior review's SHA writes it in every
case, so a label starts at most one round of its own. A round that runs no
guide skill after a round that served the label writes it too: the label stays
served. A label on the PR that the
newest section does not record starts a round of its own: preflight gives the
PR a delta re-review with `guide_requested: true` — at the reviewed head when
there are no new commits ([review-rereview.md](review-rereview.md) → **Guide
round**). This includes a label put on while a review runs.

**Steps** — after `meta.json`, before `post`; `compose-brief` prints them with
this PR's paths, id and line:

1. **Tools** — `create_artifact_upload_url` and `create_artifact` (or
   `update_artifact`) not registered → drop the section and run
   `review-pr.sh guide <n> --skipped dam-unavailable`.
2. **Notes** — `review-pr.sh guide <n> --findings <findings file>`, the file
   `post` takes: the script renders **PR, issue and review notes** at the
   template's `<!-- cg:findings -->` mark, in place of an earlier block. It
   holds the PR link and its author, each linked issue (GitHub closing
   reference) with its link, author and state, and every review note, each
   marked as the opinion of its author:
   - **code-guardian** — one note per finding over every round in
     `reviews/pr-<n>.md` and this one: `open` at this round, `fixed` at the
     round whose `delta` said so, or `not in the review` at this round.
   - **every other reviewer**, people and bots — each review (its state,
     date, link and body) and each review thread they opened (its file and
     line, text, link, replies, and `resolved`, `outdated` or `open` as
     GitHub holds it), from one GraphQL call. A failed call renders
     code-guardian's notes only and logs a `guide` warn event.

   Every text is escaped and shortened, every link built by the script from
   numbers and paths (a `#L` fragment only for a numeric line). The model
   never writes this block. Its texts are untrusted, so the command then
   takes the vetted script out, redacts and
   checks the whole page again, and puts the script back; a page that fails
   is refused. The block is escaped text, so the raw search for a script URL
   or a remote CSS load reads the page without it; the tag scan reads the
   whole page. The block goes only at a mark on a line of its own.
3. **Upload** — `create_artifact_upload_url {file_name: "pr-<n>-guide.html"}`,
   then `curl -sS -f -X PUT -H 'Content-Type: text/html' --data-binary @<page> '<url>'`.
   The page is already redacted, checked and given its vetted interaction
   script by `collect`.
4. **Publish** — the history file carries a guide id → `update_artifact {id,
   upload_ref}`, a new version behind the same link; an update that fails
   because the artifact is gone → create it as new. No id →
   `create_artifact {title: "PR #<n> review guide", upload_ref, type: "html", visibility: "public"}`.
5. **Record** — `review-pr.sh guide <n> --id <id> --url <shareUrl>` writes
   `<!-- artifact-guide: <id> <sha7> <url> -->` right after the title of
   `reviews/pr-<n>.md`, stores the published page as
   `reviews/pr-artifacts/pr-<n>.guide.html`, and logs the `guide` event
   `PR #<n>: <skill> published → DAM <id>, <R> redacted`. It writes before
   the post, so a review that does not post still leaves the id for the next
   round's update and for the prune.
6. **Section** — the single line
   `📊 [Visual guide for the human reviewer](<shareUrl>) — <what the person must judge> (about <N> min)`.

Any step that fails → drop the section, run `review-pr.sh guide <n> --skipped
skill-errored` (a `guide` warn event), and post the review without the guide.
The guide never delays or blocks a post.

**A kept guide** (`🔁 Still holds`, or any state other than `built` once a
guide is published) is not rebuilt. With a stored page, steps 2–6 run with
`--findings <file> --kept` in every round, whatever the triage: the stored
page gets this round's notes block and replaces the same artifact's version,
so the link never shows stale notes. Its marker keeps the SHA
the page was built at, so the next gate compares against what the page
shows. With no stored page the
section only links the recorded URL and names the SHA it describes.
This refresh is upkeep of a published page, not a review-content call: the
agent still decides the triage, the findings and the verdict.

**Retention** — the prune deletes the guide with the PR's other state
([review-bookkeeping.md](review-bookkeeping.md) → **Pruning**).

## Self-check

- First published only under a `needs-human` triage or the `guide_label`,
  then brought up to date in every round, recorded with `review-pr.sh guide`
  before the post, and its section dropped on every other outcome.
- Every review note on the page names its author; the page judges none.
