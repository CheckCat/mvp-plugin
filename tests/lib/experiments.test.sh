#!/usr/bin/env bash
# Tests for lib/experiments.sh — гигиена реестра enforced скриптом.
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
last_line() { tail -n 1; }
jget() { # <json> <py-expr over d>
  J="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["J"]); print(eval(os.environ["E"]))'
}

# Песочница-плагин: experiments.sh читает registry относительно себя,
# поэтому копируем lib + свой registry в фикстуру.
mkdir -p "$tmpdir/plug/lib" "$tmpdir/plug/docs/experiments" "$tmpdir/plug/scripts/experiments"
cp "$repo_root/lib/experiments.sh" "$tmpdir/plug/lib/"
cp "$repo_root/lib/state.sh" "$tmpdir/plug/lib/"
cat > "$tmpdir/plug/docs/experiments/registry.json" <<'EOF'
{ "version": 1, "max_open": 5, "hypotheses": [
  { "id": "T-pass", "title": "t", "status": "open", "mode_required": "passive",
    "check_script": "scripts/experiments/t-pass.sh",
    "threshold": "value >= 1", "ttl_runs": 3, "opened": "2026-09-22" },
  { "id": "T-greedy", "title": "t", "status": "needs-optin", "mode_required": "greedy",
    "check_script": "scripts/experiments/t-greedy.sh",
    "threshold": "value >= 1", "ttl_runs": 9, "opened": "2026-09-22" },
  { "id": "T-missing", "title": "t", "status": "open", "mode_required": "passive",
    "check_script": "scripts/experiments/no-such.sh",
    "threshold": "value >= 1", "ttl_runs": 9, "opened": "2026-09-22" }
] }
EOF
cat > "$tmpdir/plug/scripts/experiments/t-pass.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"reason":null,"hint":null,"data":{"value":42,"verdict":null}}'
EOF
cat > "$tmpdir/plug/scripts/experiments/t-greedy.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"reason":null,"hint":null,"data":{"value":1,"verdict":"confirmed"}}'
EOF
chmod +x "$tmpdir/plug/scripts/experiments/"*.sh

# Проект-фикстура
mkdir -p "$tmpdir/proj/.mvp"
cd "$tmpdir/proj"

# (1) off: check ничего не пишет и ok:true
echo '{"phase":"done","experiments":"off"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-1 | last_line)"
assert_eq "off: ok" "True" "$(jget "$out" 'd["ok"]')"
[ -f .mvp/experiments/results.jsonl ] && { echo "FAIL: off-режим записал results" >&2; fail=1; }

# (2) passive: passive-гипотеза прогнана, greedy — пропущена, missing — залогирована, не упала
echo '{"phase":"done","experiments":"passive"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-1 | last_line)"
assert_eq "passive: ok" "True" "$(jget "$out" 'd["ok"]')"
assert_eq "passive: T-pass записан" "1" "$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"
assert_eq "passive: T-greedy пропущен" "0" "$(grep -c '"T-greedy"' .mvp/experiments/results.jsonl)"
assert_eq "passive: missing-скрипт как skipped, не crash" "True" "$(jget "$out" '"script missing" in json.dumps(d["data"])')"

# (3) greedy: обе прогнаны; вердикт confirmed доехал до results
echo '{"phase":"done","experiments":"greedy"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-2 | last_line)"
assert_eq "greedy: T-greedy записан" "1" "$(grep -c '"T-greedy"' .mvp/experiments/results.jsonl)"
assert_eq "greedy: verdict" "1" "$(grep -c '"verdict": "confirmed"' .mvp/experiments/results.jsonl)"

# (4) отсутствующий ключ experiments = greedy (альфа-дефолт)
echo '{"phase":"done"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-3 | last_line)"
assert_eq "дефолт greedy" "2" "$(grep -c '"T-greedy"' .mvp/experiments/results.jsonl)"

# (5) list: T-pass прогоняется на run-1/run-2/run-3 — перед каждым прогоном
# runs_seen (0, затем 1, затем 2) ещё < ttl_runs=3, гипотеза не expired.
# После третьего прогона runs_seen=3, и 3 >= ttl_runs=3 → expired_candidate.
out="$(bash "$tmpdir/plug/lib/experiments.sh" list | last_line)"
assert_eq "list ok" "True" "$(jget "$out" 'd["ok"]')"
assert_eq "runs_seen из results" "3" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-pass"][0]["runs_seen"]')"
assert_eq "ttl исчерпан → expired-candidate" "True" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-pass"][0]["expired_candidate"]')"

# (6) на run-4 T-pass уже expired_candidate (см. (5)) — check её пропускает,
# число записей T-pass в results.jsonl не растёт.
n_before="$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"
bash "$tmpdir/plug/lib/experiments.sh" check run-4 >/dev/null
assert_eq "expired не прогоняется" "$n_before" "$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"

# (7) add: без числа в threshold — отказ; с числом — входит; шестая открытая — отказ
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t","status":"open","mode_required":"passive","check_script":"scripts/experiments/x.sh","threshold":"без числа","ttl_runs":5,"opened":"2026-09-22"}' | last_line)" || true
assert_eq "add без числа в threshold" "False" "$(jget "$out" 'd["ok"]')"
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t","status":"open","mode_required":"passive","check_script":"scripts/experiments/x.sh","threshold":"value >= 3","ttl_runs":5,"opened":"2026-09-22"}' | last_line)"
assert_eq "add ok" "True" "$(jget "$out" 'd["ok"]')"
for i in 5 6 7; do
  bash "$tmpdir/plug/lib/experiments.sh" add --json "{\"id\":\"T-fill$i\",\"title\":\"t\",\"status\":\"open\",\"mode_required\":\"passive\",\"check_script\":\"scripts/experiments/x.sh\",\"threshold\":\"value >= $i\",\"ttl_runs\":5,\"opened\":\"2026-09-22\"}" >/dev/null 2>&1 || true
done
out="$(bash "$tmpdir/plug/lib/experiments.sh" list | last_line)"
n_open="$(jget "$out" 'len([h for h in d["data"]["hypotheses"] if h["status"] in ("open","needs-optin")])')"
[ "$n_open" -le 5 ] || { echo "FAIL: max_open=5 нарушен, открытых $n_open" >&2; fail=1; }
# (8) дубликат id — отказ
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t2","status":"open","mode_required":"passive","check_script":"s.sh","threshold":"value >= 1","ttl_runs":5,"opened":"2026-09-22"}' | last_line)" || true
assert_eq "дубликат id" "False" "$(jget "$out" 'd["ok"]')"

exit $fail
