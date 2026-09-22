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

# Валидатор — единственная точка диспатча. need_count_code с ожидаемым "1"
# (не голый need_code — fix round 1 находка 2), той же формы, что и соседние
# ассерты для mvp-relay/mvp-reviewer ниже: "хотя бы одно совпадение" не ловит
# случайное ДУБЛИРОВАНИЕ диспатча валидатора, а точный счёт ловит.
need_count_code "agentType: 'mvp-validator'" "1" "валидатор должен диспатчиться РОВНО один раз (не 0, не 2+) — узкая роль без дублей"

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

# CAP-рукав (task 8, спека §9; fix round 1, находка 1 — все четыре ассерта
# ниже переписаны на need_code/need_count_code, пин на РЕАЛЬНОЕ выражение
# активации, не на голую встречаемость подстроки). Ревью эмпирически сняло
# `&& !!adv.data.capped_role` из условия активации — весь прежний гейт (голый
# `need "capped_role"` и т.п.) остался зелёным, потому что подстрока
# "capped_role" продолжает встречаться и в комментариях, и в других строках
# кода (agentType: adv.data.capped_role — сам диспатч). Ассерты ниже пинуются
# на ТОЧНОЕ выражение armEligible/armActive построчно, вне комментариев.

# (1) «рукав мёртв без capped-роли»: !!adv.data.capped_role обязан входить в
# armEligible. Уникальная подстрока во всём файле (см. grep-проверку в
# отчёте) — единственное место, где она стоит, это само условие активации.
need_code "adv\.data\.experiments === 'greedy' && !!adv\.data\.capped_role" "рукав должен требовать существующую capped-роль в условии armEligible — иначе включится без неё до Task 9 (закон недублирования не про это, но безопасный порядок — именно про это)"

# (2) «режимы off/passive»: та же строка, отдельно пиннуем experiments==='greedy'
# — если рукав перестанет смотреть на режим, эта подстрока пропадёт из строки
# armEligible независимо от того, жив ли ещё capped_role-чек рядом.
need_code "const armEligible = adv\.data\.experiments === 'greedy'" "рукав должен требовать experiments==='greedy' в самом начале armEligible — иначе включится в off/passive"

# (3) «чётность среза»: armActive обязан требовать И armEligible, И чётность
# ПОЗИЦИИ задачи в плане (task_index из payload next — финальное ревью,
# находка I6). Откат на счётчик запуска (tasksDone) тест обязан ловить:
# счётчик обнуляется на каждом старте оркестратора, первая задача любого
# запуска попадала бы в рукав, а упавшая в рукаве задача при перезапуске
# попадала бы в него снова.
need_code "const armActive = armEligible && \(taskIndex % 2 === 0\)" "нет чётного среза по позиции в плане — рукав обязан резать чёт/нечет по task_index (стабилен между запусками), не по tasksDone (обнуляется на каждом старте)"
need_code "const taskIndex = adv\.data\.task_index" "taskIndex обязан браться из payload next (plan-io.mjs task_index), а не из счётчика внутри запуска"

# (3б) исключение явного --task из рукава (находка I6): пере-прогон одной
# задачи по решению оператора — смещённая выборка, ни cap30, ни control.
# Пин на точное выражение внутри armEligible.
need_code "Number\.isInteger\(taskIndex\) && !argv\.task_id" "armEligible обязан требовать известный task_index И отсутствие явного --task — иначе перезапуск упавшей задачи снова попадает в рукав (цикл без выхода)"

# Выход из цикла обязан быть НАЗВАН в park-тексте «сегменты исчерпаны»
# (находка I6): и путь мимо рукава (явный task_id), и полное отключение
# (режим экспериментов в state.json).
need_code "set experiments passive" "park-текст «сегменты исчерпаны» обязан называть выход: переключение режима экспериментов в состоянии проекта"
need_code "идёт МИМО рукава" "park-текст «сегменты исчерпаны» обязан называть выход: перезапуск задачи явным task_id идёт мимо рукава"

# сегментный потолок: пин на объявление с конкретным числом — не просто
# встречаемость идентификатора CAP_SEGMENTS (который иначе можно было бы
# оставить только в тексте park-сообщения ниже по коду, ничего не ограничивая).
# Хвостовая `;` обязательна: без неё "= 4" остаётся substring-префиксом
# "= 400;" и тест не заметил бы молчаливую замену потолка (двусторонняя
# проверка в отчёте нашла эту дыру в первой версии этого ассерта).
need_code "const CAP_SEGMENTS = 4;" "нет фиксированного потолка сегментов = 4 (final-verdict дискуссии)"

# (4) «счётчик диспатчей»: рукав не должен заводить НОВУЮ статическую точку
# `dispatchCount += 1` сверх существующих пяти (relayLine×2, relay/attempt×1,
# agentText×1, patch-writer×1) — он обязан ходить через уже инкрементирующие
# agentText()/relay(), не мимо них. Точное число, как need_count_code для
# ролей выше, а не голое "нашлось хоть раз".
need_count_code "dispatchCount \+= 1" "5" "рукав добавил новую статическую точку инкремента dispatchCount сверх agentText/relay — CAP-путь обязан ходить только через них"

