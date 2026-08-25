#!/usr/bin/env bash
# Tests for skills/plan/scripts/validate-plan.py
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
validate_plan="$repo_root/skills/plan/scripts/validate-plan.py"
fixture="$repo_root/tests/fixtures/plan-3tasks.json"

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
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) echo "FAIL: $desc — expected to contain [$needle], got [$haystack]" >&2; fail=1 ;;
  esac
}

json_field() { # <json> <python-expr-on-d>
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null
}

# new_repo_with_plan <raw-json-content> -> path to a fresh tmp-git project
# with .mvp/plan.json set to the given raw content (uncommitted is
# fine — validate-plan.py only reads).
new_repo_with_plan() {
  local content="$1"
  local dir
  dir="$(mktemp -d -p "$tmproot")"
  ( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
  mkdir -p "$dir/.mvp"
  printf '%s' "$content" > "$dir/.mvp/plan.json"
  echo "$dir"
}

run_validate_plan() { # <dir> [args...]
  local dir="$1"; shift
  ( cd "$dir" && python3 "$validate_plan" "$@" )
}

# ---------------------------------------------------------------------------
# (a) valid fixture: ok:true, total_estimate correct
# ---------------------------------------------------------------------------

dir="$(mktemp -d -p "$tmproot")"
( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
mkdir -p "$dir/.mvp"
cp "$fixture" "$dir/.mvp/plan.json"

out="$(run_validate_plan "$dir")"; rc=$?
assert_eq "valid fixture: exit code" "0" "$rc"
assert_eq "valid fixture: ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "valid fixture: errors empty" "0" "$(json_field "$out" 'len(d["data"]["errors"])')"
# fixture estimate_tokens: 4000 + 6000 + 8000 = 18000
assert_eq "valid fixture: total_estimate" "18000" "$(json_field "$out" 'd["data"]["total_estimate"]')"

# ---------------------------------------------------------------------------
# (b) schema violation surfaces from plan-io (missing required field)
# ---------------------------------------------------------------------------

bad_schema_plan='{
  "tasks": [
    {
      "id": "001",
      "title": "Missing service_path",
      "level": 1,
      "service": "api",
      "role": "backend-implementer",
      "files": ["app/main.py"],
      "depends_on": [],
      "estimate_tokens": 4000,
      "status": "pending",
      "complexity_class": "boilerplate"
    }
  ]
}'
dir="$(new_repo_with_plan "$bad_schema_plan")"
out="$(run_validate_plan "$dir")"; rc=$?
assert_eq "schema violation: exit code" "1" "$rc"
assert_eq "schema violation: ok" "False" "$(json_field "$out" 'd["ok"]')"
errs="$(json_field "$out" '" | ".join(d["data"]["errors"])')"
assert_contains "schema violation: mentions service_path" "$errs" "service_path"

# ---------------------------------------------------------------------------
# (c) frontend task with api-client file, no backend dep -> plan-level error
# ---------------------------------------------------------------------------

fe_no_backend_plan='{
  "tasks": [
    {
      "id": "001",
      "title": "Frontend api client",
      "level": 1,
      "service": "frontend",
      "service_path": "services/frontend",
      "role": "frontend-implementer",
      "files": ["services/frontend/src/api/client.ts"],
      "depends_on": [],
      "estimate_tokens": 5000,
      "status": "pending",
      "complexity_class": "novel-design"
    }
  ]
}'
dir="$(new_repo_with_plan "$fe_no_backend_plan")"
out="$(run_validate_plan "$dir")"; rc=$?
assert_eq "frontend no backend dep: exit code" "1" "$rc"
assert_eq "frontend no backend dep: ok" "False" "$(json_field "$out" 'd["ok"]')"
errs="$(json_field "$out" '" | ".join(d["data"]["errors"])')"
assert_contains "frontend no backend dep: mentions task id" "$errs" "001"
assert_contains "frontend no backend dep: mentions backend-implementer" "$errs" "backend-implementer"

