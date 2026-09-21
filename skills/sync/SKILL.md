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

**Не угадывай.** Агент не помнит шаблона, фронтматтер не различает стек — неверный стек соберёт не того агента незаметно.

Нельзя печатать lock без пересборки — залочит расхождение как норму.

## Шаг 3 — пересборка

На каждую роль из `data.derived_stale`, `derived_tampered`, `derived_missing`:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/assemble-agent.sh <role> [stack]
```

`stack` — из находки (`data.derived_*[].stack`); пустой не передавай, lock обновится сам.

`derived_missing` без `stack` (поля нет) — спроси оператора, как на Шаге 2.

Затем:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/verify-agents-drift.sh
```

`ok:false` — НЕ правь `.claude/agents/*.md` руками, чини `assemble-agent.sh`.

## Шаг 4 — нормативка

Покажи `normative_changed`/`normative_added`/`normative_removed`. `plugin.git_sha` непуст и плагин — чекаут:

```
git -C ${CLAUDE_PLUGIN_ROOT} diff <git_sha>..HEAD -- <пути>
```

Нет коммита (переустановка, force-push) — только пути, не ошибка.

## Шаг 5 — Stop&Ask по нормативке

Правки проекту нужны? Спроси оператора; да — задача плана, не sync:

```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs add-task --json '{...}'
```

## Шаг 6 — после подтверждения оператора

```
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh seal
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh sync <msg-file>
```

`<msg-file>` первой строкой: `chore: sync project artifacts with plugin`.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Изменилось несильно, запечатаю без чтения» | `seal`=«принял»; слепая догонялка плагина |
| «Подправлю `.claude/agents/*.md` руками» | `check`=`tampered`; правь шаблон, потом пересборка |
| «Стек не записан, но я его помню» | Шаг 2 — Stop&Ask; неверный стек — не тот агент незаметно |
| «Заодно перегенерирую `ci-mirror.sh`» | маппинг 5 строк от инцидентов, регенерация уничтожит |

## HARD-GATE

Покажи: что пересобрано, `verify-agents-drift.sh`, нормативные изменения, sha коммита.

Пересобран хоть один агент — скажи оператору **дословно**:

> Агенты зарегистрируются только в НОВОЙ сессии. Перед `mvp:build` перезапусти сессию, иначе задачи пойдут на `general-purpose` без контракта `_common.md`.

Скажи: «sync complete».
