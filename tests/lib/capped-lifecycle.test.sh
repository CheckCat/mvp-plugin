#!/usr/bin/env bash
# capped-lifecycle.test.sh — жизненный цикл capped-копий ролей (финальное
# ревью, находка I2) и безусловная сборка ролей механики в mvp:sync (C1).
#
# Поведенческая часть: устаревшая capped-копия (исходную роль пересобрали,
# копию — нет) обязана РОНЯТЬ verify-agents-drift.sh — это ровно тот ложный
# след («чини сборщик»), который sync теперь предотвращает, пересобирая
# копию вслед за ролью; повторный `--capped` обязан копию освежать и
# возвращать дрейф-чек в зелёное.
#
# Проводка (grep): sync/SKILL.md обязан 1) собирать роли механики безусловно
# при любом исходе check (C1 — на проекте со старого плагина их нет, а check
# отвечает «всё в порядке»), 2) пересобирать capped-копию вслед за ролью;
# справочники обязаны нести содержимое, на которое ссылаются комментарии
# (assemble-agent.sh отсылает за порядком удаления в experiments-handbook).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
need_doc() { # <file> <fixed-string> <msg>
  grep -qF -e "$2" "$1" || { echo "FAIL: $1: не найдено «$2» — $3" >&2; fail=1; }
}
jok() { O="$1" python3 -c 'import json,os; print(json.loads(os.environ["O"])["ok"])'; }

# --- поведенческая часть -----------------------------------------------------
cd "$tmpdir"
mkdir -p .mvp

out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" integration-specialist | tail -n 1)"
assert_eq "роль собралась" "True" "$(jok "$out")"
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped integration-specialist | tail -n 1)"
assert_eq "capped-копия собралась" "True" "$(jok "$out")"

out="$(bash "$repo_root/skills/bootstrap/scripts/verify-agents-drift.sh" 2>/dev/null | tail -n 1)"
assert_eq "свежая пара: дрейф-чек зелёный" "True" "$(jok "$out")"

# Симулируем находку I2: _common.md «обновился», исходная роль пересобрана
# (у нас она и так актуальна), а capped-копия осталась со СТАРЫМ общим
# контрактом — портим общий блок только в копии.
python3 - <<'PY'
p = '.claude/agents/integration-specialist-capped.md'
s = open(p, encoding='utf-8').read()
s = s.replace('##', '@@', 1)  # ломаем байт-в-байт вхождение _common.md
open(p, 'w', encoding='utf-8').write(s)
PY
out="$(bash "$repo_root/skills/bootstrap/scripts/verify-agents-drift.sh" 2>/dev/null | tail -n 1)"
assert_eq "устаревшая capped-копия РОНЯЕТ дрейф-чек (ложный след, который sync обязан предотвращать)" "False" "$(jok "$out")"
assert_eq "дрейф-чек называет именно capped-файл" "1" \
  "$(O="$out" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(len([v for v in d["data"]["violations"] if "capped" in v["file"]]))')"

# Лекарство из Шага 3 sync: пересобрать копию вслед за ролью.
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped integration-specialist | tail -n 1)"
assert_eq "--capped освежает копию" "True" "$(jok "$out")"
out="$(bash "$repo_root/skills/bootstrap/scripts/verify-agents-drift.sh" 2>/dev/null | tail -n 1)"
assert_eq "после пересборки копии дрейф-чек снова зелёный" "True" "$(jok "$out")"

# Отложенная находка (ре-ревью): hint отказа --capped обязан называть
# КОНКРЕТНУЮ причину (текст SystemExit из python-блока), а не общую фразу
# «see python error above» — портим уже собранный источник (снимаем первую
# строку "---", фронтматтера не остаётся) и проверяем, что hint дословно
# несёт python-сообщение о причине, а не заглушку.
python3 - <<'PY'
p = '.claude/agents/integration-specialist.md'
s = open(p, encoding='utf-8').read()
s = s.split('\n', 1)[1]  # срезаем первую строку "---" — фронтматтера больше нет
open(p, 'w', encoding='utf-8').write(s)
PY
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped integration-specialist | tail -n 1)"
assert_eq "--capped на источнике без фронтматтера отказывает" "False" "$(jok "$out")"
hint="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["hint"])')"
case "$hint" in
  *"no frontmatter"*) : ;;
  *) echo "FAIL: hint не называет конкретную причину отказа (нет фронтматтера), получено: [$hint]" >&2; fail=1 ;;
esac
case "$hint" in
  *"see python error above"*) echo "FAIL: hint всё ещё общая фраза «see python error above»" >&2; fail=1 ;;
  *) : ;;
esac

# --- проводка ----------------------------------------------------------------
sync_skill="$repo_root/skills/sync/SKILL.md"
sync_hb="$repo_root/skills/sync/references/sync-handbook.md"
exp_hb="$repo_root/skills/retro/references/experiments-handbook.md"

# C1: sync собирает роли механики безусловно, до/независимо от раннего выхода
need_doc "$sync_skill" 'при любом исходе check' "sync обязан собирать роли механики при любом исходе check, не только при пересборке"
need_doc "$sync_skill" 'assemble-agent.sh mvp-reviewer' "sync обязан явно собирать mvp-reviewer"
need_doc "$sync_skill" '`mvp-validator`, `mvp-relay`' "sync обязан явно собирать mvp-validator и mvp-relay"
need_doc "$sync_hb" 'Роли механики' "sync-handbook обязан объяснять безусловную сборку ролей механики"
need_doc "$sync_hb" 'проект соответствует плагину' "sync-handbook обязан описывать тупик «check молчит про отсутствующие роли механики»"

# Второй проход финального ревью (мелкая находка 2): состав capped-копий в
# bootstrap назван явно — ВСЕ собранные роли плана, не только *-implementer.
# Рукав применим к любой роли плана; копии только для имплементеров молча
# выкидывали бы задачи остальных ролей из выборки эксперимента H1.
bootstrap_skill="$repo_root/skills/bootstrap/SKILL.md"
need_doc "$bootstrap_skill" 'capped-копии ВСЕХ собранных ролей плана' "bootstrap обязан называть состав capped-копий явно (все роли плана)"
need_doc "$bootstrap_skill" 'не только *-implementer' "bootstrap обязан явно исключать чтение «только имплементерские»"

# I2: пересборка capped-копий и задокументированный жизненный цикл
need_doc "$sync_skill" '--capped <role>' "sync Шаг 3 обязан пересобирать capped-копию вслед за исходной ролью"
need_doc "$sync_hb" 'Capped-копии' "sync-handbook обязан объяснять пересборку capped-копий (ложный след дрейф-чека)"
need_doc "$exp_hb" 'Capped-копии ролей' "experiments-handbook обязан нести жизненный цикл capped-файлов (на него ссылается комментарий assemble-agent.sh)"
need_doc "$exp_hb" 'не штампуется' "experiments-handbook: почему capped-копии не в plugin-lock"
need_doc "$exp_hb" 'НЕ останавливает рукав' "experiments-handbook: удаление строки реестра не останавливает рукав — файлы удаляются руками"
need_doc "$exp_hb" 'удалить все' "experiments-handbook: закрытие H1 требует удалить capped-файлы руками"

exit $fail
