---
name: resume
description: Use to resume an MVP pipeline run from a cold context or after an interruption
---

# mvp:resume

**Announce at start:** «Using mvp:resume to restore pipeline context».

**Iron Law: Не гадай фазу — читай.** `state.sh get phase`, а если файла нет — факты на диске (Шаг 2). Никогда Workflow `resumeFromRunId` — мёртвая фича здесь: `run_id`/`now`/аргументы build генерятся заново каждый запуск.

## Шаг 1 — прочитать state

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh get phase
```

`ok:true` → `data.value` — иди в Шаг 4. `ok:false` (нет `state.json`) → Шаг 2.

## Шаг 2 — восстановление потерянного state.json

По порядку, первое совпадение решает:

1. `.claude/state/plan.json` есть и закоммичен (`git status --porcelain` по нему пуст) → `plan-done`.
2. `CLAUDE.md` + `ARCHITECTURE.md` есть → `bootstrap-done`.
3. `project_brief/clarify_queue.jsonl` есть, у каждой записи `status=="applied"` → `clarify-done`.
4. `project_brief/` есть (`business_logic.md`+`technical_solutions.md`) → `brief-done`.
5. Иначе → Stop&Ask: ничего не запаковано, начни с mvp:brief.

Восстановил → `state.sh init`, затем `state.sh set phase <фаза>`. Скажи оператору: «фаза восстановлена из файлов, не из state.json — проверь точку».

## Шаг 3 — ledger-правило

Строка `Task <id>: complete (<sha>)` в `.claude/state/ledger.md` = задача сделана. `plan-io.mjs next` берёт `status` из `plan.json` (не ledger), но раз строка есть — эта задача НЕ передиспатчится при рестарте mvp:build. Не предлагай оператору план/build заново.

## Шаг 4 — таблица диспатча

| phase | действие |
|---|---|
| `brief-done` | **NEXT:** Use mvp:clarify |
| `clarify-done` | **NEXT:** Use mvp:bootstrap |
| `bootstrap-done` | **NEXT:** Use mvp:plan |
| `plan-done` | Шаг 5 — build не автозапускается |
| `done` | **NEXT:** Use mvp:retro |
| нет / `brief` | Stop&Ask — начни с mvp:brief |

## Шаг 5 — `plan-done`: build-гейт и blockers

```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs summary
```

`data.failed == 0` → покажи прогресс (`data.done`/`data.total`), скажи что build стартует явной командой `mvp:build` — сама не дёргай.

`data.failed > 0` → прошлый build встал в `stop-and-ask`. Прочитай `.claude/state/blockers.md` (контекст) и `.claude/state/decisions.log` (уже решено?). Для failed-id без записи — `AskUserQuestion` с этим контекстом. Реши, допиши `[id] решение — обоснование` в `decisions.log` (Write/Edit сама, не скрипт). При «переделать»:
```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs set-status <id> pending
```
Скажи оператору: `mvp:build` перезапустит именно эту задачу.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «resumeFromRunId быстрее» | `run_id`/`now` каждый раз новые — фича не подходит |
| «state.json потерян — начну с mvp:brief заново» | `plan.json`/`CLAUDE.md`/`clarify_queue.jsonl`/`project_brief/` уже несут прогресс — восстанови фазу, не стирай работу |

## HARD-GATE

Покажи оператору прочитанную/восстановленную фазу и действие из Шага 4/5. Фаза восстановлена вручную (Шаг 2) → дождись подтверждения перед диспатчем.
