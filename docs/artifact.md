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
match forces it, [review-mechanics.md](review-mechanics.md) → **Summary body
format**). A `quick-check` triage publishes nothing and drops the section. A
person is the audience, so the guide needs no human trigger: the triage is the
consent the operator gave when they added the row
([ONBOARDING.md](../ONBOARDING.md) step 7).

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
2. **Findings** — `review-pr.sh guide <n> --findings <findings file>`, the
   file `post` takes: the script renders the review's open blocking findings
   into the page as **Verified by the review** — escaped, each linked to its
   line at the head SHA (a `#L` fragment only for a numeric line),
   suggestions only counted — at the template's `<!-- cg:findings -->` mark,
   in place of an earlier block. The model never writes this block, so the
   page shows exactly what the review verified. The findings text is model
   output too, so the command then takes the vetted script out, redacts and
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

**A kept guide** (`🔁 Still holds`) is not rebuilt. With a `needs-human`
triage and a stored page, steps 2–6 run with `--findings <file> --kept`: the
stored page gets this round's findings block and replaces the same artifact's
version, so the link never shows stale findings. Its marker keeps the SHA
the page was built at, so the next gate compares against what the page
shows. With no stored page the
section only links the recorded URL and names the SHA it describes.

**Retention** — the prune deletes the guide with the PR's other state
([review-bookkeeping.md](review-bookkeeping.md) → **Pruning**).

## Self-check

- Published or linked only under a `needs-human` triage or the
  `guide_label`, recorded with `review-pr.sh guide` before the post, and its
  section dropped on every other outcome.
