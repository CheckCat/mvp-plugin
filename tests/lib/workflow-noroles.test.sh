#!/usr/bin/env bash
# workflow-noroles.test.sh — поведенческие сценарии для skills/build/workflow.mjs
# на мини-стенде tests/lib/workflow-noroles-harness.mjs (см. его шапку).
#
# (A) Находка C1: проект без файлов ролей механики (.claude/agents/mvp-*.md —
#     обновление со старой версии плагина). До фикса прогон умирал на первом
#     не-retryable релее (save-review): узкая роль возвращала пустоту, relay()
#     бросал исключение ДО запасной попытки. После фикса узкая роль вообще не
#     диспатчится (mech_roles из payload next), задача проходит весь конвейер
#     на generic-диспатчах и коммитится.
# (B) Находка C1, хвост all-done: релей установки фазы (retryable:false) идёт
#     сразу после халта all-done — mech_roles обязан приехать и на халте.
# (C) Находка I6: чётность CAP-рукава — по позиции задачи в плане, не по
#     счётчику задач запуска. Задача с task_index=1, первая в СВОЁМ запуске,
#     обязана попасть в контроль (arm=control), не в рукав (cap30).
# (D) Находка I6: явный --task исключает задачу из рукава целиком — событие
#     task_complete не несёт arm-полей вовсе.
# (E) Второй проход финального ревью, слепая зона: АКТИВНЫЙ CAP-рукав целиком
#     — обрыв первого сегмента → handoff.sh → сегмент продолжения с
#     указателем → финализация с полями рукава. До этого сценария цикл рукава
#     в оркестраторе не исполнялся ни одним тестом (только грепы и юниты).
# (F) Тот же рукав, исчерпание сегментов: ровно CAP_SEGMENTS диспатчей
#     имплементера, затем park с внятным текстом — не тихий успех.
# (G) Все опросы ревью воздержались (обрыв/мёртвая роль) → park «ревью не
#     состоялось», не тихое «ревью прошло чисто»; реплики сохранены как
#     evidence, задача не закоммичена.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
harness="$here/workflow-noroles-harness.mjs"
mkdry="$repo_root/tests/fixtures/dryrun/make-dryrun.sh"
fail=0

assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
jq_out() { O="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(eval(os.environ["E"]))'; }

new_fixture() { # -> путь к свежей dryrun-фикстуре (без ролей механики)
  local out
  out="$(bash "$mkdry" | tail -n 1)"
  jq_out "$out" 'd["data"]["path"]'
}

run_wf() { # <project> <impl-files-csv> <extra-args-json-fragment>
  local project="$1" impl="$2" extra="$3"
  WF_PROJECT="$project" IMPL_FILES="$impl" \
  WF_ARGS="$(P="$project" X="$extra" python3 -c '
import json, os
a = {"run_id": "t-noroles", "now": "2026-09-23T00:00:00Z", "max_tasks": 1,
     "plugin_root": os.environ["PLUGIN_ROOT_T"], "project_root": os.environ["P"]}
a.update(json.loads(os.environ["X"]))
print(json.dumps(a))
')" PLUGIN_ROOT_T="$repo_root" node "$harness"
}
export PLUGIN_ROOT_T="$repo_root"

# --- (A) C1: ролей механики нет — задача проходит и коммитится ---------------
proj="$(new_fixture)"
out="$(run_wf "$proj" "app/a.txt" '{}')" || { echo "FAIL: (A) harness упал" >&2; echo "$out" >&2; fail=1; }
assert_eq "(A) halt null — прогон не умер на не-retryable релее" "None" "$(jq_out "$out" 'd["result"]["halt"]')"
assert_eq "(A) одна задача сделана" "1" "$(jq_out "$out" 'd["result"]["tasks_done"]')"
# Узкая роль диспатчилась РОВНО один раз — первый advance (mech_roles ещё не
# известен, retryable-фолбэк это переживает). Ни save-review, ни finalize, ни
# ревью/валидатор её не трогали.
assert_eq "(A) mvp-* только на первом advance" "['advance-0']" \
  "$(jq_out "$out" '[c["label"] for c in d["calls"] if (c["agentType"] or "").startswith("mvp-")]')"
# Не-retryable точки исполнились generic-диспатчем (первая попытка, не фолбэк)
assert_eq "(A) save-review шёл generic" "3" \
  "$(jq_out "$out" 'len([c for c in d["calls"] if (c["label"] or "").startswith("save-review-") and c["agentType"] is None])')"
assert_eq "(A) finalize шёл generic" "1" \
  "$(jq_out "$out" 'len([c for c in d["calls"] if (c["label"] or "").startswith("finalize-") and c["agentType"] is None])')"
# Об отсутствии ролей сказано в лог РОВНО один раз, с настоящим лекарством
assert_eq "(A) лог про отсутствующие роли — один раз" "1" \
  "$(jq_out "$out" 'len([l for l in d["logs"] if "роли механики отсутствуют" in l])')"
assert_eq "(A) лог называет лекарство (mvp:sync собирает безусловно)" "1" \
  "$(jq_out "$out" 'len([l for l in d["logs"] if "собирает роли механики" in l and "mvp:sync" in l])')"
# Задача реально закоммичена настоящим finalize.sh
n_commits="$(cd "$proj" && git rev-list --count HEAD)"
assert_eq "(A) в фикстуре появился коммит задачи" "2" "$n_commits"
rm -rf "$proj"

# --- (B) C1: all-done -> не-retryable релей установки фазы -------------------
proj="$(new_fixture)"
python3 - "$proj/.mvp/plan.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
for t in p["tasks"]:
    t["status"] = "done"
json.dump(p, open(sys.argv[1], "w"))
PY
( cd "$proj" && git add .mvp/plan.json && git commit -q -m "chore: all done" )
printf '%s' '{"phase":"build"}' > "$proj/.mvp/state.json"
out="$(run_wf "$proj" "" '{}')" || { echo "FAIL: (B) harness упал" >&2; echo "$out" >&2; fail=1; }
assert_eq "(B) halt all-done" "all-done" "$(jq_out "$out" 'd["result"]["halt"]')"
assert_eq "(B) фаза поставлена (phase_set)" "True" "$(jq_out "$out" 'd["result"]["phase_set"]')"
assert_eq "(B) релей фазы шёл generic с первой попытки" "1" \
  "$(jq_out "$out" 'len([c for c in d["calls"] if c["label"]=="phase-done" and c["agentType"] is None])')"
assert_eq "(B) mvp-* только на первом advance" "['advance-0']" \
  "$(jq_out "$out" '[c["label"] for c in d["calls"] if (c["agentType"] or "").startswith("mvp-")]')"
assert_eq "(B) state.json: phase=done" "done" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["phase"])' "$proj/.mvp/state.json")"
rm -rf "$proj"

# --- (C) I6: чётность по позиции в плане, не по счётчику запуска -------------
# 001 (task_index=0) уже done; 002 (task_index=1) — первая задача ЭТОГО
# запуска. Старый код (tasksDone % 2) отправил бы её в рукав (cap30); новый
# (task_index % 2) — в контроль. experiments отсутствует в state -> greedy.
proj="$(new_fixture)"
python3 - "$proj/.mvp/plan.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["tasks"][0]["status"] = "done"
json.dump(p, open(sys.argv[1], "w"))
PY
mkdir -p "$proj/.claude/agents"
echo x > "$proj/.claude/agents/general-purpose-capped.md"
( cd "$proj" && git add .mvp/plan.json .claude/agents/general-purpose-capped.md && git commit -q -m "chore: seed capped" )
out="$(run_wf "$proj" "app/b.txt" '{}')" || { echo "FAIL: (C) harness упал" >&2; echo "$out" >&2; fail=1; }
assert_eq "(C) halt null" "None" "$(jq_out "$out" 'd["result"]["halt"]')"
ev="$(tail -n 1 "$proj/.mvp/telemetry/events.jsonl")"
assert_eq "(C) task_index=1 -> контроль, не рукав" "control" "$(jq_out "$ev" 'd["arm"]')"
rm -rf "$proj"

