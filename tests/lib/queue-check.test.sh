#!/usr/bin/env bash
# Tests for skills/clarify/scripts/queue-check.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
qc="$repo_root/skills/clarify/scripts/queue-check.sh"
state="$repo_root/lib/state.sh"

fail=0
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    fail=1
  fi
}

json_field() { # <json> <python-expr-on-d>
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null
}

new_project_dir() {
  local d
  d="$(mktemp -d -p "$tmproot")"
  mkdir -p "$d/project_brief"
  (cd "$d" && "$state" init >/dev/null)
  printf '%s' "$d"
}

# write_queue <dir> <line>...  — writes project_brief/clarify_queue.jsonl
write_queue() {
  local dir="$1"; shift
  : >"$dir/project_brief/clarify_queue.jsonl"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$dir/project_brief/clarify_queue.jsonl"
  done
}

rec() { # id severity status source options_json recommended -> one JSON line
  python3 -c '
import json, sys
id_, sev, status, source, options_json, recommended = sys.argv[1:7]
options = json.loads(options_json)
print(json.dumps({
    "id": id_, "summary": "s", "evidence": ["e"], "severity": sev,
    "category": "stack", "options": options,
    "recommended_v1": options[0] if options else None, "rationale_v1": "r1",
    "self_critique": {"verdict": "confirmed", "reason": "r"},
    "recommended": recommended, "rationale": "r",
    "status": status, "source": (None if source == "null" else source),
}))
' "$1" "$2" "$3" "$4" "$5" "$6"
}

run_qc() { # <dir> -> sets Q_OUT Q_EXIT
  Q_OUT="$(cd "$1" && "$qc" 2>/tmp/mvp-qc-test-err)"
  Q_EXIT=$?
}

# --- (1) answered but not applied -> ok:false, unapplied lists the id -------

d1="$(new_project_dir)"
write_queue "$d1" \
  "$(rec Q-001 critical answered_human human '["X","Y"]' X)" \
  "$(rec Q-002 medium pending null '["Y","Z"]' Y)"
run_qc "$d1"
assert_eq "(1) unapplied exit code" "1" "$Q_EXIT"
assert_eq "(1) unapplied ok:false" "False" "$(json_field "$Q_OUT" 'd["ok"]')"
assert_eq "(1) unapplied lists Q-001" "['Q-001']" "$(json_field "$Q_OUT" 'd["data"]["unapplied"]')"
assert_eq "(1) unapplied counts.critical" "1" "$(json_field "$Q_OUT" 'd["data"]["counts"]["critical"]')"
assert_eq "(1) unapplied counts.medium" "1" "$(json_field "$Q_OUT" 'd["data"]["counts"]["medium"]')"
assert_eq "(1) unapplied counts.pending_critical" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_critical"]')"
assert_eq "(1) unapplied counts.pending_medium" "1" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_medium"]')"
assert_eq "(1) unapplied counts.pending_low" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_low"]')"
assert_eq "(1) unapplied counts.pending_total" "1" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_total"]')"

# --- (2) all applied -> ok:true, correct counts + auto_closed_critical -----

d2="$(new_project_dir)"
write_queue "$d2" \
  "$(rec Q-001 critical applied auto '["X"]' X)" \
  "$(rec Q-002 critical applied human '["Y"]' Y)" \
  "$(rec Q-003 medium applied auto '["Z"]' Z)" \
  "$(rec Q-004 low applied human '["W"]' W)"
run_qc "$d2"
assert_eq "(2) all applied exit code" "0" "$Q_EXIT"
assert_eq "(2) all applied ok:true" "True" "$(json_field "$Q_OUT" 'd["ok"]')"
assert_eq "(2) all applied unapplied empty" "[]" "$(json_field "$Q_OUT" 'd["data"]["unapplied"]')"
assert_eq "(2) counts.critical" "2" "$(json_field "$Q_OUT" 'd["data"]["counts"]["critical"]')"
assert_eq "(2) counts.medium" "1" "$(json_field "$Q_OUT" 'd["data"]["counts"]["medium"]')"
assert_eq "(2) counts.low" "1" "$(json_field "$Q_OUT" 'd["data"]["counts"]["low"]')"
assert_eq "(2) counts.pending_critical" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_critical"]')"
assert_eq "(2) counts.pending_medium" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_medium"]')"
assert_eq "(2) counts.pending_low" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_low"]')"
assert_eq "(2) counts.pending_total" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_total"]')"

# state.json side effects
sc_out="$(cd "$d2" && "$state" get pending_critical)"
assert_eq "(2) state pending_critical" "0" "$(json_field "$sc_out" 'd["data"]["value"]')"
st_out="$(cd "$d2" && "$state" get pending_total)"
assert_eq "(2) state pending_total" "0" "$(json_field "$st_out" 'd["data"]["value"]')"
# auto_closed_critical: only Q-001 (critical, applied, source=auto). Q-002 is
# critical+applied but source=human — must NOT count.
ac_out="$(cd "$d2" && "$state" get auto_closed_critical)"
assert_eq "(2) state auto_closed_critical" "1" "$(json_field "$ac_out" 'd["data"]["value"]')"

