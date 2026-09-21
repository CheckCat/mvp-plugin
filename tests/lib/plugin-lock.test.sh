#!/usr/bin/env bash
# Tests for lib/plugin-lock.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
LOCK_SH="$repo_root/lib/plugin-lock.sh"

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() { # <desc> <expected> <actual>
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1 — expected [$2], got [$3]" >&2
    fail=1
  fi
}

# Последняя строка stdout — JSON-контракт. Всё, что скрипт напечатал раньше,
# к контракту не относится и в тестах не участвует.
last_line() { printf '%s\n' "$1" | tail -n1; }

jq_py() { # <json> <python-выражение над d>
  PL_J="$1" PL_E="$2" python3 -c '
import json, os
d = json.loads(os.environ["PL_J"])
print(eval(os.environ["PL_E"]))
'
}

# Минимальный поддельный плагин: ровно те файлы, которые скрипт читает.
# Настоящий плагин не трогаем — тесты мутируют шаблоны.
make_fake_plugin() { # <dir>
  local p="$1"
  mkdir -p "$p/skills/bootstrap/templates" "$p/skills/bootstrap/scripts" \
           "$p/skills/build" "$p/lib" "$p/.claude-plugin"
  printf '%s\n' '{"name":"mvp","version":"9.9.9"}' > "$p/.claude-plugin/plugin.json"
  printf 'COMMON v1\n' > "$p/skills/bootstrap/templates/_common.md"
  printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nBODY devops v1\n' \
    > "$p/skills/bootstrap/templates/devops-engineer.docker-compose.fastify.template.md"
  # Второй валидный стековый шаблон той же роли — нужен, чтобы негативный
  # контроль "record получил НЕВЕРНЫЙ, но всё же существующий стек" мог
  # покраснеть именно на значении stack, а не на "assemble ok" (см. round 1
  # review finding в task-4-report.md): без него у роли devops-engineer
  # была ровно одна легальная пара (роль, стек), и "assemble ok:true" было
  # логически неотличимо от "stack передан верно".
  printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nBODY devops swarm v1\n' \
    > "$p/skills/bootstrap/templates/devops-engineer.docker-swarm.template.md"
  printf -- '---\nname: integration-specialist\ndescription: d\ntools: Read\n---\n\nBODY integ v1\n' \
    > "$p/skills/bootstrap/templates/integration-specialist.template.md"
  printf -- '---\nname: test-writer\ndescription: d\ntools: Read\n---\n\nBODY test-writer v1\n' \
    > "$p/skills/bootstrap/templates/test-writer.fastify.template.md"
  printf 'SKILL bootstrap v1\n' > "$p/skills/bootstrap/SKILL.md"
  printf 'SKILL build v1\n'     > "$p/skills/build/SKILL.md"
  printf 'echo hi\n'            > "$p/lib/validate-task.sh"
  printf 'echo meta\n'          > "$p/skills/bootstrap/scripts/check-meta.sh"
}

make_fake_project() { # <dir>
  mkdir -p "$1/.claude/agents" "$1/.mvp"
}

# --- Test 1: record создаёт lock с одной записью derived ------------------

t1_plugin="$tmpdir/t1-plugin"; t1_proj="$tmpdir/t1-proj"
make_fake_plugin "$t1_plugin"; make_fake_project "$t1_proj"
printf 'ASSEMBLED devops\n' > "$t1_proj/.claude/agents/devops-engineer.md"

out1="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" PROJECT=trellis \
  SERVICE_API=trellis-api SERVICE_WORKER=trellis-worker \
  bash "$LOCK_SH" record devops-engineer docker-compose.fastify 2>/dev/null)"
rc1=$?
assert_eq "test 1: record exit" "0" "$rc1"
assert_eq "test 1: ok" "True" "$(jq_py "$(last_line "$out1")" 'd["ok"]')"

