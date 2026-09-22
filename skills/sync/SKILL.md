---
name: sync
description: Use when the plugin was updated to rebuild derived project artifacts and report changed requirements
---

# mvp:sync

**Announce at start:** «Using mvp:sync to realign project artifacts».

**Iron Law: чинится только производное; нормативка докладывается, но никогда не применяется автоматически.**

Скилл терминальный: **NEXT отсутствует**.

## Шаг 1 — проверка + роли механики

```
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh check
```

`data.lock_broken:true` → [справочник](references/sync-handbook.md) (**Load when:** lock не парсится).

Затем безусловно, при любом исходе check: `assemble-agent.sh mvp-reviewer`, `mvp-validator`, `mvp-relay` — скрипт с Шага 3.

check `ok:true` → роли изменились (`git status`)? → Шаг 6: собранное коммитится, иначе следующий `next` — halt dirty-tree; плюс фраза HARD-GATE. Затем скажи «проект соответствует плагину», стоп.

## Шаг 2 — нет отметки (`lock_present:false`)

Stop&Ask: роли `.claude/agents/*.md`, стек — `## Stack` (`docs/product/technical-solutions.md`).

**Не угадывай:** стек не хранится машинно-читаемо, ошибка даёт не того агента.

Нельзя печатать lock без пересборки — залочит расхождение.

## Шаг 3 — пересборка

Роли: нет lock → все с Шага 2 (`derived_*` пусты); иначе — все `derived_*`-находки, из `derived_unstamped` — только роли с шаблоном (справочник: посторонний агент).

На каждую:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/assemble-agent.sh <role> [stack]
```

`stack` — из находки или Шага 2; пустой не передавай, lock обновится сам.

Находка без `stack` — спроси, как на Шаге 2.

У роли есть `<role>-capped.md` → обнови: `assemble-agent.sh --capped <role>` (справочник «Capped-копии»).

Затем:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/verify-agents-drift.sh
```

`ok:false` — НЕ правь агентов руками, чини `assemble-agent.sh`.

## Шаг 4 — нормативка

Покажи `normative_changed`/`_added`/`_removed`. `plugin.git_sha` в lock непуст, плагин — чекаут:

```
git -C ${CLAUDE_PLUGIN_ROOT} diff <git_sha>..HEAD -- <пути>
```

Нет коммита (переустановка) — пути без ошибки.

## Шаг 5 — Stop&Ask по нормативке

Правки проекту нужны? Спроси; да — задача плана, не sync:

```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs add-task --json '{...}'
```

## Шаг 6 — после подтверждения

```
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh seal
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh sync <msg-file>
```

Заводил задачу на Шаге 5 → `... --files .mvp/plan.json`.

`<msg-file>` первой строкой: `chore: sync project artifacts with plugin`.

Таблица рационализаций — [справочник](references/sync-handbook.md) (**Load when:** тянет срезать угол).

## HARD-GATE

Покажи: пересобрано, дрейф-чек, нормативные изменения, sha коммита.

Пересобран хоть один агент — скажи оператору **дословно**:

> Агенты зарегистрируются только в НОВОЙ сессии. Перед `mvp:build` перезапусти сессию, иначе задачи пойдут на `general-purpose` без контракта `_common.md`.

Скажи: «sync complete».