# ---------------------------------------------------------------------------
# (d) frontend task WITH transitive backend dep -> no plan-level error
# ---------------------------------------------------------------------------

fe_with_backend_plan='{
  "tasks": [
    {
      "id": "001",
      "title": "Backend contract",
      "level": 1,
      "service": "api",
      "service_path": "app",
      "role": "backend-implementer",
      "files": ["app/main.py"],
      "depends_on": [],
      "estimate_tokens": 4000,
      "status": "pending",
      "complexity_class": "boilerplate"
    },
    {
      "id": "002",
      "title": "Bridge task",
      "level": 2,
      "service": "api",
      "service_path": "app",
      "role": "test-writer",
      "files": ["app/tests/test_main.py"],
      "depends_on": ["001"],
      "estimate_tokens": 3000,
      "status": "pending",
      "complexity_class": "follow-pattern"
    },
    {
      "id": "003",
      "title": "Frontend api client",
      "level": 3,
      "service": "frontend",
      "service_path": "services/frontend",
      "role": "frontend-implementer",
      "files": ["services/frontend/src/api/client.ts"],
      "depends_on": ["002"],
      "estimate_tokens": 5000,
      "status": "pending",
      "complexity_class": "novel-design"
    }
  ]
}'
dir="$(new_repo_with_plan "$fe_with_backend_plan")"
out="$(run_validate_plan "$dir")"; rc=$?
assert_eq "frontend transitive backend dep: exit code" "0" "$rc"
assert_eq "frontend transitive backend dep: ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "frontend transitive backend dep: errors empty" "0" "$(json_field "$out" 'len(d["data"]["errors"])')"
assert_eq "frontend transitive backend dep: total_estimate" "12000" "$(json_field "$out" 'd["data"]["total_estimate"]')"

# ---------------------------------------------------------------------------
# (e) role not in enum -> plan-level error (field-based, not title-based)
# ---------------------------------------------------------------------------

bad_role_plan='{
  "tasks": [
    {
      "id": "001",
      "title": "Weird role",
      "level": 1,
      "service": "api",
      "service_path": "app",
      "role": "architect",
      "files": ["app/main.py"],
      "depends_on": [],
      "estimate_tokens": 4000,
      "status": "pending",
      "complexity_class": "boilerplate"
    }
  ]
}'
dir="$(new_repo_with_plan "$bad_role_plan")"
out="$(run_validate_plan "$dir")"; rc=$?
assert_eq "bad role: exit code" "1" "$rc"
errs="$(json_field "$out" '" | ".join(d["data"]["errors"])')"
assert_contains "bad role: mentions role value" "$errs" "architect"

# ---------------------------------------------------------------------------
# (f) missing plan.json -> ok:false, error surfaces (not a crash)
# ---------------------------------------------------------------------------

dir="$(mktemp -d -p "$tmproot")"
( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
out="$(run_validate_plan "$dir")"; rc=$?
assert_eq "missing plan.json: exit code" "1" "$rc"
assert_eq "missing plan.json: ok" "False" "$(json_field "$out" 'd["ok"]')"

# ---------------------------------------------------------------------------
# (g) argv guard: unknown flag -> ok:false, usage hint, no crash
# ---------------------------------------------------------------------------

dir="$(mktemp -d -p "$tmproot")"
out="$(run_validate_plan "$dir" --bogus)"; rc=$?
assert_eq "argv guard: exit code" "1" "$rc"
assert_eq "argv guard: ok" "False" "$(json_field "$out" 'd["ok"]')"

# ---------------------------------------------------------------------------
# (h) single-line JSON contract: exactly one line of stdout
# ---------------------------------------------------------------------------

dir="$(mktemp -d -p "$tmproot")"
( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
mkdir -p "$dir/.mvp"
cp "$fixture" "$dir/.mvp/plan.json"
out="$(run_validate_plan "$dir")"
nlines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "single-line JSON contract" "1" "$nlines"

if [ "$fail" -eq 0 ]; then
  echo "OK: all validate-plan.py assertions passed"
fi
exit $fail
