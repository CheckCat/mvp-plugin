# Fix — Task {{TASK_ID}}

You are fixing review findings for task {{TASK_ID}} in a TARGET PROJECT —
not this plugin's own repository.

## Findings To Fix

```json
{{FINDINGS}}
```

Shape: `[{"severity","file","line","quote","summary"}]` — one entry per
finding raised in review.

## Try To Refute Each Finding First

A review finding is an argument, not a fact. Measured on this pipeline: of
five findings a strong independent audit raised against already-shipped
code, **two did not survive verification** — and during a live run two more
had to be overruled by the operator after a full fix round had already been
spent on them. Applying a wrong "fix" is worse than applying none: it
changes working code to satisfy a claim nobody checked.

So for EVERY finding, before you touch anything:

1. Read the actual code at `file`/`line` and confirm the `quote` is really
   there and really means what the `summary` says.
2. Try to construct the concrete execution path that makes the defect
   happen — real inputs, real call sites, real configuration. Search for the
   callers if the claim depends on how the code is used.
3. If you cannot construct that path, the finding is **refuted**. Say so
   with the evidence; do not "fix it anyway to be safe".

Refuting is a legitimate outcome, not an escape hatch, and it is not your
decision alone: a separate re-review stage adjudicates your refutation
against the code. Argue it as if to a sceptic — an unsupported "I don't
think this is a problem" will be rejected and the task parked.

Common shapes of a false finding, all seen in practice: the flagged code
path has no caller today; a dependency the reviewer did not recognise is
legitimate; the "unsafe" default is unreachable given how the object is
constructed; the diff line quoted was not written by this task.

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
bash .mvp/ci-mirror.sh
```

until it exits 0. You do NOT `git commit` — the pipeline's finalize step
commits for you.

## Report

Append a fix entry to `{{REPORT_PATH}}` — do not overwrite the
implementer's original report. For each finding, one of:

- **fixed** — what you changed, and the `ci-mirror.sh` command plus result.
- **refuted** — the evidence: what you read, why the described path cannot
  happen, and what would have to be true for the finding to hold. The
  re-review stage judges this section, so it must stand on its own without
  your context.

Every finding must appear under exactly one of those. Silence on a finding
is treated as an unfixed finding and parks the task.

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

"I refuted it" is NOT `BLOCKED`. A refutation is normal, reported work:
finish the run, write the evidence into the report, and report `DONE` (or
`DONE_WITH_CONCERNS`). Reserve `BLOCKED` for something that physically
stops you, like a fix that needs a file outside `{{BOUNDARY}}`.

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
- `{{REPORT_PATH}}` — `.mvp/reports/task-{{TASK_ID}}.md`
