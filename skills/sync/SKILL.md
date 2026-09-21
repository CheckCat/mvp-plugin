---
name: sync
description: Use when the plugin was updated to rebuild derived project artifacts and report changed requirements
---

# mvp:sync

**Announce at start:** «Using mvp:sync to realign project artifacts with the current plugin».

**Iron Law: чинится только производное; нормативка докладывается, но никогда не применяется автоматически.**

Скилл терминальный: **NEXT отсутствует**.

## Шаг 1 — проверка

```
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh check
```

`ok:true` → скажи «проект соответствует плагину», останови скилл.

## Шаг 2 — нет отметки (`lock_present:false`)

Stop&Ask: роли `.claude/agents/*.md`, стек — `## Stack` (`docs/product/technical-solutions.md`); жди подтверждения.

**Не угадывай.** Стек не хранится машинно-читаемо; угадывание по описанию неточно — ошибка молча даёт не того агента.

Нельзя печатать lock без пересборки — залочит расхождение как норму.

## Шаг 3 — пересборка

Роли: нет lock → все с Шага 2 (`derived_*` пусты); иначе — `derived_stale`/`derived_tampered`/`derived_missing`/`derived_unstamped`.

На каждую:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/assemble-agent.sh <role> [stack]
```

`stack` — из `data.derived_*[].stack` или Шага 2; пустой не передавай, lock обновится сам.

`derived_missing`/`derived_unstamped` без `stack` (поля нет) — спроси оператора, как на Шаге 2.

Затем:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/verify-agents-drift.sh
```

`ok:false` — НЕ правь `.claude/agents/*.md` руками, чини `assemble-agent.sh`.

## Шаг 4 — нормативка

Покажи `normative_changed`/`normative_added`/`normative_removed`. `plugin.git_sha` в `.mvp/plugin-lock.json` непуст, плагин — чекаут:

```
git -C ${CLAUDE_PLUGIN_ROOT} diff <git_sha>..HEAD -- <пути>
```

Нет коммита (переустановка, force-push) — пути без ошибки.

## Шаг 5 — Stop&Ask по нормативке

Правки проекту нужны? Спроси; да — задача плана, не sync:

```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs add-task --json '{...}'
```

## Шаг 6 — после подтверждения оператора

```
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh seal
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh sync <msg-file>
```

`<msg-file>` первой строкой: `chore: sync project artifacts with plugin`.

Таблица рационализаций — [references/sync-handbook.md](references/sync-handbook.md) (**Load when:** тянет срезать угол).

## HARD-GATE

Покажи: пересобрано, `verify-agents-drift.sh`, нормативные изменения, sha коммита.

Пересобран хоть один агент — скажи оператору **дословно**:

> Агенты зарегистрируются только в НОВОЙ сессии. Перед `mvp:build` перезапусти сессию, иначе задачи пойдут на `general-purpose` без контракта `_common.md`.

Скажи: «sync complete».
