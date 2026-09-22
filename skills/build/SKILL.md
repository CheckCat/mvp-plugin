---
name: build
description: Use when .mvp/plan.json exists and implementation should proceed
---

# mvp:build

**Announce at start:** «Using mvp:build to run the implementation loop».

**Iron Law: «LLM думает — скрипты двигают данные».** Ты не редактируешь `plan.json`/`ledger.md`-Task-строки/`state.json` руками — их трогают только `lib/plan-io.mjs`, `lib/state.sh`, `lib/finalize.sh` (все вызываются ИЗНУТРИ `workflow.mjs`, ты их напрямую не зовёшь). Твоя работа — запустить `Workflow`, прочитать её `halt`, и там где нужно суждение (Stop&Ask, ruling) — рассудить.

**НИКОГДА не запускай второй `Workflow` параллельно этому** — один git working tree, второй запуск = гонка коммитов. **НИКОГДА не используй `resumeFromRunId`** — мёртвая фича для этого пайплайна: `run_id`/`now` каждый раз новые, аргументы между сессиями меняются.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh build
```

`ok:false` → Stop&Ask с `reason`/`hint` как есть.

`ok:true` с непустым `data.normative_changed` / `normative_added` /
`normative_removed` — в плагине изменились нормативные файлы после того, как
проект их принял. Не блокер: покажи список оператору одной строкой и
продолжай. Разобраться — `mvp:sync`.

## Шаг 2 — аргументы оператора

- `--tasks N` → `max_tasks` (жёсткий cap задач за этот запуск). Флаг не задан → `999` («до конца плана или до halt»).
- `--task <id>` → `task_id`. При явном `--task` `max_tasks` не работает как cap (передай `1` — validateArgs требует положительное число всегда), Workflow остановится после этой одной задачи.
- `+NNNk` (токен-потолок) — **не поле args Workflow.** `validateArgs` в `workflow.mjs` проверяет только `run_id/now/plugin_root/max_tasks` (+опц. `project_root`) — бюджета там нет; это величина Workflow-рантайма (`budget.spent()`), скрипт не режет по ней в середине задачи. Держи `NNNk*1000` как свой потолок: после каждого `halt:null` суммируй `results[].tokens_delta`, при превышении предупреди оператора в сводке — это предупреждение, не hard-cap.
- Флаг `experiments` живёт в `.mvp/state.json` (`greedy`-дефолт | `passive` | `off`): greedy ведёт CAP-рукав на чётных позициях плана (закон недублирования: ничего не удваивается); явный `--task` в рукав не попадает; выход из рукава — `passive`/`off`.

## Шаг 3 — запуск

`run_id` — уникальный слаг, придумай сам, новый на каждый запуск (например `build-<ISO без разделителей>`). `now` — ISO-таймштамп, возьми один раз через `date -u +"%Y-%m-%dT%H:%M:%SZ"` (сам `workflow.mjs` `Date`/`Math.random` вызывать не может — эти значения даёшь только ты, единожды на запуск).

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/skills/build/workflow.mjs",
  args: { run_id, now, max_tasks, task_id, plugin_root: "${CLAUDE_PLUGIN_ROOT}" }
})
```

`args` — обычный объект. Опусти ключ `task_id` целиком, если `--task` не задан. `project_root` не передавай в обычном случае — cwd этой сессии уже корень целевого проекта, workflow дефолтит на него сам; передай явно, только если твой cwd отличается от корня проекта.

## Шаг 4 — halt-таблица

