# Queue record schema

Load when: reading or writing `docs/product/clarify-queue.jsonl`.

One JSON object per line (JSONL). Fields, verbatim:

```
{id, summary, evidence[], severity: critical|medium|low, category, options[],
 recommended_v1, rationale_v1, self_critique:{verdict, reason}, recommended,
 rationale, status: pending|answered_human|answered_auto|applied|skipped, source}
```

| Field | Meaning |
|---|---|
| `id` | Stable identifier, e.g. `Q-001`. |
| `summary` | One sentence — what's unclear. |
| `evidence[]` | Quote(s) from the brief, or an explicit "section X is empty" — never invented. |
| `severity` | `critical` \| `medium` \| `low`. |
| `category` | Free-form finding category (e.g. `stack`, `business`, `inconsistency`). |
| `options[]` | Candidate answers. |
| `recommended_v1` | Pass 1 (formulate) recommendation. Immutable audit trail — never rewritten by Pass 2. |
| `rationale_v1` | Pass 1 rationale. Immutable, same reason. |
| `self_critique` | `{verdict: confirmed\|changed, reason}` — result of the Pass 2 refute (see `references/refute-prompt.md`). |
| `recommended` | Final recommendation after Pass 2. Equals `recommended_v1` if `verdict: confirmed`, otherwise the changed pick. |
| `rationale` | Final rationale after Pass 2. |
| `status` | `pending` \| `answered_human` \| `answered_auto` \| `applied` \| `skipped`. |
| `source` | `auto` \| `human` — how the record left `pending`. Set once, never rewritten by the later `applied` transition. |

## Invariant

**`options[0] === recommended`.** Always, for every record, regardless of status. If Pass 2 changes the recommendation, move the new pick to `options[0]` — do not leave the Pass-1 order standing. `scripts/queue-check.sh` enforces this before finalize.

## Status lifecycle

```
pending → answered_human | answered_auto → applied
pending → skipped   (only if the record became moot between sessions,
                      e.g. the operator already answered it by hand-editing the brief)
```

`queue-check.sh` fails (`unapplied`) if any record is `answered_human`/`answered_auto` and not yet `applied` — that transition is the skill's job (Step 7: apply the answer to the brief, then flip status), not automatic.
