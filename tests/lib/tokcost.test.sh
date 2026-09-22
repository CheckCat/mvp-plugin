#!/usr/bin/env bash
# Tests for scripts/experiments/tokcost.py — дедуп по requestId обязателен:
# наивная сумма завышает output в ~2.2x (см. observation 2026-09-22).
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

# Фикстура: один requestId написан трижды (стрим), второй — один раз.
cat > "$tmpdir/agent-a1.jsonl" <<'EOF'
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_2","message":{"model":"claude-sonnet-5","usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000,"output_tokens":10}}}
{"type":"user","noise":true}
EOF

out="$(TOKCOST_DIR="$repo_root/scripts/experiments" TOKCOST_PATH="$tmpdir/agent-a1.jsonl" python3 -c '
import os, sys, json
sys.path.insert(0, os.environ["TOKCOST_DIR"])
from tokcost import scan
agg, n = scan(os.environ["TOKCOST_PATH"])
v = agg["claude-sonnet-5"]
print(json.dumps({"n": n, "out": v[4], "cr": v[3], "cw": v[1] + v[2], "base": v[0]}))
')"
# (1) два уникальных запроса, не четыре
assert_eq "уникальных запросов" "2" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n"])')"
# (2) output = max(1,50,200) + 10 = 210 — НЕ сумма 251+10
assert_eq "output с дедупом" "210" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["out"])')"
# (3) cache_read = 1000 + 2000, не 3000+2000
assert_eq "cache_read с дедупом" "3000" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cr"])')"
# (4) запись без cache_creation-объекта: cw = плоское поле, в 5m-колонку
assert_eq "cw" "100" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cw"])')"

exit $fail
