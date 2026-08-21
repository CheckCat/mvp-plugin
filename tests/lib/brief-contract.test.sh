#!/usr/bin/env bash
# Tests for lib/brief-contract.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
source "$repo_root/lib/brief-contract.sh"

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    fail=1
  fi
}

# --- fixtures ---------------------------------------------------------------

valid_file="$tmpdir/technical_solutions_valid.md"
cat >"$valid_file" <<'EOF'
# Technical solutions

## Stack
Backend: fastapi

## Services
api, worker

## Auth
argon2id + JWT RTR

## Deploy
Docker Compose via Dokploy
EOF

empty_section_file="$tmpdir/technical_solutions_empty.md"
cat >"$empty_section_file" <<'EOF'
# Technical solutions

## Stack

## Services
api, worker

## Auth
argon2id + JWT RTR

## Deploy
Docker Compose via Dokploy
EOF

headers=("## Stack" "## Services" "## Auth" "## Deploy")

# --- (a) valid file -> validate_headers exit 0 ------------------------------

if validate_headers "$valid_file" "${headers[@]}" 2>/tmp/mvp-bc-test-err; then
  :
else
  echo "FAIL: (a) valid file expected exit 0, got 1" >&2
  cat /tmp/mvp-bc-test-err >&2
  fail=1
fi

# --- (b) empty section -> validate_headers exit 1 --------------------------

if validate_headers "$empty_section_file" "${headers[@]}" 2>/tmp/mvp-bc-test-err; then
  echo "FAIL: (b) empty section expected exit 1, got 0" >&2
  fail=1
else
  if [ ! -s /tmp/mvp-bc-test-err ]; then
    echo "FAIL: (b) empty section expected diagnostics on stderr, got none" >&2
    fail=1
  fi
fi

# --- required_headers_tech / required_headers_biz sanity -------------------

tech_headers="$(required_headers_tech)"
assert_eq "required_headers_tech contains ## Stack" "## Stack" "$(echo "$tech_headers" | sed -n '1p')"

biz_headers="$(required_headers_biz)"
assert_eq "required_headers_biz contains ## Goal" "## Goal" "$(echo "$biz_headers" | sed -n '1p')"

# --- (c) validate_stack fastapi react docker-dokploy postgresql,redis -> 0 -

out_c="$(validate_stack fastapi react docker-dokploy postgresql,redis)"
rc_c=$?
assert_eq "(c) validate_stack valid combo exit code" "0" "$rc_c"
if ! echo "$out_c" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True' 2>/tmp/mvp-bc-test-err; then
  echo "FAIL: (c) validate_stack output is not valid ok:true JSON: $out_c" >&2
  cat /tmp/mvp-bc-test-err >&2
  fail=1
fi

# --- (d) validate_stack django ... -> exit 1 --------------------------------

out_d="$(validate_stack django react docker-dokploy postgresql)"
rc_d=$?
assert_eq "(d) validate_stack invalid backend exit code" "1" "$rc_d"
if ! echo "$out_d" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False' 2>/tmp/mvp-bc-test-err; then
  echo "FAIL: (d) validate_stack output is not valid ok:false JSON: $out_d" >&2
  cat /tmp/mvp-bc-test-err >&2
  fail=1
fi

# --- (e) layout_for_stack ----------------------------------------------------

assert_eq "layout_for_stack fastapi react 3" "services" "$(layout_for_stack fastapi react 3)"
assert_eq "layout_for_stack fastapi react 1" "app" "$(layout_for_stack fastapi react 1)"
assert_eq "layout_for_stack nestjs nextjs 2" "packages" "$(layout_for_stack nestjs nextjs 2)"

exit $fail
