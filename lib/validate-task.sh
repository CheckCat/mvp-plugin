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
#   1. ci      — execute .mvp/ci-mirror.sh (a plain list of
#                commands, run via `bash -e` so the FIRST failing command
#                aborts the rest, giving deterministic "first failure"
#                semantics even if the mirror script itself has no `set -e`).
#                Missing file -> its own ci violation.
#   2. boundary — every file changed in the working tree (union of
#                `git diff --name-only HEAD`, `git diff --name-only --cached`,
#                and untracked files via `git ls-files --others
#                --exclude-standard`) must resolve under --boundary, under
#                .mvp, or be a project-declared BOUNDARY_EXEMPT path
#                (see below). Path containment is computed with Python's
#                os.path.relpath (not bash string-prefix matching) to avoid
#                the "app/../secret.py passes a naive `startswith('app/')`
#                check" class of bug (see task-7 report I-3 fix for the
#                precedent this follows).
#   3. declared — same changed-file set, minus anything under .mvp
#                or BOUNDARY_EXEMPT, compared against --files. ONE direction
#                only: a declared file the task never produced ->
#                missing-declared. Files the task created without the plan
#                naming them are NOT reported.
#
#                Why one-directional (2026-08-24): `files` is the planner's
#                guess, made before the code exists — a hint for
#                observability, never a contract (that is what --boundary
#                is). Measured over the vireo run, the old two-directional
#                form fired `undeclared-files` on 35 of 36 tasks — a check
#                with a 97% base rate carries no information, it just trains
#                everyone to wave the result through. Dropping that half
#                leaves the direction that still means something: the plan
#                promised an artifact and it isn't there. That fires on 20
#                of 36, and every firing is real plan-vs-reality drift.
#
#                Still non-blocking: workflow.mjs treats a violation set made
#                up only of `declared` entries as a concern (which now
#                reaches ledger.md), never a park.
#
# BOUNDARY_EXEMPT (workspace-shared artifacts, e.g. a uv-workspace root
# uv.lock that a --boundary task legitimately regenerates): lines matching
# `^BOUNDARY_EXEMPT: <path>` in .mvp/invariants.md, one exact
# relative path per line (globs are NOT supported — exact string match only).
# Missing invariants.md -> no exemptions, current behavior. Exempt paths are
# treated exactly like .mvp in both the boundary and declared
# checks (allowed outside boundary, not required to be declared — they are
# shared noise, not this task's business).
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

CI_MIRROR=".mvp/ci-mirror.sh"
CI_VIOLATION=0
CI_DETAIL=""
if [ ! -f "$CI_MIRROR" ]; then
  CI_VIOLATION=1
  CI_DETAIL="missing .mvp/ci-mirror.sh"
else
  CI_OUT="$(bash -e "$CI_MIRROR" 2>&1)"
  CI_RC=$?
  if [ "$CI_RC" -ne 0 ]; then
    CI_VIOLATION=1
    CI_DETAIL="$(printf '%s\n' "$CI_OUT" | tail -n 40)"
  fi
fi

# --- BOUNDARY_EXEMPT: read project-declared exemptions from invariants.md ----
#
# One path per line, exact-match, no globs. Missing file -> empty (no
# exemptions, current behavior). Comma-joined like FILES_CSV — same
# env-var-scalar pattern as everything else here, never shell-interpolated
# into the python source text.

EXEMPT_CSV=""
INVARIANTS=".mvp/invariants.md"
if [ -f "$INVARIANTS" ]; then
  EXEMPT_CSV="$(grep -E '^BOUNDARY_EXEMPT:[[:space:]]*' "$INVARIANTS" \
    | sed -E 's/^BOUNDARY_EXEMPT:[[:space:]]*//; s/[[:space:]]*$//' \
    | paste -sd, - 2>/dev/null)"
fi

# --- steps 2+3: boundary + declared, one python3 call -------------------------
#
# Changed files come in over stdin (NUL-delimited, deduped by union of the
# three git sources); everything else (boundary, declared csv, exempt csv,
# the ci violation computed above) comes in via env vars — never
# interpolated into the python source text. This single call also decides
# ok/exit-code so bash just relays python's exit status (pipeline exit
# status = last stage).

RESULT="$(
  {
    git diff --name-only -z HEAD 2>/dev/null
    git diff --name-only -z --cached 2>/dev/null
    git ls-files --others --exclude-standard -z 2>/dev/null
  } | CI_VIOLATION="$CI_VIOLATION" CI_DETAIL="$CI_DETAIL" \
      V_BOUNDARY="$BOUNDARY" V_FILES_CSV="$FILES_CSV" V_EXEMPT_CSV="$EXEMPT_CSV" python3 -c '
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
exempt_csv = os.environ.get("V_EXEMPT_CSV", "")
exempt = {e.strip() for e in exempt_csv.split(",") if e.strip()}

violations = []

if os.environ.get("CI_VIOLATION") == "1":
    violations.append({"check": "ci", "detail": os.environ.get("CI_DETAIL", "")})

for f in seen:
    if not (under(f, boundary) or under(f, ".mvp") or f in exempt):
        violations.append({"check": "boundary", "detail": f})

actual_excl_state = {f for f in seen if not under(f, ".mvp") and f not in exempt}

# One direction only (see the header): a file the plan promised and the task
# did not produce. The reverse — files created but not listed — is normal and
# was reported on 35 of 36 vireo tasks, which is noise, not signal.
#
# exempt is subtracted from BOTH sides. It is already out of
# actual_excl_state (line above), so without subtracting it here too, a file
# that is both declared in the task files list and BOUNDARY_EXEMPT can never
# pass: it is removed from what we saw but not from what we require. Observed
# on glotok task 001 — pyproject.toml was declared, exempt, created and
# committed, and still reported missing-declared on every run.
#
# NOTE: this python source is inside a single-quoted `python3 -c '...'`.
# No apostrophes anywhere in it, comments included.
missing_declared = sorted(declared - actual_excl_state - exempt)

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
