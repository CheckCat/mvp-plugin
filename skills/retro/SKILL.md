---
name: retro
description: Use after a finished mvp:build run to harvest telemetry into template and skill improvements
---

# mvp:retro

**Announce at start:** «Using mvp:retro to harvest this run into template/skill improvements».

**Iron Law: Уроки прогона → invariants.md проекта или observation-файл плагина; глобальные промпты не трогаем на живую.** Ты никогда не редактируешь `skills/*/SKILL.md`/`skills/bootstrap/templates/*` отсюда — только пишешь кандидаты в observation-файл. Применение — отдельный коммит/PR в репозитории плагина, вручную или отдельной сессией там.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh get phase
```

`data.value != "done"` → Stop&Ask: «запусти после mvp:build all-done (phase=done)».

## Шаг 2 — телеметрия

Прочитай `.claude/state/telemetry/events.jsonl` (JSON Lines). Единственный существующий тип — `task_complete`: `{"event","task","delta_tokens","ts"}`. Не выдумывай другие поля/типы. Собери `delta_tokens` по каждой `task`, сумму, min/max/avg. Конверсию в $ не считай (нет цены API) — отдай числа как есть, это сырьё для калибровки.

## Шаг 3 — вербатим-наблюдения

Прочитай `.claude/state/ledger.md` (`Ruling:`/`Parked:`), `decisions.log`, `blockers.md` (если есть). На каждый кандидат в rationalization-таблицу/правку шаблона — **вербатим-цитата**, не перефраз (тот же evidence-принцип, что в mvp:clarify), плюс источник-файл и цель (`skills/<name>/SKILL.md#Rationalization` или `skills/bootstrap/templates/<file>`).

## Шаг 4 — observation-файл

Путь: `${CLAUDE_PLUGIN_ROOT}/docs/observations/<date>-<project>.md`, `date`=`date -u +%Y-%m-%d`, `project`=`basename "$PWD"`. `mkdir -p`, пиши через `Write`:

```markdown
# Observations: <project> — <date>

## Run summary
tasks done/failed (plan-io.mjs summary), суммарные delta_tokens

## Token calibration data
| task | delta_tokens |  (Шаг 2, без пересчёта в $)

## Rationalization-table candidates (verbatim)
| cite | source file | target skill/table |

## Template edit candidates (verbatim)
| cite | source file | target template |
```

`${CLAUDE_PLUGIN_ROOT}` не dev-checkout плагина (read-only install) → всё равно пиши файл, предупреди оператора: перенеси в репозиторий плагина руками.

## Шаг 5 — что дальше руками

Ничего из Шага 3/4 не применяется автоматически. Правки `skills/*/SKILL.md`/`templates/*` — отдельный коммит/PR в репозитории плагина (не в этом проекте): оператором или новой сессией, работающей прямо там.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Подправлю шаблон плагина сейчас, чего ждать PR» | Iron Law — живые правки глобальных шаблонов ломают доверие для всех проектов, не только этого |
| «Придумаю коэффициент $/token сам» | нет данных о цене API — только `delta_tokens`, конверсию считает оператор отдельно |

## HARD-GATE

Покажи: путь observation-файла, сводку телеметрии (Шаг 2), число найденных вербатим-кандидатов (Шаг 3). Терминальный скилл — **NEXT отсутствует**. Скажи: «pipeline complete».
