#!/usr/bin/env bash
# save-review.sh <task-id> <label> <raw-reply>
# save-review.sh <task-id> <label> --b64 <byteLen>.<base64>
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
#
# WHY --b64. The reply is the largest free-text blob in the pipeline (kilobytes
# of reviewer prose, code quotes and JSON) and it reaches this script through a
# RELAY AGENT that is asked to retype the command verbatim. On task 018 of the
# trellis run the relay did not retype a smaller, quoted payload — it
# re-authored the command and invented a flag. Here the same drift would be
# SILENT: a mangled reply still appends, and the artifact whose only job is to
# record what the reviewer actually said would be quietly wrong. The base64
# form gives the relay one opaque ASCII token with nothing to improve, and the
# byte-length prefix turns truncation into a refusal instead of a short file.

set -u

USAGE="usage: save-review.sh <task-id> <label> (<raw-reply> | --b64 <byteLen>.<base64>)"

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

# --b64 decodes into a FILE, not a command substitution: $(...) strips trailing
# newlines, and trimming whitespace inside a fix whose whole point is faithful
# transport would be a poor joke. The file also keeps arbitrary bytes out of
# any further shell handling.
REPLY_FILE=""
cleanup_reply_file() { [ -n "$REPLY_FILE" ] && rm -f "$REPLY_FILE" "$REPLY_FILE.err"; }
trap cleanup_reply_file EXIT

if [ "${3-}" = "--b64" ]; then
  PAYLOAD="${4-}"
  [ -n "$PAYLOAD" ] || fail "missing payload after --b64" "$USAGE"
  REPLY_FILE="$(mktemp)" || fail "cannot create a temp file"
  if ! SR_PAYLOAD="$PAYLOAD" SR_OUT="$REPLY_FILE" python3 -c '
import base64, binascii, os, re, sys
raw = os.environ["SR_PAYLOAD"]
dot = raw.find(".")
if dot <= 0:
    sys.exit("payload must be \"<byteLen>.<base64>\"")
try:
    declared = int(raw[:dot])
except ValueError:
    sys.exit("payload length prefix is not an integer")
if declared < 0:
    sys.exit("payload length prefix is negative")
b64 = raw[dot + 1:]
if re.fullmatch(r"[A-Za-z0-9+/]*={0,2}", b64) is None:
    sys.exit("payload is not base64")
try:
    data = base64.b64decode(b64, validate=True)
except (binascii.Error, ValueError):
    sys.exit("payload is not decodable base64")
if len(data) != declared:
    sys.exit(f"payload truncated in transit: declared {declared} bytes, decoded {len(data)}")
if base64.b64encode(data).decode() != b64:
    sys.exit("payload altered in transit: base64 is not canonical")
with open(os.environ["SR_OUT"], "wb") as fh:
    fh.write(data)
' 2>"$REPLY_FILE.err"; then
    DECODE_ERR="$(tail -n1 "$REPLY_FILE.err" 2>/dev/null)"
    fail "${DECODE_ERR:-cannot decode --b64 payload}" \
      "workflow.mjs builds this payload; a mismatch means the relay altered the command"
  fi
fi

OUT_DIR=".mvp/review"
OUT_PATH="$OUT_DIR/task-${TASK_ID}.verdicts.md"

mkdir -p "$OUT_DIR" || fail "cannot create $OUT_DIR"

if [ ! -f "$OUT_PATH" ]; then
  printf '# Reviewer replies: task %s\n\nRaw, unparsed. One section per poll.\n' \
    "$TASK_ID" >"$OUT_PATH" || fail "cannot write $OUT_PATH"
fi

{
  printf '\n## %s\n\n' "$LABEL"
  if [ -n "$REPLY_FILE" ]; then
    if [ -s "$REPLY_FILE" ]; then
      printf '```\n'; cat "$REPLY_FILE"; printf '\n```\n'
    else
      printf '(no reply — the dispatch returned nothing)\n'
    fi
  elif [ -z "$REPLY" ]; then
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
