---
name: build
description: Use when .claude/state/plan.json exists and implementation should proceed
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

## Шаг 2 — аргументы оператора

- `--tasks N` → `max_tasks` (жёсткий cap задач за этот запуск). Флаг не задан → `999` («до конца плана или до halt»).
- `--task <id>` → `task_id`. При явном `--task` `max_tasks` не работает как cap (передай `1` — validateArgs требует положительное число всегда), Workflow остановится после этой одной задачи.
- `+NNNk` (токен-потолок) — **это НЕ поле args Workflow.** `validateArgs` в `workflow.mjs` проверяет только `run_id/now/plugin_root/max_tasks` (+опционально `project_root`) — поля под бюджет там нет; бюджет — глобальная величина Workflow-рантайма (`budget.spent()`), сам скрипт не умеет резать по нему на середине задачи. Держи `NNNk*1000` как СВОЙ, SKILL-уровня потолок: после каждого возврата с `halt:null` суммируй `results[].tokens_delta` и, если накопленная сумма его превысила, честно предупреди оператора в сводке — это предупреждение, не hard-cap.

## Шаг 3 — запуск

`run_id` — уникальный слаг, придумай сам, новый на каждый запуск (например `build-<компактный ISO без разделителей>`). `now` — ISO-таймштамп, возьми один раз через `date -u +"%Y-%m-%dT%H:%M:%SZ"` (сам `workflow.mjs` `Date`/`Math.random` вызывать не может — эти значения даёшь только ты, единожды на запуск).

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
| `null` | `tasks_done`, `results:[{task_id,sha,tokens_delta,dispatches,concerns[]}]` | Покажи список задач+sha. `concerns[]` **уже записаны** в `.claude/state/ledger.md` — их пишет `plan-io.mjs ledger --concern` внутри finalize, руками дописывать не надо (раньше это была обязанность SKILL'а и она была пропущена на 36 задачах из 36 — см. `docs/observations/2026-08-24-pipeline-economics-and-review-yield.md` §8.1). Операторское решение по concern'у — по-прежнему твоё: если оно есть, допиши строку `Ruling: <что> — <почему> — <цена ошибки>`. План ещё не весь `done` → перезапусти mvp:build (новые `run_id`/`now`) для продолжения. |
| `all-done` | `detail` + `phase_set` † | `phase=done` ставит сам workflow. `phase_set:false` — предупреждение в `detail`, поставь вручную, иначе mvp:retro не стартует. Покажи хвост `ledger.md`. **NEXT: Use mvp:retro**. |
| `dag-stuck` | `detail` — блокирующие id+статус (`blocking tasks: 004(failed), 007(pending)`) либо `task X has unmet deps: ...` † | Обычно причина — упавшая (`failed`) задача блокирует зависимых. Не Stop&Ask автоматом — сверься с закрытым списком ниже; если не подпадает — реши сам (ruling) и перезапусти именно блокирующую задачу: `args:{..., task_id: "<blocking-id>"}` — явный `task_id` обходит фильтр `status===pending` в `plan-io.mjs next`, единственный путь повторно продиспатчить `failed`-задачу. |
| `interrupt` | нет `detail` — только факт, что `.claude/state/user-interrupt.md` существует † | Подтверди у оператора продолжение. Да → удали файл, перезапусти. Нет → остановись, файл не трогай. |
| `dirty-tree` | `files` — список грязных путей (`plan-io.mjs next` кладёт его туда, `workflow.mjs` пробрасывает); `detail` при этом халте пуст † | Покажи `files` оператору. Если поля нет (старый payload) — сверься сам: `git status --porcelain -- . ':!.claude/state'`. Предложи `git checkout -- <files>` (сброс) или ручной коммит вне пайплайна, затем перезапусти. |
| `stop-and-ask` | `task_id`, `detail` = причина `park()` (implementer BLOCKED/NEEDS_CONTEXT текст, либо validate/review-лестница исчерпана, либо **неполный ревью-пакет**: `review package is incomplete — ... truncated` / `reviewer could not verify ...`) † | Прочитай статус `task_id` в `.claude/state/plan.json` (уже `failed`, дерево уже чистое — `park()` сам делает `git checkout`+unstage) и `.claude/state/blockers.md` (пишет диспатченный агент по контракту `_common.md`, не `workflow.mjs`). `AskUserQuestion` с этим контекстом. Решение запиши в `.claude/state/decisions.log` — Write/Edit append строкой `[task_id] решение — обоснование` (это НЕ pipeline-state, а журнал оператора; пишет сама сессия, не скрипт). Перезапусти ту же задачу явным `task_id`.<br><br>**Блокер называет работу вне границы задачи?** Заведи отдельную: `plan-io.mjs add-task --json '{...}'` — присвоит id, поставит `pending`, запишет только если план остаётся валидным. Не правь plan.json руками и не бросай блокер в `blockers.md`: так на vireo потерялся циклический импорт, ронявший два деплой-юнита. |
| `bad-args` / `error` | `detail` — текст ошибки | Не контентное решение, а сбой аргументов/окружения. Покажи `detail` как есть, Stop&Ask (почини вызов или прерви run) — не угадывай фикс сам. |

† halt≠null никогда не несёт `results`/`tasks_done` — даже если этот же запуск уже закоммитил задачи раньше в своём цикле: all-done/dag-stuck/interrupt/dirty-tree отдают единый `{halt, detail}` из `workflow.mjs` без ветки для накопленных `results`; `stop-and-ask` возвращается из `park()` до `results.push()` текущей задачи. Что реально закоммичено этим run — смотри `ledger.md`/`git log`, не payload.

## «Rulings, not stalls»

Закрытый список Stop&Ask (§6.5 спеки, verbatim): **(1) необратимая операция, (2) security-выбор, (3) конфликт с планом/инвариантами, (4) двусмысленность, которую brief не разрешает.** Всё остальное — ruling в ledger с ценой ошибки, run продолжается.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «План почти валиден, поправлю поле на лету» | так v1 терял service и валил рабочий код — только plan-io |
| «Ревью можно скипнуть, молекула тривиальная» | 7/16 тривиальных молекул baseline содержали реальные баги |
| «git add -A, файлов много» | finalize.sh стейджит явными путями (граница задачи + `.claude/state`), всегда |
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
