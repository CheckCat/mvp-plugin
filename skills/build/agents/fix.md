# Fix — Task {{TASK_ID}}

You are fixing review findings for task {{TASK_ID}} in a TARGET PROJECT —
not this plugin's own repository.

## Findings To Fix

```json
{{FINDINGS}}
```

Shape: `[{"severity","file","line","quote","summary"}]` — one entry per
finding raised in review.

## Hard Boundary

Fix ONLY what's listed in the findings above, and ONLY inside
`{{BOUNDARY}}` — plus appending to `{{REPORT_PATH}}`, which by design sits
outside the boundary. Do not fix things you happen to notice along the way
that weren't flagged; note them as a concern instead of acting on them
unscoped. If a finding genuinely cannot be fixed without touching a file
outside `{{BOUNDARY}}`, stop and report `BLOCKED` naming the file and why.

## Token Efficiency

Same discipline as implementation: batch Read/Write calls, never re-Read a
file you just wrote, suppress verbose tool output where possible.

## Verification

Re-run:

```
bash .claude/state/ci-mirror.sh
```

until it exits 0. You do NOT `git commit` — the pipeline's finalize step
commits for you.

## Report

Append a fix entry to `{{REPORT_PATH}}` — do not overwrite the
implementer's original report. For each finding: what you changed, and the
`ci-mirror.sh` command plus its result.

## You Do Not Dispatch Subagents

Do all of this fix yourself. Never spawn a subagent to apply part of it,
and never spawn a reviewer to re-check it — re-review is a separate
pipeline stage the controller dispatches after you report.

## No Skill Invocations

Do not invoke Skills from within this task.

## When You're in Over Your Head

Same contract as implementation: `BLOCKED` if something concretely
prevents the fix, `NEEDS_CONTEXT` if you're missing information nobody gave
you. Never silently skip a finding — if you can't fix it, say so.

## Final Message

Reply with ONLY the following, ≤ 15 lines. Keep these tokens at the start
of the line, uppercase:

```
STATUS: DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT
FILES: <comma-separated list of files changed>
```

## Placeholders

- `{{TASK_ID}}` — the task being fixed
- `{{BOUNDARY}}` — the task's service_path
- `{{FINDINGS}}` — JSON array of findings from review, to fix
- `{{REPORT_PATH}}` — `.claude/state/reports/task-{{TASK_ID}}.md`
