#!/usr/bin/env bash
# Tests for skills/brief/scripts/package-brief.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
pb="$repo_root/skills/brief/scripts/package-brief.sh"

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
  mktemp -d -p "$tmproot"
}

# run_pb <projectdir> <arg...> -> sets P_OUT P_EXIT, asserts single-line JSON
run_pb() {
  local dir="$1"
  shift
  P_OUT="$(cd "$dir" && "$pb" "$@" 2>/tmp/mvp-pb-test-err)"
  P_EXIT=$?
  local lines
  lines="$(printf '%s' "$P_OUT" | wc -l | tr -d ' ')"
  if [ "$lines" != "0" ]; then
    echo "FAIL: (json) output is not single-line for args [$*]: $P_OUT" >&2
    fail=1
  fi
}

# ============================================================================
# discover
# ============================================================================

# --- (d1) 2 candidate root files -> data.candidates has 2 entries -----------

d1="$(new_project_dir)"
echo "idea" >"$d1/idea.md"
echo "notes" >"$d1/notes.txt"
run_pb "$d1" discover
assert_eq "(d1) exit code" "0" "$P_EXIT"
assert_eq "(d1) ok:true" "True" "$(json_field "$P_OUT" 'd["ok"]')"
assert_eq "(d1) candidates count" "2" "$(json_field "$P_OUT" 'len(d["data"]["candidates"])')"

# --- (d2) no candidates -> empty list, ok:true -------------------------------

d2="$(new_project_dir)"
run_pb "$d2" discover
assert_eq "(d2) exit code" "0" "$P_EXIT"
assert_eq "(d2) candidates count" "0" "$(json_field "$P_OUT" 'len(d["data"]["candidates"])')"

# --- (d3) standard dir present (brief/ with a file inside) -> 1 dir candidate

d3="$(new_project_dir)"
mkdir -p "$d3/brief"
echo "x" >"$d3/brief/spec.md"
run_pb "$d3" discover
assert_eq "(d3) exit code" "0" "$P_EXIT"
assert_eq "(d3) candidates count" "1" "$(json_field "$P_OUT" 'len(d["data"]["candidates"])')"
assert_eq "(d3) candidate is brief/" "brief/" "$(json_field "$P_OUT" 'd["data"]["candidates"][0]')"

# --- (d3b) docs/ is NOT a source: it is the pipeline's own output root -------
# `docs` was a standard source dir until the docs/ migration. It cannot be one
# any more: the brief now WRITES docs/product/, so treating docs/ as raw input
# would make `archive docs` move docs/product into docs/product/_raw — a
# directory swallowing itself.

d3b="$(new_project_dir)"
mkdir -p "$d3b/docs"
echo "x" >"$d3b/docs/spec.md"
run_pb "$d3b" discover
assert_eq "(d3b) exit code" "0" "$P_EXIT"
assert_eq "(d3b) docs/ is not discovered as a source" "0" \
  "$(json_field "$P_OUT" 'len(d["data"]["candidates"])')"

# --- (d4) standard root filenames excluded (README.md, package.json) --------

d4="$(new_project_dir)"
echo "x" >"$d4/README.md"
echo "{}" >"$d4/package.json"
echo "x" >"$d4/CLAUDE.md"
run_pb "$d4" discover
assert_eq "(d4) exit code" "0" "$P_EXIT"
assert_eq "(d4) candidates count (excluded standard files)" "0" "$(json_field "$P_OUT" 'len(d["data"]["candidates"])')"

# --- (d5) nonexistent path arg -> ok:false -----------------------------------

d5="$(new_project_dir)"
run_pb "$d5" discover "$d5/does-not-exist"
assert_eq "(d5) exit code" "1" "$P_EXIT"
assert_eq "(d5) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"

# ============================================================================
# skeleton
# ============================================================================

# --- (s1) empty dir -> all required headers present, services_count 0, layout null

s1="$(new_project_dir)"
skdir1="$s1/tmp-brief"
run_pb "$s1" skeleton "$skdir1"
assert_eq "(s1) exit code" "0" "$P_EXIT"
assert_eq "(s1) ok:true" "True" "$(json_field "$P_OUT" 'd["ok"]')"
assert_eq "(s1) services_count" "0" "$(json_field "$P_OUT" 'd["data"]["services_count"]')"
assert_eq "(s1) layout is null" "None" "$(json_field "$P_OUT" 'd["data"]["layout"]')"

