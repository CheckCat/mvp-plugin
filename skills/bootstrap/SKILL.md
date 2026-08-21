---
name: bootstrap
description: Use after mvp:clarify to generate project meta-files, agents and state from a validated brief
---

# mvp:bootstrap

**Announce at start:** «Using mvp:bootstrap to generate project meta-files, agents and state».

**Iron Law: Уроки прогонов попадают в invariants.md проекта, не в плагин.** v1 позволил специфике одного конкретного проекта прорасти в глобальные `~/.claude/agents/templates/` — следующий проект наследовал чужие допущения молча. В v2 канал для проектных инвариантов — `.claude/state/invariants.md`, файл проекта, коммитится вместе с остальным bootstrap. Шаблоны в `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/templates/` остаются stack-специфичными, не project-специфичными: если тянет дописать туда что-то про конкретный проект — это невыполненный Stop&Ask, не шаблон.

Каждый результат скрипта — последняя строка stdout, JSON `{"ok","reason","hint","data"}`. При `ok:false` — почини по `hint` и повтори, либо Stop&Ask. `state.json` руками не редактируется — только через `state.sh`.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh bootstrap
```

`ok:false` с `reason` про `pending_critical` — Stop&Ask: «N critical находок mvp:clarify ещё не закрыты — вернись в mvp:clarify (mode ≥ light), либо явно подтверди override через auto-режим clarify». Никакого скрытого обхода — gate.sh не принимает override-флаг, единственный путь снять блокировку — сделать `pending_critical == 0` через сам mvp:clarify.

Любой другой `ok:false` — Stop&Ask с `reason`/`hint` как есть.

`ok:true` → проверь, не было ли скрытых допущений:
```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh get auto_closed_critical
```
Если `data.value > 0` — покажи оператору: «N critical находок были auto-closed в mvp:clarify без ручного ревью» (не блокер, просто прозрачность — см. `project_brief/clarify_queue.jsonl` для деталей). Продолжай.

## Шаг 2 — state skeleton

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh init
mkdir -p .claude/state/briefs .claude/state/reports .claude/state/review .claude/state/telemetry
```
`init` идемпотентен — `.claude/state/state.json` уже существует с прошлых фаз (brief/clarify), это ожидаемо, не ошибка.

## Шаг 3 — invariants.md + ci-mirror.sh

Оба файла читает `mvp:plan` и `validate-task.sh` (build); `ci-mirror.sh` — единственный источник команд линта/теста для `validate-task.sh`.

**3.1. `invariants.md`** (творческая часть — читаешь `project_brief/`, пишешь сам через `Write`). Секции обязательны:

```markdown
## Architectural invariants
<границы bounded contexts из technical_solutions.md — что нельзя импортировать напрямую>

## Service boundaries
<service_path на каждый сервис из "## Services" brief'а>

## Forbidden edges
FORBIDDEN_EDGE: <src-pattern> --> <dst-pattern>
```
`FORBIDDEN_EDGE:` — по одной строке на явную архитектурную границу из brief'а (например «integration-сервисы stateless, без прямого доступа к БД» → `FORBIDDEN_EDGE: integration-* --> DB`). Паттерны glob-ish: `*` — wildcard, `(A|B)` проходит как regex-alternation. Не выдумывай границы, которых brief не называет — пустая секция (без строк `FORBIDDEN_EDGE:`) валиднее выдуманной.

**3.2. `ci-mirror.sh`** — детерминированная генерация из `## Stack` brief'а. Читай `backend`/`frontend` ТЕМ ЖЕ способом, что `_extract_stack_value` в `skills/brief/scripts/package-brief.sh` (строки ~166–188: awk по `## Stack`, `- key: value`, case-insensitive key, первое совпадение побеждает) — replicate этот awk один в один для `backend` и для `frontend`, не изобретай новый формат парсинга.

Маппинг стек → команды (пишутся в `.claude/state/ci-mirror.sh`, по одной команде на строку — `validate-task.sh` гоняет их через `bash -e`, первая ошибка обрывает остальные). Каждая команда guarded своим предусловием: на пустом дереве зеркало обязано выходить 0 — это исполняемый гейт check-meta (Шаг 6 реально запускает `ci-mirror.sh`, не только `bash -n`).

