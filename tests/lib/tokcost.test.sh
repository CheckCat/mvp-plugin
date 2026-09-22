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
# req_2 НЕ имеет cache_creation-объекта — fallback должен читать плоское поле.
cat > "$tmpdir/agent-a1.jsonl" <<'EOF'
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_2","message":{"model":"claude-sonnet-5","usage":{"input_tokens":3,"cache_creation_input_tokens":50,"cache_read_input_tokens":2000,"output_tokens":10}}}
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
# (4) запись без cache_creation-объекта: cw = плоское поле в 5m-колонку; req_2 даёт 50, req_1 даёт 100
assert_eq "cw с fallback" "150" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cw"])')"
# (5) столбец base_input (index 0) = 2 + 3 = 5
assert_eq "base_input" "5" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["base"])')"

# (6) merge(): два счётчика по одной модели складываются поэлементно, новая модель появляется из src
TOKCOST_DIR="$repo_root/scripts/experiments" python3 -c '
import os, sys, json
sys.path.insert(0, os.environ["TOKCOST_DIR"])
from tokcost import merge

# dst: {sonnet: [10, 5, 0, 20, 30]}
# src: {sonnet: [2, 3, 1, 5, 10], opus: [1, 1, 1, 1, 1]}
dst = {"claude-sonnet-5": [10, 5, 0, 20, 30]}
src = {"claude-sonnet-5": [2, 3, 1, 5, 10], "claude-opus-4": [1, 1, 1, 1, 1]}
merge(dst, src)

# ожидание: sonnet поэлементно сложился, opus появился из src
if dst != {"claude-sonnet-5": [12, 8, 1, 25, 40], "claude-opus-4": [1, 1, 1, 1, 1]}:
  print("FAIL: merge() — неправильный результат", file=__import__("sys").stderr)
  __import__("sys").exit(1)
'
if [ $? -ne 0 ]; then
  fail=1
fi

exit $fail