# --- (D) I6: явный --task исключает задачу из рукава -------------------------
proj="$(new_fixture)"
python3 - "$proj/.mvp/plan.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["tasks"][0]["status"] = "done"
json.dump(p, open(sys.argv[1], "w"))
PY
mkdir -p "$proj/.claude/agents"
echo x > "$proj/.claude/agents/general-purpose-capped.md"
( cd "$proj" && git add .mvp/plan.json .claude/agents/general-purpose-capped.md && git commit -q -m "chore: seed capped" )
out="$(run_wf "$proj" "app/b.txt" '{"task_id": "002"}')" || { echo "FAIL: (D) harness упал" >&2; echo "$out" >&2; fail=1; }
assert_eq "(D) halt null" "None" "$(jq_out "$out" 'd["result"]["halt"]')"
ev="$(tail -n 1 "$proj/.mvp/telemetry/events.jsonl")"
assert_eq "(D) с явным task_id arm-полей нет" "False" "$(jq_out "$ev" '"arm" in d')"
assert_eq "(D) с явным task_id segments-полей нет" "False" "$(jq_out "$ev" '"segments" in d')"
rm -rf "$proj"

# --- (E) активный рукав: обрыв → handoff → продолжение → финализация ---------
# Задача 001 (task_index=0, чёт) + capped-файл + greedy-дефолт = armActive.
# Первый имплементер-диспатч «обрывается» (IMPL_SILENT=1): пишет app/a.txt,
# финального сообщения нет. Рукав обязан пройти handoff.sh, отдать агенту
# продолжения указатель и довести задачу до коммита с полями рукава.
proj="$(new_fixture)"
mkdir -p "$proj/.claude/agents"
echo x > "$proj/.claude/agents/general-purpose-capped.md"
( cd "$proj" && git add .claude/agents/general-purpose-capped.md && git commit -q -m "chore: seed capped" )
out="$(IMPL_SILENT=1 run_wf "$proj" "app/a.txt" '{}')" || { echo "FAIL: (E) harness упал" >&2; echo "$out" >&2; fail=1; }
assert_eq "(E) halt null — рукав довёл задачу" "None" "$(jq_out "$out" 'd["result"]["halt"]')"
assert_eq "(E) одна задача сделана" "1" "$(jq_out "$out" 'd["result"]["tasks_done"]')"
# Оба сегмента шли на capped-роль, и ровно два
assert_eq "(E) сегменты: implementer-001 и -seg2 на capped-роли" "['implementer-001', 'implementer-001-seg2']" \
  "$(jq_out "$out" '[c["label"] for c in d["calls"] if c["agentType"]=="general-purpose-capped"]')"
# Работа не теряется за швом: агент продолжения получил указатель handoff
assert_eq "(E) первый сегмент без указателя" "False" \
  "$(jq_out "$out" '[c for c in d["calls"] if c["label"]=="implementer-001"][0]["handoff_ref"]')"
assert_eq "(E) сегмент продолжения несёт указатель handoff" "True" \
  "$(jq_out "$out" '[c for c in d["calls"] if c["label"]=="implementer-001-seg2"][0]["handoff_ref"]')"
# Указатель — настоящий файл с изложением сделанного (называет тронутый файл)
grep -q 'a.txt' "$proj/.mvp/handoff-001.md" \
  || { echo "FAIL: (E) .mvp/handoff-001.md не называет работу первого сегмента" >&2; fail=1; }
# Работа первого (оборванного) сегмента дошла до коммита
( cd "$proj" && git show HEAD:app/a.txt >/dev/null 2>&1 ) \
  || { echo "FAIL: (E) app/a.txt не попал в коммит — работа потеряна за швом" >&2; fail=1; }
# Телеметрия несёт поля рукава: активное плечо и число сегментов
ev="$(tail -n 1 "$proj/.mvp/telemetry/events.jsonl")"
assert_eq "(E) arm=cap30 в событии" "cap30" "$(jq_out "$ev" 'd["arm"]')"
assert_eq "(E) segments=2 в событии" "2" "$(jq_out "$ev" 'd["segments"]')"
rm -rf "$proj"

# --- (F) активный рукав: исчерпание сегментов → park, не тихий успех ---------
# Все имплементер-диспатчи молчат (IMPL_SILENT=99), дерево каждый раз грязное
# — handoff.sh честно продолжает, пока workflow не упрётся в CAP_SEGMENTS.
proj="$(new_fixture)"
mkdir -p "$proj/.claude/agents"
echo x > "$proj/.claude/agents/general-purpose-capped.md"
( cd "$proj" && git add .claude/agents/general-purpose-capped.md && git commit -q -m "chore: seed capped" )
n_before="$(cd "$proj" && git rev-list --count HEAD)"
out="$(IMPL_SILENT=99 run_wf "$proj" "app/a.txt" '{}')" || { echo "FAIL: (F) harness упал" >&2; echo "$out" >&2; fail=1; }
assert_eq "(F) halt stop-and-ask" "stop-and-ask" "$(jq_out "$out" 'd["result"]["halt"]')"
assert_eq "(F) task_id в халте" "001" "$(jq_out "$out" 'd["result"]["task_id"]')"
# Число сегментов ограничено: ровно CAP_SEGMENTS=4 имплементер-диспатча
assert_eq "(F) ровно 4 имплементер-диспатча (CAP_SEGMENTS)" "4" \
  "$(jq_out "$out" 'len([c for c in d["calls"] if (c["label"] or "").startswith("implementer")])')"
