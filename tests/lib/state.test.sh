#!/usr/bin/env bash
# Tests for lib/state.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

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

# Helper to parse JSON and extract a field
json_get_field() {
  local json="$1" field="$2"
  python3 -c "import json,sys; d=json.loads('$json'); print(d.get('$field'))" 2>/dev/null || echo "null"
}

# Helper to extract data.value from JSON response
json_get_data_value() {
  local json="$1"
  python3 -c "import json,sys; d=json.loads('$json'); print(json.dumps(d.get('data', {}).get('value')))" 2>/dev/null || echo "null"
}

# --- Test 1: init creates {"phase":"brief"} -----

STATE_DIR="$tmpdir" bash "$repo_root/lib/state.sh" init >/tmp/state-test-out 2>&1
init_exit=$?
init_output="$(cat /tmp/state-test-out)"

if [ $init_exit -eq 0 ]; then
  if echo "$init_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True' 2>/dev/null; then
    :
  else
    echo "FAIL: test 1 (init) output not valid ok:true JSON: $init_output" >&2
    fail=1
  fi
else
  echo "FAIL: test 1 (init) expected exit 0, got $init_exit" >&2
  fail=1
fi

# Verify state.json was created with correct content
if [ -f "$tmpdir/state.json" ]; then
  state_content="$(cat "$tmpdir/state.json")"
  if python3 -c "import json; d=json.loads('$state_content'); assert d.get('phase') == 'brief'" 2>/dev/null; then
    :
  else
    echo "FAIL: test 1 (init) state.json not created correctly, got: $state_content" >&2
    fail=1
  fi
else
  echo "FAIL: test 1 (init) state.json not created" >&2
  fail=1
fi

# --- Test 2: set pending_critical 2, then get pending_critical -> "value":2 (number) ---

STATE_DIR="$tmpdir" bash "$repo_root/lib/state.sh" set pending_critical 2 >/tmp/state-test-out 2>&1
set_exit=$?

if [ $set_exit -ne 0 ]; then
  echo "FAIL: test 2 (set) expected exit 0, got $set_exit" >&2
  fail=1
fi

STATE_DIR="$tmpdir" bash "$repo_root/lib/state.sh" get pending_critical >/tmp/state-test-out 2>&1
get_exit=$?
get_output="$(cat /tmp/state-test-out)"

if [ $get_exit -eq 0 ]; then
  # Verify it's valid JSON with ok:true
  if echo "$get_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True' 2>/dev/null; then
    # Verify data.value is the number 2 (not string "2")
    if echo "$get_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["value"] == 2' 2>/dev/null; then
      :
    else
      echo "FAIL: test 2 (get) data.value not number 2: $get_output" >&2
      fail=1
    fi
  else
    echo "FAIL: test 2 (get) output not valid JSON: $get_output" >&2
    fail=1
  fi
else
  echo "FAIL: test 2 (get) expected exit 0, got $get_exit" >&2
  fail=1
fi

# --- Test 3: set without init -> ok:false with hint ---

tmpdir2="$(mktemp -d)"
trap 'rm -rf "$tmpdir2"' EXIT

STATE_DIR="$tmpdir2" bash "$repo_root/lib/state.sh" set some_key some_value >/tmp/state-test-out 2>&1
set_noinit_exit=$?
set_noinit_output="$(cat /tmp/state-test-out)"

if [ $set_noinit_exit -ne 0 ]; then
  # Verify it's valid JSON with ok:false
  if echo "$set_noinit_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False' 2>/dev/null; then
    # Verify hint mentions init
    if echo "$set_noinit_output" | grep -q "state.sh init"; then
      :
    else
      echo "FAIL: test 3 (set without init) hint doesn't mention state.sh init: $set_noinit_output" >&2
      fail=1
    fi
  else
    echo "FAIL: test 3 (set without init) output not valid ok:false JSON: $set_noinit_output" >&2
    fail=1
  fi
else
  echo "FAIL: test 3 (set without init) expected exit non-zero, got $set_noinit_exit" >&2
  fail=1
