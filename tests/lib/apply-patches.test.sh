#!/usr/bin/env bash
# Tests for lib/apply-patches.py
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
applier="$repo_root/lib/apply-patches.py"

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

new_git_dir() {
  local d
  d="$(mktemp -d -p "$tmproot")"
  (cd "$d" && git init -q && git config user.email test@test.local && git config user.name test)
  printf '%s' "$d"
}

checksum() { # <file> -> stable checksum
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

run_applier() { # <projectdir> <patches-json-relpath> [--stage] -> sets A_OUT A_EXIT
  if [ "${3:-}" = "--stage" ]; then
    A_OUT="$(cd "$1" && python3 "$applier" "$2" --stage 2>/tmp/mvp-apply-test-err)"
  else
    A_OUT="$(cd "$1" && python3 "$applier" "$2" 2>/tmp/mvp-apply-test-err)"
  fi
  A_EXIT=$?
}

# --- (a) unique search -> applied; with --stage, file ends up staged -------

da="$(new_git_dir)"
printf 'hello world\nsecond line\n' >"$da/target.txt"
git -C "$da" add target.txt && git -C "$da" commit -q -m "chore: seed"
cat >"$da/patches.json" <<'EOF'
[{"file": "target.txt", "search": "hello world", "replace": "hello there"}]
EOF
run_applier "$da" patches.json --stage
assert_eq "(a) exit code" "0" "$A_EXIT"
assert_eq "(a) ok:true" "True" "$(json_field "$A_OUT" 'd["ok"]')"
assert_eq "(a) applied list" "['target.txt']" "$(json_field "$A_OUT" 'd["data"]["applied"]')"
assert_eq "(a) failed list empty" "[]" "$(json_field "$A_OUT" 'd["data"]["failed"]')"
assert_eq "(a) file content replaced" "hello there" "$(head -n1 "$da/target.txt")"
staged="$(git -C "$da" diff --cached --name-only)"
assert_eq "(a) file staged after --stage" "target.txt" "$staged"

# --- (a2) same run without --stage -> patched but NOT staged ----------------

da2="$(new_git_dir)"
printf 'hello world\n' >"$da2/target.txt"
git -C "$da2" add target.txt && git -C "$da2" commit -q -m "chore: seed"
cat >"$da2/patches.json" <<'EOF'
[{"file": "target.txt", "search": "hello world", "replace": "bye world"}]
EOF
run_applier "$da2" patches.json
assert_eq "(a2) exit code" "0" "$A_EXIT"
assert_eq "(a2) file content replaced" "bye world" "$(head -n1 "$da2/target.txt")"
staged2="$(git -C "$da2" diff --cached --name-only)"
assert_eq "(a2) file NOT staged without --stage" "" "$staged2"

# --- (b) search occurs twice -> untouched byte-for-byte, reason ambiguous --

db="$(new_git_dir)"
printf 'dup dup end\n' >"$db/target.txt"
before_sum="$(checksum "$db/target.txt")"
cat >"$db/patches.json" <<'EOF'
[{"file": "target.txt", "search": "dup", "replace": "single"}]
EOF
run_applier "$db" patches.json
assert_eq "(b) exit code" "1" "$A_EXIT"
assert_eq "(b) ok:false" "False" "$(json_field "$A_OUT" 'd["ok"]')"
assert_eq "(b) failed[0].file" "target.txt" "$(json_field "$A_OUT" 'd["data"]["failed"][0]["file"]')"
assert_eq "(b) failed[0].reason" "ambiguous" "$(json_field "$A_OUT" 'd["data"]["failed"][0]["reason"]')"
assert_eq "(b) applied empty" "[]" "$(json_field "$A_OUT" 'd["data"]["applied"]')"
after_sum="$(checksum "$db/target.txt")"
assert_eq "(b) file untouched byte-for-byte (checksum)" "$before_sum" "$after_sum"

# --- (c) search absent -> not-found -----------------------------------------

dc="$(new_git_dir)"
printf 'nothing to see here\n' >"$dc/target.txt"
before_sum_c="$(checksum "$dc/target.txt")"
cat >"$dc/patches.json" <<'EOF'
[{"file": "target.txt", "search": "absent-string", "replace": "x"}]
EOF
run_applier "$dc" patches.json
assert_eq "(c) exit code" "1" "$A_EXIT"
assert_eq "(c) ok:false" "False" "$(json_field "$A_OUT" 'd["ok"]')"
assert_eq "(c) failed[0].reason" "not-found" "$(json_field "$A_OUT" 'd["data"]["failed"][0]["reason"]')"
after_sum_c="$(checksum "$dc/target.txt")"
assert_eq "(c) file untouched byte-for-byte (checksum)" "$before_sum_c" "$after_sum_c"

# --- (d) argv guard: malformed JSON -> contract JSON, no traceback ---------

dd="$(new_git_dir)"
printf '{not valid json' >"$dd/patches.json"
run_applier "$dd" patches.json
assert_eq "(d) exit code" "1" "$A_EXIT"
assert_eq "(d) ok:false" "False" "$(json_field "$A_OUT" 'd["ok"]')"
if grep -qi "traceback" /tmp/mvp-apply-test-err; then
  echo "FAIL: (d) traceback leaked to stderr" >&2
  fail=1
fi
lines_d="$(printf '%s' "$A_OUT" | wc -l | tr -d ' ')"
assert_eq "(d) stdout is single-line JSON" "0" "$lines_d"

# --- (e) argv guard: missing patches.json -> ok:false, no traceback --------

de="$(new_git_dir)"
run_applier "$de" does-not-exist.json
assert_eq "(e) exit code" "1" "$A_EXIT"
assert_eq "(e) ok:false" "False" "$(json_field "$A_OUT" 'd["ok"]')"
if grep -qi "traceback" /tmp/mvp-apply-test-err; then
  echo "FAIL: (e) traceback leaked to stderr" >&2
  fail=1
fi

# --- (f) argv guard: wrong shape (not a list) -> ok:false, no traceback ----

df="$(new_git_dir)"
printf '{"file": "a", "search": "b", "replace": "c"}' >"$df/patches.json"
run_applier "$df" patches.json
assert_eq "(f) exit code" "1" "$A_EXIT"
assert_eq "(f) ok:false" "False" "$(json_field "$A_OUT" 'd["ok"]')"
if grep -qi "traceback" /tmp/mvp-apply-test-err; then
  echo "FAIL: (f) traceback leaked to stderr" >&2
  fail=1
fi

# --- (g) same-file sequential: 2nd patch on same file fails -> 1st stands --

dg="$(new_git_dir)"
printf 'alpha beta gamma\n' >"$dg/target.txt"
git -C "$dg" add target.txt && git -C "$dg" commit -q -m "chore: seed"
cat >"$dg/patches.json" <<'EOF'
[
  {"file": "target.txt", "search": "alpha", "replace": "ALPHA"},
  {"file": "target.txt", "search": "not-there", "replace": "x"}
]
EOF
run_applier "$dg" patches.json --stage
assert_eq "(g) exit code" "1" "$A_EXIT"
assert_eq "(g) ok:false" "False" "$(json_field "$A_OUT" 'd["ok"]')"
assert_eq "(g) first patch applied (stands)" "ALPHA beta gamma" "$(head -n1 "$dg/target.txt")"
assert_eq "(g) applied list has target.txt" "['target.txt']" "$(json_field "$A_OUT" 'd["data"]["applied"]')"
assert_eq "(g) failed[0].reason" "not-found" "$(json_field "$A_OUT" 'd["data"]["failed"][0]["reason"]')"
staged_g="$(git -C "$dg" diff --cached --name-only)"
assert_eq "(g) dirty-but-patched file still staged with --stage" "target.txt" "$staged_g"

# --- (h) missing patch file on disk -> not-found, other patches unaffected -

dh="$(new_git_dir)"
printf 'only file\n' >"$dh/present.txt"
before_sum_h="$(checksum "$dh/present.txt")"
cat >"$dh/patches.json" <<'EOF'
[{"file": "missing.txt", "search": "x", "replace": "y"}]
EOF
run_applier "$dh" patches.json
assert_eq "(h) exit code" "1" "$A_EXIT"
assert_eq "(h) failed[0].reason" "not-found" "$(json_field "$A_OUT" 'd["data"]["failed"][0]["reason"]')"
after_sum_h="$(checksum "$dh/present.txt")"
assert_eq "(h) unrelated file untouched" "$before_sum_h" "$after_sum_h"

exit $fail
