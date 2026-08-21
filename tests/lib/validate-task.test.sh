#!/usr/bin/env bash
# Tests for lib/validate-task.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
vt="$repo_root/lib/validate-task.sh"

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

# new_git_repo -> dir with an initial commit (task-1..8 scripts operate
# post-bootstrap, i.e. HEAD always exists by the time build/validate runs).
new_git_repo() {
  local dir
  dir="$(mktemp -d -p "$tmproot")"
  (
    cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test
    mkdir -p app .claude/state
    echo 'init' >app/init.py
    git add app/init.py
    git commit -q -m "chore: init"
  )
  printf '%s' "$dir"
}

write_ci_mirror() { # <dir> <line1> [<line2> ...] -- writes .claude/state/ci-mirror.sh
  local dir="$1"
  shift
  {
    for line in "$@"; do printf '%s\n' "$line"; done
  } >"$dir/.claude/state/ci-mirror.sh"
}

# run_vt <projectdir> <arg...> -> sets VT_OUT VT_EXIT
# Also asserts, per invocation (not just once at the end), that stdout is
# exactly one line of JSON — every call site gets this check, not just the
# last one (a `for out in "$VT_OUT"` loop after all calls would silently
# only re-check the final invocation's output).
run_vt() {
  local dir="$1"
  shift
  VT_OUT="$(cd "$dir" && "$vt" "$@" 2>/tmp/mvp-vt-test-err)"
  VT_EXIT=$?
  local lines
  lines="$(printf '%s' "$VT_OUT" | wc -l | tr -d ' ')"
  if [ "$lines" != "0" ]; then
    echo "FAIL: (json) output is not single-line for args [$*]: $VT_OUT" >&2
    fail=1
  fi
}

violations_of_check() { # <json> <check> -> newline-separated details for that check
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for v in d["data"]["violations"]:
    if v["check"] == sys.argv[2]:
        print(v["detail"])
' "$1" "$2" 2>/dev/null
}

violations_count() {
  json_field "$1" 'len(d["data"]["violations"])'
}

# --- (a) clean run: ci passes, file within boundary, declared matches actual -

d_a="$(new_git_repo)"
write_ci_mirror "$d_a" "true"
echo 'x' >"$d_a/app/foo.py"
(cd "$d_a" && git add app/foo.py)

run_vt "$d_a" 001 --boundary app --files app/foo.py

assert_eq "(a) exit code" "0" "$VT_EXIT"
assert_eq "(a) ok:true" "True" "$(json_field "$VT_OUT" 'd["ok"]')"
assert_eq "(a) no violations" "0" "$(violations_count "$VT_OUT")"

# --- (b) missing ci-mirror.sh -> violation ci with specific detail -----------

d_b="$(new_git_repo)"
echo 'x' >"$d_b/app/foo.py"
(cd "$d_b" && git add app/foo.py)

run_vt "$d_b" 001 --boundary app --files app/foo.py

assert_eq "(b) exit code" "1" "$VT_EXIT"
assert_eq "(b) ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"
assert_eq "(b) ci detail" "missing .claude/state/ci-mirror.sh" "$(violations_of_check "$VT_OUT" ci)"

# --- (c) failing command in ci-mirror.sh -> violation ci, later cmd skipped --

d_c="$(new_git_repo)"
write_ci_mirror "$d_c" "true" "false" "echo SHOULD_NOT_RUN"
echo 'x' >"$d_c/app/foo.py"
(cd "$d_c" && git add app/foo.py)

run_vt "$d_c" 001 --boundary app --files app/foo.py

assert_eq "(c) exit code" "1" "$VT_EXIT"
assert_eq "(c) ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"
CI_DETAIL_C="$(violations_of_check "$VT_OUT" ci)"
if printf '%s' "$CI_DETAIL_C" | grep -q "SHOULD_NOT_RUN"; then
  echo "FAIL: (c) ci-mirror kept running after first failure: $VT_OUT" >&2
  fail=1
fi

# --- (d) file outside boundary -> violation boundary --------------------------

d_d="$(new_git_repo)"
write_ci_mirror "$d_d" "true"
mkdir -p "$d_d/other"
echo 'x' >"$d_d/other/stray.py"
(cd "$d_d" && git add other/stray.py)

run_vt "$d_d" 001 --boundary app --files other/stray.py

