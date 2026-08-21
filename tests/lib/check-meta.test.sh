#!/usr/bin/env bash
# Tests for skills/bootstrap/scripts/check-meta.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
cm="$repo_root/skills/bootstrap/scripts/check-meta.sh"

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

violations_of_check() { # <json> <check> -> newline-separated details for that check
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for v in d["data"]["violations"]:
    if v["check"] == sys.argv[2]:
        print(v["detail"])
' "$1" "$2" 2>/dev/null
}

# Every fixture gets a VALID .claude/state/ci-mirror.sh by default — it is a
# check-meta gate now (a real bootstrap always has one by Step 3.2), so the
# cases that are about CLAUDE.md/ARCHITECTURE.md must not trip over it.
# check-meta.sh now EXECUTES this mirror (not just `bash -n`), so the default
# must be guard-safe on the empty fixture tree (no pyproject.toml here) —
# same existence-guard pattern as skills/bootstrap/SKILL.md Step 3.2's
# fastapi block. An unguarded `uv run ruff check .` would fail for real here
# (no pyproject.toml / no ruff installed) and spuriously trip every case
# below with ci-mirror-exec. The ci-mirror cases further down deliberately
# remove/corrupt/unguard it to exercise that gate on purpose.
new_project_dir() {
  local d
  d="$(mktemp -d -p "$tmproot")"
  mkdir -p "$d/.claude/state"
  printf 'if [ -f pyproject.toml ]; then uv run ruff check .; fi\nif [ -f pyproject.toml ]; then uv run pytest; fi\n' >"$d/.claude/state/ci-mirror.sh"
  printf '%s' "$d"
}

write_valid_claude_md() { # <dir>
  cat >"$1/CLAUDE.md" <<'EOF'
# Project

## Стек

FastAPI + React.

## Команды (CI = local)

pytest, ruff.

## Правила, специфичные для проекта

Не делай глупостей.
EOF
}

write_valid_architecture_md() { # <dir>
  mkdir -p "$1"
  cat >"$1/ARCHITECTURE.md" <<'EOF'
# Architecture

```mermaid
graph TD
  api --> DB
  worker --> Redis
```
EOF
}

run_cm() { # <projectdir> <arg...> -> sets CM_OUT CM_EXIT
  local dir="$1"
  shift
  CM_OUT="$(cd "$dir" && "$cm" "$@" 2>/tmp/mvp-cm-test-err)"
  CM_EXIT=$?
  local lines
  lines="$(printf '%s' "$CM_OUT" | wc -l | tr -d ' ')"
  if [ "$lines" != "0" ]; then
    echo "FAIL: (json) output is not single-line for args [$*]: $CM_OUT" >&2
    fail=1
  fi
}

# --- (a) valid CLAUDE.md + valid ARCHITECTURE.md, no invariants -> ok:true --

d_a="$(new_project_dir)"
write_valid_claude_md "$d_a"
write_valid_architecture_md "$d_a"

run_cm "$d_a"

assert_eq "(a) exit code" "0" "$CM_EXIT"
assert_eq "(a) ok:true" "True" "$(json_field "$CM_OUT" 'd["ok"]')"
assert_eq "(a) no violations" "0" "$(json_field "$CM_OUT" 'len(d["data"]["violations"])')"

# --- (b) CLAUDE.md 151+ lines -> violation claude-md-length -----------------

d_b="$(new_project_dir)"
write_valid_claude_md "$d_b"
{
  echo ""
  for i in $(seq 1 200); do echo "line $i"; done
} >>"$d_b/CLAUDE.md"
write_valid_architecture_md "$d_b"

run_cm "$d_b"

assert_eq "(b) exit code" "1" "$CM_EXIT"
assert_eq "(b) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
if [ -z "$(violations_of_check "$CM_OUT" claude-md-length)" ]; then
  echo "FAIL: (b) expected a claude-md-length violation: $CM_OUT" >&2
  fail=1
fi

# --- (c) CLAUDE.md missing required section (## Правила) -> violation -------

d_c="$(new_project_dir)"
cat >"$d_c/CLAUDE.md" <<'EOF'
# Project

## Стек

FastAPI.

## Команды

