#!/usr/bin/env bash
# queue-check.sh [queue-file]
#
# Deterministic pre-finalize check for the mvp:clarify skill. Run from the
# TARGET PROJECT root (not this plugin repo). Single-line JSON contract on
# every exit path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1.
#
# <queue-file> defaults to docs/product/clarify-queue.jsonl. A missing file
# is treated as an empty queue (ok:true, all counts 0) — zero findings is a
# valid clarify outcome (see SKILL.md anti-patterns), not an error state.
#
# What it checks, in order (each is a distinct failure mode with its own
# `data` shape — see below):
#   1. Every JSONL line parses. A malformed line fails fast with the 1-based
#      line number; nothing downstream (invariant check, counts, state.json)
#      runs on unparseable data.
#   2. The options[0] === recommended invariant holds for EVERY record,
#      regardless of status. This is the contract the self-critique pass
#      (Step 4 of SKILL.md) must leave behind: recommended is finalized
#      before a record ever reaches the queue file, so the invariant is not
#      conditional on being answered/applied yet.
#   3. No answered_human/answered_auto record is left unapplied. This is the
#      actual finalize gate: the skill translates an answer into a brief
#      edit and flips status -> applied (Step 7); if a crash or an early
#      "chinu, ne kommit'" fix cycle skips that flip, queue-check.sh must
#      catch it before finalize.sh commits the queue file.
#
# state.json counters (written via lib/state.sh, skipped entirely if check
# 1 or 2 fails — do not let unparseable/invalid data produce trustworthy-
# looking counters; a state.sh write that FAILS is itself an ok:false outcome
# of this script, never a silent no-op: gate.sh reads these counters to admit
# mvp:bootstrap, so a swallowed write means the gate judges stale data):
#   pending_critical      = count of records: status=="pending" AND severity=="critical"
#   pending_total         = count of records: status=="pending" (any severity)
#   auto_closed_critical  = count of records: severity=="critical" AND
#                            status IN {"answered_auto","applied"} AND
#                            source=="auto"
#     Counting rule, spelled out: `source` records HOW a record was
#     answered ("auto" | "human"), set once when it leaves "pending" (Step 6
#     of SKILL.md) and never rewritten by the later answered_* -> applied
#     transition (Step 7). So a critical record answered by the operator
#     (source=human) that later gets applied does NOT count here, even
#     though its status is indistinguishable from an auto-closed one at that
#     point — only `source` tells them apart. Both answered_auto AND
#     applied statuses count (not just answered_auto) because a fully
#     applied auto-closed record is still, causally, auto-closed; excluding
#     it the moment Step 7 flips its status would make the metric drop to 0
#     by the time anyone reads it, which defeats the point of tracking it.
#
# Exit-path data shapes:
#   check 1 fails -> data: null
#   check 2 fails -> data: {"invariant_violations": [ids]}
#   check 3 fails or success -> data: {"unapplied":[ids],"counts":{
#     "critical":N,"medium":N,"low":N,"pending_critical":N,"pending_medium":N,
#     "pending_low":N,"pending_total":N}}
#     counts.critical/medium/low are TOTAL records of that severity
#     regardless of status (audit totals); pending_critical/pending_medium/
#     pending_low/pending_total count only status=="pending" records, broken
#     down by severity plus the aggregate. pending_medium/pending_low exist
#     so SKILL.md's Step 5 mode-selection summary can show accurate
#     per-severity remaining-work counts even on resume (where some records
#     may already be answered/applied, so the plain totals would overstate
#     what's left) — only pending_critical/pending_total are mirrored into
#     state.json (see above); pending_medium/pending_low are stdout-only,
#     consumed by the skill at Step 5, not persisted.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_sh="$here/../../../lib/state.sh"

USAGE="usage: queue-check.sh [queue-file]"