# Park с внятным текстом: сколько сегментов, что исчерпано, как выйти из рукава
assert_eq "(F) detail называет число сегментов" "True" "$(jq_out "$out" '"4 segment(s)" in d["result"]["detail"]')"
assert_eq "(F) detail называет исчерпание" "True" "$(jq_out "$out" '"segments were exhausted" in d["result"]["detail"]')"
assert_eq "(F) detail называет выход из рукава" "True" "$(jq_out "$out" '"Выход из рукава" in d["result"]["detail"]')"
# Не тихий успех: задача failed, коммита нет, task_complete не писалось
task_status="$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print([t["status"] for t in p["tasks"] if t["id"]=="001"][0])' "$proj/.mvp/plan.json")"
assert_eq "(F) задача 001 failed" "failed" "$task_status"
assert_eq "(F) новых коммитов нет" "$n_before" "$(cd "$proj" && git rev-list --count HEAD)"
[ ! -f "$proj/.mvp/telemetry/events.jsonl" ] \
  || { echo "FAIL: (F) task_complete записан для незавершённой задачи" >&2; fail=1; }
# park привёл дерево в порядок (вне .mvp — состояние stash'ится).
# Обычный grep, ничего сверх bash/node/python3/git (fix round 1: сюда
# просочился личный CLI-прокси окружения разработчика, и на машине без него
# || true глотал «команда не найдена» — сравнение «пусто == пусто» проходило
# при ЛЮБОМ состоянии дерева). || true остаётся легитимно: grep -v без
# оставшихся строк (всё дерево под .mvp — ожидаемый исход) выходит 1.
dirty_outside="$(cd "$proj" && git status --porcelain | grep -v '\.mvp' || true)"
assert_eq "(F) после park вне .mvp чисто" "" "$dirty_outside"
rm -rf "$proj"

# --- (G) все опросы ревью воздержались → park, не «ревью прошло чисто» -------
proj="$(new_fixture)"
n_before="$(cd "$proj" && git rev-list --count HEAD)"
out="$(REVIEWER_SILENT=1 run_wf "$proj" "app/a.txt" '{}')" || { echo "FAIL: (G) harness упал" >&2; echo "$out" >&2; fail=1; }
assert_eq "(G) halt stop-and-ask" "stop-and-ask" "$(jq_out "$out" 'd["result"]["halt"]')"
assert_eq "(G) task_id в халте" "001" "$(jq_out "$out" 'd["result"]["task_id"]')"
assert_eq "(G) detail: ни один опрос не ответил" "True" \
  "$(jq_out "$out" '"review polls returned no text" in d["result"]["detail"]')"
assert_eq "(G) detail: ревью не состоялось, вердикт невозможен" "True" \
  "$(jq_out "$out" '"No review happened" in d["result"]["detail"]')"
# Опросов было три, и каждая пустая реплика сохранена как evidence
assert_eq "(G) три опроса ревью" "3" \
  "$(jq_out "$out" 'len([c for c in d["calls"] if (c["label"] or "").startswith("reviewer-")])')"
assert_eq "(G) три save-review релея" "3" \
  "$(jq_out "$out" 'len([c for c in d["calls"] if (c["label"] or "").startswith("save-review-")])')"
[ -f "$proj/.mvp/review/task-001.verdicts.md" ] \
  || { echo "FAIL: (G) evidence-файл ревью не создан" >&2; fail=1; }
# Не тихое «чисто»: задача failed, коммита нет
task_status="$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print([t["status"] for t in p["tasks"] if t["id"]=="001"][0])' "$proj/.mvp/plan.json")"
assert_eq "(G) задача 001 failed" "failed" "$task_status"
assert_eq "(G) новых коммитов нет" "$n_before" "$(cd "$proj" && git rev-list --count HEAD)"
rm -rf "$proj"

exit $fail
