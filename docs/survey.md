# Codebase survey — the scheduled deep pass

Read this file when the worklist has a `survey_due` object, or when the
operator asks about a survey. It runs only under `survey: enabled`.

A review reads a diff. A survey reads **one area of the repository as it
stands**, and reports what a diff structurally cannot show: code nothing
reaches any more, logic that exists twice, a critical path with no test, a
convention the area stopped following, a decision record the code drifted away
from. It never reviews a PR, never posts to a PR, and never changes code.

## The worklist entry

`survey_due` — `{area, path, slug, last_surveyed, pass, history_slice,
report}`. `path` is the directory to read, `pass` is the number of this pass
over the area, and `history_slice` carries the profile's own finding history
for it ([profile.md](profile.md)) — orientation, never evidence.

Area selection is the script's and is deterministic, over the `## Modules` of
the project profile: an area never surveyed comes first, then the one surveyed
longest ago, then the one carrying the most open findings, then the first by
path. No message, comment or issue steers it.

## Procedure

1. **Prepare** — `bash "$HOME/scripts/survey.sh" prepare "$HOME/work" <slug>`.
   It clones the default branch, lists the area's files with the profile's
   noise globs applied, starts after the file the last pass stopped at,
   applies the caps and prints `{outcome, slug, path, root, sha, files[],
   after, counted:{files,lines}, caps:{files,lines}, truncated, remainder}`.
   `outcome: "empty"` (the area is gone, or holds no reviewable file) →
   record a pass with no findings and stop. `after` is that stopping file,
   `null` when the pass starts at the area's first file.
   **`truncated: true`** means the rest of the area is larger than one pass:
   `files[]` is the part to read now, `remainder` counts the files left. Read
   exactly `files[]` — the caps are the run's cost bound.
2. **Read the area.** Work file by file. The question is never "is this line
   right" but "does this area still hold together":
   - code nothing reaches, and exports nobody imports;
   - the same logic in more than one place;
   - a critical path with no test;
   - `TODO`/`FIXME` older than the area's last real change;
   - a rule of `## Conventions` the area does not follow
     ([profile.md](profile.md));
   - a `## Decisions` record the area drifted away from — cite the document;
   - a `## Docs` page that covers this area and no longer describes it.
3. **Write the findings** in the review's own form
   ([finding-form.md](finding-form.md)): severity, one-line summary, the file
   and line, and a **Fix:** line. A survey finding is anchored in the code it
   names, exactly like a review finding — the profile only said where to look.
   Nothing is reported that a review of the next PR would catch anyway.
4. **Record** — `bash "$HOME/scripts/survey.sh" record "$HOME/work" <slug>
   <findings.json>`. It appends the pass to `work/survey/<slug>.md` with the
   commit it read, the file count and the last file it read, updates the
   ledger row, and prints the pass counts.
5. **Publish** — `bash "$HOME/scripts/survey.sh" report "$HOME/work" >
   "$HOME/work/survey/report.html"`, then publish per `survey_report`
   ([config.md](config.md)), updated in place so the URL stays stable, exactly
   as the trend artifact does ([trends.md](trends.md) → **Procedure** step 4).
   `report` masks the page with `scripts/lib/redact.sh` first. Publish only
   after exit 0: exit 1 means the mask did not run, and there is no page.
   The page lists the findings only under `survey_report_findings: enabled`
   ([config.md](config.md)). The marker lives in `work/survey/LEDGER.md`
   (`<!-- survey-dam: <id> -->`).
6. **Report one line** to the chat UI, and to Slack under
   `slack_notifications: enabled`:
   `🔬 **<bot_display_name>** — surveyed <area> (<n> files): <c> 🔴 · <w> 🟡 · <s> 🟢. <url>`
   Wording per ASD-STE100 ([review.md](review.md) → **Criteria & review
   style**).

## Bounds

- **One area per run, always inside the caps.** An area over the cap is read
  across several passes: each starts after the last file the previous pass
  read (`pass-json` → `last` in `<slug>.md`), and a pass that reaches the
  area's last file ends the cycle — the next one starts at the first file.
- **Read-only on the repository.** No PR comment, no issue, no label, no
  commit. The artifact and `work/survey/` are the only outputs.
- A survey never changes a posted review, and its findings never enter the
  review ledger ([audit.md](audit.md)).
- The clone is deleted when the run ends, the same as a review's.

## Survey-run self-check

The area came from `survey_due`, never from a judgment of your own · exactly
the files `prepare` listed were read · every finding names a file and a line in
this area and carries a **Fix:** · the pass was recorded before the publish ·
the artifact was published to each configured surface, or its failure logged ·
the clone is gone · `work/` backed up last ([persistence.md](persistence.md)).
