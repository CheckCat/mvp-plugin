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
# Снимок ДО любых add — находка 5d (форматирование реестра при регистрации):
# сверяем позже, что все последующие add() не переформатировали уже бывшее
# в файле содержимое, а только дописали новые записи точечно.
cp "$tmpdir/plug/docs/experiments/registry.json" "$tmpdir/registry-before-add.json"
# t-pass заодно зонд наследования окружения (находка I1): JOURNALS_DIR
# приходит от вызывающего experiments.sh обычным bash-наследованием — если
# это сломается (например, check начнёт чистить env), reason это покажет.
cat > "$tmpdir/plug/scripts/experiments/t-pass.sh" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import json,os; print(json.dumps({"ok":True,"reason":"probe: journals=%s" % os.environ.get("JOURNALS_DIR","ABSENT"),"hint":None,"data":{"value":42,"verdict":None}}))'
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

# (2) passive: passive-гипотеза прогнана, greedy — пропущена, missing — залогирована, не упала.
# JOURNALS_DIR передан снаружи (как это делает retro Шаг 5) — обязан дойти
# до check-скрипта через окружение; reason скрипта — доехать до results.jsonl
# (находка I1: без reason голодание гипотезы неотличимо от данных).
echo '{"phase":"done","experiments":"passive"}' > .mvp/state.json
out="$(JOURNALS_DIR=/tmp/j-probe bash "$tmpdir/plug/lib/experiments.sh" check run-1 | last_line)"
assert_eq "passive: ok" "True" "$(jget "$out" 'd["ok"]')"
assert_eq "passive: T-pass записан" "1" "$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"
rec="$(grep '"T-pass"' .mvp/experiments/results.jsonl | tail -n 1)"
assert_eq "JOURNALS_DIR наследуется check-скриптом" "True" "$(jget "$rec" '"journals=/tmp/j-probe" in (d.get("reason") or "")')"
assert_eq "reason пишется в results.jsonl" "True" "$(jget "$rec" '"reason" in d')"
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

# (11) проводка JOURNALS_DIR (находка I1): Шаг 5 retro обязан передавать
# каталог журналов, справочник — описывать переменную в контракте env и
# объяснять цену её отсутствия (голодание гипотез).
grep -qF 'JOURNALS_DIR=<каталог agent-*.jsonl из Шага 3> ${CLAUDE_PLUGIN_ROOT}/lib/experiments.sh check $(git rev-parse --short HEAD)' \
  "$repo_root/skills/retro/SKILL.md" \
  || { echo "FAIL: retro/SKILL.md Шаг 5 не передаёт JOURNALS_DIR — H2/H3 голодают и закроются «недоказуемо»" >&2; fail=1; }

# (11b) второй проход финального ревью (следствие I-2): run_label обязан быть
# СТАБИЛЬНЫМ на прогон (HEAD), не временем разбора — иначе каждый повторный
# mvp:retro (он перезапускаем по построению) плодит «новый прогон» в
# счётчике runs_seen у ВСЕХ гипотез и приближает их закрытие по исчерпанию
# ttl_runs, ничего не измерив.
grep -qF 'check $(git rev-parse --short HEAD)' "$repo_root/skills/retro/SKILL.md" \
  || { echo "FAIL: retro/SKILL.md Шаг 5: run_label должен быть HEAD прогона, не временем разбора" >&2; fail=1; }
grep -qF 'повторный разбор не плодит' "$repo_root/skills/retro/SKILL.md" \
  || { echo "FAIL: retro/SKILL.md Шаг 5 не объясняет, зачем метка стабильна" >&2; fail=1; }

# (11c) второй проход финального ревью (мелкая находка 5): требование
# «file:line, открытая глазами» — поведенческое требование к верификации
# кандидата, а не проза; однажды уже потерялось при выкраивании байтов.
grep -qF '`file:line`, открытая глазами' "$repo_root/skills/retro/SKILL.md" \
  || { echo "FAIL: retro/SKILL.md Шаг 3 потерял требование «file:line, открытая глазами»" >&2; fail=1; }
grep -qF 'PROJECT_ROOT, JOURNALS_DIR' "$repo_root/skills/retro/references/experiments-handbook.md" \
  || { echo "FAIL: experiments-handbook не называет JOURNALS_DIR в контракте env check-скрипта" >&2; fail=1; }
grep -qF '`JOURNALS_DIR` обязателен' "$repo_root/skills/retro/references/experiments-handbook.md" \
  || { echo "FAIL: experiments-handbook не объясняет обязательность JOURNALS_DIR на Шаге 5" >&2; fail=1; }

# ========== ФИНАЛЬНОЕ РЕВЬЮ ВЕТКИ (находка 5) ==========

