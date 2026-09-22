# Общая фактическая база дискуссии (установлено до начала, перепроверяемо)

## Предмет
Пайплайн mvp-plugin: skills brief→clarify→bootstrap→plan→build→retro.
Ядро расхода — mvp:build: `skills/build/workflow.mjs` диспатчит на каждую задачу
лестницу субагентов (implementer → validate → review, ревью до 3 опросов, fix-раунды).
Репо плагина: /Users/vadim/Documents/tools/claude/mvp-plugin

## Метрика дискуссии
ТОЛЬКО количество токенов и их категории (output, cache write 5m/1h, cache read, base input).
Разница цен моделей НЕ обсуждается. Экономия выражается в токенах и % от прогона.

## Правило подсчёта (обязательно, иначе числа завышены ~2x)
Журналы пишут одну строку запроса многократно (частичные ответы стрима) с одним requestId.
Считать МАКСИМУМ каждого поля на пару (файл, requestId), не сумму подряд.
Готовый корректный модуль: scratchpad-каталог, файл `../tokcost.py` относительно этого файла
(абсолютный путь: /private/tmp/claude-501/-Users-vadim-Documents-Pet-trellis/ffbe66c3-5d41-424f-b4eb-27417e32a7fc/scratchpad/tokcost.py) — функции scan/merge/total.

## Где лежат сырые данные
- Журналы: ~/.claude/projects/<slug>/<session-id>.jsonl (главный цикл),
  <session-id>/subagents/agent-*.jsonl (+ .meta.json: agentType/description/model),
  <session-id>/subagents/workflows/wf_*/agent-*.jsonl (workflow-прогоны mvp:build).
  Slug'и: -Users-vadim-Documents-Pet-vireo, -Users-vadim-Documents-Pet-glotok, -Users-vadim-Documents-Pet-trellis
- Телеметрия пайплайна: <проект>/.mvp/telemetry/events.jsonl (task_complete: delta_tokens, dispatches).
  Проекты: /Users/vadim/Documents/Pet/{vireo,glotok,trellis}
- План с зависимостями: <проект>/.mvp/plan.json (deps, files — мера связности задач)
- Прошлые разборы: mvp-plugin/docs/observations/2026-08-24-pipeline-economics-and-review-yield.md,
  2026-09-21-delta-tokens-measures-output.md (там: delta_tokens == сумма output субагентов, ±2%)

## Уже установленные числа (метод: дедуп по requestId, все сессии проекта)
| | vireo | glotok | trellis |
|---|---|---|---|
| токенов всего | 1.38 млрд | 568 млн | 815 млн |
| cache read | 54% | 60% | 62% (доля токенов ~99% везде; в деньгах 54-62%) |
| output от всех токенов | ~0.7% | ~0.6% | ~0.6% |
| субагентов | 939 | 320 | 262 |
| запросов всего | 11,078 | 3,461 | 5,617 |
| ходов на субагента | 10.0 | 6.6 | 16.6 |
| контекст/запрос (cache read) | 118k | 158k | 141k |

Прогон wf_4d14cdc2 (trellis, mvp:build, 8 задач, 110 субагентов, 1,073 запроса):
output 800,128; cache_creation 3,995,364; cache_read 68,013,693; base input 3,042.
Т.е. на 1 задачу ≈ 13.8 субагентов, ≈134 запроса, ≈8.5M cache read.

Отдельный агент-аномалия (SDD, не пайплайн): 189 запросов, 36.4M cache read —
долгожитель дороже десятка короткоживущих.

## Границы честности
- Утверждение принимается только с числом, полученным из журналов/эксперимента,
  или с цитатой авторитетного источника (docs.anthropic/platform.claude, engineering-блоги, статьи).
- «В теории должно помочь» без замера — отклоняется.
- Если для проверки нужен эксперимент — сформулируй протокол; если он выполним локально
  на журналах — выполни сам.
