---
name: bootstrap
description: Use after mvp:clarify to generate project meta-files, agents and state from a validated brief
---

# mvp:bootstrap

**Announce at start:** «Using mvp:bootstrap to generate project meta-files, agents and state».

**Iron Law: Уроки прогонов попадают в invariants.md проекта, не в плагин.** v1 позволил специфике проекта прорасти в глобальные `~/.claude/agents/templates/` — следующий проект унаследовал чужие допущения молча. Канал для проектных инвариантов — `.mvp/invariants.md`, коммитится вместе с bootstrap. Шаблоны в `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/templates/` — stack-специфичные, не project-специфичные: тянет дописать конкретику проекта — это Stop&Ask, не шаблон.

Каждый результат скрипта — последняя строка stdout, JSON `{"ok","reason","hint","data"}`. При `ok:false` — почини по `hint` и повтори, либо Stop&Ask. `state.json` руками не редактируется — только через `state.sh`.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh bootstrap
```

`ok:false` с `reason` про `pending_critical` — Stop&Ask: «N critical находок mvp:clarify не закрыты — вернись в mvp:clarify (mode ≥ light), либо подтверди override через auto-режим clarify». gate.sh не принимает override-флаг — снять блокировку можно только через `pending_critical == 0` в mvp:clarify.

Любой другой `ok:false` — Stop&Ask с `reason`/`hint` как есть.

`ok:true` → проверь, не было ли скрытых допущений:
```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh get auto_closed_critical
```
Если `data.value > 0` — покажи оператору: «N critical auto-closed в mvp:clarify без ревью» (не блокер — см. `docs/product/clarify-queue.jsonl`). Продолжай.

## Шаг 2 — state skeleton

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh init
mkdir -p .mvp/briefs .mvp/reports .mvp/review .mvp/telemetry
```
`init` идемпотентен — `.mvp/state.json` уже существует с прошлых фаз (brief/clarify), это ожидаемо, не ошибка.

## Шаг 3 — invariants.md + ci-mirror.sh

Оба файла читает `mvp:plan` и `validate-task.sh` (build); `ci-mirror.sh` — единственный источник команд линта/теста для `validate-task.sh`.

**3.1. `invariants.md`** (творческая часть — читаешь `docs/product/`, пишешь сам через `Write`). Секции обязательны:

```markdown
## Architectural invariants
<границы bounded contexts из technical-solutions.md — что нельзя импортировать напрямую>

## Service boundaries
<service_path на каждый сервис из "## Services" brief'а>

## Forbidden edges
FORBIDDEN_EDGE: <src-pattern> --> <dst-pattern>
BOUNDARY_EXEMPT: <path>
```
`FORBIDDEN_EDGE:` — строка на каждую явную границу из brief'а («integration-сервисы без прямого доступа к БД» → `FORBIDDEN_EDGE: integration-* --> DB`). Паттерны glob-ish: `*` — wildcard, `(A|B)` — regex-alternation. Не выдумывай границы, которых brief не называет: пустая секция валиднее выдуманной.

`BOUNDARY_EXEMPT:` — путь workspace-shared артефакта, который меняют задачи любого boundary (`uv.lock` в uv-workspace); точное совпадение, не glob. `validate-task.sh` не гейтит его по boundary, `finalize.sh` стейджит с задачей.

**Несколько деплой-юнитов на одном образе** (api/worker/beat) → впиши инвариант: у каждого smoke-тест импорта entrypoint'а **в отдельном процессе**. Тест-сьюта этот класс не ловит: она импортирует модули в своём порядке, юнит — один entrypoint в свежем интерпретаторе. На vireo так цикл импорта уронил worker/beat при зелёном pytest.

**3.2. `ci-mirror.sh`** — детерминированная генерация из `## Stack` brief'а. Читай `backend`/`frontend` ТЕМ ЖЕ способом, что `_extract_stack_value` в `skills/brief/scripts/package-brief.sh` (строки ~166–188: awk по `## Stack`, `- key: value`, case-insensitive key, первое совпадение побеждает) — replicate этот awk один в один для `backend` и для `frontend`, не изобретай новый формат парсинга.

Маппинг стек → команды (пишутся в `.mvp/ci-mirror.sh`, по одной команде на строку). Каждая команда guarded своим предусловием: на пустом дереве зеркало обязано выходить 0 — это исполняемый гейт check-meta (Шаг 6 реально запускает `ci-mirror.sh`, не только `bash -n`). **`set -e` первой строкой**: иначе код возврата — от последней команды, и падение линта маскируется у всех, кто зовёт файл не через `bash -e`.

`backend=fastapi`:
```
set -e
if [ -f pyproject.toml ]; then uv sync --frozen --all-packages; fi
if [ -f pyproject.toml ]; then uv run ruff check .; fi
if [ -f pyproject.toml ]; then uv run ruff format --check .; fi
if [ -n "$(find services -name node_modules -prune -o -name '*.py' -type f -print -quit 2>/dev/null)" ]; then uv run mypy services; fi
if [ -f pyproject.toml ]; then uv run pytest || [ $? -eq 5 ]; fi
```
Exit 5 значит «no tests collected» — ожидаемо на greenfield-дереве, не валит ci-mirror; любой другой ненулевой код по-прежнему валит.

