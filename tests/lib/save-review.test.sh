#!/usr/bin/env bash
# Tests for lib/save-review.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
#
# What is actually being defended here: the reviewer's reply is the gate's only
# evidence, and for weeks it was written nowhere. The claim "0 findings across
# 28 reviews" survived that long precisely because no artifact could contradict
# it. So the properties that matter are (a) the reply lands on disk verbatim,
# (b) polls accumulate instead of overwriting each other, and (c) an empty or
# malformed reply is recorded AS an empty reply rather than silently skipped.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
sr="$repo_root/lib/save-review.sh"

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

assert_contains() {
  local desc="$1" needle="$2" file="$3"
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL: $desc — [$needle] not found in $file" >&2
    fail=1
  fi
}

ok_of() { # <json-line> -> true|false
  printf '%s' "$1" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["ok"]).lower())'
}

work="$tmproot/project"
mkdir -p "$work"
cd "$work" || exit 1

# --- happy path: three polls accumulate into one file ------------------------
out1="$(bash "$sr" 021 "reviewer-021-1" "VERDICT: approve
CANNOT_VERIFY: none
FINDINGS: []" | tail -1)"
assert_eq "first poll ok" "true" "$(ok_of "$out1")"

out2="$(bash "$sr" 021 "reviewer-021-2" 'VERDICT: request-changes
FINDINGS: [{"severity":"bug","file":"a.py","line":7}]' | tail -1)"
assert_eq "second poll ok" "true" "$(ok_of "$out2")"

path=".mvp/review/task-021.verdicts.md"
[ -f "$path" ] || { echo "FAIL: $path was not created" >&2; fail=1; }

assert_contains "first poll's label is present" "## reviewer-021-1" "$path"
assert_contains "second poll's label is present" "## reviewer-021-2" "$path"
assert_contains "a verdict line survives verbatim" "VERDICT: request-changes" "$path"
assert_contains "the findings JSON survives verbatim" '{"severity":"bug","file":"a.py","line":7}' "$path"
assert_eq "appending never drops the earlier poll" "2" "$(grep -c '^## reviewer-021' "$path")"

# --- an empty reply is recorded as an empty reply, not skipped ---------------
# A dead dispatch returns null; "the reviewer said nothing" and "nobody asked
# it" must not look the same on disk.
out3="$(bash "$sr" 021 "reviewer-021-3" "" | tail -1)"
assert_eq "empty reply is still ok" "true" "$(ok_of "$out3")"
assert_contains "empty reply is recorded explicitly" "(no reply" "$path"
assert_eq "empty reply still gets its own section" "3" "$(grep -c '^## reviewer-021' "$path")"

# --- prose in CANNOT_VERIFY survives ----------------------------------------
# Measured 3 times in 84 replies: the reviewer describes a real defect in the
# CANNOT_VERIFY line while its own FINDINGS array is empty. Losing that prose
# loses the defect.
bash "$sr" 020 "reviewer-020-2" "VERDICT: request-changes
CANNOT_VERIFY: whether DailyPlan snapshots successful_day_threshold_percent — if it does not, a mid-day change decides an already-running day
FINDINGS: []" >/dev/null
assert_contains "CANNOT_VERIFY prose survives" "a mid-day change decides an already-running day" ".mvp/review/task-020.verdicts.md"

# --- shell-hostile content is content, not syntax ---------------------------
bash "$sr" 022 "reviewer-022-1" 'VERDICT: approve
FINDINGS: []
note: `id` $HOME "quoted" '"'"'single'"'"' ; rm -rf / && echo pwned' >/dev/null
assert_contains "backticks survive as text" '`id`' ".mvp/review/task-022.verdicts.md"
assert_contains "a semicolon-and-rm injection stays text" "; rm -rf / && echo pwned" ".mvp/review/task-022.verdicts.md"
[ -e "$work/pwned" ] && { echo "FAIL: injection executed" >&2; fail=1; }

# --- separate tasks get separate files --------------------------------------
assert_eq "task 021 has its own file" "1" "$([ -f .mvp/review/task-021.verdicts.md ] && echo 1 || echo 0)"
assert_eq "task 020 has its own file" "1" "$([ -f .mvp/review/task-020.verdicts.md ] && echo 1 || echo 0)"

# --- argument validation fails closed ---------------------------------------
bad_no_args="$(bash "$sr" 2>/dev/null | tail -1)"
assert_eq "no arguments is ok:false" "false" "$(ok_of "$bad_no_args")"
bash "$sr" >/dev/null 2>&1
assert_eq "no arguments exits non-zero" "1" "$?"