| halt | payload (что реально приходит) | действие |
|---|---|---|
| `null` | `tasks_done`, `results:[{task_id,sha,tokens_delta,dispatches,concerns[]}]` | Покажи список задач+sha. `concerns[]` **уже записаны** в `.mvp/ledger.md` — их пишет `plan-io.mjs ledger --concern-b64` внутри finalize, руками дописывать не надо (раньше это была обязанность SKILL'а и она была пропущена на 36 задачах из 36 — см. `docs/observations/2026-08-24-pipeline-economics-and-review-yield.md` §8.1). Операторское решение по concern'у — по-прежнему твоё: если оно есть, допиши строку `Ruling: <что> — <почему> — <цена ошибки>`. План ещё не весь `done` → перезапусти mvp:build (новые `run_id`/`now`) для продолжения. |
| `all-done` | `detail` + `phase_set` † | `phase=done` ставит сам workflow. `phase_set:false` — предупреждение в `detail`, поставь вручную, иначе mvp:retro не стартует. Покажи хвост `ledger.md`. **NEXT: Use mvp:retro**. |
| `dag-stuck` | `detail` — блокирующие id+статус (`blocking tasks: 004(failed), 007(pending)`) либо `task X has unmet deps: ...` † | Обычно причина — упавшая (`failed`) задача блокирует зависимых. Не Stop&Ask автоматом — сверься с закрытым списком ниже; если не подпадает — реши сам (ruling) и перезапусти именно блокирующую задачу: `args:{..., task_id: "<blocking-id>"}` — явный `task_id` обходит фильтр `status===pending` в `plan-io.mjs next`, единственный путь повторно продиспатчить `failed`-задачу. |
| `interrupt` | нет `detail` — только факт, что `.mvp/user-interrupt.md` существует † | Подтверди у оператора продолжение. Да → удали файл, перезапусти. Нет → остановись, файл не трогай. |
| `dirty-tree` | `files` — список грязных путей; `hint` непуст, если названная `--task` задача `failed` (её работа и лежит в дереве: `park()` не сбрасывает границу-корень); `detail` при этом халте пуст † | Покажи `files` и `hint` оператору. Обычно: `git checkout -- <files>` (сброс) или ручной коммит вне пайплайна, затем перезапуск. Если оператор посмотрел дерево и подтвердил, что это работа той самой запаркованной задачи — перезапусти с `accept_dirty: true` в `args`. Сам этот флаг не ставь: он и есть запись о том, что дерево смотрел человек. |
| `stop-and-ask` | `task_id`, `detail` = причина `park()` (BLOCKED/NEEDS_CONTEXT текст implementer'а, исчерпанная validate/review-лестница, **неполный ревью-пакет** — `review package is incomplete — ... truncated` / `reviewer could not verify ...`, либо **роль не продиспатчилась** — `agentType "<role>" did not dispatch`) † | Проверь `task_id` в `.mvp/plan.json` (уже `failed`, дерево чистое — `park()` делает `git checkout`+unstage) и `.mvp/blockers.md` (пишет агент по контракту `_common.md`, не `workflow.mjs`). `AskUserQuestion` с этим контекстом; решение — строкой в `.mvp/decisions.log` (Write/Edit append: `[task_id] решение — обоснование`; журнал оператора, не pipeline-state). Перезапусти ту же задачу явным `task_id`. **`did not dispatch`** — не ruling, а перезапуск сессии: есть `.claude/agents/<role>.md` → перезапусти сессию (роли регистрируются при старте); нет → роль не собрана.<br><br>**Блокер вне границы задачи?** Заведи отдельную: `plan-io.mjs add-task --json '{...}'` (id, `pending`, только если план валиден). Не правь plan.json руками и не пиши блокер в `blockers.md` — так на vireo потерялся циклический импорт, ронявший два деплой-юнита. |
| `bad-args` / `error` | `detail`; у `error` ещё `in_flight_task`, `recovery: parked\|failed` † | Сбой окружения/аргументов. Покажи `detail`. **`recovery: failed` → сначала дерево:** `git status`, снеси незакоммиченное под границей упавшей задачи (она `pending`, гейты не проходила), потом перезапуск. Фикс причины — Stop&Ask. |

† halt≠null никогда не несёт `results`/`tasks_done` — даже если запуск уже коммитил задачи раньше в цикле: all-done/dag-stuck/interrupt/dirty-tree отдают единый `{halt, detail}` без ветки для накопленных `results`; `stop-and-ask` возвращается из `park()` до `results.push()`. Что реально закоммичено этим run — смотри `ledger.md`/`git log`, не payload.

## «Rulings, not stalls»

Закрытый список Stop&Ask (§6.5 спеки, verbatim): **(1) необратимая операция, (2) security-выбор, (3) конфликт с планом/инвариантами, (4) двусмысленность, которую brief не разрешает.** Всё остальное — ruling в ledger с ценой ошибки, run продолжается.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «План почти валиден, поправлю поле на лету» | так v1 терял service и валил рабочий код — только plan-io |
| «Ревью можно скипнуть, молекула тривиальная» | 7/16 тривиальных молекул baseline содержали реальные баги |
| «git add -A, файлов много» | finalize.sh стейджит явными путями (граница задачи + `.mvp`), всегда |
| «`files` в плане не сошлись с диффом — задача провалена» | `files` — подсказка планировщика, контракт — граница; такое расхождение приходит как concern, не как halt |
| «Пакет обрезан на одном файле, ревьюер и так всё понял — пропущу» | это ровно тот отказ, ради которого гейт и добавлен: 16 из 36 пакетов vireo были обрезаны и все 16 получили `approve`. Чини причину (разбей задачу / внеси файл в generated-список), гейт не обходится |
| «CANNOT_VERIFY есть, но вердикт approve — значит нормально» | approve поверх непроверенных требований не гейт. Это halt; снимается только тем, что ревьюер получит данные |
| «Fix-агент сказал REFUTED — значит находка ложная» | закрывает находку не fix, а re-review: fix только аргументирует, вердикт выносит отдельный агент |

## Red flags

«перепишу этот JSON сам», «вызову git commit напрямую», «запущу второй workflow параллельно» — STOP. Туда же: «использую resumeFromRunId» (мёртвая фича для этого пайплайна).

## HARD-GATE

`all-done` → показать сводку (сколько задач закоммичено по `ledger.md`) → сверить `phase_set` → **NEXT: Use mvp:retro**.
`null` с необойдённым планом → показать сводку этого запуска, явно сказать оператору, что нужен ещё один `mvp:build` для продолжения.
Любой другой halt — по таблице Шага 4, без самовольных переходов дальше по цепочке.
