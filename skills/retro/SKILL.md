---
name: retro
description: Use after a finished mvp:build run to harvest telemetry into template and skill improvements
---

# mvp:retro

**Announce at start:** «Using mvp:retro to harvest this run into template/skill improvements».

**Iron Law: Уроки прогона → invariants.md проекта или observation-файл плагина; глобальные промпты не трогаем на живую.** Отсюда ты не редактируешь `skills/*`/`templates/*` — только пишешь кандидаты в observation-файл.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh get phase
```

`data.value != "done"` → Stop&Ask: «запусти после mvp:build all-done (phase=done)».

## Шаг 2 — телеметрия

Прочитай `.claude/state/telemetry/events.jsonl`. Тип один — `task_complete`: `{"event","task","delta_tokens","controller_only","dispatches","ts"}` (два средних поля с 2026-08-25, раньше `null`). Собери по `task`: сумму, min/max/avg.

**Ни одно поле тут не стоимость.** `delta_tokens` — `budget.spent()` глазами контроллера, субагентов не видит (на vireo занизил в **8.4×**). `dispatches` — тоже не прокси: замер на 19 задачах дал корреляцию +0.28 с токенами и −0.04 с деньгами. Это **форма прогона**: 5 — чистый путь, 8 — лестница валидации. В $ не переводи.

## Шаг 3 — вербатим-наблюдения

Прочитай `ledger.md`, `decisions.log`, `blockers.md`. В ledger: `  concern (task <id>): …` (пишет `ledger --concern`, основной источник), `Ruling:`, `Parked:`.

**`blockers.md` — приоритетный вход**: дефекты вне границы агента, которых не ловит ни один гейт (на vireo — цикл импорта, ронявший два деплой-юнита при зелёном CI). Каждый незакрытый — кандидат в правку плагина или в `plan-io.mjs add-task`.

На каждый кандидат — **вербатим-цитата** (не перефраз), источник-файл и цель (`skills/<name>/SKILL.md#Rationalization` либо `templates/<file>`).

## Шаг 4 — observation-файл

Путь: `${CLAUDE_PLUGIN_ROOT}/docs/observations/<date>-<project>.md`, `date`=`date -u +%Y-%m-%d`, `project`=`basename "$PWD"`. `mkdir -p`, пиши через `Write`:

```markdown
# Observations: <project> — <date>

## Run summary
done/failed (plan-io.mjs summary), сумма delta_tokens и dispatches

## Token calibration data
| task | delta_tokens | dispatches |

## Rationalization-table candidates (verbatim)
| cite | source file | target skill/table |

## Template edit candidates (verbatim)
| cite | source file | target template |
```

## Шаг 5 — что дальше руками

Ничего из Шага 3/4 не применяется автоматически: правки `skills/*`/`templates/*` — отдельный коммит в репо плагина. Если `${CLAUDE_PLUGIN_ROOT}` read-only — файл всё равно пиши, оператор перенесёт.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Подправлю шаблон плагина сейчас» | Iron Law: живая правка глобальных шаблонов бьёт по всем проектам, не только этому |
| «`delta_tokens` = стоимость» | тень: занижает в 8.4×, субагентов не видит |

## HARD-GATE

Покажи: путь observation-файла, сводку телеметрии, число вербатим-кандидатов. Терминальный скилл — **NEXT отсутствует**. Скажи: «pipeline complete».
