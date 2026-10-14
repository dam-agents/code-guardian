# Visual PR artifact

Read this file when the worklist has a non-empty `artifacts_due`. Each entry is
`{number, action, triggers}`. `triggers` names what asks for the artifact:
`assignee` (`$BOT_LOGIN` assigned to the PR), `label` (`artifact_label` on the
PR), or both.

- **`action: "retry_release"`** — the PR's history file carries an
  `<!-- artifact-dam: … -->` marker, but a trigger is still on the PR because
  an earlier release failed. Retry the release (step 5), log the outcome as
  `PR #<n>: artifact trigger release retried (<outcome>)`, generate nothing.
- **`action: "generate"`** — run the full procedure below.

Preflight emits an entry for each open non-draft PR with a trigger while
`artifact_skill` is set ([config.md](config.md)), and installs
`$ARTIFACT_SKILL` from its source. A GitHub App `bot_login` cannot be
assigned, so the label is its trigger ([github-access.md](github-access.md) →
**Triggers by identity**).

**Where it publishes:** the platform's DAM Artifact Library, via the
per-agent MCP tools (`create_artifact_upload_url` + `create_artifact`),
registered only under the owner's **"artifact library" experimental flag**.
The step is **best-effort**: tools not registered, or any sub-step erroring →
log and stop this PR. A missing DAM surface never fails the run.

> ⚠️ **Publishes to a public surface.** A `visibility:"public"` DAM artifact is
> reachable by anyone with its `shareUrl`. An explicit human trigger is the
> gate: the assignment of `$BOT_LOGIN` or `artifact_label`.

## Procedure (per `generate` entry)

0. **Tools** — `create_artifact_upload_url` and `create_artifact` not
   registered this session → write
   `<!-- artifact-skip: dam-unavailable <UTC ISO-8601> -->` in
   `reviews/pr-<n>.md` right after the title heading (overwrite an existing one
   in place), log `PR #<n>: <artifact_skill> skipped (dam-unavailable)` (warn)
   and stop this PR before generating anything; the triggers stay on the PR.
   Preflight offers the next `generate` 24 h after that timestamp.
1. **Generate** — invoke `$ARTIFACT_SKILL` with the PR number; the skill reads
   the PR through `gh`. Save the single self-contained HTML to
   `work/reviews/pr-artifacts/pr-<n>.html` (`mkdir -p` first). Then redact it
   before any publish:
   `. "$HOME/scripts/lib/redact.sh" && REDACTIONS=$(redact_file work/reviews/pr-artifacts/pr-<n>.html)`
   masks the credential shapes in place and prints the count; a non-zero return
   means the file is unredacted. Skill error, or a pass that did not run → log
   `skipped (skill-errored)` and stop this PR: no publish, no comment, no
   release.
2. **Publish** the on-disk `pr-<n>.html` to the DAM Artifact Library:
   1. `create_artifact_upload_url {file_name: "pr-<n>.html"}` →
      `{url, uploadRef}`.
   2. `curl -sS -f -X PUT -H 'Content-Type: text/html' --data-binary @work/reviews/pr-artifacts/pr-<n>.html '<url>'`.
   3. `create_artifact {title: "PR #<n> review artifact", upload_ref: "<uploadRef>", type: "html", visibility: "public"}`
      → capture `shareUrl` as `DAM_URL` and `id` as `DAM_ID`.

   Any sub-step erroring → treat the step as `skill-errored`: post no comment,
   write no marker, keep the triggers on the PR for a later retry, log, and
   stop this PR here.
3. **Comment the link** in a **single** PR comment:

   ```bash
   gh pr comment <n> --repo "$REPO" --body "📊 **PR #<n> review artifact** — [DAM Artifact Library](<DAM_URL>)"
   ```
4. **Record the id** in `reviews/pr-<n>.md` right after the title heading,
   overwriting an existing marker in place: `<!-- artifact-dam: <DAM_ID> -->`.
   Delete an `<!-- artifact-skip: … -->` line.
5. **Release the triggers** in `triggers` — REST first
   ([review-bookkeeping.md](review-bookkeeping.md) → **Trigger removal**).
   `assignee`:

   ```bash
   gh api -X DELETE "repos/$REPO/issues/<n>/assignees" -f "assignees[]=$BOT_LOGIN" >/dev/null \
     || gh pr edit <n> --repo "$REPO" --remove-assignee "$BOT_LOGIN"
   ```

   `label`, with the label name URL-encoded as one path segment:

   ```bash
   gh api -X DELETE "repos/$REPO/issues/<n>/labels/$(jq -rn --arg v "$ARTIFACT_LABEL" '$v | @uri')" >/dev/null
   ```

   A failed release is logged, not fatal: preflight emits a `retry_release`
   entry, which waits as bookkeeping ([worklist.md](worklist.md) → **The
   schedule gate**).
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
