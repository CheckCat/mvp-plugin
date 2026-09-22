---
name: retro
description: Use after a finished mvp:build run to harvest telemetry into template and skill improvements
---

# mvp:retro

**Announce at start:** «Using mvp:retro to harvest this run into template/skill improvements».

**Iron Law: Уроки прогона → invariants.md проекта или observation-файл плагина; глобальные промпты не трогаем на живую.** Ты не редактируешь `skills/*`/`templates/*` — только пишешь кандидаты в observation-файл.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh get phase
```

`data.value != "done"` → Stop&Ask: «запусти после mvp:build all-done».

## Шаг 2 — телеметрия

Прочитай `.mvp/telemetry/events.jsonl`, собери сумму, min/max/avg по `delta_tokens` и `dispatches`.

**Ни одно поле тут не стоимость.** Что значат и откуда реальный расход — в [справочнике](references/retro-handbook.md). В $ не переводи.

## Шаг 3 — вербатим-наблюдения

Четыре входа (зачем — в справочнике): `ledger.md`, `decisions.log`, `blockers.md`, **транскрипт прогона** (`journal.jsonl`, `agent-*.jsonl`).

**`blockers.md`** — приоритетный вход: дефекты, которых не ловит ни один гейт (почему — в справочнике); каждый незакрытый — кандидат в правку или `add-task`.

Кандидат = вербатим-цитата (не перефраз) + источник + цель. Для дефекта кода цель — `file:line`, открытая глазами.

## Шаг 4 — observation-файл

Путь: **`.mvp/retro/<stamp>.md`**, `stamp` = `date -u +%Y-%m-%dT%H%M`. НЕ в `${CLAUDE_PLUGIN_ROOT}` (почему — в справочнике).

Форма файла — [справочник](references/retro-handbook.md) (**Load when:** пишешь отчёт). Пиши через `Write`.

## Шаг 5 — реестр гипотез

```
JOURNALS_DIR=<каталог agent-*.jsonl из Шага 3> ${CLAUDE_PLUGIN_ROOT}/lib/experiments.sh check $(git rev-parse --short HEAD)
```

Метка — HEAD, не время: повторный разбор не плодит «прогонов» в ttl_runs. Сводку `checked` — в observation-файл. `list` покажет `expired_candidate` и терминальные статусы: оператор переносит вердикт в observation плагина и удаляет строку registry.json (сам не трогай) — порядок в [справочнике](references/experiments-handbook.md).

## Шаг 6 — что дальше руками

Правки из Шага 3/4 — отдельный коммит в **репо плагина** (не в кэше), не автоматом. Скажи оператору путь отчёта.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Подправлю шаблон плагина сейчас» | Iron Law: живая правка глобальных шаблонов бьёт по всем проектам |
| «`delta_tokens` = стоимость» | это output-токены, ~14% расхода; стоимость — `subagent_tokens` уведомления |

## HARD-GATE

Покажи: путь отчёта, сводку телеметрии, число кандидатов, строку на каждую открытую гипотезу.

Перед «pipeline complete» прогони `git status --short` и назови незакоммиченное (почему хвост грязен — в справочнике). Не коммить сам — молчание о грязном дереве это ложь.

Терминальный скилл — **NEXT отсутствует**. Скажи: «pipeline complete».
