---
name: brief
description: Use when starting the MVP pipeline on a fresh project from raw idea/description files (any format) that need packaging into docs/product/
---

# mvp:brief

**Announce at start:** «Using mvp:brief to package the project brief».

**Iron Law: Стек не выбирается за оператора.** Ни при каких сигналах — явных упоминаниях, инфраструктурных подсказках, «очевидности» из контекста — модель не проставляет `backend`/`frontend`/`deploy`/`db` в `## Stack` сама. Решает оператор, всегда через Stop&Ask.

Каждый результат скрипта — последняя строка stdout, JSON `{"ok","reason","hint","data"}`. При `ok:false` — два исхода: почини по `hint` и повтори, либо Stop&Ask. `state.json` руками не редактируется — только через `state.sh`.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh brief
```

`ok:false` с `data.recovery == "archive-only"` — docs/product/ уже валиден, но исходники не заархивированы (крэш между swap и archive). Пропусти шаги 3–4 и swap (5.1) — они уже сделаны. Выполни discover (шаг 2), чтобы найти неархивированный SOURCE, затем archive (5.2) над ним, затем продолжи с шага 6.

Любой другой `ok:false` — Stop&Ask с `reason`/`hint` как есть; mvp:brief работает только на пустом/свежем проекте.

## Шаг 2 — discover

```
${CLAUDE_PLUGIN_ROOT}/skills/brief/scripts/package-brief.sh discover
```

Разбери `data.candidates`:
- **0** — Stop&Ask: попроси создать `project_prompt_files/` с описанием продукта и стека, повторить discover.
- **1** — используй как SOURCE, без вопросов.
- **>1** — Stop&Ask через `AskUserQuestion`, options = пути из `data.candidates`.

## Шаг 3 — упаковка (единственное творческое место)

1. `skeleton <tmpdir>` — создаёт `<tmpdir>` с 4 каноническими файлами и всеми обязательными заголовками (`lib/brief-contract.sh`) пустыми.
2. Прочитай все файлы SOURCE, разложи факты по секциям через `Edit`: `business-logic.md` (Goal, Roles, Core scenarios, MVP scope, Success criteria), `technical-solutions.md` (Stack — формат `- backend: <v>` бюллетами, Services, Auth, Deploy). `glossary.md`/`analysis-grey-zones.md` — только если в источниках есть термины / явные «решили X, а не Y».
3. **Не выдумывай факты.** Нет данных под секцией — секция остаётся пустой (заголовок без контента — норма, закрывает её mvp:clarify). Не дублируй контент между файлами.

## Шаг 4 — Stop&Ask по стеку

Проверь `## Stack` в `<tmpdir>/technical-solutions.md`. Stop&Ask (`AskUserQuestion`, options из allowlist `backend∈{nestjs,fastapi}` / `frontend∈{nextjs,react,none}` / `deploy∈{docker-dokploy}` / `db⊇{postgresql}`) обязателен при ЛЮБОМ из:

1. **Не указан** — источники вообще не называют технологию.
2. **Не в allowlist** — названо что-то вне списка (`spring-boot`, `vue`, ...).
3. **Противоречив** — источники называют разные значения в разных местах.
4. **Неоднозначен** — источники дают альтернативу («NestJS или FastAPI», «Next.js / Remix») без выбора, ИЛИ «очевиден» только из косвенных сигналов (упоминания библиотек, инфраструктурные подсказки). Такие сигналы — не более чем рекомендация в `description` опции; выбор всегда за оператором.

После ответа — ЗАМЕНИ весь контент секции `## Stack` целиком на подтверждённые оператором значения, не дописывай под старыми строками: `_extract_stack_value` берёт первое совпадение по ключу, и не удалённая строка `- backend: ...` до Stop&Ask молча победит новую — это нарушит Iron Law. Затем перезапусти `skeleton <tmpdir>` (идемпотентен для остальных секций, но `## Layout` теперь досчитает из финального Stack).

## Шаг 5 — swap + archive

5.1.
```
${CLAUDE_PLUGIN_ROOT}/skills/brief/scripts/package-brief.sh swap <tmpdir>
```
Если в проекте уже был `docs/product/` — Stop&Ask ДО этого вызова: «docs/product/ уже существует, пересоздать?» (да → продолжай, старое уйдёт в `docs/product.bak.<ts>/` атомарно; нет → exit, ничего не трогай).

5.2.
```
${CLAUDE_PLUGIN_ROOT}/skills/brief/scripts/package-brief.sh archive <src>...
```
`<src>` — тот же SOURCE, что в шаге 2. `ok:false` с `data.conflicts` — Stop&Ask через `AskUserQuestion`: перезаписать / переименовать (переименуй конфликты в SOURCE, повтори archive) / прервать.

## Шаг 6 — git

Нет репозитория (`git rev-parse --git-dir` падает) — Stop&Ask: «git init?» (да → `git init`, проверь `user.name`/`user.email`, пустые — попроси настроить и остановись; нет → SKIP, шаг 8 не коммитит, оператор сделает это сам).

## Шаг 7 — state

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh init
${CLAUDE_PLUGIN_ROOT}/lib/state.sh set phase brief-done
```
`init` обязательно ПЕРЕД `set` (идемпотентен, безопасно вызывать всегда). `.mvp/` создаётся только здесь — раньше гейт из шага 1 упал бы, если бы она уже существовала.

## Шаг 8 — finalize

Если git пропущен (SKIP на шаге 6) — пропусти и этот шаг, скажи оператору закоммитить руками.
Иначе:
```
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh brief <msg-file>
```
`<msg-file>` первой строкой содержит `chore: package project brief`. Коммитит только `docs/product` + `docs/product/_raw` — `state.json` в коммит не входит (закоммитит mvp:clarify).

## Recreate существующего brief

Только через Stop&Ask (см. шаг 5.1) — никогда молча. Пересоздание всегда atomic через `swap` (старое → `.bak.<ts>`), никогда `rm -rf` вручную.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Стек очевиден из упоминаний библиотек — выберу сам» | v1 требовал Stop&Ask даже здесь: выбор за тебя ломал доверие к пайплайну |
| «Посчитаю сервисы прямо в чате» | awk-однострочник в v1 всегда возвращал мусор — считает только package-brief.sh |

## HARD-GATE

Прежде чем объявить шаг завершённым, покажи оператору:
- что куда легло (пути к 4 файлам `docs/product/`, что заполнено / оставлено пустым);
- распознанный стек (`backend`/`frontend`/`deploy`/`db`, из шага 4).

Дождись подтверждения. Затем:

**NEXT:** Use mvp:clarify

Никаких других переходов отсюда — не bootstrap, не plan, не build.