lock1="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 1: lock_version" "1" "$(jq_py "$lock1" 'd["lock_version"]')"
assert_eq "test 1: ключ derived" ".claude/agents/devops-engineer.md" \
  "$(jq_py "$lock1" 'list(d["derived"])[0]')"
assert_eq "test 1: stack" "docker-compose.fastify" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
assert_eq "test 1: template" "devops-engineer.docker-compose.fastify.template.md" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["template"]')"
assert_eq "test 1: PROJECT" "trellis" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["placeholders"]["PROJECT"]')"
assert_eq "test 1: два источника" "2" \
  "$(jq_py "$lock1" 'len(d["derived"][".claude/agents/devops-engineer.md"]["sources"])')"
assert_eq "test 1: output_sha256 есть" "True" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["output_sha256"].startswith("sha256:")')"
assert_eq "test 1: plugin.version" "9.9.9" "$(jq_py "$lock1" 'd["plugin"]["version"]')"
assert_eq "test 1: normative пуста" "0" "$(jq_py "$lock1" 'len(d["normative"])')"

# --- Test 8: record одной роли не ломает записи остальных ------------------
# Спека §11 случай 8 требует ОБЕ половины: derived остальных ролей И
# normative не изменились. Normative запечатывается ЗДЕСЬ, до record второй
# роли, и должна быть непустой — иначе "record её не трогает" сравнивало бы
# {} с {} и не покраснело бы на мутации lock.setdefault("normative", {}) ->
# lock["normative"] = {} в record (см. task-9-brief.md, находка 4).

(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" bash "$LOCK_SH" seal >/dev/null 2>&1)
normative_before8="$(jq_py "$(cat "$t1_proj/.mvp/plugin-lock.json")" 'json.dumps(d["normative"], sort_keys=True)')"
assert_eq "test 8: normative до record непуста (иначе тест ничего не проверяет)" "True" \
  "$(jq_py "$(cat "$t1_proj/.mvp/plugin-lock.json")" 'len(d["normative"]) > 0')"

printf 'ASSEMBLED integ\n' > "$t1_proj/.claude/agents/integration-specialist.md"
(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" bash "$LOCK_SH" record integration-specialist >/dev/null 2>&1)

lock8="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 8: две записи" "2" "$(jq_py "$lock8" 'len(d["derived"])')"
assert_eq "test 8: devops уцелел" "docker-compose.fastify" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
assert_eq "test 8: роль без стека" "" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/integration-specialist.md"]["stack"]')"
assert_eq "test 8: шаблон без стека" "integration-specialist.template.md" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/integration-specialist.md"]["template"]')"
normative_after8="$(jq_py "$lock8" 'json.dumps(d["normative"], sort_keys=True)')"
assert_eq "test 8: normative не тронута record'ом" "$normative_before8" "$normative_after8"

# --- Test 8b: record при отсутствующем собранном агенте — ok:false ---------
# Шаблон test-writer.fastify.template.md существует (см. make_fake_plugin),
# поэтому падение должно случиться именно на отсутствии .claude/agents/test-writer.md,
# а не раньше — на отсутствии шаблона. Иначе тест проверяет не ту ветку.

out8b="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" \
  bash "$LOCK_SH" record test-writer fastify 2>/dev/null)"
rc8b=$?
assert_eq "test 8b: exit" "1" "$rc8b"
assert_eq "test 8b: ok" "False" "$(jq_py "$(last_line "$out8b")" 'd["ok"]')"
assert_eq "test 8b: reason про отсутствующий собранный агент" "True" \
  "$(jq_py "$(last_line "$out8b")" '"assembled agent missing" in d["reason"]')"

# --- Test 9: record с несуществующим стеком сбрасывает stack в "" ----------
# integration-specialist уже собран (.claude/agents/integration-specialist.md
# создан для Test 8). Запрашиваем заведомо отсутствующий стек: стекового
# шаблона <role>.<stack>.template.md нет, есть только общий <role>.template.md —
# запись обязана указывать на общий шаблон с обнулённым stack, а не хранить
# запрошенный "nosuchstack".

out9="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" \
  bash "$LOCK_SH" record integration-specialist nosuchstack 2>/dev/null)"
