#!/usr/bin/env bash
# Tests for lib/finalize.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
finalize="$repo_root/lib/finalize.sh"

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

# write_msg <file> <subject-line>
write_msg() {
  printf '%s\n\nbody text.\n' "$2" >"$1"
}

# run_finalize <projectdir> <arg...> -> sets F_OUT F_EXIT
# Also asserts, per invocation (not just once at the end), that stdout is
# exactly one line of JSON — every call site gets this check, not just the
# last one (a `for out in "$F_OUT"` loop after all calls would silently only
# re-check the final invocation's output).
run_finalize() {
  local dir="$1"
  shift
  F_OUT="$(cd "$dir" && "$finalize" "$@" 2>/tmp/mvp-finalize-test-err)"
  F_EXIT=$?
  local lines
  lines="$(printf '%s' "$F_OUT" | wc -l | tr -d ' ')"
  if [ "$lines" != "0" ]; then
    echo "FAIL: (json) output is not single-line for args [$*]: $F_OUT" >&2
    fail=1
  fi
}

head_sha() { # <dir> -> HEAD sha or "none"
  (cd "$1" && git rev-parse HEAD 2>/dev/null) || echo none
}

# --- (a) valid msg + files -> commit created, sha in JSON, foreign staged
#         file (operator's) NOT included in the commit -------------------------

d_a="$(new_git_repo)"
mkdir -p "$d_a/.claude/state"
echo '{}' >"$d_a/.claude/state/state.json"
echo 'print(1)' >"$d_a/task.py"
echo 'operator wip' >"$d_a/unrelated.txt"
(cd "$d_a" && git add unrelated.txt)
write_msg "$d_a/msg.txt" "feat: add task"

run_finalize "$d_a" build-task msg.txt --files task.py

assert_eq "(a) exit code" "0" "$F_EXIT"
assert_eq "(a) ok:true" "True" "$(json_field "$F_OUT" 'd["ok"]')"
SHA_A="$(json_field "$F_OUT" 'd["data"]["sha"]')"
if [ -z "$SHA_A" ]; then
  echo "FAIL: (a) sha missing from data: $F_OUT" >&2
  fail=1
fi
assert_eq "(a) sha matches HEAD" "$(head_sha "$d_a")" "$SHA_A"

COMMITTED_FILES="$(cd "$d_a" && git show --name-only --pretty=format: HEAD | sed '/^$/d')"
if ! printf '%s\n' "$COMMITTED_FILES" | grep -qxF "task.py"; then
  echo "FAIL: (a) task.py not in commit: $COMMITTED_FILES" >&2
  fail=1
fi
if printf '%s\n' "$COMMITTED_FILES" | grep -qxF "unrelated.txt"; then
  echo "FAIL: (a) unrelated.txt leaked into commit: $COMMITTED_FILES" >&2
  fail=1
fi
STILL_STAGED="$(cd "$d_a" && git diff --cached --name-only)"
if ! printf '%s\n' "$STILL_STAGED" | grep -qxF "unrelated.txt"; then
  echo "FAIL: (a) unrelated.txt should remain staged (operator's index preserved): $STILL_STAGED" >&2
  fail=1
fi

# --- (b) msg with subject "WIP: x" -> ok:false, no commit created ------------

d_b="$(new_git_repo)"
mkdir -p "$d_b/.claude/state"
echo '{}' >"$d_b/.claude/state/state.json"
echo 'x' >"$d_b/task.py"
write_msg "$d_b/msg.txt" "WIP: x"
BEFORE_B="$(head_sha "$d_b")"

run_finalize "$d_b" build-task msg.txt --files task.py

assert_eq "(b) exit code" "1" "$F_EXIT"
assert_eq "(b) ok:false" "False" "$(json_field "$F_OUT" 'd["ok"]')"
assert_eq "(b) no commit created" "$BEFORE_B" "$(head_sha "$d_b")"

# --- (c) missing file from list skipped silently, commit still succeeds
#         via the other existing path -----------------------------------------