# CAP-рукав, fix round 1, находка 2: «агента вообще не было» (незарегистрированная
# capped-роль — файл на диске есть, но текущая сессия не подхватила его при
# старте) обязана иметь СВОЙ park-текст, отдельный от «сегменты исчерпаны».
# Тот же приём, что для armEligible/armActive выше — пин на точное выражение,
# не на голую встречаемость подстроки "neverStarted".
need_code "const neverStarted = segments === 1 && handoffReason != null;" "дискриминатор «агента вообще не было» обязан требовать И первый сегмент, И handoffReason — иначе не отличит незарегистрированную роль от обычного обрыва"

# Новый диагностический текст обязан называть вероятную причину (сессия) и
# действие (рестарт) — по образцу текста для agentTypeFallbacks в обычной
# ветке ниже (already covered by "restart the session" не проверяем — она
# специфична для обычной ветки; здесь пиннуем именно cap-формулировку).
need_code "produced no text on the very first dispatch attempt" "новый park-текст для «агента вообще не было» не найден вне комментариев — диагностика деградировала обратно к общей фразе"
need_code "restart the session and" "новый park-текст обязан называть действие (перезапуск сессии), а не только факт"

# Нормальный случай («сегменты исчерпаны», агент реально работал) обязан
# СОХРАНИТЬ свой текст без изменений — иначе fix round 1 находки 2 тихо
# перезаписал бы соседнюю, ранее рабочую диагностику.
need_code "implementer \(cap arm\) returned no text after \\\$\{segments\} segment\(s\); handoff\.sh declined to continue: \\\$\{handoffReason\}" "текст «handoff.sh declined to continue» (не-первый сегмент, обычный обрыв) не должен исчезнуть — сохраняется без изменений"
need_code "implementer \(cap arm\) returned no text after \\\$\{segments\} segment\(s\) — \\\$\{CAP_SEGMENTS\} segments were exhausted" "текст «сегменты исчерпаны» (агент работал, дерево грязное) не должен исчезнуть — сохраняется без изменений"

# handoffReason — причина от handoff.sh — обязана звучать в ОБОИХ ветках
# (новой «never started» и старой «declined to continue»), не потеряться при
# разводке. Считаем подстановку `${handoffReason}` вне комментариев — ровно 2
# точки (было 1 до этого фикса).
need_count_code "\\\$\{handoffReason\}" "2" "причина handoff.sh обязана звучать в ОБЕИХ park-ветках (new «never started» + старая «declined to continue»), не потеряться при разводке текста"

# --- mech_roles (финальное ревью, находка C1) --------------------------------
# Проект со старой версии плагина не имеет файлов mvp-*.md; узкая роль там
# не должна диспатчиться ВООБЩЕ — пустой ответ на не-retryable команде
# (save-review, finalize, apply-patches, handoff, установка фазы) бросает
# исключение до запасной попытки, а повтор запрещён законом недублирования.
# Поведенческий тест сценария — tests/lib/workflow-noroles.test.sh; здесь —
# проводка: mechRoles обязан существовать, кормиться из payload next ДО
# halt-ветки и гейтить каждую точку узкого диспатча.

need_code "const mechRoles = \{ 'mvp-reviewer': true, 'mvp-validator': true, 'mvp-relay': true \}" "нет реестра mechRoles с оптимистичным дефолтом (payload без поля = прежнее поведение)"
need_code "noteMechRoles\(adv\.data && adv\.data\.mech_roles\)" "mech_roles из payload next не применяется — оркестратор не узнаёт об отсутствии ролей"

# noteMechRoles обязан отработать ДО halt-ветки: за all-done идёт
# не-retryable релей установки фазы (тот же приём сравнения позиций, что для
# all-abstain/blind выше).
line_note="$(grep_code "noteMechRoles\(adv\.data && adv\.data\.mech_roles\)" | head -1)"
line_halt="$(grep_code "if \(adv\.data && adv\.data\.halt\)" | head -1)"
if [ -z "${line_note:-}" ] || [ -z "${line_halt:-}" ]; then
  echo "FAIL: workflow.mjs: не нашёл обе точки вне комментариев для проверки порядка noteMechRoles/halt-ветки" >&2
  fail=1
elif [ "$line_note" -ge "$line_halt" ]; then
  echo "FAIL: workflow.mjs: noteMechRoles(adv.data...) обязан идти ДО halt-ветки — иначе релей установки фазы после all-done диспатчит несуществующую роль и умирает" >&2
  fail=1
fi

# Каждая точка узкого диспатча гейтится существованием файла роли:
# relayLine + relay — по mechRoles['mvp-relay'] (обе через const narrow),
# три ревью-диспатча — spread-условием, валидатор — одним.
need_count_code "const narrow = mechRoles\['mvp-relay'\]" "2" "обе релей-точки (relayLine + relay) обязаны спрашивать mechRoles перед узким диспатчем"
need_count_code "\.\.\.\(mechRoles\['mvp-reviewer'\] \? \{ agentType: 'mvp-reviewer' \} : \{\}\)" "3" "все три ревью-диспатча (опрос-цикл + reviewer-retry + re-review) обязаны гейтиться mechRoles"
need_count_code "\.\.\.\(mechRoles\['mvp-validator'\] \? \{ agentType: 'mvp-validator' \} : \{\}\)" "1" "диспатч валидатора обязан гейтиться mechRoles"

# Sanity-parse (та же команда, что в Global Constraints)
node -e "const src=require('fs').readFileSync('$wf','utf8').replace(/^export const meta[\s\S]*?^}/m,''); new (Object.getPrototypeOf(async function(){}).constructor)('agent','parallel','pipeline','log','phase','args','budget','workflow', src)" || { echo "FAIL: sanity-parse" >&2; fail=1; }

exit $fail