rc9=$?
assert_eq "test 9: exit" "0" "$rc9"
assert_eq "test 9: ok" "True" "$(jq_py "$(last_line "$out9")" 'd["ok"]')"

lock9="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 9: stack сброшен" "" \
  "$(jq_py "$lock9" 'd["derived"][".claude/agents/integration-specialist.md"]["stack"]')"
assert_eq "test 9: template общий" "integration-specialist.template.md" \
  "$(jq_py "$lock9" 'd["derived"][".claude/agents/integration-specialist.md"]["template"]')"

# --- Общая фикстура для check-тестов --------------------------------------
# Плагин и проект с двумя записанными ролями. Каждый тест получает СВОЮ
# копию: тесты мутируют шаблоны, общая фикстура склеила бы их между собой.
make_recorded_pair() { # <prefix> -> печатает "<plugin-dir> <proj-dir>"
  local p="$tmpdir/$1-plugin" j="$tmpdir/$1-proj"
  make_fake_plugin "$p"; make_fake_project "$j"
  printf 'ASSEMBLED devops\n' > "$j/.claude/agents/devops-engineer.md"
  printf 'ASSEMBLED integ\n'  > "$j/.claude/agents/integration-specialist.md"
  (cd "$j" && PLUGIN_ROOT="$p" bash "$LOCK_SH" record devops-engineer docker-compose.fastify >/dev/null 2>&1)
  (cd "$j" && PLUGIN_ROOT="$p" bash "$LOCK_SH" record integration-specialist >/dev/null 2>&1)
  printf '%s %s\n' "$p" "$j"
}

run_check() { # <plugin-dir> <proj-dir>
  (cd "$2" && PLUGIN_ROOT="$1" bash "$LOCK_SH" check 2>/dev/null) | tail -n1
}

# --- Test 2 (часть 1): всё чисто ------------------------------------------
# record (Task 1/2) не трогает normative — это работа seal (Task 3). Фейковый
# плагин уже содержит файлы под NORMATIVE_GLOBS (skills/*/SKILL.md, lib/*),
# поэтому без seal здесь check всегда видел бы normative_added и "чистое"
# состояние было бы недостижимо — этот seal не проверяет seal сам по себе
# (это делает test 7), он лишь достраивает то, что реальный mvp:bootstrap
# делает автоматически (спека §10), чтобы "чисто" вообще было возможно.

read -r p2 j2 <<< "$(make_recorded_pair t2)"
(cd "$j2" && PLUGIN_ROOT="$p2" bash "$LOCK_SH" seal >/dev/null 2>&1)
c2="$(run_check "$p2" "$j2")"
assert_eq "test 2a: ok при чистом плагине" "True" "$(jq_py "$c2" 'd["ok"]')"
assert_eq "test 2a: lock_present" "True" "$(jq_py "$c2" 'd["data"]["lock_present"]')"
assert_eq "test 2a: stale пуст" "0" "$(jq_py "$c2" 'len(d["data"]["derived_stale"])')"

# --- Test 2 (часть 2): правка _common.md поднимает ОБЕ роли ---------------

printf 'COMMON v2\n' > "$p2/skills/bootstrap/templates/_common.md"
c2b="$(run_check "$p2" "$j2")"
assert_eq "test 2b: ok:false" "False" "$(jq_py "$c2b" 'd["ok"]')"
assert_eq "test 2b: обе роли stale" "2" "$(jq_py "$c2b" 'len(d["data"]["derived_stale"])')"
assert_eq "test 2b: changed_sources называет _common.md" "True" \
  "$(jq_py "$c2b" 'all(x["changed_sources"] == ["skills/bootstrap/templates/_common.md"] for x in d["data"]["derived_stale"])')"
