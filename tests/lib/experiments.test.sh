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
    "threshold": "value >= 1", "ttl_runs": 9, "opened": "2026-09-22" },
  { "id": "T-verdict", "title": "t", "status": "open", "mode_required": "passive",
    "check_script": "scripts/experiments/t-verdict.sh",
    "threshold": "value >= 1", "ttl_runs": 1, "opened": "2026-09-22" }
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
cat > "$tmpdir/plug/scripts/experiments/t-verdict.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"reason":null,"hint":null,"data":{"value":7,"verdict":"refuted"}}'
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

# (5) list: T-pass (без вердикта — check-скрипт всегда отдаёт verdict:null) прогоняется
# на run-1/run-2/run-3 — перед каждым прогоном runs_seen (0, затем 1, затем 2) ещё
# < ttl_runs=3, гипотеза не expired. После третьего прогона runs_seen=3, verdict_seen
# отсутствует, и 3 >= ttl_runs=3 → expired_candidate (спека: «>=ttl_runs БЕЗ вердикта»).
# T-verdict истекает ttl (ttl_runs=1) уже после первого прогона, но её check-скрипт
# всегда отдаёт непустой verdict — по той же спеке она обязана НЕ стать expired_candidate,
# иначе вывод, ради сохранения которого механизм существует, был бы потерян.
out="$(bash "$tmpdir/plug/lib/experiments.sh" list | last_line)"
assert_eq "list ok" "True" "$(jget "$out" 'd["ok"]')"
assert_eq "runs_seen из results" "3" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-pass"][0]["runs_seen"]')"
assert_eq "T-pass: verdict_seen отсутствует" "None" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-pass"][0]["verdict_seen"]')"
assert_eq "ttl исчерпан без вердикта → expired-candidate" "True" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-pass"][0]["expired_candidate"]')"
assert_eq "T-verdict: runs_seen" "3" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-verdict"][0]["runs_seen"]')"
assert_eq "T-verdict: verdict_seen непустой" "refuted" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-verdict"][0]["verdict_seen"]')"
assert_eq "ttl исчерпан, но есть вердикт → НЕ expired-candidate" "False" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-verdict"][0]["expired_candidate"]')"

# (6) на run-4: T-pass уже expired_candidate (см. (5), без вердикта) — check её пропускает,
# число записей T-pass в results.jsonl не растёт. T-verdict, наоборот, исчерпала ttl,
# но имеет вердикт — по спеке check обязан продолжать её прогонять, а не молчаливо
# считать expired только потому, что ttl вышел.
n_before="$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"
n_verdict_before="$(grep -c '"T-verdict"' .mvp/experiments/results.jsonl)"
bash "$tmpdir/plug/lib/experiments.sh" check run-4 >/dev/null
assert_eq "expired без вердикта не прогоняется" "$n_before" "$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"
n_verdict_after="$(grep -c '"T-verdict"' .mvp/experiments/results.jsonl)"
[ "$n_verdict_after" -gt "$n_verdict_before" ] || { echo "FAIL: гипотеза с вердиктом должна продолжать проверяться после исчерпания ttl (было $n_verdict_before, стало $n_verdict_after)" >&2; fail=1; }

# (7) add: без числа в threshold — отказ; с числом — входит; сверх cap (max_open=5) — отказ
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t","status":"open","mode_required":"passive","check_script":"scripts/experiments/x.sh","threshold":"без числа","ttl_runs":5,"opened":"2026-09-22"}' | last_line)" || true
assert_eq "add без числа в threshold" "False" "$(jget "$out" 'd["ok"]')"
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t","status":"open","mode_required":"passive","check_script":"scripts/experiments/x.sh","threshold":"value >= 3","ttl_runs":5,"opened":"2026-09-22"}' | last_line)"
assert_eq "add ok" "True" "$(jget "$out" 'd["ok"]')"
for i in 5 6 7; do
  bash "$tmpdir/plug/lib/experiments.sh" add --json "{\"id\":\"T-fill$i\",\"title\":\"t\",\"status\":\"open\",\"mode_required\":\"passive\",\"check_script\":\"scripts/experiments/x.sh\",\"threshold\":\"value >= $i\",\"ttl_runs\":5,\"opened\":\"2026-09-22\"}" >/dev/null 2>&1 || true