pytest.
EOF
write_valid_architecture_md "$d_c"

run_cm "$d_c"

assert_eq "(c) exit code" "1" "$CM_EXIT"
assert_eq "(c) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
SEC_C="$(violations_of_check "$CM_OUT" claude-md-section)"
if ! printf '%s' "$SEC_C" | grep -q "Правила"; then
  echo "FAIL: (c) expected claude-md-section violation mentioning Правила: $CM_OUT" >&2
  fail=1
fi

# --- (d) ARCHITECTURE.md forbidden edge (glob rule) -> violation ------------

d_d="$(new_project_dir)"
write_valid_claude_md "$d_d"
mkdir -p "$d_d/.claude/state"
cat >"$d_d/.claude/state/invariants.md" <<'EOF'
# Invariants

FORBIDDEN_EDGE: integration-* --> DB
EOF
cat >"$d_d/ARCHITECTURE.md" <<'EOF'
# Architecture

```mermaid
graph TD
  integration-tiktok --> DB
  api --> DB
```
EOF

run_cm "$d_d"

assert_eq "(d) exit code" "1" "$CM_EXIT"
assert_eq "(d) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
EDGE_D="$(violations_of_check "$CM_OUT" architecture-forbidden-edge)"
if ! printf '%s' "$EDGE_D" | grep -q "integration-tiktok"; then
  echo "FAIL: (d) expected architecture-forbidden-edge violation mentioning integration-tiktok: $CM_OUT" >&2
  fail=1
fi

# --- (e) ARCHITECTURE.md clean diagram (same rule, no matching edge) -> ok:true

d_e="$(new_project_dir)"
write_valid_claude_md "$d_e"
mkdir -p "$d_e/.claude/state"
cat >"$d_e/.claude/state/invariants.md" <<'EOF'
FORBIDDEN_EDGE: integration-* --> DB
EOF
cat >"$d_e/ARCHITECTURE.md" <<'EOF'
# Architecture

```mermaid
graph TD
  api --> DB
  integration-tiktok --> queue
```
EOF

run_cm "$d_e"

assert_eq "(e) exit code" "0" "$CM_EXIT"
assert_eq "(e) ok:true" "True" "$(json_field "$CM_OUT" 'd["ok"]')"

# --- (e2) forbidden edge ONLY inside a %% comment, plus a clean real edge ---
# -> ok:true (regression: a commented-out edge must never trigger a violation)

d_e2="$(new_project_dir)"
write_valid_claude_md "$d_e2"
mkdir -p "$d_e2/.claude/state"
cat >"$d_e2/.claude/state/invariants.md" <<'EOF'
FORBIDDEN_EDGE: integration-* --> DB
EOF
cat >"$d_e2/ARCHITECTURE.md" <<'EOF'
# Architecture

```mermaid
graph TD
  %% integration-tiktok --> DB (forbidden, kept here only as a comment)
  integration-tiktok --> queue
  api --> DB
```
EOF

run_cm "$d_e2"

assert_eq "(e2) exit code" "0" "$CM_EXIT"
assert_eq "(e2) ok:true" "True" "$(json_field "$CM_OUT" 'd["ok"]')"
assert_eq "(e2) no violations" "0" "$(json_field "$CM_OUT" 'len(d["data"]["violations"])')"

# --- (f) argv guard: unexpected argument -> ok:false, exit 1 ----------------

d_f="$(new_project_dir)"
write_valid_claude_md "$d_f"
write_valid_architecture_md "$d_f"

run_cm "$d_f" --bogus-flag

assert_eq "(f) argv guard exit code" "1" "$CM_EXIT"
assert_eq "(f) argv guard ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
if [ -z "$(json_field "$CM_OUT" 'd["hint"]')" ]; then
  echo "FAIL: (f) argv guard hint missing: $CM_OUT" >&2
  fail=1
fi

# --- (g) missing CLAUDE.md entirely -> violation claude-md-missing ----------

d_g="$(new_project_dir)"
write_valid_architecture_md "$d_g"

run_cm "$d_g"