assert_eq "test 2b: tampered пуст" "0" "$(jq_py "$c2b" 'len(d["data"]["derived_tampered"])')"

# --- Test 3: правка одного шаблона роли поднимает ТОЛЬКО эту роль ---------

read -r p3 j3 <<< "$(make_recorded_pair t3)"
printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nBODY devops v2\n' \
  > "$p3/skills/bootstrap/templates/devops-engineer.docker-compose.fastify.template.md"
c3="$(run_check "$p3" "$j3")"
assert_eq "test 3: ровно одна роль" "1" "$(jq_py "$c3" 'len(d["data"]["derived_stale"])')"
assert_eq "test 3: это devops" "devops-engineer" \
  "$(jq_py "$c3" 'd["data"]["derived_stale"][0]["role"]')"
assert_eq "test 3: стек в находке" "docker-compose.fastify" \
  "$(jq_py "$c3" 'd["data"]["derived_stale"][0]["stack"]')"

# --- Test 4: правка собранного агента руками = tampered, не stale ---------

read -r p4 j4 <<< "$(make_recorded_pair t4)"
printf 'ASSEMBLED devops — HAND EDITED\n' > "$j4/.claude/agents/devops-engineer.md"
c4="$(run_check "$p4" "$j4")"
assert_eq "test 4: ok:false" "False" "$(jq_py "$c4" 'd["ok"]')"
assert_eq "test 4: stale пуст" "0" "$(jq_py "$c4" 'len(d["data"]["derived_stale"])')"
assert_eq "test 4: ровно один tampered" "1" "$(jq_py "$c4" 'len(d["data"]["derived_tampered"])')"
assert_eq "test 4: это devops" "devops-engineer" \
  "$(jq_py "$c4" 'd["data"]["derived_tampered"][0]["role"]')"

# --- Test 9b: агент удалён из проекта = missing, не stale -----------------
# (Test 9 в этом файле уже занят кейсом record'а — здесь речь о check.)

read -r p9b j9b <<< "$(make_recorded_pair t9b)"
rm "$j9b/.claude/agents/integration-specialist.md"
c9b="$(run_check "$p9b" "$j9b")"
assert_eq "test 9b: ровно один missing" "1" "$(jq_py "$c9b" 'len(d["data"]["derived_missing"])')"
assert_eq "test 9b: это integ" "integration-specialist" \
  "$(jq_py "$c9b" 'd["data"]["derived_missing"][0]["role"]')"
assert_eq "test 9b: stale пуст" "0" "$(jq_py "$c9b" 'len(d["data"]["derived_stale"])')"
assert_eq "test 9b: tampered пуст" "0" "$(jq_py "$c9b" 'len(d["data"]["derived_tampered"])')"

# --- Test 6: lock-файла нет — отдельный reason, не дрейф ------------------

p6="$tmpdir/t6-plugin"; j6="$tmpdir/t6-proj"
make_fake_plugin "$p6"; make_fake_project "$j6"
printf 'ASSEMBLED devops\n' > "$j6/.claude/agents/devops-engineer.md"
c6="$(run_check "$p6" "$j6")"
assert_eq "test 6: ok:false" "False" "$(jq_py "$c6" 'd["ok"]')"
assert_eq "test 6: reason" "no plugin-lock.json" "$(jq_py "$c6" 'd["reason"]')"
assert_eq "test 6: lock_present" "False" "$(jq_py "$c6" 'd["data"]["lock_present"]')"
assert_eq "test 6: списки пусты" "True" \
  "$(jq_py "$c6" 'all(len(d["data"][k]) == 0 for k in ("derived_stale","derived_tampered","derived_missing"))')"
