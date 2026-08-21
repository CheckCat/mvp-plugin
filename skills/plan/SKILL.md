---
name: plan
description: Use after mvp:bootstrap to produce plan.json (task DAG) and PROJECT_PLAN.md
---

# mvp:plan

**Announce at start:** «Using mvp:plan to build the task DAG».

**Iron Law: Каждый гейт плана — скрипт, не намерение.** Годен план или нет решает `validate-plan.py`, не твоё чтение plan.json глазами. Ты не пересчитываешь ошибки/сумму estimate в prose — только `data.errors`/`data.total_estimate` из скрипта.

Каждый результат скрипта — последняя строка stdout, JSON `{"ok","reason","hint","data"}`. При `ok:false` — почини по `hint` и повтори, либо Stop&Ask. `plan.json` руками не редактируется НИКЕМ, кроме планнера (создаёт) и `lib/plan-io.mjs` (дальше меняет через `next`/`complete`/`set-status`) — этот скилл сам plan.json не пишет.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh plan
```

`ok:false` с `data.recovery == "finalize-plan"` — `plan.json` уже существует и валиден, но не закоммичен (крэш между Шагом 3 и Шагом 5). Не зови планнера заново — предложи оператору доделать: сразу перейди к Шагу 4 (PROJECT_PLAN.md может быть уже сгенерирован — проверь) и Шагу 5 (`finalize.sh plan`).

Любой другой `ok:false` — Stop&Ask с `reason`/`hint` как есть.

## Шаг 2 — планнер-субагент

Дёрни Agent tool, `subagent_type: general-purpose` (нужен Write — планнер пишет `plan.json` напрямую). Промпт — секция «Planner prompt» ниже ДОСЛОВНО. Планнер сам читает пути (`project_brief/`, `.claude/state/invariants.md`, `ARCHITECTURE.md`) — ему передаются пути, не содержимое.

Планнер пишет `.claude/state/plan.json` целиком через Write — **единственное место, где `plan.json` создаётся**; дальше файл трогает только `lib/plan-io.mjs`. Жди от планнера ТОЛЬКО счётчики (фазы/задачи/estimate) — не план текстом, он уже в файле.

## Шаг 3 — валидация (скриптовый гейт)

```
${CLAUDE_PLUGIN_ROOT}/skills/plan/scripts/validate-plan.py
```

`ok:false` → покажи планнеру `data.errors` дословно, сделай **ОДИН** re-dispatch: тот же промпт из Шага 2 + приписка «Предыдущая попытка провалила validate-plan.py: <errors>. Перепиши `.claude/state/plan.json` через Write так, чтобы каждая ошибка исчезла.» Повтори Шаг 3. Снова `ok:false` → Stop&Ask с полным `data.errors`, не третья попытка молча.

`ok:true` → `data.total_estimate` — единственный источник суммарной оценки для Шага 4/HARD-GATE, не пересчитывай сам.

## Шаг 4 — PROJECT_PLAN.md

```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs summary
```

`data.total/done/pending/failed` и `data.phases.<level>` — единственный источник цифр. Для списка задач по фазам прочитай `.claude/state/plan.json` (read-only) и сгруппируй по `level`. Сгенерируй через `Write`:

```markdown
# Project Plan

Автогенерация из `.claude/state/plan.json` + `plan-io.mjs summary`. **Не редактируй вручную** — правки потеряются при следующей генерации. Меняй `plan.json` (через `plan-io.mjs`), не этот файл.

## Прогресс
- Всего задач: <data.total>
- Готово: <data.done> / <data.total>
- Суммарная оценка: <total_estimate из Шага 3> токенов

## Фазы

### Phase <level>
- [ ] <id> — <title> (<role>)
...

## Граф зависимостей
\`\`\`mermaid
graph TD
  001 --> 002
  ...
\`\`\`
```

## Шаг 5 — state + finalize

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh set phase plan-done
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh plan <msg-file>
```

`<msg-file>` первой строкой: `chore: project plan v1`. Коммитит `.claude/state` + `PROJECT_PLAN.md` (пресет `plan`).

## Planner prompt

Промпт для Agent tool (Шаг 2), дословно:

```
Ты — архитектор MVP. По предоставленным путям построй DAG задач и запиши его
в `.claude/state/plan.json` через Write. Не выводи план в чат — только
короткую сводку (число фаз, число задач, суммарный estimate_tokens).

Входные пути (прочитай их сам — тебе передали пути, не содержимое):
- `project_brief/` — все .md файлы (business_logic.md, technical_solutions.md,
  glossary.md, analysis_grey_zones.md — если есть)
- `.claude/state/invariants.md` — архитектурные инварианты ИМЕННО ЭТОГО
  проекта (Architectural invariants / Service boundaries / Forbidden edges).
  Не выдумывай других инвариантов, которых там нет.