`backend=nestjs`:
```
set -e
if [ -f package.json ]; then pnpm install --frozen-lockfile; fi
if [ -f package.json ]; then pnpm turbo lint; fi
if [ -f package.json ]; then pnpm turbo build; fi
if [ -f package.json ]; then pnpm turbo test; fi
```

`frontend` (`react`/`nextjs`) **только когда `backend=fastapi`** — nestjs уже покрывает frontend через тот же pnpm/turbo workspace (`layout=packages`, см. `lib/brief-contract.sh:layout_for_stack`), отдельных команд не нужно; guard'ы `[ -d services/frontend ]` уже на месте:
```
if [ -d services/frontend ]; then npm --prefix services/frontend ci; fi
if [ -d services/frontend ]; then npm --prefix services/frontend run lint; fi
if [ -d services/frontend ]; then npm --prefix services/frontend run test -- --run; fi
```

`frontend=none` — не добавляй frontend-команды вообще.

## Шаг 4 — агенты

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/assemble-agent.sh <role> [stack]
```
Только роли из enum `role` в `skills/plan/references/plan-schema.json` — по ним `mvp:build` диспатчит агентов (`agentType`). Всегда: `backend-implementer <backend>`, `devops-engineer docker-dokploy.<backend>`, `test-writer <backend>`. Плюс `frontend-implementer <frontend>` при `frontend != none` и `integration-specialist`, если brief называет сервисы `integration-*`. Ролей `validator`/`code-reviewer` нет — эти шаги гоняются инлайн-шаблонами `skills/build/agents/*.md`. `TEMPLATES_DIR`/`OUT_DIR` не трогай.

Затем ОБЯЗАТЕЛЬНО:
```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/verify-agents-drift.sh
```
`ok:false` — НЕ правь `.claude/agents/*.md` руками, перезапусти `assemble-agent.sh` для найденной в `data.violations` роли. Этот скрипт byte-substring-инвариант не ослабляет ни при каких обстоятельствах (см. предупреждение в самом файле) — если инвариант мешает, значит `assemble-agent.sh` сломан, чини его, не проверку.

## Шаг 5 — CLAUDE.md + docs/architecture.md (творческая часть)

Пиши сам через `Write`, по образцу этого же файла плагина (`CLAUDE.md` репозитория — секции `## Стек`, `## Команды`, `## Правила...`). Обязательно:
- `CLAUDE.md` ≤ 150 строк, содержит `## Стек`, `## Команды` (= содержимое `ci-mirror.sh` человеко-читаемо), `## Правила` (project-specific, не общие банальности).
- `docs/architecture.md` — mermaid-диаграмма сервисов из brief'а; рёбра НЕ должны совпадать ни с одним `FORBIDDEN_EDGE:` из `.mvp/invariants.md`, который ты сам написал на Шаге 3 — сверься перед записью, не полагайся только на Шаг 6.

## Шаг 6 — check-meta (max 2 попытки)

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/check-meta.sh
```
Три гейта: `CLAUDE.md` (есть, ≤150 строк, обязательные секции), `docs/architecture.md` (есть, ни одно ребро не нарушает `FORBIDDEN_EDGE`), `.mvp/ci-mirror.sh` (есть, непустой, проходит `bash -n` И реально выполняется — `bash -e`, exit 0 на текущем дереве). `ok:false` → почини файл по `data.violations`, повтори. Нарушение `ci-mirror-*` — возврат к Шагу 3.2, а не к правке `CLAUDE.md`: этот файл дальше гоняет `validate-task.sh` на каждой задаче build'а. После 2 неудачных попыток подряд — Stop&Ask, не третья попытка молча.

## Шаг 7 — phase + finalize

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh set phase bootstrap-done
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh bootstrap <msg-file>
```
`<msg-file>` первой строкой: `chore: bootstrap project meta`. Коммитит `CLAUDE.md docs/architecture.md .claude/agents .mvp` (пресет scope `bootstrap` в `finalize.sh`).

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Допишу совет конкретного проекта прямо в шаблон, он же полезный» | это ровно то, что сломало v1 — совет живёт в `.mvp/invariants.md` этого проекта, не в `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/templates/` |
| «pending_critical>0, но я уверен что не критично — пропущу гейт» | gate.sh не принимает override; единственный легитимный путь — вернуться в mvp:clarify |
| «invariants.md пустой, допишу пару FORBIDDEN_EDGE на всякий случай» | не выдуманные границы — только те, что brief называет явно; пустая секция закрывает clarify, не bootstrap |

## HARD-GATE

Прежде чем объявить шаг завершённым, покажи оператору:
- содержимое `CLAUDE.md` и `docs/architecture.md` целиком;
- список собранных агентов (`.claude/agents/*.md`) и `verify-agents-drift.sh` результат;
- `.mvp/invariants.md` — особенно секцию `Forbidden edges`.

Дождись подтверждения. Затем:

**NEXT:** Use mvp:plan
