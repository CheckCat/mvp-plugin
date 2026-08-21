# MVP playbook run 2 — гибрид boundary patch (2026-06-16)

Прогон с новой семантикой `service` = HARD boundary / `planned_files` = HINT
(см. commit `f2233e5` в проекте + `~/.claude/skills/{plan,execute}-mvp/SKILL.md`).

## Что патчилось перед прогоном

| Файл | Изменение |
|---|---|
| `.claude/agents/validator.md` | Check 3 → exit code only (`--passWithNoTests` ОК), Check 4 → `diff_within_service_boundary` |
| `~/.claude/skills/execute-mvp/SKILL.md` | `computeServiceBoundary()`, implement prompt с boundary + hint, VALIDATOR_SCHEMA enum |
| `~/.claude/skills/plan-mvp/SKILL.md` | planner НЕ предугадывает spec/migration файлы |
| 5 проектных agent-ролей | "Boundary respect" переформулирован под service+hint |

## Прогон

- **Команда:** `/execute-mvp only task 4`
- **Workflow:** `wf_207aa837-0cb` (paused юзером)
- **Target:** task-004 (Prisma scaffold, 5 файлов, NestJS backend)
- **Бюджет:** без cap'а (юзер не указал)
- **Применено:** 7 optimization patterns + новые hybrid prompts

## Реальная стоимость (по тарифам Anthropic)

ВАЖНО: первый анализ был **неправильным** (я суммировал накопительный
usage по каждой строке jsonl вместо последней записи). Реальные цифры
получены повторным парсингом — взята ПОСЛЕДНЯЯ usage запись в каждом
transcript (там накопительный итог).

| Agent | Model | tokens | $ |
|---|---|---|---|
| load-plan | Haiku | 32k | $0.030 |
| check-interrupt #1 | Haiku | 24k | $0.003 |
| ? (haiku worker) | Haiku | 24k | $0.005 |
| subgraph | Haiku | 38k | $0.010 |
| **implement task-004** | **Opus** | **56k** | **$0.092** |
| stage-planned | Haiku | 24k | $0.004 |
| validator | Sonnet | 24k | $0.016 |
| code-reviewer | Sonnet | 38k | $0.041 |
| finalize (merged commit+persist+invalidate) | Haiku | 39k | $0.004 |
| check-interrupt #2 (task-005 уже!) | Haiku | 24k | $0.003 |
| ? subgraph task-005 | Haiku | 24k | $0.003 |
| ? implement-prep task-005 | Haiku | 28k | $0.010 |
| implement task-005 (юзер стопнул) | Opus | 33k | $0.068 |
| **TOTAL** | | **408k** | **$0.29** |

**Только task-004 (без a2f299 = task-005): ~$0.22**

## Сравнение с прошлыми прогонами того же проекта

| Run | task | actual_tokens (workflow runtime) | $ |
|---|---|---|---|
| run-1 (без гибрида) | task-002 shared | 345.2k | — |
| run-1 (без гибрида) | task-003 backend scaffold | 192.1k | — |
| **run-2 (гибрид)** | **task-004 prisma** | **1.51M** (но это workflow-runtime budget, не API spend) | **$0.22** |

Workflow runtime `budget.spent()` ≠ реальный API spend. Workflow считает
включая всю infrastructure (system prompts, tool definitions передаваемые
sub-agent'ам). API spend в **5-15× меньше** того что показывает Workflow.

## Что сработало

1. **Гибрид boundary** — нулевой fix-validator loop (`retry_count: 0`). Контракт
   между planner и validator больше не расходится.
2. **MODEL_FOR mapping** — Opus только на 1 вызов implement (главный). Остальное
   Sonnet/Haiku.
3. **Skip review для trivial** не применён (task-004 имеет 5 файлов > 3 порога).
4. **Merged finalize** Haiku — 39k токенов на commit+persist+invalidate sentinel.

## Что НЕ сработало

### Баг 1 (критичный): `only_task` логика не сработала

После успешного finalize task-004 цикл перешёл на task-005 (AuthModule)
вместо halt'а с `only-target-done`. Юзер стопнул на implementer'е task-005.

Транскрипт `a2f299` подтверждает — prompt содержит "Реализовать AuthModule"
(task-005), не task-004. Появления в тексте: task-004 (13 раз) + task-005 (8 раз).

Проверь:
- В скрипте есть halt-check `if (onlyTask && task.id === onlyTask) { halted=true }`
- После finalize. Но перед ним успели запуститься несколько Haiku агентов
  (check-interrupt #2, subgraph task-005) — это значит while-loop НЕ вышел
  и попал в следующую итерацию.
- В новой итерации `ready.find(t => t.id === "task-004")` должен вернуть
  undefined (task-004 уже done). Но почему-то нашёл task-005 как next ready
  и пошёл к нему.

Гипотезы (для отладки):
- Code path `if (onlyTask) { task = ready.find(t => t.id === onlyTask) }` — find
  возвращает undefined для task-004 (done), тогда дальше:
  ```js
  if (!task) {
    const found = plan.tasks.find(t => t.id === onlyTask)
    haltReason = found?.status === 'done' ? 'only-target-done' : 'only-target-not-ready'
    halted = true; break
  }
  ```
  Это должно halt. Если оно НЕ сработало — значит `task` НЕ был undefined,
  значит `ready` ВСЁ ЕЩЁ содержит task-004. Значит `plan` в памяти не обновился.
- Проверить: возможно `updateTask` возвращает новый объект, но плагинирование
  переменной `plan = updateTask(...)` в каком-то async closure не пробросилось.
- Или: finalize-agent (haiku) перезаписал plan.json (на диске) с СТАРОЙ версией
  (потому что plan на момент `JSON.stringify(plan)` был ещё со status='pending').
  Это маловероятно — мы updateTask до finalize вызываем.

### Не-баг, но дорого: implement Opus 56k

56k токенов на 5 файлов скаффолда — это **много** для такой простой работы.
Implementer сделал 146 шагов диалога (28 Read, 22 Bash, 9 Write, 2 Edit).

Возможно: Opus переусердствовал. Sonnet на scaffold справился бы за 20-30 шагов
и дешевле в 5× ($0.09 → ~$0.02).

Рекомендация — на следующих task'ах попробовать `MODEL_FOR.implement = 'sonnet'`
для scaffold-молекул (`level: molecule` + role не требует глубокой логики).

## TODO до следующего прогона

1. **Пофиксить `only_task` halt** — критичный. Без этого `/execute-mvp +50k`
   с указанием задачи всё равно поедет в следующие.
2. **Попробовать downgrade implement Opus → Sonnet** на простом scaffold.
3. **Поднять порог skip-review до ≤ 6 файлов** для molecule-уровня.

## Где транскрипты

- Workflow: `~/.claude/projects/-Users-vadim-Documents-Pet-vireo/d53dd969-e09f-4eda-b1dd-8e4d22f4286b/subagents/workflows/wf_207aa837-0cb/`
- Raw cost JSON: `/Users/vadim/Documents/Pet/vireo/.claude/task-004-cost-analysis.json`