- `ARCHITECTURE.md` — карта сервисов проекта

## Декомпозиция

- Атом — правка одного поля/метода. НЕ используй в плане.
- Молекула — фича внутри ОДНОГО сервиса, помещается в один контекст агента
  (estimate_tokens ≤ 25000). Основная единица плана.
- Организм — целый сервис или кросс-сервисное взаимодействие. Разбивай на молекулы.

## service_path — HARD boundary (hybrid: service HARD, files HINT)

`service_path` — единственный жёсткий gate build-стадии: все файлы задачи
обязаны лежать внутри него. `files` — HINT для наблюдаемости, НЕ
exhaustive-контракт (не перечисляй тесты/lock-файлы/dockerignore).

- Все `files` задачи ⊆ `service_path`.
- ОДНА задача = ОДИН `service_path`. Артефакты в разных сервисах — раздели
  на отдельные молекулы, не батчи.
- Cross-cutting (корневые tooling-configs, docker-compose, `.github/workflows/`,
  `deploy/`, корневые `tests/`) → `service: "root", service_path: "."`.

## Фазы — из brief, БЕЗ предзаданного списка

Нет фиксированного набора фаз. Разбей план на фазы исходя из
`## Services`/`## MVP scope` brief'а этого проекта: обычно
инфраструктура/скаффолд → общий foundation → фичи по сервисам (порядок из
зависимостей в brief'е) → интеграции с внешними API (если есть) → frontend
(если есть) → deploy. Название, число и границы фаз — твой выбор по факту
конкретного brief'а, не копируй чужой пример.

`level` — ЦЕЛОЕ число, номер фазы (1, 2, 3, …), НЕ категория
"молекула/организм" — по нему `plan-io.mjs summary` группирует задачи для
прогресса. Задачи без зависимостей — `level: 1`; их потребители — следующий
номер; и так далее. Все задачи одной фазы делят одно значение `level`.

## Поля задачи

Ровно эти поля (схема — `skills/plan/references/plan-schema.json`), поля
`blocks` в схеме НЕТ — не добавляй:

- `id` — bare zero-padded строка `"001"`, `"002"`, … БЕЗ префикса `task-`.
  `depends_on` ссылается на такие же bare id.
- `title` — одно предложение.
- `level` — см. выше, целое число (номер фазы).
- `service` — имя сервиса из ARCHITECTURE.md ИЛИ `"root"` для cross-cutting.
- `service_path` — relative путь к корню сервиса (`"."` для root).
- `role` — РОВНО одно из: `backend-implementer`, `frontend-implementer`,
  `test-writer`, `devops-engineer`, `integration-specialist`. Не выдумывай
  другие роли и не подглядывай в `.claude/agents/*.md` — набор фиксирован.
- `files` — ключевые artefact-файлы (HINT, не exhaustive).
- `depends_on` — массив bare id задач-предшественников.
- `estimate_tokens` — целое, ≤ 25000. Больше — разбей задачу.
- `status` — всегда `"pending"` на старте.
- `complexity_class` — см. таксономию ниже.

## complexity_class — таксономия (обязательно на каждой задаче)

| Класс | Что это | Признаки |
|---|---|---|
| `boilerplate` | Скаффолд по канону, решений ноль. | Конфиги, init фреймворка, Dockerfile по официальному образцу. |
| `follow-pattern` | Воспроизведение существующего или канонического паттерна. | Новый модуль по образцу другого; стандартный CRUD/эндпоинт. |
| `novel-design` | Новые решения, готового примера нет. | Первая интеграция библиотеки, архитектурный выбор, нетривиальные edge cases (concurrency, transactions). |

Сомневаешься — выбирай `novel-design` (провал review/retry дешевле тихой
недооценки). НЕ ориентируйся на `files.length`/`estimate_tokens` — объём ≠ сложность.

## DAG

- Ацикличен.
- `depends_on` ссылается только на `id`, существующие в этом же плане.
- Верни ТОЛЬКО итог в чат: число фаз, число задач, суммарный
  estimate_tokens. План уже записан в файл — не пересказывай его текстом.
```

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Впишу в промпт фазы под конкретный стек, чтобы планнер не тупил» | это ровно то, что зашило чужой проект в v1 — источник фаз только brief/invariants ЭТОГО проекта |
| «Провалидирую план сам, глазами, скрипт долго» | Iron Law: `validate-plan.py` — единственный источник `errors`/`total_estimate` |

## HARD-GATE

Прежде чем объявить шаг завершённым, покажи оператору:
- фазы плана (номера `level` + сколько задач в каждой);
- общее число задач и `data.total_estimate` (Шаг 3, не пересчитанное);
- `PROJECT_PLAN.md` целиком или ссылку на него.

Дождись подтверждения. **Build стартует только явной командой оператора** — не автоматически по завершении этого шага.

**NEXT:** Use mvp:build
