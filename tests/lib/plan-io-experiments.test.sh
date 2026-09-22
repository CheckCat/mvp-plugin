#!/usr/bin/env bash
# Tests for the CAP-experiment additive fields on lib/plan-io.mjs (спека 2026-09-22 §8/§9):
#   `next` payload gains `experiments` (off|passive|greedy, default greedy) and
#   `capped_role` (<role>-capped when that project agent file exists, else null);
#   `complete` gains --arm/--segments -> additive `arm`/`segments` fields on the
#   task_complete telemetry event (absent entirely when the flags are absent —
#   passive/off runs never pass them, and old events.jsonl consumers must keep
#   reading unaffected).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
jfield() { O="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(eval(os.environ["E"]))'; }

# Fixture setup — same shape as tests/lib/plan-io.test.sh's new_repo(): a
# fresh tmp git repo, tests/fixtures/plan-3tasks.json seeded at .mvp/plan.json
# and committed (task 001 role=backend-implementer status=pending, task 002
# depends_on 001 — reused verbatim for step (5)'s "second pending task"), plus
# .mvp/state.json {"phase":"build"} (left uncommitted — under .mvp, so it
# never trips the dirty-tree gate in plan-io.mjs next).
cd "$tmpdir" || { echo "FAIL: cannot cd to tmpdir" >&2; exit 1; }
git init -q
git config user.email test@test.local
git config user.name test
mkdir -p .mvp
cp "$repo_root/tests/fixtures/plan-3tasks.json" .mvp/plan.json
git add .mvp/plan.json
git commit -q -m "chore: seed plan"
printf '%s' '{"phase":"build"}' > .mvp/state.json

# (1) без ключа experiments → greedy; capped-файла нет → capped_role null.
# Плюс аддитивные поля финального ревью: mech_roles (C1 — ролей механики в
# фикстуре нет, все false) и task_index (I6 — задача 001 стоит в плане первой).
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "experiments default" "greedy" "$(jfield "$out" 'd["data"]["experiments"]')"
assert_eq "capped_role null" "None" "$(jfield "$out" 'd["data"]["capped_role"]')"
assert_eq "mech_roles: без файлов всё false" "False False False" \
  "$(jfield "$out" 'str(d["data"]["mech_roles"]["reviewer"])+" "+str(d["data"]["mech_roles"]["validator"])+" "+str(d["data"]["mech_roles"]["relay"])')"
assert_eq "task_index первой задачи" "0" "$(jfield "$out" 'd["data"]["task_index"]')"

# (2) passive из state.json доезжает
python3 - <<'EOF'
import json
s = json.load(open(".mvp/state.json")); s["experiments"] = "passive"
json.dump(s, open(".mvp/state.json", "w"))
EOF
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "experiments passive" "passive" "$(jfield "$out" 'd["data"]["experiments"]')"

# (3) capped-файл существует → имя роли в payload. Committed (not left
# untracked): a real capped-role file is authored by mvp:bootstrap and
# already part of the target repo's history by the time `next` runs — an
# untracked .claude/agents/ would trip plan-io's own (unrelated) dirty-tree
# gate before capped_role is even computed, which is not what this case is
# testing.
mkdir -p .claude/agents && echo x > .claude/agents/backend-implementer-capped.md
git add .claude/agents/backend-implementer-capped.md
git commit -q -m "chore: seed capped role"
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "capped_role" "backend-implementer-capped" "$(jfield "$out" 'd["data"]["capped_role"]')"

# (4) complete с --arm/--segments → additive-поля события
node "$repo_root/lib/plan-io.mjs" complete 001 --tokens 5 --dispatches 7 --arm cap30 --segments 2 >/dev/null
ev="$(tail -n 1 .mvp/telemetry/events.jsonl)"
assert_eq "arm в событии" "cap30" "$(jfield "$ev" 'd["arm"]')"
assert_eq "segments в событии" "2" "$(jfield "$ev" 'd["segments"]')"
# (5) additive: complete БЕЗ --arm/--segments не пишет эти поля вовсе
#     (фикстура: вторая pending-задача id=002 в том же plan.json, уже есть в
#     tests/fixtures/plan-3tasks.json)
node "$repo_root/lib/plan-io.mjs" complete 002 --tokens 1 --dispatches 1 >/dev/null
ev="$(tail -n 1 .mvp/telemetry/events.jsonl)"
assert_eq "без флагов arm отсутствует" "False" "$(jfield "$ev" '"arm" in d')"
assert_eq "без флагов segments отсутствует" "False" "$(jfield "$ev" '"segments" in d')"

# (5b) находка финального ревью (минорная): опечатка в --arm — раньше молча
# отбрасывалась (событие писалось без поля arm, задача беззвучно выпадала из
# выборки эксперимента), теперь обычный отказ, exit 1, и НИЧЕГО не мутирует:
# ни plan.json (задача 003 остаётся pending), ни events.jsonl (строк не
# прибавляется) — иначе повторный legit-вызов ниже (шаг 7) застал бы задачу
# уже "done" от невалидной попытки.
n_events_before="$(wc -l < .mvp/telemetry/events.jsonl)"
out="$(node "$repo_root/lib/plan-io.mjs" complete 003 --tokens 1 --dispatches 1 --arm cap31)"; ec=$?
assert_eq "invalid --arm: exit code" "1" "$ec"
assert_eq "invalid --arm: ok:false" "False" "$(jfield "$out" 'd["ok"]')"
assert_eq "invalid --arm: reason называет значение" "True" "$(jfield "$out" '"cap31" in d["reason"]')"
n_events_after="$(wc -l < .mvp/telemetry/events.jsonl)"
assert_eq "invalid --arm: events.jsonl не растёт" "$n_events_before" "$n_events_after"
task_status="$(python3 -c 'import json; p=json.load(open(".mvp/plan.json")); print([t["status"] for t in p["tasks"] if t["id"]=="003"][0])')"
assert_eq "invalid --arm: задача 003 осталась pending" "pending" "$task_status"

# (6) mech_roles отражает СУЩЕСТВУЮЩИЕ файлы ролей механики (находка C1):
# кладём только mvp-relay.md — relay true, reviewer/validator остаются false.
# Заодно task_index: 001/002 done, next выдаёт 003 — третью позицию плана,
# и позиция не зависит от того, что это первая задача «этого запуска» (I6).
echo x > .claude/agents/mvp-relay.md
git add .claude/agents/mvp-relay.md
git commit -q -m "chore: seed mvp-relay role"
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "mech_roles.relay true при файле" "True" "$(jfield "$out" 'd["data"]["mech_roles"]["relay"]')"
assert_eq "mech_roles.reviewer false без файла" "False" "$(jfield "$out" 'd["data"]["mech_roles"]["reviewer"]')"
assert_eq "mech_roles.validator false без файла" "False" "$(jfield "$out" 'd["data"]["mech_roles"]["validator"]')"
assert_eq "task_index третьей задачи" "2" "$(jfield "$out" 'd["data"]["task_index"]')"

# (7) mech_roles едет и на халте (C1: за all-done идёт не-retryable релей
# установки фазы — оркестратору нужно знать про роли ДО него).
node "$repo_root/lib/plan-io.mjs" complete 003 --tokens 1 --dispatches 1 >/dev/null
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "халт all-done" "all-done" "$(jfield "$out" 'd["data"]["halt"]')"
assert_eq "mech_roles есть на халте" "True" "$(jfield "$out" '"mech_roles" in d["data"]')"

exit $fail