# Бриф проверяет только ok/reason/data — этого недостаточно: reason может
# остаться "no plugin-lock.json", даже если ветка FileNotFoundError забыла
# sys.exit(1) (см. негативный контроль №3 в task-2-brief.md). Код возврата —
# отдельный контракт (emit ok:false ⇒ exit 1), и его надо снять отдельным
# вызовом: run_check теряет $? внутри конвейера "| tail -n1".
err6_file="$tmpdir/t6-stderr"
(cd "$j6" && PLUGIN_ROOT="$p6" bash "$LOCK_SH" check >/dev/null 2>"$err6_file")
rc6=$?
assert_eq "test 6: exit code" "1" "$rc6"
# Проверка exit code одна НЕ ловит пропажу sys.exit(1): без него выполнение
# проваливается дальше в 'for ... in lock.get(...)', где lock не определена —
# NameError оттуда сам даёт процессу exit 1, маскируя пропавший sys.exit(1)
# (см. .superpowers/sdd/2026-09-21-plugin-lock-and-sync/task-2-report.md).
# Ловим это не по пустоте stderr (это покраснело бы от любого постороннего
# шума — DeprecationWarning, будущая диагностика и т.п.), а по признаку
# именно неотловленного исключения: подстроке "Traceback" в stderr. Она
# появляется только когда python сам печатает traceback необработанного
# исключения — то есть скрипт не завершился контролируемо через print+exit.
if grep -q "Traceback" "$err6_file"; then
  echo "FAIL: test 6: неотловленное исключение в stderr (нашли \"Traceback\"): $(cat "$err6_file")" >&2
  fail=1
fi

# --- Test 5: правка SKILL.md — только normative_changed ------------------

read -r p5 j5 <<< "$(make_recorded_pair t5)"
(cd "$j5" && PLUGIN_ROOT="$p5" bash "$LOCK_SH" seal >/dev/null 2>&1)
c5a="$(run_check "$p5" "$j5")"
assert_eq "test 5a: после seal чисто" "True" "$(jq_py "$c5a" 'd["ok"]')"

printf 'SKILL retro v2 — новое требование\n' > "$p5/skills/build/SKILL.md"
c5="$(run_check "$p5" "$j5")"
assert_eq "test 5: ok:false" "False" "$(jq_py "$c5" 'd["ok"]')"
assert_eq "test 5: ровно один changed" "1" "$(jq_py "$c5" 'len(d["data"]["normative_changed"])')"
assert_eq "test 5: это build/SKILL.md" "skills/build/SKILL.md" \
  "$(jq_py "$c5" 'd["data"]["normative_changed"][0]')"
assert_eq "test 5: derived не тронут" "0" \
  "$(jq_py "$c5" 'len(d["data"]["derived_stale"]) + len(d["data"]["derived_tampered"]) + len(d["data"]["derived_missing"])')"

# --- Test 10: новый файл под глоб lib/* = normative_added ----------------

printf 'echo new\n' > "$p5/lib/brand-new.sh"
c10="$(run_check "$p5" "$j5")"
assert_eq "test 10: ровно один added" "1" "$(jq_py "$c10" 'len(d["data"]["normative_added"])')"
assert_eq "test 10: это brand-new.sh" "lib/brand-new.sh" \
  "$(jq_py "$c10" 'd["data"]["normative_added"][0]')"

# --- Test 10b: удалённый файл = normative_removed ------------------------

rm "$p5/lib/validate-task.sh"
c10b="$(run_check "$p5" "$j5")"
assert_eq "test 10b: ровно один removed" "1" "$(jq_py "$c10b" 'len(d["data"]["normative_removed"])')"
assert_eq "test 10b: это validate-task.sh" "lib/validate-task.sh" \
  "$(jq_py "$c10b" 'd["data"]["normative_removed"][0]')"

# --- Test 5b: глоб не захватывает agents/ и references/ ------------------

