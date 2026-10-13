# Visual PR artifact

Read this file when the worklist has a non-empty `artifacts_due`. Each entry is
`{number, action}`:

- **`action: "retry_unassign"`** — the PR's history file carries an
  `<!-- artifact-dam: … -->` marker, but the bot is still assigned because an
  earlier unassign failed. Retry the unassign (step 5), log the outcome as
  `PR #<n>: artifact unassign retried (<outcome>)`, generate nothing.
- **`action: "generate"`** — run the full procedure below.

Preflight emits an entry for each open non-draft PR assigned to `$BOT_LOGIN`
while `artifact_skill` is set ([config.md](config.md)), and installs
`$ARTIFACT_SKILL` from its source.

**Where it publishes:** the platform's DAM Artifact Library, via the
per-agent MCP tools (`create_artifact_upload_url` + `create_artifact`),
registered only under the owner's **"artifact library" experimental flag**.
The step is **best-effort**: tools not registered, or any sub-step erroring →
log and stop this PR. A missing DAM surface never fails the run.

> ⚠️ **Publishes to a public surface.** A `visibility:"public"` DAM artifact is
> reachable by anyone with its `shareUrl`. The explicit human assignment of
> `$BOT_LOGIN` is the gate.

## Procedure (per `generate` entry)

0. **Tools** — `create_artifact_upload_url` and `create_artifact` not
   registered this session → write
   `<!-- artifact-skip: dam-unavailable <UTC ISO-8601> -->` in
   `reviews/pr-<n>.md` right after the title heading (overwrite an existing one
   in place), log `PR #<n>: <artifact_skill> skipped (dam-unavailable)` (warn)
   and stop this PR before generating anything; `$BOT_LOGIN` stays assigned.
   Preflight offers the next `generate` 24 h after that timestamp.
1. **Generate** — invoke `$ARTIFACT_SKILL` with the PR number; the skill reads
   the PR through `gh`. Save the single self-contained HTML to
   `work/reviews/pr-artifacts/pr-<n>.html` (`mkdir -p` first). Then redact it
   before any publish:
   `. "$HOME/scripts/lib/redact.sh" && REDACTIONS=$(redact_file work/reviews/pr-artifacts/pr-<n>.html)`
   masks the credential shapes in place and prints the count; a non-zero return
   means the file is unredacted. Skill error, or a pass that did not run → log
   `skipped (skill-errored)` and stop this PR: no publish, no comment, no
   unassign.
2. **Publish** the on-disk `pr-<n>.html` to the DAM Artifact Library:
   1. `create_artifact_upload_url {file_name: "pr-<n>.html"}` →
      `{url, uploadRef}`.
   2. `curl -sS -f -X PUT -H 'Content-Type: text/html' --data-binary @work/reviews/pr-artifacts/pr-<n>.html '<url>'`.
   3. `create_artifact {title: "PR #<n> review artifact", upload_ref: "<uploadRef>", type: "html", visibility: "public"}`
      → capture `shareUrl` as `DAM_URL` and `id` as `DAM_ID`.

   Any sub-step erroring → treat the step as `skill-errored`: post no comment,
   write no marker, keep `$BOT_LOGIN` assigned for a later retry, log, and
   stop this PR here.
3. **Comment the link** in a **single** PR comment:

   ```bash
   gh pr comment <n> --repo "$REPO" --body "📊 **PR #<n> review artifact** — [DAM Artifact Library](<DAM_URL>)"
   ```
4. **Record the id** in `reviews/pr-<n>.md` right after the title heading,
   overwriting an existing marker in place: `<!-- artifact-dam: <DAM_ID> -->`.
   Delete an `<!-- artifact-skip: … -->` line.
5. **Unassign** — REST first ([review-bookkeeping.md](review-bookkeeping.md) →
   **Trigger removal**):

   ```bash
   gh api -X DELETE "repos/$REPO/issues/<n>/assignees" -f "assignees[]=$BOT_LOGIN" >/dev/null \
     || gh pr edit <n> --repo "$REPO" --remove-assignee "$BOT_LOGIN"
   ```

   A failed unassign is logged, not fatal: next run preflight emits a
   `retry_unassign` entry.
6. **Audit line (mandatory)** — to the chat UI **and** as an `artifact` event
   ([logging.md](logging.md)), which is what the weekly audit counts:
   `PR #<n>: <artifact_skill> published → DAM <DAM_ID>, <REDACTIONS> redacted`
   (info), or
   `PR #<n>: <artifact_skill> skipped (<install-failed|dam-unavailable|skill-errored>)`
   (warn). The outcome word after the skill name — `published` or `skipped` —
   is the parsed part:

   ```bash
   . "$HOME/scripts/log.sh" && LOG_JOB=review logev info artifact "PR #<n>: <artifact_skill> published → DAM <DAM_ID>, $REDACTIONS redacted"
   ```

The saved HTML is persisted `work/` state. It and the DAM artifact are
deleted by the prune step when the PR closes
([review-bookkeeping.md](review-bookkeeping.md) → **Pruning**).

## Self-check

- Redacted before the first publish, published to the DAM Artifact Library,
  one comment with the link, marker recorded.
