#!/usr/bin/env bash
set -u; fail=0
for t in "$(dirname "$0")"/lib/*.test.sh; do
  [ -e "$t" ] || continue
  if bash "$t" >/tmp/mvp-test-out 2>&1; then echo "PASS $(basename "$t")"
  else echo "FAIL $(basename "$t")"; cat /tmp/mvp-test-out; fail=1; fi
done
exit $fail
