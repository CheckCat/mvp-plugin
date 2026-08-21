#!/usr/bin/env bash
# validate-task.sh <task-id> --boundary <path> --files <csv>
#
# Deterministic post-implementation validation for one build task. Run from
# the TARGET PROJECT root (not this plugin repo). Single-line JSON contract
# on every exit path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1. data = {"violations":[{"check":"ci|boundary|declared","detail":str}, ...]}.
# ok:true iff violations is empty.
#
# Steps (always run all three, regardless of earlier failures, so a single
# call reports everything wrong with the task at once):
#   1. ci      — execute .claude/state/ci-mirror.sh (a plain list of
#                commands, run via `bash -e` so the FIRST failing command
#                aborts the rest, giving deterministic "first failure"
#                semantics even if the mirror script itself has no `set -e`).
#                Missing file -> its own ci violation.
#   2. boundary — every file changed in the working tree (union of
#                `git diff --name-only HEAD`, `git diff --name-only --cached`,
#                and untracked files via `git ls-files --others
#                --exclude-standard`) must resolve under --boundary or under
#                .claude/state. Path containment is computed with Python's
#                os.path.relpath (not bash string-prefix matching) to avoid
#                the "app/../secret.py passes a naive `startswith('app/')`
#                check" class of bug (see task-7 report I-3 fix for the
#                precedent this follows).
#   3. declared — same changed-file set, minus anything under .claude/state,
#                compared against --files. Extra actual files -> undeclared-files;
#                extra declared files -> missing-declared.
#
# Filenames are carried NUL-delimited (git ... -z | python3, stdin) end to
# end so spaces/special characters in paths are never word-split or
# corrupted. No shell-interpolation of untrusted strings into printf/python
# source text: all dynamic values cross the bash/python boundary via env
# vars (scalars) or stdin (the file list), matching lib/gate.sh's emit
# pattern (ruling R10).

set -u

USAGE="usage: validate-task.sh <task-id> --boundary <path> --files <csv>"

# emit_result <ok:true|false> <reason> <hint> <data-json> — see lib/gate.sh.
emit_result() {
  VT_OK="$1" VT_REASON="$2" VT_HINT="$3" VT_DATA="$4" python3 -c '
import json, os
ok = os.environ["VT_OK"] == "true"
reason = os.environ.get("VT_REASON") or None
hint = os.environ.get("VT_HINT") or None
data_raw = os.environ.get("VT_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint]
  emit_result false "$1" "${2:-}" ""
  exit 1
}

# --- parse argv --------------------------------------------------------------

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  fail "missing task-id" "$USAGE"
fi
shift

BOUNDARY=""
FILES_CSV=""
HAVE_BOUNDARY=0
HAVE_FILES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --boundary)
      if [ $# -lt 2 ]; then fail "--boundary requires a value" "$USAGE"; fi
      BOUNDARY="$2"
      HAVE_BOUNDARY=1
      shift 2
      ;;
    --files)
      if [ $# -lt 2 ]; then fail "--files requires a value" "$USAGE"; fi
      FILES_CSV="$2"
      HAVE_FILES=1
      shift 2
      ;;
    *)
      fail "unexpected argument: $1" "$USAGE"
      ;;
  esac
done

if [ "$HAVE_BOUNDARY" -ne 1 ]; then
  fail "missing --boundary" "$USAGE"
fi
if [ "$HAVE_FILES" -ne 1 ]; then
  fail "missing --files" "$USAGE"
fi

# --- step 1: ci-mirror.sh -----------------------------------------------------

CI_MIRROR=".claude/state/ci-mirror.sh"
CI_VIOLATION=0
CI_DETAIL=""
if [ ! -f "$CI_MIRROR" ]; then
  CI_VIOLATION=1
  CI_DETAIL="missing .claude/state/ci-mirror.sh"
else
  CI_OUT="$(bash -e "$CI_MIRROR" 2>&1)"
  CI_RC=$?
  if [ "$CI_RC" -ne 0 ]; then
    CI_VIOLATION=1
    CI_DETAIL="$(printf '%s\n' "$CI_OUT" | tail -n 40)"
  fi
fi

# --- steps 2+3: boundary + declared, one python3 call -------------------------
#
# Changed files come in over stdin (NUL-delimited, deduped by union of the
# three git sources); everything else (boundary, declared csv, the ci
# violation computed above) comes in via env vars — never interpolated into
# the python source text. This single call also decides ok/exit-code so bash
# just relays python's exit status (pipeline exit status = last stage).

RESULT="$(
  {
    git diff --name-only -z HEAD 2>/dev/null
    git diff --name-only -z --cached 2>/dev/null
    git ls-files --others --exclude-standard -z 2>/dev/null
  } | CI_VIOLATION="$CI_VIOLATION" CI_DETAIL="$CI_DETAIL" \
      V_BOUNDARY="$BOUNDARY" V_FILES_CSV="$FILES_CSV" python3 -c '
import json, os, sys


def under(f, boundary):
    rel = os.path.relpath(os.path.normpath(f), os.path.normpath(boundary))
    return rel == "." or not rel.startswith("..")


data = sys.stdin.buffer.read()
parts = [p.decode("utf-8", "replace") for p in data.split(b"\x00") if p]
seen = []
seenset = set()
for p in parts:
    if p not in seenset:
        seenset.add(p)
        seen.append(p)

boundary = os.environ.get("V_BOUNDARY", "")
declared_csv = os.environ.get("V_FILES_CSV", "")
declared = {d.strip() for d in declared_csv.split(",") if d.strip()}

violations = []

if os.environ.get("CI_VIOLATION") == "1":
    violations.append({"check": "ci", "detail": os.environ.get("CI_DETAIL", "")})

for f in seen:
    if not (under(f, boundary) or under(f, ".claude/state")):
        violations.append({"check": "boundary", "detail": f})

actual_excl_state = {f for f in seen if not under(f, ".claude/state")}

undeclared = sorted(actual_excl_state - declared)
missing_declared = sorted(declared - actual_excl_state)

if undeclared:
    violations.append({"check": "declared", "detail": "undeclared-files: " + ", ".join(undeclared)})
if missing_declared:
    violations.append({"check": "declared", "detail": "missing-declared: " + ", ".join(missing_declared)})

ok = len(violations) == 0
print(json.dumps({"ok": ok, "reason": None, "hint": None, "data": {"violations": violations}}))
sys.exit(0 if ok else 1)
'
)"
RC=$?

printf '%s\n' "$RESULT"
exit "$RC"