read -r p5b j5b <<< "$(make_recorded_pair t5b)"
mkdir -p "$p5b/skills/build/agents" "$p5b/skills/retro/references"
printf 'reviewer v1\n' > "$p5b/skills/build/agents/reviewer.md"
printf 'handbook v1\n' > "$p5b/skills/retro/references/retro-handbook.md"
(cd "$j5b" && PLUGIN_ROOT="$p5b" bash "$LOCK_SH" seal >/dev/null 2>&1)
printf 'reviewer v2\n' > "$p5b/skills/build/agents/reviewer.md"
printf 'handbook v2\n' > "$p5b/skills/retro/references/retro-handbook.md"
c5b="$(run_check "$p5b" "$j5b")"
assert_eq "test 5b: agents/ и references/ вне наблюдения" "True" \
  "$(jq_py "$c5b" 'd["ok"]')"

# --- Test 7: seal гасит нормативку и не трогает derived ------------------
# derived_before снят ДО первого вызова seal (сразу после record, который
# normative не трогает — Task 1/2). Если бы снимок брался после seal, как
# после первой попытки написать этот тест, "seal стирает derived" не
# покраснел бы: оба снимка были бы одинаково испорчены (см. негативный
# контроль №3 в task-3-report.md) — сравнение "испорчено == испорчено"
# проходит, ничего не проверяя.

read -r p7 j7 <<< "$(make_recorded_pair t7)"
derived_before="$(jq_py "$(cat "$j7/.mvp/plugin-lock.json")" 'json.dumps(d["derived"], sort_keys=True)')"
(cd "$j7" && PLUGIN_ROOT="$p7" bash "$LOCK_SH" seal >/dev/null 2>&1)

printf 'SKILL bootstrap v2\n' > "$p7/skills/bootstrap/SKILL.md"
c7a="$(run_check "$p7" "$j7")"
assert_eq "test 7a: дрейф виден" "1" "$(jq_py "$c7a" 'len(d["data"]["normative_changed"])')"

out7="$(cd "$j7" && PLUGIN_ROOT="$p7" bash "$LOCK_SH" seal 2>/dev/null)"
assert_eq "test 7: seal ok" "True" "$(jq_py "$(last_line "$out7")" 'd["ok"]')"

c7b="$(run_check "$p7" "$j7")"
assert_eq "test 7b: после seal чисто" "True" "$(jq_py "$c7b" 'd["ok"]')"

derived_after="$(jq_py "$(cat "$j7/.mvp/plugin-lock.json")" 'json.dumps(d["derived"], sort_keys=True)')"
assert_eq "test 7c: derived не изменился" "$derived_before" "$derived_after"

# --- Test 11: assemble-agent.sh сам записывает lock ----------------------
# Производитель штампует свой результат: он единственный знает роль,
# выбранный шаблон, значения плейсхолдеров и путь результата сразу.

ASSEMBLE_SH="$repo_root/skills/bootstrap/scripts/assemble-agent.sh"
p11="$tmpdir/t11-plugin"; j11="$tmpdir/t11-proj"
make_fake_plugin "$p11"; make_fake_project "$j11"

out11="$(cd "$j11" && PLUGIN_ROOT="$p11" \
  TEMPLATES_DIR="$p11/skills/bootstrap/templates" \
  bash "$ASSEMBLE_SH" devops-engineer docker-compose.fastify 2>/dev/null)"
rc11=$?
assert_eq "test 11: assemble exit" "0" "$rc11"
assert_eq "test 11: assemble ok" "True" "$(jq_py "$(last_line "$out11")" 'd["ok"]')"

if [ -f "$j11/.mvp/plugin-lock.json" ]; then
  lock11="$(cat "$j11/.mvp/plugin-lock.json")"
  assert_eq "test 11: запись появилась" "docker-compose.fastify" \
    "$(jq_py "$lock11" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
  # И сразу проверяем главное: свежесобранный агент не считается дрейфующим.
  c11="$(run_check "$p11" "$j11")"
  assert_eq "test 11: свежая сборка чиста по derived" "0" \
    "$(jq_py "$c11" 'len(d["data"]["derived_stale"]) + len(d["data"]["derived_tampered"])')"