# (12) находка 5a — без pipefail `${PIPESTATUS[0]}` (а не общий `$?` пайплайна)
# обязан ловить ПАДЕНИЕ check-скрипта, даже если тот успел напечатать
# валидный на вид ok:true JSON перед падением: `... | tail -n1` без pipefail
# берёт код возврата от tail (почти никогда не падает), поэтому голый `$?`
# здесь всегда 0 и не видит реального отказа скрипта.
tmpdir_badexit="$tmpdir/plug-badexit"
mkdir -p "$tmpdir_badexit/lib" "$tmpdir_badexit/docs/experiments" "$tmpdir_badexit/scripts/experiments" "$tmpdir_badexit/proj/.mvp"
cp "$repo_root/lib/experiments.sh" "$tmpdir_badexit/lib/"
cp "$repo_root/lib/state.sh" "$tmpdir_badexit/lib/"
cat > "$tmpdir_badexit/docs/experiments/registry.json" <<'EOF'
{ "version": 1, "max_open": 5, "hypotheses": [
  { "id": "T-badexit", "title": "t", "status": "open", "mode_required": "passive",
    "check_script": "scripts/experiments/t-badexit.sh",
    "threshold": "value >= 1", "ttl_runs": 5, "opened": "2026-09-22" }
] }
EOF
cat > "$tmpdir_badexit/scripts/experiments/t-badexit.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"reason":null,"hint":null,"data":{"value":99,"verdict":"confirmed"}}'
exit 1
EOF
chmod +x "$tmpdir_badexit/scripts/experiments/t-badexit.sh"
cd "$tmpdir_badexit/proj"
echo '{"phase":"done","experiments":"passive"}' > .mvp/state.json
out="$(bash "$tmpdir_badexit/lib/experiments.sh" check run-badexit | last_line)"
assert_eq "badexit: check сам не падает" "True" "$(jget "$out" 'd["ok"]')"
if [ -f .mvp/experiments/results.jsonl ] && grep -q '"T-badexit"' .mvp/experiments/results.jsonl; then
  echo "FAIL: упавший (exit!=0) check-скрипт всё равно записан в results.jsonl несмотря на валидный на вид ok:true JSON — PIPESTATUS не ловит" >&2
  fail=1
fi
assert_eq "badexit: summary отмечает отказ, не recorded" "True" \
  "$(jget "$out" '"not-ok" in json.dumps(d["data"]["checked"])')"
cd "$tmpdir/proj"

# (13) находка 5c — add с синтаксически невалидным JSON: обе ветки этого кода
# есть (json-parse и missing-field), тестом раньше не покрыта ни одна.
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{this is not json' | last_line)" || true
assert_eq "add: синтаксически невалидный JSON — ok" "False" "$(jget "$out" 'd["ok"]')"
assert_eq "add: невалидный JSON — reason называет причину" "True" "$(jget "$out" '"not valid JSON" in (d["reason"] or "")')"

# (14) находка 5c — add с валидным JSON, но без обязательного поля (`opened`).
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-nofield","title":"t","status":"open","mode_required":"passive","check_script":"s.sh","threshold":"value >= 1","ttl_runs":5}' | last_line)" || true
assert_eq "add: отсутствует обязательное поле — ok" "False" "$(jget "$out" 'd["ok"]')"
assert_eq "add: отсутствует поле — reason называет его" "True" "$(jget "$out" '"opened" in (d["reason"] or "")')"

# (15) находка 5d — регистрация не переписывает уже бывшее в файле
# содержимое (indent=1 рефлоу всего файла), только дописывает новую запись
# точечно. К этому моменту через фикстуру уже прошли несколько add() (сценарии
# 7/8: T-new, T-fill5/6/7) — если бы одна из них перезаписала весь файл под
# json.dump(indent=1), исходное форматирование T-pass/T-greedy/T-missing/
# T-verdict уже было бы потеряно.
REG_BEFORE="$tmpdir/registry-before-add.json" REG_AFTER="$tmpdir/plug/docs/experiments/registry.json" python3 -c '
import os
orig = open(os.environ["REG_BEFORE"], encoding="utf-8").read()
new = open(os.environ["REG_AFTER"], encoding="utf-8").read()
tail = "\n] }\n"
assert orig.endswith(tail), "фикстура теста не оканчивается ожидаемым хвостом"
head = orig[: -len(tail)]
if not new.startswith(head):
    idx = next((i for i in range(min(len(head), len(new))) if head[i] != new[i]), min(len(head), len(new)))
    raise SystemExit("форматирование существующих записей реестра изменилось при add (первое расхождение на байте %d)" % idx)
import re
if re.search(r"\n \S", new):
    raise SystemExit("похоже на json.dump(indent=1) — в файле строка с отступом в один пробел")
' || { echo "FAIL: add() переформатировал существующее содержимое реестра вместо точечной вставки" >&2; fail=1; }

exit $fail