emit_result() {
  QC_OK="$1" QC_REASON="$2" QC_HINT="$3" QC_DATA="$4" python3 -c '
import json, os
ok = os.environ["QC_OK"] == "true"
reason = os.environ.get("QC_REASON") or None
hint = os.environ.get("QC_HINT") or None
data_raw = os.environ.get("QC_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint] [data-json]
  emit_result false "$1" "${2:-}" "${3:-}"
  exit 1
}

# state_set <key> <value> — write one state.json counter through lib/state.sh.
# A failure here is REPORTED, never swallowed: these counters are what
# gate.sh reads to decide whether mvp:bootstrap may start, so a silently
# failed write (no state.json yet, unwritable dir, broken JSON) would leave
# the gate reading a stale — or absent — pending_critical while queue-check
# still printed ok:true. Fails the whole check with state.sh's own last
# output as the reason.
state_set() { # <key> <value>
  local out
  if ! out="$("$state_sh" set "$1" "$2" 2>&1)"; then
    fail "state.sh set $1 failed: $(printf '%s' "$out" | tail -n 1 | head -c 300)" \
      "run lib/state.sh init in the project root (and check .claude/state is writable), then rerun queue-check.sh"
  fi
}

if [ $# -gt 1 ]; then
  fail "unexpected argument: $2" "$USAGE"
fi

QUEUE="${1:-docs/product/clarify-queue.jsonl}"

if [ ! -f "$QUEUE" ]; then
  ZERO='{"unapplied":[],"counts":{"critical":0,"medium":0,"low":0,"pending_critical":0,"pending_medium":0,"pending_low":0,"pending_total":0}}'
  state_set pending_critical 0
  state_set pending_total 0
  state_set auto_closed_critical 0
  emit_result true "" "" "$ZERO"
  exit 0
fi

AUX_OUT="$(mktemp)"
CONTRACT_OUT="$(mktemp)"
trap 'rm -f "$AUX_OUT" "$CONTRACT_OUT"' EXIT

QC_QUEUE="$QUEUE" QC_AUX_OUT="$AUX_OUT" python3 -c '
import json, os, sys

queue_path = os.environ["QC_QUEUE"]
aux_out = os.environ["QC_AUX_OUT"]


def emit(ok, reason, hint, data):
    print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))


records = []
with open(queue_path, "r", encoding="utf-8") as f:
    for lineno, raw in enumerate(f, start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError as e:
            emit(
                False,
                f"malformed JSONL at line {lineno}: {e}",
                "fix or remove the offending line in the queue file, then rerun queue-check.sh",
                None,
            )
            sys.exit(1)

violations = []
for r in records:
    options = r.get("options") or []
    recommended = r.get("recommended")
    if not options or options[0] != recommended:
        violations.append(r.get("id"))

if violations:
    emit(
        False,
        f"options[0] != recommended for {len(violations)} record(s)",
        "fix options[0] to equal recommended for the listed record ids, then rerun queue-check.sh",
        {"invariant_violations": violations},
    )
    sys.exit(1)

SEVERITIES = ("critical", "medium", "low")
counts = {s: 0 for s in SEVERITIES}
pending_by_severity = {s: 0 for s in SEVERITIES}
pending_total = 0
auto_closed_critical = 0
unapplied = []

for r in records:
    sev = r.get("severity")
    status = r.get("status")
    source = r.get("source")
    if sev in counts:
        counts[sev] += 1
    if status == "pending":
        pending_total += 1
        if sev in pending_by_severity:
            pending_by_severity[sev] += 1
    if status in ("answered_human", "answered_auto"):
        unapplied.append(r.get("id"))
    if sev == "critical" and status in ("answered_auto", "applied") and source == "auto":
        auto_closed_critical += 1

data = {
    "unapplied": unapplied,
    "counts": {
        "critical": counts["critical"],
        "medium": counts["medium"],
        "low": counts["low"],
        "pending_critical": pending_by_severity["critical"],
        "pending_medium": pending_by_severity["medium"],
        "pending_low": pending_by_severity["low"],
        "pending_total": pending_total,
    },
}

with open(aux_out, "w", encoding="utf-8") as f:
    json.dump(
        {
            "pending_critical": pending_by_severity["critical"],
            "pending_total": pending_total,
            "auto_closed_critical": auto_closed_critical,
        },
        f,
    )

if unapplied:
    emit(
        False,
        f"{len(unapplied)} record(s) answered but not applied",
        "apply the listed answers to the brief and set status=applied for each, then rerun queue-check.sh",
        data,
    )
    sys.exit(1)

emit(True, None, None, data)
sys.exit(0)
' >"$CONTRACT_OUT"
PY_EXIT=$?

# state.json is only updated when the python pass reached the counting stage
# (AUX_OUT non-empty) — check 1/2 failures above never write it, by design.
if [ -s "$AUX_OUT" ]; then
  PC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_critical"])' "$AUX_OUT")"
  PT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_total"])' "$AUX_OUT")"
  AC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auto_closed_critical"])' "$AUX_OUT")"
  state_set pending_critical "$PC"
  state_set pending_total "$PT"
  state_set auto_closed_critical "$AC"
fi

cat "$CONTRACT_OUT"
exit "$PY_EXIT"