`backend=fastapi`:
```
if [ -f pyproject.toml ]; then uv sync --frozen; fi
if [ -f pyproject.toml ]; then uv run ruff check .; fi
if [ -f pyproject.toml ]; then uv run ruff format --check .; fi
if [ -n "$(find services -name node_modules -prune -o -name '*.py' -type f -print -quit 2>/dev/null)" ]; then uv run mypy services; fi
if [ -f pyproject.toml ]; then uv run pytest || [ $? -eq 5 ]; fi
```
Exit 5 значит «no tests collected» — ожидаемо на greenfield-дереве, не валит ci-mirror; любой другой ненулевой код по-прежнему валит.

`backend=nestjs`:
```
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
Собираются ТОЛЬКО роли из enum `role` в `skills/plan/references/plan-schema.json` — по ним `mvp:build` диспатчит агентов (`agentType`). Вызови: `backend-implementer <backend>`, `devops-engineer docker-dokploy.<backend>`, `test-writer <backend>` — всегда; `frontend-implementer <frontend>` — если `frontend != none`; `integration-specialist` — если brief явно описывает интеграции со сторонним API (сервисы `integration-*` в "## Services"). Ролей `validator`/`code-reviewer` в проекте нет: эти шаги v2 гоняет инлайн-шаблонами (`skills/build/agents/*.md`) на дефолтном агенте — собирать их не надо и не из чего. `TEMPLATES_DIR`/`OUT_DIR` не трогай — дефолты уже указывают на `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/templates` и `.claude/agents`.

Затем ОБЯЗАТЕЛЬНО:
```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/verify-agents-drift.sh
```
`ok:false` — НЕ правь `.claude/agents/*.md` руками, перезапусти `assemble-agent.sh` для найденной в `data.violations` роли. Этот скрипт byte-substring-инвариант не ослабляет ни при каких обстоятельствах (см. предупреждение в самом файле) — если инвариант мешает, значит `assemble-agent.sh` сломан, чини его, не проверку.

## Шаг 5 — CLAUDE.md + ARCHITECTURE.md (творческая часть)

Пиши сам через `Write`, по образцу этого же файла плагина (`CLAUDE.md` репозитория — секции `## Стек`, `## Команды`, `## Правила...`). Обязательно:
- `CLAUDE.md` ≤ 150 строк, содержит `## Стек`, `## Команды` (= содержимое `ci-mirror.sh` человеко-читаемо), `## Правила` (project-specific, не общие банальности).
- `ARCHITECTURE.md` — mermaid-диаграмма сервисов из brief'а; рёбра НЕ должны совпадать ни с одним `FORBIDDEN_EDGE:` из `.claude/state/invariants.md`, который ты сам написал на Шаге 3 — сверься перед записью, не полагайся только на Шаг 6.

## Шаг 6 — check-meta (max 2 попытки)

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/check-meta.sh
```
Три гейта: `CLAUDE.md` (есть, ≤150 строк, обязательные секции), `ARCHITECTURE.md` (есть, ни одно ребро не нарушает `FORBIDDEN_EDGE`), `.claude/state/ci-mirror.sh` (есть, непустой, проходит `bash -n` И реально выполняется — `bash -e`, exit 0 на текущем дереве). `ok:false` → почини соответствующий файл по `data.violations`, повтори. Нарушение `ci-mirror-*` — это возврат к Шагу 3.2, а не к правке `CLAUDE.md`: этот файл дальше гоняет `validate-task.sh` на каждой задаче build'а. После 2 неудачных попыток подряд — Stop&Ask, не третья попытка молча.

## Шаг 7 — phase + finalize

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh set phase bootstrap-done
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh bootstrap <msg-file>
```
`<msg-file>` первой строкой: `chore: bootstrap project meta`. Коммитит `CLAUDE.md ARCHITECTURE.md .claude/agents .claude/state` (пресет scope `bootstrap` в `finalize.sh`).

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Допишу совет конкретного проекта прямо в шаблон, он же полезный» | это ровно то, что сломало v1 — совет живёт в `.claude/state/invariants.md` этого проекта, не в `${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/templates/` |
| «pending_critical>0, но я уверен что не критично — пропущу гейт» | gate.sh не принимает override; единственный легитимный путь — вернуться в mvp:clarify |
| «invariants.md пустой, допишу пару FORBIDDEN_EDGE на всякий случай» | не выдуманные границы — только те, что brief называет явно; пустая секция закрывает clarify, не bootstrap |

## HARD-GATE

Прежде чем объявить шаг завершённым, покажи оператору:
- содержимое `CLAUDE.md` и `ARCHITECTURE.md` целиком;
- список собранных агентов (`.claude/agents/*.md`) и `verify-agents-drift.sh` результат;
- `.claude/state/invariants.md` — особенно секцию `Forbidden edges`.

Дождись подтверждения. Затем:

**NEXT:** Use mvp:plan