d_c="$(new_git_repo)"
mkdir -p "$d_c/.claude/state"
echo '{}' >"$d_c/.claude/state/state.json"
echo 'x' >"$d_c/exists.py"
write_msg "$d_c/msg.txt" "feat: partial files"

run_finalize "$d_c" build-task msg.txt --files exists.py missing.py

assert_eq "(c) exit code" "0" "$F_EXIT"
assert_eq "(c) ok:true" "True" "$(json_field "$F_OUT" 'd["ok"]')"
COMMITTED_C="$(cd "$d_c" && git show --name-only --pretty=format: HEAD | sed '/^$/d')"
if ! printf '%s\n' "$COMMITTED_C" | grep -qxF "exists.py"; then
  echo "FAIL: (c) exists.py not in commit: $COMMITTED_C" >&2
  fail=1
fi
if printf '%s\n' "$COMMITTED_C" | grep -qxF "missing.py"; then
  echo "FAIL: (c) missing.py should never appear: $COMMITTED_C" >&2
  fail=1
fi

# --- (c2) all listed paths missing -> "nothing to commit", ok:false, exit 1 ---

d_c2="$(new_git_repo)"
write_msg "$d_c2/msg.txt" "feat: nothing here"

run_finalize "$d_c2" build-task msg.txt --files does-not-exist.py

assert_eq "(c2) exit code" "1" "$F_EXIT"
assert_eq "(c2) ok:false" "False" "$(json_field "$F_OUT" 'd["ok"]')"
if ! echo "$F_OUT" | grep -qi "nothing to commit"; then
  echo "FAIL: (c2) reason doesn't mention 'nothing to commit': $F_OUT" >&2
  fail=1
fi

# --- (c3) declared path deleted by the task (tracked, absent from disk)
#          -> the deletion is staged and lands in the commit -----------------

d_c3="$(new_git_repo)"
mkdir -p "$d_c3/.claude/state"
echo '{}' >"$d_c3/.claude/state/state.json"
echo 'x' >"$d_c3/gone.py"
(cd "$d_c3" && git add gone.py .claude/state/state.json && git commit -qm "chore: seed")
rm "$d_c3/gone.py"
write_msg "$d_c3/msg.txt" "fix: drop gone.py"

run_finalize "$d_c3" build-task msg.txt --files gone.py

assert_eq "(c3) exit code" "0" "$F_EXIT"
assert_eq "(c3) ok:true" "True" "$(json_field "$F_OUT" 'd["ok"]')"
DELETED_C3="$(cd "$d_c3" && git show --name-status --pretty=format: HEAD | sed '/^$/d')"
if ! printf '%s\n' "$DELETED_C3" | grep -q "^D[[:space:]]*gone.py$"; then
  echo "FAIL: (c3) deletion of gone.py not in commit: $DELETED_C3" >&2
  fail=1
fi
if (cd "$d_c3" && git ls-files --error-unmatch -- gone.py >/dev/null 2>&1); then
  echo "FAIL: (c3) gone.py still tracked after the commit" >&2
  fail=1
fi

# --- argv guard: unknown scope -> ok:false, hint present, exit 1 -------------

d_arg="$(new_git_repo)"
write_msg "$d_arg/msg.txt" "feat: x"

run_finalize "$d_arg" bogus-scope msg.txt

assert_eq "(argv) unknown scope exit code" "1" "$F_EXIT"
assert_eq "(argv) unknown scope ok:false" "False" "$(json_field "$F_OUT" 'd["ok"]')"
if [ -z "$(json_field "$F_OUT" 'd["hint"]')" ]; then
  echo "FAIL: (argv) unknown scope hint missing: $F_OUT" >&2
  fail=1
fi

# --- argv guard: missing msg-file arg -> ok:false, exit 1 --------------------

d_arg2="$(new_git_repo)"
run_finalize "$d_arg2" brief

assert_eq "(argv) missing msg-file exit code" "1" "$F_EXIT"
assert_eq "(argv) missing msg-file ok:false" "False" "$(json_field "$F_OUT" 'd["ok"]')"

# --- argv guard: unexpected extra positional arg (not "--files") -> ok:false -

d_arg3="$(new_git_repo)"
write_msg "$d_arg3/msg.txt" "feat: x"

