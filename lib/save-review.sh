#!/usr/bin/env bash
# save-review.sh <task-id> <label> <raw-reply>
#
# Appends one reviewer's raw reply to .mvp/review/task-<task-id>.verdicts.md.
# Run from the TARGET PROJECT root. Single-line JSON contract on every exit
# path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1. Success: data = {"path": "<relative path>",
# "bytes": <file size after the append>}.
#
# WHY THIS FILE EXISTS. Until 2026-08-26 the reviewer's reply was parsed and
# thrown away — nothing on disk, nothing in the commit. The consequence was not
# hypothetical: the claim "0 findings across 28 reviews" stood for weeks and
# turned out to be unverifiable, because no artifact recorded what any reviewer
# had actually said. It had to be reconstructed from dispatch COUNTS in
# telemetry, which can only distinguish "some task was blocked" from "none
# was" — and the real answer was the weaker "no task was ever blocked", not
# "the reviewer found nothing". A gate whose output is not persisted cannot be
# audited afterwards, so it cannot be trusted afterwards either.
#
# The file is plain markdown rather than JSONL on purpose: a CANNOT_VERIFY line
# regularly carries a real defect in prose that the machine-readable FINDINGS
# array missed (measured: 3 times in 84 replies), and prose that a human will
# read belongs in a format a human reads. finalize.sh commits .mvp/ with the
# task, so this lands in the same commit as the package it judges.

set -u

USAGE="usage: save-review.sh <task-id> <label> <raw-reply>"

emit_result() {
  SR_OK="$1" SR_REASON="$2" SR_HINT="$3" SR_DATA="$4" python3 -c '
import json, os
ok = os.environ["SR_OK"] == "true"
reason = os.environ.get("SR_REASON") or None
hint = os.environ.get("SR_HINT") or None
data_raw = os.environ.get("SR_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() {
  emit_result false "$1" "${2:-}" ""
  exit 1
}

TASK_ID="${1:-}"
[ -n "$TASK_ID" ] || fail "missing task-id" "$USAGE"
LABEL="${2:-}"
[ -n "$LABEL" ] || fail "missing label" "$USAGE"
# The reply may legitimately be empty (a dead dispatch returns null) — record
# that fact rather than refusing to, so "the reviewer said nothing" is itself
# on disk instead of being indistinguishable from "nobody asked it".
REPLY="${3-}"

OUT_DIR=".mvp/review"
OUT_PATH="$OUT_DIR/task-${TASK_ID}.verdicts.md"

mkdir -p "$OUT_DIR" || fail "cannot create $OUT_DIR"

if [ ! -f "$OUT_PATH" ]; then
  printf '# Reviewer replies: task %s\n\nRaw, unparsed. One section per poll.\n' \
    "$TASK_ID" >"$OUT_PATH" || fail "cannot write $OUT_PATH"
fi

{
  printf '\n## %s\n\n' "$LABEL"
  if [ -z "$REPLY" ]; then
    printf '(no reply — the dispatch returned nothing)\n'
  else
    printf '```\n%s\n```\n' "$REPLY"
  fi
} >>"$OUT_PATH" || fail "cannot append to $OUT_PATH"

DATA="$(RP_PATH="$OUT_PATH" python3 -c '
import json, os
p = os.environ["RP_PATH"]
print(json.dumps({"path": p, "bytes": os.path.getsize(p)}))
')" || fail "cannot stat $OUT_PATH"

emit_result true "" "" "$DATA"
exit 0
