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

For EACH finding in the list above, in order, return exactly one verdict:

- `ADDRESSED` — the diff now shows the defect resolved.
- `REFUTED` — the fix stage argued the finding was never a defect, and its
  argument holds against the code. See below — this verdict is yours to
  grant or deny, never the fix stage's to assume.
- `NOT ADDRESSED` — the defect is still present, the fix is superficial or
  incomplete, or a claimed refutation does not hold.

Do not re-litigate severity and do not invent new findings against the
original list — this pass is strictly one verdict per listed finding.

## Adjudicating A Refutation

The fix stage is required to attempt to refute each finding before changing
code, because review findings are not automatically true: measured on this
pipeline, two of five findings from a strong audit did not survive
verification. Its refutations arrive in the fix report.

You are the check on that, and you are meant to be hard to convince. Grant
`REFUTED` only when the report shows the concrete reason the described
defect cannot occur — no caller reaches that path, the value cannot take
that form given how it is constructed, the quoted line is not what this task
changed. Deny it — `NOT ADDRESSED` — when the argument is an assertion
("this looks fine", "unlikely in practice"), when it addresses a weaker
version of the finding than the one raised, or when you cannot check it
against the diff you were given.

"The code is unchanged" is not evidence either way: that is exactly what a
correct refutation and an ignored finding both look like. Judge the
argument.

## Do Not Trust the Report

Read the fix report: `.claude/state/reports/task-{{TASK_ID}}.md`. Treat
everything appended to it as an unverified claim. Verify each `ADDRESSED`
verdict against the diff itself, not against what the fix report says it
did.

The same scepticism applies to a claimed refutation — with one asymmetry
worth naming: a bad `ADDRESSED` leaves a defect in the code, while a bad
`REFUTED` leaves a defect in the code *and* records that someone looked at
it and decided it was fine. The second is the more expensive mistake.

## Out-of-Scope

If the fix introduced a NEW problem that was not one of the original
findings, list it under a separate `Out-of-Scope:` note. These do not
block — they're a note for the controller, not a gate.

## Final Message

Reply with ONLY the following, ≤ 15 lines. Keep `FINDINGS:` at the start of
the line, uppercase — the workflow greps for it:

```
FINDINGS: [{"severity":"...","file":"...","line":N,"quote":"...","summary":"...","verdict":"ADDRESSED|REFUTED|NOT ADDRESSED"}]
```

`ADDRESSED` and `REFUTED` both close a finding and let the task proceed;
`REFUTED` additionally reaches the operator as a ledger concern, so say in
`summary` what you accepted and why. Anything else parks the task.

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
