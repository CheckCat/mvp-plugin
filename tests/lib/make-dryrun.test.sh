#!/usr/bin/env bash
# Smoke test for tests/fixtures/dryrun/make-dryrun.sh.
# Convention (tests/run.sh): exit 0 = pass.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
make_dryrun="$repo_root/tests/fixtures/dryrun/make-dryrun.sh"
plan_io="$repo_root/lib/plan-io.mjs"

fail=0
cleanup_dirs=()
trap 'for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    fail=1
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" != "true" ] && [ "$cond" != "1" ]; then
    echo "FAIL: $desc — expected truthy, got [$cond]" >&2
    fail=1
  fi
}

json_field() { # <json> <python-expr-on-d>
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# (a) contract: single line of JSON, ok:true, data.path exists and is a dir
# ---------------------------------------------------------------------------

out="$(bash "$make_dryrun")"; rc=$?
assert_eq "make-dryrun: exit code" "0" "$rc"
line_count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "make-dryrun: exactly one line of output" "1" "$line_count"
assert_eq "make-dryrun: ok" "True" "$(json_field "$out" 'd["ok"]')"

repo_path="$(json_field "$out" 'd["data"]["path"]')"
cleanup_dirs+=("$repo_path")
assert_true "make-dryrun: data.path is a directory" "$([ -d "$repo_path" ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# (b) the built repo: clean git tree, expected fixture files present
# ---------------------------------------------------------------------------

assert_true "fixture: is a git repo" "$([ -d "$repo_path/.git" ] && echo true || echo false)"
porcelain="$(cd "$repo_path" && git status --porcelain)"
assert_eq "fixture: clean working tree" "" "$porcelain"

assert_true "fixture: plan.json exists" "$([ -f "$repo_path/.claude/state/plan.json" ] && echo true || echo false)"
assert_true "fixture: ci-mirror.sh exists and is executable" "$([ -x "$repo_path/.claude/state/ci-mirror.sh" ] && echo true || echo false)"
assert_true "fixture: invariants.md exists" "$([ -f "$repo_path/.claude/state/invariants.md" ] && echo true || echo false)"

ci_out="$(cd "$repo_path" && bash .claude/state/ci-mirror.sh; echo "rc=$?")"
assert_eq "fixture: ci-mirror.sh exits 0" "rc=0" "$ci_out"

# ---------------------------------------------------------------------------
# (c) plan.json validates via plan-io.mjs (this IS the executable spec check
# the task brief asks for: "asserts plan.json validates via plan-io")
# ---------------------------------------------------------------------------

validate_out="$(cd "$repo_path" && node "$plan_io" validate)"; validate_rc=$?
assert_eq "fixture: plan-io.mjs validate exit code" "0" "$validate_rc"
assert_eq "fixture: plan-io.mjs validate ok" "True" "$(json_field "$validate_out" 'd["ok"]')"
assert_eq "fixture: plan-io.mjs validate errors empty" "0" "$(json_field "$validate_out" 'len(d["data"]["errors"])')"

# ---------------------------------------------------------------------------
# (d) plan-io.mjs next on the fixture picks task 001, boundary/role/files as
# seeded — the exact shape skills/build/workflow.mjs's advance step consumes.
# ---------------------------------------------------------------------------

next_out="$(cd "$repo_path" && node "$plan_io" next)"; next_rc=$?
assert_eq "fixture: plan-io.mjs next exit code" "0" "$next_rc"
assert_eq "fixture: next task_id" "001" "$(json_field "$next_out" 'd["data"]["task_id"]')"
assert_eq "fixture: next boundary" "app" "$(json_field "$next_out" 'd["data"]["boundary"]')"
assert_eq "fixture: next role" "general-purpose" "$(json_field "$next_out" 'd["data"]["role"]')"
assert_eq "fixture: next files" "app/a.txt" "$(json_field "$next_out" '",".join(d["data"]["files"])')"

# ---------------------------------------------------------------------------
# (e) argv guard: unexpected argument rejected, still contract JSON
# ---------------------------------------------------------------------------

bad_out="$(bash "$make_dryrun" extra-arg)"; bad_rc=$?
assert_eq "make-dryrun: unexpected argument exit code" "1" "$bad_rc"
assert_eq "make-dryrun: unexpected argument ok" "False" "$(json_field "$bad_out" 'd["ok"]')"

exit $fail
