# Re-Review — Task {{TASK_ID}}

You are re-reviewing task {{TASK_ID}} after a fix was applied to the
findings from its first review. This pass verdicts the original findings —
it is not a fresh review.

## Findings To Verify

```json
{{FINDINGS}}
```

Shape: `[{"severity","file","line","quote","summary"}]` — the exact
findings from the original review, unchanged.

## Diff Under Review

Read `{{PACKAGE_PATH}}` — the updated diff, now including the fix. This is
your only source; do not re-run git commands and do not crawl the wider
codebase.

## Your Job

For EACH finding in the list above, in order, decide whether it was
addressed:
- `ADDRESSED` — the diff now shows the defect resolved.
- `NOT ADDRESSED` — the defect is still present, or the fix is superficial
  or incomplete.

Do not re-litigate severity and do not invent new findings against the
original list — this pass is strictly one verdict per listed finding.

## Do Not Trust the Report

Read the fix report: `.claude/state/reports/task-{{TASK_ID}}.md`. Treat
everything appended to it as an unverified claim. Verify each `ADDRESSED`
verdict against the diff itself, not against what the fix report says it
did.

## Out-of-Scope

If the fix introduced a NEW problem that was not one of the original
findings, list it under a separate `Out-of-Scope:` note. These do not
block — they're a note for the controller, not a gate.

## Final Message

Reply with ONLY the following, ≤ 15 lines. Keep `FINDINGS:` at the start of
the line, uppercase — the workflow greps for it:

```
FINDINGS: [{"severity":"...","file":"...","line":N,"quote":"...","summary":"...","verdict":"ADDRESSED|NOT ADDRESSED"}]
```

Then, only if applicable, one `Out-of-Scope:` line with a brief note. No
other text.

## You Do Not Dispatch Subagents

Do all of this verification yourself. Never spawn a subagent to check part
of the fix, and never spawn another reviewer for a second opinion.

## No Skill Invocations

Do not invoke Skills from within this task.

## Placeholders

- `{{TASK_ID}}` — the task being re-reviewed
- `{{PACKAGE_PATH}}` — the updated review package (commits + diffstat + diff)
- `{{FINDINGS}}` — JSON array of findings from the original review, to verdict