fi

# --- Test 4: get non-existent key -> ok:true, data.value null ---

STATE_DIR="$tmpdir" bash "$repo_root/lib/state.sh" get nonexistent_key >/tmp/state-test-out 2>&1
get_missing_exit=$?
get_missing_output="$(cat /tmp/state-test-out)"

if [ $get_missing_exit -eq 0 ]; then
  # Verify it's valid JSON with ok:true
  if echo "$get_missing_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True' 2>/dev/null; then
    # Verify data.value is null
    if echo "$get_missing_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["value"] is None' 2>/dev/null; then
      :
    else
      echo "FAIL: test 4 (get missing) data.value not null: $get_missing_output" >&2
      fail=1
    fi
  else
    echo "FAIL: test 4 (get missing) output not valid JSON: $get_missing_output" >&2
    fail=1
  fi
else
  echo "FAIL: test 4 (get missing) expected exit 0, got $get_missing_exit" >&2
  fail=1
fi

# --- Test 5 (h): get without key -> exit 1 and valid JSON with ok:false (no traceback) ---

STATE_DIR="$tmpdir" bash "$repo_root/lib/state.sh" get >/tmp/state-test-out 2>&1
get_nokey_exit=$?
get_nokey_output="$(cat /tmp/state-test-out)"

if [ $get_nokey_exit -ne 0 ]; then
  # Verify output is valid JSON with ok:false (no Python traceback)
  if echo "$get_nokey_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False' 2>/dev/null; then
    # Ensure no "Traceback" or "IndexError" strings in output
    if echo "$get_nokey_output" | grep -q "Traceback\|IndexError"; then
      echo "FAIL: test 5 (get without key) output contains Python traceback: $get_nokey_output" >&2
      fail=1
    fi
  else
    echo "FAIL: test 5 (get without key) output not valid ok:false JSON: $get_nokey_output" >&2
    fail=1
  fi
else
  echo "FAIL: test 5 (get without key) expected exit non-zero, got $get_nokey_exit" >&2
  fail=1
fi

# --- Test 6 (i): set without value -> exit 1 and valid JSON with ok:false (no traceback) ---

STATE_DIR="$tmpdir" bash "$repo_root/lib/state.sh" set pending_critical >/tmp/state-test-out 2>&1
set_novalue_exit=$?
set_novalue_output="$(cat /tmp/state-test-out)"

if [ $set_novalue_exit -ne 0 ]; then
  # Verify output is valid JSON with ok:false (no Python traceback)
  if echo "$set_novalue_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False' 2>/dev/null; then
    # Ensure no "Traceback" or "IndexError" strings in output
    if echo "$set_novalue_output" | grep -q "Traceback\|IndexError"; then
      echo "FAIL: test 6 (set without value) output contains Python traceback: $set_novalue_output" >&2
      fail=1
    fi
  else
    echo "FAIL: test 6 (set without value) output not valid ok:false JSON: $set_novalue_output" >&2
    fail=1
  fi
else
  echo "FAIL: test 6 (set without value) expected exit non-zero, got $set_novalue_exit" >&2
  fail=1
fi

# --- Test 7 (i): state.json parses as valid JSON after set ---

# Create fresh tmpdir for this test
tmpdir3="$(mktemp -d)"
trap 'rm -rf "$tmpdir3"' EXIT

STATE_DIR="$tmpdir3" bash "$repo_root/lib/state.sh" init >/dev/null 2>&1
STATE_DIR="$tmpdir3" bash "$repo_root/lib/state.sh" set test_key test_value >/dev/null 2>&1

if [ -f "$tmpdir3/state.json" ]; then
  if python3 -c "import json; json.load(open('$tmpdir3/state.json'))" 2>/dev/null; then
    :
  else
    echo "FAIL: test 7 (state.json valid after set) state.json is corrupted: $(cat "$tmpdir3/state.json")" >&2
    fail=1
  fi
else
  echo "FAIL: test 7 (state.json valid after set) state.json not found" >&2
  fail=1
fi

exit $fail