for h in "## Stack" "## Services" "## Auth" "## Deploy"; do
  if ! grep -qxF "$h" "$skdir1/technical-solutions.md"; then
    echo "FAIL: (s1) technical-solutions.md missing header: $h" >&2
    fail=1
  fi
done
for h in "## Goal" "## Roles" "## Core scenarios" "## MVP scope" "## Success criteria"; do
  if ! grep -qxF "$h" "$skdir1/business-logic.md"; then
    echo "FAIL: (s1) business-logic.md missing header: $h" >&2
    fail=1
  fi
done
for f in glossary.md analysis-grey-zones.md; do
  if [ ! -f "$skdir1/$f" ]; then
    echo "FAIL: (s1) missing file: $f" >&2
    fail=1
  fi
done

# --- (s2) partial headers already present -> missing ones added, no dupes ---

s2="$(new_project_dir)"
skdir2="$s2/tmp-brief"
mkdir -p "$skdir2"
printf '## Stack\n- backend: fastapi\n' >"$skdir2/technical-solutions.md"
run_pb "$s2" skeleton "$skdir2"
assert_eq "(s2) exit code" "0" "$P_EXIT"
stack_count="$(grep -cxF "## Stack" "$skdir2/technical-solutions.md")"
assert_eq "(s2) ## Stack not duplicated" "1" "$stack_count"
for h in "## Services" "## Auth" "## Deploy"; do
  if ! grep -qxF "$h" "$skdir2/technical-solutions.md"; then
    echo "FAIL: (s2) missing header not added: $h" >&2
    fail=1
  fi
done

# --- (s3) v1 awk-bug regression: services count scoped to ## Services only,
#          bullets before (## Stack) and after (## Auth) must NOT count;
#          layout auto-filled from the Stack fixture --------------------------

s3="$(new_project_dir)"
skdir3="$s3/tmp-brief"
mkdir -p "$skdir3"
cat >"$skdir3/technical-solutions.md" <<'EOF'
## Stack
- backend: fastapi
- frontend: react
- deploy: docker-dokploy
- db: postgresql

## Services
- api
- worker
- integration-tiktok

## Auth
- argon2id
- jwt-rtr

## Deploy
Docker Compose via Dokploy
EOF
run_pb "$s3" skeleton "$skdir3"
assert_eq "(s3) exit code" "0" "$P_EXIT"
assert_eq "(s3) services_count == 3 (not 9, not 1)" "3" "$(json_field "$P_OUT" 'd["data"]["services_count"]')"
assert_eq "(s3) layout auto-filled" "services" "$(json_field "$P_OUT" 'd["data"]["layout"]')"
if ! grep -qxF "## Layout" "$skdir3/technical-solutions.md"; then
  echo "FAIL: (s3) ## Layout header not written to file" >&2
  fail=1
fi
if ! grep -qxF "services" "$skdir3/technical-solutions.md"; then
  echo "FAIL: (s3) layout value 'services' not written to file" >&2
  fail=1
fi

# --- (s4) argv guard: missing dir -> ok:false --------------------------------

s4="$(new_project_dir)"
run_pb "$s4" skeleton
assert_eq "(s4) exit code" "1" "$P_EXIT"
assert_eq "(s4) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"

# ============================================================================
# swap
# ============================================================================

# --- (w1) target does not exist -> plain move, backup null ------------------

w1="$(new_project_dir)"
mkdir -p "$w1/newbrief"
echo "new content" >"$w1/newbrief/technical-solutions.md"
run_pb "$w1" swap newbrief
assert_eq "(w1) exit code" "0" "$P_EXIT"
assert_eq "(w1) backup is null" "None" "$(json_field "$P_OUT" 'd["data"]["backup"]')"
assert_eq "(w1) target moved" "new content" "$(cat "$w1/docs/product/technical-solutions.md")"
if [ -e "$w1/newbrief" ]; then
  echo "FAIL: (w1) tmpdir still exists after swap" >&2
  fail=1
fi

# --- (w2) target exists -> atomic backup .bak.<ts>, old content preserved ---

w2="$(new_project_dir)"
mkdir -p "$w2/docs/product"
echo "old content" >"$w2/docs/product/technical-solutions.md"
mkdir -p "$w2/newbrief"
echo "new content" >"$w2/newbrief/technical-solutions.md"
run_pb "$w2" swap newbrief
assert_eq "(w2) exit code" "0" "$P_EXIT"
assert_eq "(w2) target has new content" "new content" "$(cat "$w2/docs/product/technical-solutions.md")"
backup_path="$(json_field "$P_OUT" 'd["data"]["backup"]')"
if [ -z "$backup_path" ] || [ "$backup_path" = "None" ]; then
  echo "FAIL: (w2) backup path missing from data: $P_OUT" >&2
  fail=1