# --- (3) broken invariant options[0] != recommended -> ok:false ------------

d3="$(new_project_dir)"
write_queue "$d3" \
  "$(rec Q-001 critical pending null '["A","B"]' B)"
run_qc "$d3"
assert_eq "(3) invariant violation exit code" "1" "$Q_EXIT"
assert_eq "(3) invariant violation ok:false" "False" "$(json_field "$Q_OUT" 'd["ok"]')"
assert_eq "(3) invariant violation lists Q-001" "['Q-001']" "$(json_field "$Q_OUT" 'd["data"]["invariant_violations"]')"

# --- (4) malformed JSONL line -> contract error, no traceback --------------

d4="$(new_project_dir)"
write_queue "$d4" \
  "$(rec Q-001 critical pending null '["A"]' A)" \
  "{this is not json"
run_qc "$d4"
assert_eq "(4) malformed line exit code" "1" "$Q_EXIT"
assert_eq "(4) malformed line ok:false" "False" "$(json_field "$Q_OUT" 'd["ok"]')"
if echo "$Q_OUT" | grep -qi "traceback"; then
  echo "FAIL: (4) malformed line output contains a Python traceback: $Q_OUT" >&2
  fail=1
fi
if ! echo "$Q_OUT" | grep -q "line 2"; then
  echo "FAIL: (4) malformed line reason doesn't mention 'line 2': $Q_OUT" >&2
  fail=1
fi

# --- (5) missing queue file -> ok:true, all counts zero ---------------------

d5="$(new_project_dir)"
run_qc "$d5"
assert_eq "(5) missing file exit code" "0" "$Q_EXIT"
assert_eq "(5) missing file ok:true" "True" "$(json_field "$Q_OUT" 'd["ok"]')"
assert_eq "(5) missing file counts.critical" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["critical"]')"
assert_eq "(5) missing file counts.pending_medium" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_medium"]')"
assert_eq "(5) missing file counts.pending_low" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_low"]')"
assert_eq "(5) missing file counts.pending_total" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_total"]')"
sc5_out="$(cd "$d5" && "$state" get pending_critical)"
assert_eq "(5) missing file state pending_critical" "0" "$(json_field "$sc5_out" 'd["data"]["value"]')"

# --- (5b) resume mix: some records already answered/applied, some still
#          pending across different severities -> pending_medium/pending_low
#          must reflect ONLY the remaining pending ones, not the totals
#          (this is the case Step 5 of SKILL.md relies on after a resume).

d5b="$(new_project_dir)"
write_queue "$d5b" \
  "$(rec Q-001 critical applied auto '["A"]' A)" \
  "$(rec Q-002 medium pending null '["B","C"]' B)" \
  "$(rec Q-003 medium pending null '["D","E"]' D)" \
  "$(rec Q-004 low applied human '["F"]' F)" \
  "$(rec Q-005 low pending null '["G"]' G)"
run_qc "$d5b"
assert_eq "(5b) resume mix exit code" "0" "$Q_EXIT"
assert_eq "(5b) resume mix counts.medium (total)" "2" "$(json_field "$Q_OUT" 'd["data"]["counts"]["medium"]')"
assert_eq "(5b) resume mix counts.low (total)" "2" "$(json_field "$Q_OUT" 'd["data"]["counts"]["low"]')"
assert_eq "(5b) resume mix counts.pending_critical" "0" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_critical"]')"
assert_eq "(5b) resume mix counts.pending_medium" "2" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_medium"]')"
assert_eq "(5b) resume mix counts.pending_low" "1" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_low"]')"
assert_eq "(5b) resume mix counts.pending_total" "3" "$(json_field "$Q_OUT" 'd["data"]["counts"]["pending_total"]')"

# --- (6) argv guard: unexpected extra argument -> ok:false, usage hint ------

d6="$(new_project_dir)"
Q_OUT="$(cd "$d6" && "$qc" project_brief/clarify_queue.jsonl extra-arg 2>/tmp/mvp-qc-test-err)"
Q_EXIT=$?
assert_eq "(6) argv guard exit code" "1" "$Q_EXIT"
assert_eq "(6) argv guard ok:false" "False" "$(json_field "$Q_OUT" 'd["ok"]')"
if ! echo "$Q_OUT" | grep -q "usage"; then
  echo "FAIL: (6) argv guard hint missing usage: $Q_OUT" >&2
  fail=1
fi

# --- (7) every output is single-line valid JSON -----------------------------

lines="$(printf '%s' "$Q_OUT" | wc -l | tr -d ' ')"
assert_eq "(7) output is single line" "0" "$lines"

exit $fail
