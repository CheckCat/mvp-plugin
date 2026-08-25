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

Прочитай `.mvp/telemetry/events.jsonl`. Тип один — `task_complete`: `{"event","task","delta_tokens","controller_only","dispatches","ts"}`. Собери сумму, min/max/avg.

**Ни одно поле тут не стоимость.** `delta_tokens` — взгляд контроллера, субагентов не видит (на vireo занизил в **8.4×**). `dispatches` — не прокси (корреляция −0.04), а **форма прогона**: 5 — чистый путь, 8 — лестница валидации. В $ не переводи.

## Шаг 3 — вербатим-наблюдения

Прочитай `ledger.md`, `decisions.log`, `blockers.md`. В ledger: `concern (task <id>): …` (основной источник), `Ruling:`, `Parked:`.

**`blockers.md` — приоритетный вход**: дефекты вне границы агента, которых не ловит ни один гейт (на vireo — цикл импорта, ронявший два деплой-юнита при зелёном CI). Каждый незакрытый — кандидат в правку плагина или в `add-task`.

На каждый кандидат — **вербатим-цитата** (не перефраз), источник-файл и цель (`skills/<name>/SKILL.md#Rationalization` либо `templates/<file>`).

## Шаг 4 — observation-файл

Путь: **`.mvp/retro/<stamp>.md`**, `stamp` = `date -u +%Y-%m-%dT%H%M`. НЕ в `${CLAUDE_PLUGIN_ROOT}`: переустановка стёрла бы отчёт молча. Время в имени обязательно — два retro за день иначе перезапишут друг друга. Пиши через `Write`:

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

Ничего из Шага 3/4 не применяется автоматически: правки `skills/*`/`templates/*` — отдельный коммит в **репо плагина** (не в кэше). Скажи оператору путь отчёта; кандидаты переносятся руками.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Подправлю шаблон плагина сейчас» | Iron Law: живая правка глобальных шаблонов бьёт по всем проектам, не только этому |
| «`delta_tokens` = стоимость» | тень: занижает в 8.4×, субагентов не видит |

## HARD-GATE

Покажи: путь отчёта, сводку телеметрии, число кандидатов. Терминальный скилл — **NEXT отсутствует**. Скажи: «pipeline complete».
