#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
wf="$repo_root/skills/build/workflow.mjs"

need() { grep -qE "$1" "$wf" || { echo "FAIL: workflow.mjs: не найдено /$1/ — $2" >&2; fail=1; }; }
count() { grep -oE "$1" "$wf" | wc -l | tr -d ' '; }

# grep_code(pattern) -> line numbers (original file numbering) of every match
# of $1 whose OWN line is not comment-only. "Comment-only" = first non-blank
# characters on the line are `//` or `*` (block-comment continuation) — a
# smoke-test-grade filter, not a JS parser (see report for its known gaps:
# string literals, same-line trailing comments, nested block comments are
# NOT handled). Exists because a decoy line like `// agentType: 'mvp-relay'`
# planted next to deleted real code used to satisfy grep alone (fix round 2).
grep_code() {
  local pattern="$1"
  grep -nE "$pattern" "$wf" | while IFS=: read -r lineno content; do
    trimmed="${content#"${content%%[![:space:]]*}"}"
    case "$trimmed" in
      '//'*|'*'*) ;;
      *) printf '%s\n' "$lineno" ;;
    esac
  done
}
count_code() { grep_code "$1" | wc -l | tr -d ' '; }
need_code() {
  local pattern="$1" msg="$2"
  if [ "$(count_code "$pattern")" = "0" ]; then
    echo "FAIL: workflow.mjs: не найдено вне комментариев /$pattern/ — $msg" >&2
    fail=1
  fi
}
need_count() {
  local pattern="$1" expected="$2" msg="$3" got
  got="$(count "$pattern")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: workflow.mjs: /$pattern/ встречается $got раз(а), ожидалось $expected — $msg" >&2
    fail=1
  fi
}
need_count_code() {
  local pattern="$1" expected="$2" msg="$3" got
  got="$(count_code "$pattern")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: workflow.mjs: вне комментариев /$pattern/ встречается $got раз(а), ожидалось $expected — $msg" >&2
    fail=1
  fi
}

# Валидатор — единственная точка диспатча. need_code (не голый need — task 8
# fix), чтобы голый комментарий-приманка с тем же текстом не держал ассерт
# зелёным при удалении настоящего вызова — та же дыра fix round 2 закрыл для
# соседних ассертов этого файла, но этот остался старой формой до сих пор.
need_code "agentType: 'mvp-validator'" "валидатор без узкой роли"

# agentType: 'mvp-relay' обязан стоять в ОБЕИХ точках диспатча релея:
# relayLine() (единственный вызов agent()) и relay()/attempt() (первая,
# узко-ролевая попытка внутри attempt(true)). Считаем вхождения ВНЕ
# комментариев — иначе удалённый вызов + комментарий-приманка с тем же
# текстом рядом проходят тест зелёным (fix round 2 находка ре-ревью).
need_count_code "agentType: 'mvp-relay'" "2" "релей должен нести узкую роль в обеих точках (relayLine + relay/attempt(true)), не в одной, и не в комментарии"

# agentType: 'mvp-reviewer' обязан стоять в ТРЁХ диспатчах: опрос-цикл
# (agentText в for), reviewer-retry (agentText над blockedPolls[0].text) и
# re-review (dispatchAgentText). Та же защита от комментария-приманки.
need_count_code "agentType: 'mvp-reviewer'" "3" "ревью должно нести узкую роль во всех трёх диспатчах (опрос-цикл + reviewer-retry + re-review), не в одном-двух, и не в комментарии"

# «Обрыв ≠ отказ»: проверяем не слово abstain (оно могло бы остаться только
# в комментарии или в имени переменной, никак не влияя на агрегацию), а то,
# что live СТРОИТСЯ фильтром NOT-abstain из полного списка опросов, и что
# именно live (а не исходный polls) кормит подсчёт голосов — unionFindings,
# patchPolls и blockedPolls. Откат любого из них на polls тест обязан ловить,
# даже если рядом со старым кодом кто-то оставит правильный текст в комментарии.
need_code "const live = polls\.filter\(\(p\) => !p\.abstain\)" "live не строится (вне комментариев) фильтром по !abstain из полного списка опросов — воздержавшиеся не отфильтрованы"
need_code "unionFindings\(live\)" "unionFindings не считает (вне комментариев) по live — воздержавшийся опрос может попасть в подсчёт находок"
need_code "const patchPolls = live\.filter" "patchPolls не вычисляется (вне комментариев) из live — воздержавшийся опрос может быть учтён как голос"
need_code "const blockedPolls = live\.filter" "blockedPolls не вычисляется (вне комментариев) из live — воздержавшийся опрос может быть учтён как голос"

# Фолбэк релея: проверяем не соседство слов "mvp-relay"/"fallback" в одной
# строке, а реальный путь — общая константа лог-сообщения, использованная
# РОВНО в двух точках фолбэка (relayLine и relay/attempt(false)), обе точки
# вне комментариев.
need_code "const RELAY_FALLBACK_LOG = " "нет (вне комментариев) общей константы лог-сообщения фолбэка релея"
need_count_code "log\(RELAY_FALLBACK_LOG\)" "2" "фолбэк-лог должен звучать в обеих точках фолбэка релея (relayLine + relay), не в одной, и не в комментарии"

# Порядок имеет значение: park на «все воздержались» (live.length === 0)
# обязан идти ДО вычисления blind-голосов (const blind = live.filter(...)).
# Переставь их местами — и «все воздержались» тихо станет «0 из 0 полагали
# cannotVerify», т.е. формально «ревью прошло чисто». Берём номер строки
# ПЕРВОГО совпадения вне комментариев для каждого якоря (grep_code уже
# фильтрует комментарии-приманки и сохраняет нумерацию исходного файла —
# сравнивать нужно позиции в реальном файле, не в отфильтрованном потоке).
line_allabstain="$(grep_code "live\.length === 0" | head -1)"
line_blind="$(grep_code "const blind = live\.filter" | head -1)"
if [ -z "${line_allabstain:-}" ] || [ -z "${line_blind:-}" ]; then
  echo "FAIL: workflow.mjs: не нашёл обе точки вне комментариев для проверки порядка all-abstain/blind (live.length === 0 или const blind = live.filter)" >&2
  fail=1
elif [ "$line_allabstain" -ge "$line_blind" ]; then
  echo "FAIL: workflow.mjs: ветка all-abstain (live.length === 0) должна идти ДО вычисления blind-голосов (const blind = live.filter...) — иначе «все воздержались» тихо станет «ревью прошло чисто»" >&2
  fail=1
fi

# CAP-рукав (task 8, спека §9): payload plan-io next читается, потолок
# сегментов есть, срез — чётный (внутрипрогонный контроль на нечётных).
need "capped_role" "рукав не читает payload plan-io"
need "CAP_SEGMENTS" "нет лимита сегментов"
need "tasksDone % 2" "нет чётного среза (внутрипрогонный контроль)"
grep -c "dispatchCount" "$wf" >/dev/null # рукав не должен добавлять новых точек инкремента сверх agentText/relay

# Sanity-parse (та же команда, что в Global Constraints)
node -e "const src=require('fs').readFileSync('$wf','utf8').replace(/^export const meta[\s\S]*?^}/m,''); new (Object.getPrototypeOf(async function(){}).constructor)('agent','parallel','pipeline','log','phase','args','budget','workflow', src)" || { echo "FAIL: sanity-parse" >&2; fail=1; }

exit $fail