assert_eq "(d) exit code" "1" "$VT_EXIT"
assert_eq "(d) ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"
assert_eq "(d) boundary detail" "other/stray.py" "$(violations_of_check "$VT_OUT" boundary)"

# --- (d2) file under .claude/state is always allowed regardless of boundary --

d_d2="$(new_git_repo)"
write_ci_mirror "$d_d2" "true"
echo '{}' >"$d_d2/.claude/state/report.json"
(cd "$d_d2" && git add .claude/state/report.json)

run_vt "$d_d2" 001 --boundary app --files ""

assert_eq "(d2) exit code" "0" "$VT_EXIT"
assert_eq "(d2) ok:true" "True" "$(json_field "$VT_OUT" 'd["ok"]')"

# --- (e) undeclared file: actual changed file not in --files -----------------

d_e="$(new_git_repo)"
write_ci_mirror "$d_e" "true"
echo 'x' >"$d_e/app/foo.py"
echo 'y' >"$d_e/app/bar.py"
(cd "$d_e" && git add app/foo.py app/bar.py)

run_vt "$d_e" 001 --boundary app --files app/foo.py

assert_eq "(e) exit code" "1" "$VT_EXIT"
assert_eq "(e) ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"
DECL_E="$(violations_of_check "$VT_OUT" declared)"
if ! printf '%s' "$DECL_E" | grep -q "undeclared-files:.*app/bar.py"; then
  echo "FAIL: (e) expected undeclared-files violation mentioning app/bar.py: $VT_OUT" >&2
  fail=1
fi

# --- (f) missing-declared: --files lists a file that wasn't actually changed -

d_f="$(new_git_repo)"
write_ci_mirror "$d_f" "true"
echo 'x' >"$d_f/app/foo.py"
(cd "$d_f" && git add app/foo.py)

run_vt "$d_f" 001 --boundary app --files "app/foo.py,app/never-touched.py"

assert_eq "(f) exit code" "1" "$VT_EXIT"
assert_eq "(f) ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"
DECL_F="$(violations_of_check "$VT_OUT" declared)"
if ! printf '%s' "$DECL_F" | grep -q "missing-declared:.*app/never-touched.py"; then
  echo "FAIL: (f) expected missing-declared violation mentioning app/never-touched.py: $VT_OUT" >&2
  fail=1
fi

# --- (g) untracked (never git-added) file is still detected as changed -------

d_g="$(new_git_repo)"
write_ci_mirror "$d_g" "true"
echo 'x' >"$d_g/app/untracked.py"
# deliberately NOT git add'ed

run_vt "$d_g" 001 --boundary app --files app/untracked.py

assert_eq "(g) exit code" "0" "$VT_EXIT"
assert_eq "(g) ok:true" "True" "$(json_field "$VT_OUT" 'd["ok"]')"

# --- (h) filenames with spaces are tolerated end-to-end -----------------------

d_h="$(new_git_repo)"
write_ci_mirror "$d_h" "true"
echo 'x' >"$d_h/app/file with spaces.py"
(cd "$d_h" && git add "app/file with spaces.py")

run_vt "$d_h" 001 --boundary app --files "app/file with spaces.py"

assert_eq "(h) exit code" "0" "$VT_EXIT"
assert_eq "(h) ok:true" "True" "$(json_field "$VT_OUT" 'd["ok"]')"

# --- argv guard: missing task-id ---------------------------------------------

d_arg1="$(new_git_repo)"
run_vt "$d_arg1" --boundary app --files app/foo.py
assert_eq "(argv) missing task-id exit code" "1" "$VT_EXIT"
assert_eq "(argv) missing task-id ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"
if [ -z "$(json_field "$VT_OUT" 'd["hint"]')" ]; then
  echo "FAIL: (argv) missing task-id hint missing: $VT_OUT" >&2
  fail=1
fi

# --- argv guard: missing --boundary ------------------------------------------

d_arg2="$(new_git_repo)"
run_vt "$d_arg2" 001 --files app/foo.py
assert_eq "(argv) missing --boundary exit code" "1" "$VT_EXIT"
assert_eq "(argv) missing --boundary ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"

# --- argv guard: missing --files ---------------------------------------------

d_arg3="$(new_git_repo)"
run_vt "$d_arg3" 001 --boundary app
assert_eq "(argv) missing --files exit code" "1" "$VT_EXIT"
assert_eq "(argv) missing --files ok:false" "False" "$(json_field "$VT_OUT" 'd["ok"]')"

exit $fail
