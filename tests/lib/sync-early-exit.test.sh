#!/usr/bin/env bash
# sync-early-exit.test.sh — лечебный путь mvp:sync для проекта со старого
# плагина ЗАМКНУТ (второй проход финального ревью, находка I-1).
#
# Сценарий, ради которого писалась безусловная сборка ролей механики: проект
# собран старой версией плагина, ролей на диске нет, а `plugin-lock.sh check`
# честно отвечает «проект соответствует плагину» (ранний выход sync). Sync
# собирает роли безусловно — но до этого фикса останавливался ДО финализации,
# и три новых файла ролей оставались незакоммиченными: следующий же
# `plan-io.mjs next` вставал в halt dirty-tree со списком, содержащим каталог
# агентов, а совет халта «сбрось изменения» для untracked-файлов снёс бы
# только что собранное лечение. Стенд конвейера sync не гоняет, тесты sync
# грепали только тексты — связку не сторожил никто.
#
# Здесь исполняются НАСТОЯЩИЕ скрипты пути (plugin-lock, assemble-agent,
# finalize, plan-io) на настоящей git-фикстуре: сначала воспроизводится
# тупик (dirty-tree после сборки ролей), затем — путь Шага 6, которым ранний
# выход обязан пройти, и проверяется, что конвейер после него стартует.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
mkdry="$repo_root/tests/fixtures/dryrun/make-dryrun.sh"
fail=0

assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
jd() { O="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(eval(os.environ["E"]))'; }
need_doc() { # <file> <fixed-string> <msg>
  grep -qF -e "$2" "$1" || { echo "FAIL: $1: не найдено «$2» — $3" >&2; fail=1; }
}

out="$(bash "$mkdry" | tail -n 1)"
proj="$(jd "$out" 'd["data"]["path"]')"
trap 'rm -rf "$proj"' EXIT
cd "$proj"

# Проект «со старого плагина»: lock запечатан (нормативка совпадает с
# плагином), но ролей механики на диске нет.
out="$(bash "$repo_root/lib/plugin-lock.sh" seal | tail -n 1)"
assert_eq "фикстура: seal прошёл" "True" "$(jd "$out" 'd["ok"]')"
git add .mvp/plugin-lock.json && git commit -q -m "chore: seed lock"

# Премисса раннего выхода: check говорит «проект соответствует плагину».
out="$(bash "$repo_root/lib/plugin-lock.sh" check | tail -n 1)"
assert_eq "премисса: check ok:true (ранний выход sync)" "True" "$(jd "$out" 'd["ok"]')"

# Шаг 1 sync: роли механики собираются безусловно.
for role in mvp-reviewer mvp-validator mvp-relay; do
  out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" "$role" | tail -n 1)"
  assert_eq "роль $role собралась" "True" "$(jd "$out" 'd["ok"]')"
done

# Репро находки: БЕЗ финализации следующий запуск конвейера — halt
# dirty-tree, и в списке — каталог агентов (ровно то, что видел ревьюер).
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "без финализации: next встаёт в dirty-tree" "dirty-tree" "$(jd "$out" 'd["data"]["halt"]')"
assert_eq "без финализации: в списке — каталог агентов" "True" \
  "$(jd "$out" 'any(".claude" in f for f in d["data"]["files"])')"

# Лечение (sync Шаг 1 → Шаг 6 на раннем выходе): seal + finalize sync.
# seal на совпадающих хэшах обязан оставаться безопасным no-op'ом.
out="$(bash "$repo_root/lib/plugin-lock.sh" seal | tail -n 1)"
assert_eq "Шаг 6: повторный seal безопасен" "True" "$(jd "$out" 'd["ok"]')"
printf 'chore: sync project artifacts with plugin\n' > /tmp/sync-early-msg-$$.txt
out="$(bash "$repo_root/lib/finalize.sh" sync /tmp/sync-early-msg-$$.txt | tail -n 1)"
rm -f /tmp/sync-early-msg-$$.txt
assert_eq "Шаг 6: finalize sync закоммитил собранное" "True" "$(jd "$out" 'd["ok"]')"
assert_eq "Шаг 6: есть sha коммита" "True" "$(jd "$out" 'len(d["data"]["sha"]) == 40')"

# Путь замкнут: дерево чистое, конвейер стартует (next выдаёт задачу 001).
assert_eq "после финализации: дерево чистое" "" "$(git status --porcelain)"
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "после финализации: next отдаёт задачу, не halt" "001" "$(jd "$out" 'd["data"]["task_id"]')"
# Роли и отметки derived в одном коммите: lock не разошёлся с деревом.
assert_eq "роли в HEAD" "3" "$(git show --name-only --pretty=format: HEAD | grep -c '\.claude/agents/mvp-.*\.md')"

# Проводка: скилл называет Шаг 6 на раннем выходе (иначе оператору снова
# посоветуют «сбрось изменения»), справочник объясняет цену пропуска.
need_doc "$repo_root/skills/sync/SKILL.md" 'роли изменились (`git status`)? → Шаг 6' \
  "ранний выход sync обязан вести в Шаг 6 (финализация собранных ролей)"
need_doc "$repo_root/skills/sync/SKILL.md" 'halt dirty-tree' \
  "ранний выход sync обязан называть цену пропуска финализации"
need_doc "$repo_root/skills/sync/references/sync-handbook.md" 'обязан пройти и через Шаг 6' \
  "sync-handbook обязан объяснять финализацию на раннем выходе (находка I-1)"

exit $fail
