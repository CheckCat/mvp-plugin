#!/usr/bin/env bash
# Tests for lib/review-package.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
rp="$repo_root/lib/review-package.sh"

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

new_git_repo() {
  local dir
  dir="$(mktemp -d -p "$tmproot")"
  (cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test)
  printf '%s' "$dir"
}

# run_rp <projectdir> <arg...> -> sets RP_OUT RP_EXIT
# Also asserts, per invocation (not just once at the end), that stdout is
# exactly one line of JSON — every call site gets this check, not just the
# last one (a `for out in "$RP_OUT"` loop after all calls would silently
# only re-check the final invocation's output).
run_rp() {
  local dir="$1"
  shift
  RP_OUT="$(cd "$dir" && "$rp" "$@" 2>/tmp/mvp-rp-test-err)"
  RP_EXIT=$?
  local lines
  lines="$(printf '%s' "$RP_OUT" | wc -l | tr -d ' ')"
  if [ "$lines" != "0" ]; then
    echo "FAIL: (json) output is not single-line for args [$*]: $RP_OUT" >&2
    fail=1
  fi
}

# --- (a) two commits base..HEAD -> file has both subjects + diffstat + diff --

d_a="$(new_git_repo)"
echo 'v1' >"$d_a/app.py"
(cd "$d_a" && git add app.py && git commit -q -m "chore: root commit")
BASE_A="$(cd "$d_a" && git rev-parse HEAD)"
echo 'unrelated' >"$d_a/other.txt"
(cd "$d_a" && git add other.txt && git commit -q -m "feat: first commit")
echo 'v2' >"$d_a/app.py"
(cd "$d_a" && git add app.py && git commit -q -m "fix: second commit")

run_rp "$d_a" 001 --base "$BASE_A"

assert_eq "(a) exit code" "0" "$RP_EXIT"
assert_eq "(a) ok:true" "True" "$(json_field "$RP_OUT" 'd["ok"]')"
PATH_A="$(json_field "$RP_OUT" 'd["data"]["path"]')"
assert_eq "(a) path" ".claude/state/review/task-001.md" "$PATH_A"

FULL_PATH_A="$d_a/$PATH_A"
if [ ! -f "$FULL_PATH_A" ]; then
  echo "FAIL: (a) review file not written: $FULL_PATH_A" >&2
  fail=1
else
  CONTENT_A="$(cat "$FULL_PATH_A")"
  if ! printf '%s' "$CONTENT_A" | grep -q "first commit"; then
    echo "FAIL: (a) missing first commit subject in review file" >&2
    fail=1
  fi
  if ! printf '%s' "$CONTENT_A" | grep -q "second commit"; then
    echo "FAIL: (a) missing second commit subject in review file" >&2
    fail=1
  fi
  if ! printf '%s' "$CONTENT_A" | grep -q -- "-v1"; then
    echo "FAIL: (a) missing removed-line diff content (-v1)" >&2
    fail=1
  fi
  if ! printf '%s' "$CONTENT_A" | grep -q -- "+v2"; then
    echo "FAIL: (a) missing added-line diff content (+v2)" >&2
    fail=1
  fi
  if ! printf '%s' "$CONTENT_A" | grep -q "app.py"; then
    echo "FAIL: (a) missing diffstat filename app.py" >&2
    fail=1
  fi
fi

# --- (b) invalid base sha -> ok:false, exit 1 ---------------------------------

d_b="$(new_git_repo)"
echo 'v1' >"$d_b/app.py"
(cd "$d_b" && git add app.py && git commit -q -m "feat: only commit")

run_rp "$d_b" 001 --base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

assert_eq "(b) exit code" "1" "$RP_EXIT"
assert_eq "(b) ok:false" "False" "$(json_field "$RP_OUT" 'd["ok"]')"

# --- (c) not a git repo -> ok:false, exit 1 -----------------------------------

d_c="$(mktemp -d -p "$tmproot")"

run_rp "$d_c" 001 --base HEAD

assert_eq "(c) exit code" "1" "$RP_EXIT"
assert_eq "(c) ok:false" "False" "$(json_field "$RP_OUT" 'd["ok"]')"

# --- (d) uncommitted tracked change + untracked new file -> both appear -------
# This is the ruling this rewrite exists for: skills/build/workflow.mjs's
# implementer/fix agents never commit, so the package must show working-tree
# state (not just committed history) — both a modified tracked file AND a
# brand-new untracked file with its content inlined.

d_d="$(new_git_repo)"
echo 'v1' >"$d_d/app.py"
(cd "$d_d" && git add app.py && git commit -q -m "chore: root commit")
BASE_D="$(cd "$d_d" && git rev-parse HEAD)"

# uncommitted tracked change (staged) — no new commit
echo 'v2-uncommitted' >"$d_d/app.py"
(cd "$d_d" && git add app.py)

# untracked new file — never staged, never committed
echo 'HELLO-NEW-FILE' >"$d_d/new_file.txt"

run_rp "$d_d" 001 --base "$BASE_D"

assert_eq "(d) exit code" "0" "$RP_EXIT"
assert_eq "(d) ok:true" "True" "$(json_field "$RP_OUT" 'd["ok"]')"
PATH_D="$(json_field "$RP_OUT" 'd["data"]["path"]')"
FULL_PATH_D="$d_d/$PATH_D"

if [ ! -f "$FULL_PATH_D" ]; then
  echo "FAIL: (d) review file not written: $FULL_PATH_D" >&2
  fail=1
else
  CONTENT_D="$(cat "$FULL_PATH_D")"
  if ! printf '%s' "$CONTENT_D" | grep -q -- "-v1"; then
    echo "FAIL: (d) missing uncommitted tracked-change removed-line (-v1)" >&2
    fail=1
  fi
  if ! printf '%s' "$CONTENT_D" | grep -q -- "+v2-uncommitted"; then
    echo "FAIL: (d) missing uncommitted tracked-change added-line (+v2-uncommitted)" >&2
    fail=1
  fi
  if ! printf '%s' "$CONTENT_D" | grep -q "new_file.txt"; then
    echo "FAIL: (d) untracked file name missing from package" >&2
    fail=1
  fi
  if ! printf '%s' "$CONTENT_D" | grep -q "HELLO-NEW-FILE"; then
    echo "FAIL: (d) untracked file CONTENT missing from package (must be inlined, not just named)" >&2
    fail=1
  fi
fi

# --- argv guard: missing task-id ----------------------------------------------

d_arg1="$(new_git_repo)"
run_rp "$d_arg1" --base HEAD
assert_eq "(argv) missing task-id exit code" "1" "$RP_EXIT"
assert_eq "(argv) missing task-id ok:false" "False" "$(json_field "$RP_OUT" 'd["ok"]')"
if [ -z "$(json_field "$RP_OUT" 'd["hint"]')" ]; then
  echo "FAIL: (argv) missing task-id hint missing: $RP_OUT" >&2
  fail=1
fi

# --- argv guard: missing --base -----------------------------------------------

d_arg2="$(new_git_repo)"
run_rp "$d_arg2" 001
assert_eq "(argv) missing --base exit code" "1" "$RP_EXIT"
assert_eq "(argv) missing --base ok:false" "False" "$(json_field "$RP_OUT" 'd["ok"]')"

exit $fail