bad_no_label="$(bash "$sr" 021 2>/dev/null | tail -1)"
assert_eq "missing label is ok:false" "false" "$(ok_of "$bad_no_label")"

# --- --b64: the transport a RELAY AGENT cannot silently re-author -----------
# The reply is the biggest free-text blob the pipeline moves, and it reaches
# this script through an LLM asked to retype the command. Task 018 of the
# trellis run proved that retyping is not guaranteed. Here the drift would be
# silent — a mangled reply still appends — so the payload is one opaque ASCII
# token whose declared byte length must match what decodes.
b64_of() { # <text> -> "<byteLen>.<base64>"
  python3 -c '
import base64, sys
b = sys.argv[1].encode("utf-8")
print(f"{len(b)}.{base64.b64encode(b).decode()}")
' "$1"
}

hostile='VERDICT: request-changes
CANNOT_VERIFY: none — ran `npm run test:e2e` myself; $HOME "quoted" '"'"'single'"'"' ; rm -rf /
FINDINGS: [{"severity":"bug","file":"start.ps1","line":318,"quote":"if ($id.Length -eq 0) {"}]
кириллица и эмодзи 🚀'
out_b64="$(bash "$sr" 030 "reviewer-030-1" --b64 "$(b64_of "$hostile")" | tail -1)"
assert_eq "--b64 accepted" "true" "$(ok_of "$out_b64")"
assert_contains "--b64 keeps the CANNOT_VERIFY line verbatim" "CANNOT_VERIFY: none — ran \`npm run test:e2e\` myself" ".mvp/review/task-030.verdicts.md"
assert_contains "--b64 keeps embedded JSON verbatim" '"quote":"if ($id.Length -eq 0) {"' ".mvp/review/task-030.verdicts.md"
assert_contains "--b64 keeps non-ascii verbatim" "кириллица и эмодзи 🚀" ".mvp/review/task-030.verdicts.md"
[ -e "$work/pwned" ] && { echo "FAIL: --b64 injection executed" >&2; fail=1; }

# byte-for-byte, not merely "contains": that is the whole claim of this path
printf '%s\n' "$hostile" > "$work/expected-030.txt"
python3 - "$work/expected-030.txt" .mvp/review/task-030.verdicts.md <<'PYEOF' || fail=1
import sys
expected = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
saved = open(sys.argv[2], encoding="utf-8").read()
start = saved.index("```\n") + 4
end = saved.index("\n```", start)
got = saved[start:end]
if got != expected:
    print(f"FAIL: --b64 round-trip is not byte-exact\n--- expected ---\n{expected}\n--- got ---\n{got}", file=sys.stderr)
    sys.exit(1)
PYEOF

# a relay that drops the tail must fail the command, not save a shorter reply
truncated="$(python3 -c '
import base64
b = "a reviewer reply the relay must not shorten".encode("utf-8")
print(f"{len(b)}.{base64.b64encode(b[:-7]).decode()}")
')"
out_trunc="$(bash "$sr" 031 "reviewer-031-1" --b64 "$truncated" 2>/dev/null | tail -1)"
assert_eq "truncated --b64 payload is refused" "false" "$(ok_of "$out_trunc")"
case "$out_trunc" in
  *"truncated in transit"*) ;;
  *) echo "FAIL: refusal does not name the mismatch: $out_trunc" >&2; fail=1 ;;
esac
assert_eq "a refused payload writes no verdicts file" "0" \
  "$([ -f .mvp/review/task-031.verdicts.md ] && echo 1 || echo 0)"

out_garbage="$(bash "$sr" 032 "reviewer-032-1" --b64 "not-a-payload" 2>/dev/null | tail -1)"
assert_eq "payload without a length prefix is refused" "false" "$(ok_of "$out_garbage")"
out_missing="$(bash "$sr" 033 "reviewer-033-1" --b64 2>/dev/null | tail -1)"
assert_eq "--b64 without a payload is refused" "false" "$(ok_of "$out_missing")"

# an empty reply is still a fact worth recording, in either form
out_empty="$(bash "$sr" 034 "reviewer-034-1" --b64 "$(b64_of "")" | tail -1)"
assert_eq "empty --b64 reply accepted" "true" "$(ok_of "$out_empty")"
assert_contains "empty --b64 reply recorded as such" "(no reply" ".mvp/review/task-034.verdicts.md"

# the positional form still works — operators run this by hand during recovery
bash "$sr" 035 "reviewer-035-1" "plain positional reply" >/dev/null
assert_contains "positional form still supported" "plain positional reply" ".mvp/review/task-035.verdicts.md"

exit "$fail"