else
  echo "FAIL: test 11 — assemble-agent.sh не создал .mvp/plugin-lock.json" >&2
  fail=1
fi

# --- Test 12: derived_unstamped — файл лежит в OUT_DIR, но не в lock -------
# Обратное отношение к derived_missing: check раньше обходил только
# lock["derived"] (файл-без-записи был невидим механизму целиком — ровно тот
# отказ, ради которого весь lock и построен). Два собранных агента, записан
# только один.

read -r p12 j12 <<< "$(make_recorded_pair t12-stamped)"
# make_recorded_pair уже записал ОБЕ роли — сперва проверяем обратный
# контроль (записаны обе → unstamped пуст), потом стираем запись одной из
# них из lock, оставляя сам файл на месте, и проверяем прямой случай.
c12_both="$(run_check "$p12" "$j12")"
assert_eq "test 12: обе роли записаны -> unstamped пуст" "0" \
  "$(jq_py "$c12_both" 'len(d["data"]["derived_unstamped"])')"

PL_LOCK_PATH="$j12/.mvp/plugin-lock.json" python3 -c '
import json, os
p = os.environ["PL_LOCK_PATH"]
lock = json.loads(open(p, encoding="utf-8").read())
del lock["derived"][".claude/agents/integration-specialist.md"]
open(p, "w", encoding="utf-8").write(json.dumps(lock, indent=1, sort_keys=True))
'
c12="$(run_check "$p12" "$j12")"
assert_eq "test 12: ok:false" "False" "$(jq_py "$c12" 'd["ok"]')"
assert_eq "test 12: ровно один unstamped" "1" "$(jq_py "$c12" 'len(d["data"]["derived_unstamped"])')"
assert_eq "test 12: это integration-specialist.md" ".claude/agents/integration-specialist.md" \
  "$(jq_py "$c12" 'd["data"]["derived_unstamped"][0]["path"]')"
assert_eq "test 12: находка несёт только path" '["path"]' \
  "$(jq_py "$c12" 'json.dumps(sorted(d["data"]["derived_unstamped"][0].keys()))')"
assert_eq "test 12: reason называет unstamped" "True" \
  "$(jq_py "$c12" '"unstamped" in d["reason"]')"


# --- Test 14: lock_broken — свой reason и своё поле в data, отличные от
# отсутствующего файла (спека §5.2 / §7; Шаг 2 mvp:sync иначе диспетчерит
# "нет отметки" туда, где отметка есть, но не читается).

p14="$tmpdir/t14-plugin"; j14="$tmpdir/t14-proj"
make_fake_plugin "$p14"; make_fake_project "$j14"
printf '{not valid json at all' > "$j14/.mvp/plugin-lock.json"
c14="$(run_check "$p14" "$j14")"
assert_eq "test 14: ok:false" "False" "$(jq_py "$c14" 'd["ok"]')"
assert_eq "test 14: lock_present:false" "False" "$(jq_py "$c14" 'd["data"]["lock_present"]')"
assert_eq "test 14: lock_broken:true" "True" "$(jq_py "$c14" 'd["data"]["lock_broken"]')"
assert_eq "test 14: reason отличается от отсутствующего файла" "True" \
  "$(jq_py "$c14" 'd["reason"] != "no plugin-lock.json"')"
assert_eq "test 14: reason называет валидность JSON" "True" \
  "$(jq_py "$c14" '"JSON" in d["reason"]')"

# обратный контроль: файла действительно нет -> lock_broken:false (test 6
# уже проверяет ту ветку целиком; здесь только новое поле).
assert_eq "test 14b: файла нет -> lock_broken:false" "False" "$(jq_py "$c6" 'd["data"]["lock_broken"]')"


exit $fail
