#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
wf="$repo_root/skills/build/workflow.mjs"

need() { grep -qE "$1" "$wf" || { echo "FAIL: workflow.mjs: не найдено /$1/ — $2" >&2; fail=1; }; }
count() { grep -oE "$1" "$wf" | wc -l | tr -d ' '; }
need_count() {
  local pattern="$1" expected="$2" msg="$3" got
  got="$(count "$pattern")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: workflow.mjs: /$pattern/ встречается $got раз(а), ожидалось $expected — $msg" >&2
    fail=1
  fi
}

# Валидатор — единственная точка диспатча, grep -q достаточно.
need "agentType: 'mvp-validator'" "валидатор без узкой роли"

# agentType: 'mvp-relay' обязан стоять в ОБЕИХ точках диспатча релея:
# relayLine() (единственный вызов agent()) и relay()/attempt() (первая,
# узко-ролевая попытка внутри attempt(true)). grep -q за фактом присутствия
# не отличит "потеряли одну из двух" от "обе на месте" — считаем вхождения.
need_count "agentType: 'mvp-relay'" "2" "релей должен нести узкую роль в обеих точках (relayLine + relay/attempt(true)), не в одной"

# agentType: 'mvp-reviewer' обязан стоять в ТРЁХ диспатчах: опрос-цикл
# (agentText в for), reviewer-retry (agentText над blockedPolls[0].text) и
# re-review (dispatchAgentText). Тоже считаем, а не просто ищем подстроку —
# иначе потеря роли в одном из трёх диспатчей проходит тест зелёным.
need_count "agentType: 'mvp-reviewer'" "3" "ревью должно нести узкую роль во всех трёх диспатчах (опрос-цикл + reviewer-retry + re-review), не в одном-двух"

# «Обрыв ≠ отказ»: проверяем не слово abstain (оно могло бы остаться только
# в комментарии или в имени переменной, никак не влияя на агрегацию), а то,
# что live СТРОИТСЯ фильтром NOT-abstain из полного списка опросов, и что
# именно live (а не исходный polls) кормит подсчёт голосов — unionFindings,
# patchPolls и blockedPolls. Откат любого из них на polls тест обязан ловить.
need "const live = polls\.filter\(\(p\) => !p\.abstain\)" "live не строится фильтром по !abstain из полного списка опросов — воздержавшиеся не отфильтрованы"
need "unionFindings\(live\)" "unionFindings считает не по live — воздержавшийся опрос может попасть в подсчёт находок"
need "const patchPolls = live\.filter" "patchPolls вычисляется не из live — воздержавшийся опрос может быть учтён как голос"
need "const blockedPolls = live\.filter" "blockedPolls вычисляется не из live — воздержавшийся опрос может быть учтён как голос"

# Фолбэк релея: проверяем не соседство слов "mvp-relay"/"fallback" в одной
# строке (это ловит и случайное совпадение в комментарии), а реальный путь —
# общая константа лог-сообщения, использованная РОВНО в двух точках фолбэка
# (relayLine и relay/attempt(false)). Пропажа вызова в одной из них рвёт связь
# кода с задокументированным поведением, но не рвёт "соседство слов".
need "const RELAY_FALLBACK_LOG = " "нет общей константы лог-сообщения фолбэка релея"
need_count "log\(RELAY_FALLBACK_LOG\)" "2" "фолбэк-лог должен звучать в обеих точках фолбэка релея (relayLine + relay), не в одной"

# Порядок имеет значение: park на «все воздержались» (live.length === 0)
# обязан идти ДО вычисления blind-голосов (const blind = live.filter(...)).
# Переставь их местами — и «все воздержались» тихо станет «0 из 0 полагали
# cannotVerify», т.е. формально «ревью прошло чисто». grep за наличием обеих
# строк такую перестановку не видит; видит только сравнение номеров строк.
line_allabstain="$(grep -n "live\.length === 0" "$wf" | head -1 | cut -d: -f1)"
line_blind="$(grep -n "const blind = live\.filter" "$wf" | head -1 | cut -d: -f1)"
if [ -z "${line_allabstain:-}" ] || [ -z "${line_blind:-}" ]; then
  echo "FAIL: workflow.mjs: не нашёл обе точки для проверки порядка all-abstain/blind (live.length === 0 или const blind = live.filter)" >&2
  fail=1
elif [ "$line_allabstain" -ge "$line_blind" ]; then
  echo "FAIL: workflow.mjs: ветка all-abstain (live.length === 0) должна идти ДО вычисления blind-голосов (const blind = live.filter...) — иначе «все воздержались» тихо станет «ревью прошло чисто»" >&2
  fail=1
fi

# Sanity-parse (та же команда, что в Global Constraints)
node -e "const src=require('fs').readFileSync('$wf','utf8').replace(/^export const meta[\s\S]*?^}/m,''); new (Object.getPrototypeOf(async function(){}).constructor)('agent','parallel','pipeline','log','phase','args','budget','workflow', src)" || { echo "FAIL: sanity-parse" >&2; fail=1; }

exit $fail