elif [[ "$backup_path" != docs/product.bak.* ]]; then
  echo "FAIL: (w2) backup path doesn't match docs/product.bak.<ts>: $backup_path" >&2
  fail=1
elif [ ! -f "$w2/$backup_path/technical-solutions.md" ] || \
     [ "$(cat "$w2/$backup_path/technical-solutions.md")" != "old content" ]; then
  echo "FAIL: (w2) backup doesn't contain old content" >&2
  fail=1
fi

# --- (w3) argv guard: missing tmpdir -> ok:false -----------------------------

w3="$(new_project_dir)"
run_pb "$w3" swap
assert_eq "(w3) exit code" "1" "$P_EXIT"
assert_eq "(w3) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"

# --- (w4) nonexistent tmpdir -> ok:false -------------------------------------

w4="$(new_project_dir)"
run_pb "$w4" swap does-not-exist
assert_eq "(w4) exit code" "1" "$P_EXIT"
assert_eq "(w4) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"

# ============================================================================
# archive
# ============================================================================

# --- (a1) no conflicts, dotglob (hidden file moved too) ---------------------

a1="$(new_project_dir)"
mkdir -p "$a1/raw_src"
echo "note" >"$a1/raw_src/notes.md"
echo "secret" >"$a1/raw_src/.hidden"
run_pb "$a1" archive raw_src
assert_eq "(a1) exit code" "0" "$P_EXIT"
assert_eq "(a1) ok:true" "True" "$(json_field "$P_OUT" 'd["ok"]')"
if [ ! -f "$a1/docs/product/_raw/notes.md" ]; then
  echo "FAIL: (a1) notes.md not archived" >&2
  fail=1
fi
if [ ! -f "$a1/docs/product/_raw/.hidden" ]; then
  echo "FAIL: (a1) dotfile .hidden not archived (dotglob)" >&2
  fail=1
fi

# --- (a2) conflict: dest already has same filename -> ok:false, conflicts list,
#          nothing moved (src still there, dest content unchanged) -----------

a2="$(new_project_dir)"
mkdir -p "$a2/docs/product/_raw" "$a2/raw_src"
echo "original" >"$a2/docs/product/_raw/notes.md"
echo "incoming" >"$a2/raw_src/notes.md"
run_pb "$a2" archive raw_src
assert_eq "(a2) exit code" "1" "$P_EXIT"
assert_eq "(a2) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"
assert_eq "(a2) conflicts count" "1" "$(json_field "$P_OUT" 'len(d["data"]["conflicts"])')"
assert_eq "(a2) conflict name" "notes.md" "$(json_field "$P_OUT" 'd["data"]["conflicts"][0]')"
assert_eq "(a2) dest content unchanged (no clobber)" "original" "$(cat "$a2/docs/product/_raw/notes.md")"
assert_eq "(a2) src file untouched (nothing moved)" "incoming" "$(cat "$a2/raw_src/notes.md")"

# --- (a3) single loose file as src (not a dir) -------------------------------

a3="$(new_project_dir)"
echo "loose" >"$a3/loose.md"
run_pb "$a3" archive loose.md
assert_eq "(a3) exit code" "0" "$P_EXIT"
if [ ! -f "$a3/docs/product/_raw/loose.md" ]; then
  echo "FAIL: (a3) loose file not archived" >&2
  fail=1
fi

# --- (a4) argv guard: missing src -> ok:false --------------------------------

a4="$(new_project_dir)"
run_pb "$a4" archive
assert_eq "(a4) exit code" "1" "$P_EXIT"
assert_eq "(a4) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"

# ============================================================================
# main argv guards
# ============================================================================

# --- unknown subcommand -------------------------------------------------------

m1="$(new_project_dir)"
run_pb "$m1" bogus-cmd
assert_eq "(m1) exit code" "1" "$P_EXIT"
assert_eq "(m1) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"

# --- missing subcommand -------------------------------------------------------

m2="$(new_project_dir)"
P_OUT="$(cd "$m2" && "$pb" 2>/tmp/mvp-pb-test-err)"
P_EXIT=$?
assert_eq "(m2) exit code" "1" "$P_EXIT"
assert_eq "(m2) ok:false" "False" "$(json_field "$P_OUT" 'd["ok"]')"

exit $fail
