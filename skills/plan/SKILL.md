---
name: plan
description: Use after mvp:bootstrap to produce plan.json (task DAG) and docs/plan.md
---

# mvp:plan

**Announce at start:** «Using mvp:plan to build the task DAG».

**Iron Law: Каждый гейт плана — скрипт, не намерение.** Годен план или нет решает `validate-plan.py`, не твоё чтение plan.json глазами.

Каждый результат скрипта — последняя строка stdout, JSON `{"ok","reason","hint","data"}`. При `ok:false` — почини по `hint` и повтори, либо Stop&Ask. `plan.json` руками не редактируется НИКЕМ, кроме планнера (создаёт) и `lib/plan-io.mjs` (дальше меняет через `next`/`complete`/`set-status`) — этот скилл сам plan.json не пишет.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh plan
```

`ok:false` с `data.recovery == "finalize-plan"` — `plan.json` уже существует и валиден, но не закоммичен (крэш между Шагом 3 и Шагом 5). Не зови планнера заново — предложи оператору доделать: сразу перейди к Шагу 4 (docs/plan.md может быть уже сгенерирован — проверь) и Шагу 5 (`finalize.sh plan`).

Любой другой `ok:false` — Stop&Ask с `reason`/`hint` как есть.

## Шаг 2 — планнер-субагент

Дёрни Agent tool, `subagent_type: general-purpose`, **`model: opus`** (Write нужен; иначе DAG спланирует модель сессии). Промпт — секция «Planner prompt» ниже ДОСЛОВНО. Планнер сам читает входные пути — ему передаются пути, не содержимое.

Планнер пишет `.mvp/plan.json` целиком через Write. Жди от него ТОЛЬКО счётчики (фазы/задачи/estimate) — не план текстом, он уже в файле.

## Шаг 3 — валидация (скриптовый гейт)

```
${CLAUDE_PLUGIN_ROOT}/skills/plan/scripts/validate-plan.py
```

`ok:false` → покажи планнеру `data.errors` дословно, сделай **ОДИН** re-dispatch: тот же промпт из Шага 2 + приписка «Предыдущая попытка провалила validate-plan.py: <errors>. Перепиши `.mvp/plan.json` через Write так, чтобы каждая ошибка исчезла.» Повтори Шаг 3. Снова `ok:false` → Stop&Ask с полным `data.errors`, не третья попытка молча.

`ok:true` → `data.total_estimate` — единственный источник суммарной оценки для Шага 4/HARD-GATE, не пересчитывай сам.

## Шаг 4 — docs/plan.md

```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs summary
```

`data.total/done/pending/failed` и `data.phases.<level>` — единственный источник цифр. Для списка задач по фазам прочитай `.mvp/plan.json` (read-only) и сгруппируй по `level`. Сгенерируй через `Write`:

```markdown
# Project Plan

Автогенерация из `.mvp/plan.json`. **Не редактируй вручную** — правки потеряются. Меняй `plan.json` через `plan-io.mjs`.

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

`<msg-file>` первой строкой: `chore: project plan v1`. Коммитит `.mvp` + `docs/plan.md` (пресет `plan`).

## Planner prompt

Промпт для Agent tool (Шаг 2), дословно:

```
Ты — архитектор MVP. По предоставленным путям построй DAG задач и запиши его
в `.mvp/plan.json` через Write. Не выводи план в чат — только
короткую сводку (число фаз, число задач, суммарный estimate_tokens).

Входные пути (прочитай их сам — тебе передали пути, не содержимое):
- `docs/product/` — все .md файлы (business-logic.md, technical-solutions.md,
  glossary.md, analysis-grey-zones.md — если есть)
- `.mvp/invariants.md` — архитектурные инварианты ИМЕННО ЭТОГО
  проекта (Architectural invariants / Service boundaries / Forbidden edges).
  Не выдумывай других инвариантов, которых там нет.
- `docs/architecture.md` — карта сервисов проекта

## Декомпозиция

Единица плана — **молекула**: фича внутри ОДНОГО сервиса, влезающая в один
контекст агента (`estimate_tokens ≤ 25000`). Правку одного метода в задачу не
выделяй, целый сервис разбивай на молекулы.

**Слияние — обязательный последний шаг перед записью файла.** Цена задачи
фиксирована (релеи + ревью) и от размера не зависит: дробление ниже молекулы
платится впустую. Сгруппируй по (`level`, `role`, `service_path`), слей группу
в одну задачу при сумме `estimate_tokens` ≤ 25000 и отсутствии взаимных
`depends_on`. `files` объединяются, `depends_on` — внешние,
`complexity_class` — максимальный.

## service_path — HARD boundary

`service_path` — единственный жёсткий gate build-стадии: все файлы задачи
обязаны лежать внутри него. `files` — HINT для наблюдаемости, НЕ
exhaustive-контракт (не перечисляй тесты/lock-файлы/dockerignore).

- ОДНА задача = ОДИН `service_path`. Артефакты в разных сервисах — раздели
  на отдельные молекулы, не батчи.
- Cross-cutting (корневые tooling-configs, docker-compose, `.github/workflows/`,
  `deploy/`, корневые `tests/`) → `service: "root", service_path: "."`.

## Фазы — из brief, БЕЗ предзаданного списка

Фиксированного набора фаз нет. Разбей исходя из `## Services`/`## MVP scope`
brief'а: обычно скаффолд → foundation → фичи по сервисам (порядок из
зависимостей brief'а) → интеграции → frontend → deploy. Число и границы фаз —
твой выбор по ЭТОМУ brief'у, не копируй чужой пример.

`level` — целое число, номер фазы; по нему `plan-io.mjs summary` группирует
прогресс. Задачи без зависимостей — `level: 1`, их потребители — следующий
номер. Все задачи одной фазы делят одно значение.

## Поля задачи

Ровно эти поля (схема — `skills/plan/references/plan-schema.json`), поля
`blocks` в схеме НЕТ — не добавляй:

- `id` — bare zero-padded строка `"001"`, `"002"`, … БЕЗ префикса `task-`.
- `title` — одно предложение.
- `level` — см. выше, целое число (номер фазы).
- `service` — имя сервиса из docs/architecture.md ИЛИ `"root"` для cross-cutting.
- `service_path` — relative путь к корню сервиса (`"."` для root).
- `role` — РОВНО одно из: `backend-implementer`, `frontend-implementer`,
  `test-writer`, `devops-engineer`, `integration-specialist`. Не выдумывай
  другие роли и не подглядывай в `.claude/agents/*.md` — набор фиксирован.
- `files` — ключевые artefact-файлы (HINT, не exhaustive).
- `depends_on` — массив bare id задач-предшественников.
- `estimate_tokens` — целое, ≤ 25000. Больше — разбей задачу.
- `status` — всегда `"pending"` на старте.
- `complexity_class` — см. таксономию ниже.

`.mvp/plan.json` — объект вида `{"tasks": [ {<задача>}, … ]}`;
никакого другого top-level ключа.

## complexity_class — по швам, не по объёму

| Класс | Правило |
|---|---|
| `boilerplate` | Скаффолд по канону: конфиги, init фреймворка, Dockerfile по образцу. Решений ноль. |
| `follow-pattern` | Воспроизведение паттерна. Дефолт: ни один шов ниже не сработал. |
| `novel-design` | Сработал хотя бы один шов. |

**Швы** — да/нет по brief'у, не по ощущению:

1. состояние фиксируется в один момент, а решает в другой (снимок vs живое чтение);
2. одну запись меняет больше одного сценария (кнопка и ручной ввод; API и фон);
3. внешняя строка/число становится именем поля, ключом, путём, SQL или `**kwargs`;
4. что-то открывается и обязано закрыться на каждом пути выхода;
5. статус меняется больше чем из одного места, или между выборкой и записью есть окно;
6. действие необратимо: миграция, удаление, отправка наружу;
7. поднимается процесс: entrypoint, импорт-граф, side-effect на уровне модуля.

**Объём — не признак.** Чистая функция, считающая число по формуле над валидным
входом, — `follow-pattern`, сколько бы формул в ней ни было. `novel-design` её
делает шов, а не арифметика. НЕ смотри на `files.length`/`estimate_tokens`.

## DAG

Ацикличен; `depends_on` ссылается только на `id` из этого же плана.
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
- `docs/plan.md` целиком или ссылку на него.

Дождись подтверждения. **Build стартует только явной командой оператора**, не автоматически.

**NEXT:** Use mvp:build