run_finalize "$d_arg3" brief msg.txt some-stray-arg

assert_eq "(argv) unexpected extra arg exit code" "1" "$F_EXIT"
assert_eq "(argv) unexpected extra arg ok:false" "False" "$(json_field "$F_OUT" 'd["ok"]')"

# --- build-task without --files -> ok:false, hint mentions --files ----------

d_bt="$(new_git_repo)"
write_msg "$d_bt/msg.txt" "feat: x"

run_finalize "$d_bt" build-task msg.txt

assert_eq "(build-task no-files) exit code" "1" "$F_EXIT"
assert_eq "(build-task no-files) ok:false" "False" "$(json_field "$F_OUT" 'd["ok"]')"
if ! echo "$F_OUT" | grep -qi -- "--files"; then
  echo "FAIL: (build-task no-files) hint/reason doesn't mention --files: $F_OUT" >&2
  fail=1
fi

# --- non-build-task scope: --files EXTENDS the preset (documented choice) ----

d_ext="$(new_git_repo)"
mkdir -p "$d_ext/.claude/state"
echo '{}' >"$d_ext/.claude/state/state.json"
echo '# plan' >"$d_ext/PROJECT_PLAN.md"
echo 'extra' >"$d_ext/extra.txt"
write_msg "$d_ext/msg.txt" "chore: plan with extension"

run_finalize "$d_ext" plan msg.txt --files extra.txt

assert_eq "(extend) exit code" "0" "$F_EXIT"
assert_eq "(extend) ok:true" "True" "$(json_field "$F_OUT" 'd["ok"]')"
COMMITTED_EXT="$(cd "$d_ext" && git show --name-only --pretty=format: HEAD | sed '/^$/d')"
if ! printf '%s\n' "$COMMITTED_EXT" | grep -qxF "extra.txt"; then
  echo "FAIL: (extend) extra.txt not in commit: $COMMITTED_EXT" >&2
  fail=1
fi

# --- every default scope preset stages+commits correctly (no --files) -------

d_brief="$(new_git_repo)"
mkdir -p "$d_brief/project_brief" "$d_brief/project_brief.raw"
echo 'x' >"$d_brief/project_brief/technical_solutions.md"
echo 'x' >"$d_brief/project_brief.raw/orig.md"
write_msg "$d_brief/msg.txt" "chore: brief scope"
run_finalize "$d_brief" brief msg.txt
assert_eq "(preset brief) exit code" "0" "$F_EXIT"

d_clarify="$(new_git_repo)"
mkdir -p "$d_clarify/project_brief" "$d_clarify/.claude/state"
echo 'x' >"$d_clarify/project_brief/business_logic.md"
echo '{}' >"$d_clarify/.claude/state/state.json"
write_msg "$d_clarify/msg.txt" "chore: clarify scope"
run_finalize "$d_clarify" clarify msg.txt
assert_eq "(preset clarify) exit code" "0" "$F_EXIT"

d_bootstrap="$(new_git_repo)"
mkdir -p "$d_bootstrap/.claude/agents" "$d_bootstrap/.claude/state"
echo '# CLAUDE' >"$d_bootstrap/CLAUDE.md"
echo '# ARCH' >"$d_bootstrap/ARCHITECTURE.md"
echo 'x' >"$d_bootstrap/.claude/agents/role.md"
echo '{}' >"$d_bootstrap/.claude/state/state.json"
write_msg "$d_bootstrap/msg.txt" "chore: bootstrap scope"
run_finalize "$d_bootstrap" bootstrap msg.txt
assert_eq "(preset bootstrap) exit code" "0" "$F_EXIT"

d_plan="$(new_git_repo)"
mkdir -p "$d_plan/.claude/state"
echo '{}' >"$d_plan/.claude/state/plan.json"
echo '# plan' >"$d_plan/PROJECT_PLAN.md"
write_msg "$d_plan/msg.txt" "chore: plan scope"
run_finalize "$d_plan" plan msg.txt
assert_eq "(preset plan) exit code" "0" "$F_EXIT"

exit $fail