assert_eq "(g) exit code" "1" "$CM_EXIT"
assert_eq "(g) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
if [ -z "$(violations_of_check "$CM_OUT" claude-md-missing)" ]; then
  echo "FAIL: (g) expected claude-md-missing violation: $CM_OUT" >&2
  fail=1
fi

# --- (h) ci-mirror.sh missing -> violation ci-mirror-missing ----------------
# (the (a) case above already covers the positive side: a valid mirror -> ok)

d_h="$(new_project_dir)"
write_valid_claude_md "$d_h"
write_valid_architecture_md "$d_h"
rm "$d_h/.claude/state/ci-mirror.sh"

run_cm "$d_h"

assert_eq "(h) exit code" "1" "$CM_EXIT"
assert_eq "(h) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
if [ -z "$(violations_of_check "$CM_OUT" ci-mirror-missing)" ]; then
  echo "FAIL: (h) expected ci-mirror-missing violation: $CM_OUT" >&2
  fail=1
fi

# --- (h2) ci-mirror.sh present but comment-only -> ci-mirror-empty ----------

d_h2="$(new_project_dir)"
write_valid_claude_md "$d_h2"
write_valid_architecture_md "$d_h2"
printf '# TODO: fill in the CI commands\n\n' >"$d_h2/.claude/state/ci-mirror.sh"

run_cm "$d_h2"

assert_eq "(h2) exit code" "1" "$CM_EXIT"
assert_eq "(h2) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
if [ -z "$(violations_of_check "$CM_OUT" ci-mirror-empty)" ]; then
  echo "FAIL: (h2) expected ci-mirror-empty violation: $CM_OUT" >&2
  fail=1
fi

# --- (i) ci-mirror.sh with a bash syntax error -> ci-mirror-syntax ----------

d_i="$(new_project_dir)"
write_valid_claude_md "$d_i"
write_valid_architecture_md "$d_i"
printf 'if uv run pytest\nuv run ruff check .\n' >"$d_i/.claude/state/ci-mirror.sh"

run_cm "$d_i"

assert_eq "(i) exit code" "1" "$CM_EXIT"
assert_eq "(i) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
if [ -z "$(violations_of_check "$CM_OUT" ci-mirror-syntax)" ]; then
  echo "FAIL: (i) expected ci-mirror-syntax violation: $CM_OUT" >&2
  fail=1
fi

# --- (j) ci-mirror.sh syntax-valid but unguarded, fails on empty tree -------
# -> violation ci-mirror-exec. This is the R2 regression: `bash -n` alone
# lets a semantically-broken mirror (references a precondition that doesn't
# exist yet) through; check-meta.sh must now actually run it.

d_j="$(new_project_dir)"
write_valid_claude_md "$d_j"
write_valid_architecture_md "$d_j"
printf 'ls no-such-dir\n' >"$d_j/.claude/state/ci-mirror.sh"

run_cm "$d_j"

assert_eq "(j) exit code" "1" "$CM_EXIT"
assert_eq "(j) ok:false" "False" "$(json_field "$CM_OUT" 'd["ok"]')"
if [ -z "$(violations_of_check "$CM_OUT" ci-mirror-exec)" ]; then
  echo "FAIL: (j) expected ci-mirror-exec violation: $CM_OUT" >&2
  fail=1
fi

# --- (k) ci-mirror.sh fully guarded on an empty tree -> ok:true -------------
# Companion to (j): a mirror that guards every command with its own
# existence precondition (the pattern skills/bootstrap/SKILL.md Step 3.2
# mandates) must skip everything and exit 0 on a pre-code tree — the gate
# must not punish correctly-guarded mirrors.

d_k="$(new_project_dir)"
write_valid_claude_md "$d_k"
write_valid_architecture_md "$d_k"
printf 'if [ -d no-such-dir ]; then ls no-such-dir; fi\nif [ -f pyproject.toml ]; then uv run pytest; fi\n' >"$d_k/.claude/state/ci-mirror.sh"

run_cm "$d_k"

assert_eq "(k) exit code" "0" "$CM_EXIT"
assert_eq "(k) ok:true" "True" "$(json_field "$CM_OUT" 'd["ok"]')"
assert_eq "(k) no violations" "0" "$(json_field "$CM_OUT" 'len(d["data"]["violations"])')"

exit $fail