done
out="$(bash "$tmpdir/plug/lib/experiments.sh" list | last_line)"
n_open="$(jget "$out" 'len([h for h in d["data"]["hypotheses"] if h["status"] in ("open","needs-optin")])')"
assert_eq "max_open=5 соблюдён ровно" "5" "$n_open"
# (8) дубликат id — отказ
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t2","status":"open","mode_required":"passive","check_script":"s.sh","threshold":"value >= 1","ttl_runs":5,"opened":"2026-09-22"}' | last_line)" || true
assert_eq "дубликат id" "False" "$(jget "$out" 'd["ok"]')"

# (9) битый registry.json (невалидный JSON) — list/add/check обязаны ответить контрактным
# {"ok":false,...} и exit 1, а не упасть traceback'ом без единой строки на stdout.
tmpdir_bad="$tmpdir/plug-badjson"
mkdir -p "$tmpdir_bad/lib" "$tmpdir_bad/docs/experiments"
cp "$repo_root/lib/experiments.sh" "$tmpdir_bad/lib/"
cp "$repo_root/lib/state.sh" "$tmpdir_bad/lib/"
printf '{ this is not json' > "$tmpdir_bad/docs/experiments/registry.json"

out="$(bash "$tmpdir_bad/lib/experiments.sh" list)"; ec=$?
last="$(printf '%s' "$out" | last_line)"
assert_eq "битый registry: list exit code" "1" "$ec"
assert_eq "битый registry: list ok" "False" "$(jget "$last" 'd["ok"]')"

out="$(bash "$tmpdir_bad/lib/experiments.sh" add --json '{"id":"X","title":"t","status":"open","mode_required":"passive","check_script":"s.sh","threshold":"value >= 1","ttl_runs":5,"opened":"2026-09-22"}')"; ec=$?
last="$(printf '%s' "$out" | last_line)"
assert_eq "битый registry: add exit code" "1" "$ec"
assert_eq "битый registry: add ok" "False" "$(jget "$last" 'd["ok"]')"

out="$(bash "$tmpdir_bad/lib/experiments.sh" check run-x)"; ec=$?
last="$(printf '%s' "$out" | last_line)"
assert_eq "битый registry: check exit code" "1" "$ec"
assert_eq "битый registry: check ok" "False" "$(jget "$last" 'd["ok"]')"

# (10) отсутствующий registry.json — то же самое: контрактный ok:false, exit 1, без traceback.
tmpdir_missing="$tmpdir/plug-missing"
mkdir -p "$tmpdir_missing/lib"
cp "$repo_root/lib/experiments.sh" "$tmpdir_missing/lib/"
cp "$repo_root/lib/state.sh" "$tmpdir_missing/lib/"
# docs/experiments/registry.json намеренно не создаём

out="$(bash "$tmpdir_missing/lib/experiments.sh" list)"; ec=$?
last="$(printf '%s' "$out" | last_line)"
assert_eq "отсутствующий registry: list exit code" "1" "$ec"
assert_eq "отсутствующий registry: list ok" "False" "$(jget "$last" 'd["ok"]')"

out="$(bash "$tmpdir_missing/lib/experiments.sh" add --json '{"id":"X","title":"t","status":"open","mode_required":"passive","check_script":"s.sh","threshold":"value >= 1","ttl_runs":5,"opened":"2026-09-22"}')"; ec=$?
last="$(printf '%s' "$out" | last_line)"
assert_eq "отсутствующий registry: add exit code" "1" "$ec"
assert_eq "отсутствующий registry: add ok" "False" "$(jget "$last" 'd["ok"]')"

out="$(bash "$tmpdir_missing/lib/experiments.sh" check run-x)"; ec=$?
last="$(printf '%s' "$out" | last_line)"
assert_eq "отсутствующий registry: check exit code" "1" "$ec"
assert_eq "отсутствующий registry: check ok" "False" "$(jget "$last" 'd["ok"]')"

exit $fail
