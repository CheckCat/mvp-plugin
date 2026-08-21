# MVP playbook run 3 — Pattern B (batch tool calls) (2026-06-16)

Цель прогона: проверить эффект **TOKEN EFFICIENCY RULES** в implement+review prompts на длину диалога implementer'а.

## Изменения skill'а перед прогоном

| Файл | Изменение |
|---|---|
| `~/.claude/skills/execute-mvp/SKILL.md` implement prompt | Добавлены 6 правил batching (Read'ы parallel в 1 turn, Write batch, Bash chaining, suppress flags, no re-Read, цель ≤10 turns) |
| `~/.claude/skills/execute-mvp/SKILL.md` review prompt | Аналогичные 5 правил, цель ≤5 turns |
| `~/.claude/skills/execute-mvp/SKILL.md` anti-patterns | Конкретные цифры task-004 (39 turns × 1.6M cache_read = $2.40) |
| `shouldSkipReview` порог | 3 → 6 файлов (для будущих trivial scaffold-молекул) |

## Прогон

- **Команда:** `/execute-mvp only task-005`
- **Workflow:** `wf_d2f62f4d-2eb` → **failed** (session limit Anthropic ровно на subgraph next-iter)
- **Target:** task-005 (AuthModule, 3 planned файла)
- **Total tokens:** 212k (vs 3.6M на task-004 — 17× меньше!)
- **Cost:** $3.32 за весь run (vs $6.55 task-004 — 49% меньше)

## Pattern B результаты

**Implementer Opus:**

| Метрика | task-004 | task-005 | Δ |
|---|---|---|---|
| API calls | 39 | **18** | **−54%** |
| Read calls | 28 | 8 | −71% |
| Bash calls | 22 | 11 | −50% |
| Write calls | 9 | 4 | −56% |
| Edit calls | 2 | 6 | +200% (по делу — патчит существующее) |
| cache_read (M) | 1.60 | 0.59 | −63% |
| **Cost USD** | **$4.57** | **$2.51** | **−45%** |

Pattern B **работает однозначно**. Implementer стал чётче формулировать что прочитать и куда писать.

## Баги найденные в прогоне

### Баг 1: PLAN_SCHEMA не включал `service` в required

Симптом — validator зафейлил рабочий код:
```
First failure: diff_within_service_boundary
Details: Boundary provided by workflow is 'packages/undefined/**'
Suggested fix (от Sonnet validator'а): Workflow harness bug: the 'service' field was not passed
```

Root cause: load-plan agent (Haiku StructuredOutput) видя что `service` в schema только в `properties` (не в `required`) — отбросил его. Все task'и в planRaw имели `service=None`.

Fix (уже применён): `required: ['id','title','level','service','role','files','depends_on','blocks','estimate_tokens','status']` в PLAN_SCHEMA. См. commit в `~/.claude/skills/execute-mvp/SKILL.md`.

### Баг 2: Session limit Anthropic

Workflow упал в subgraph next-iter с сообщением:
> "You've hit your session limit · resets 7am (Asia/Yekaterinburg)"

Не баг кода. Внешний фактор.

### Баг 3 (продолжается): `only_task` halt

После успешного task-004 цикл уходит в task-005 несмотря на `only_task` param. В task-005 прогоне добавил early-check в начале каждой итерации, но workflow упал до того как доехал до проверки. Тестировать на task-006.

## Текущий state после прогона

```
git log:
c2c906c feat: AuthModule с глобальным ApiKeyGuard (task-005, manual commit)
b89beab chore: persist state + TODO after task-004 hybrid run
17f6a15 feat: Prisma schema (task-004 via workflow finalize)
f2233e5 chore(agents): planned_files → hint, service → hard boundary
```

plan.json: task-005 done, current_focus=task-006

## Целевая стоимость

Если экстраполировать task-005 cost ($3.32) на 16 задач: **~$53/MVP**. Skill говорил $4-25 (с учётом review).

task-006 — HealthModule (3 файла) тривиальный. **shouldSkipReview сработает** (3 ≤ 6, title содержит "api" но фильтр уберёт). Цена должна быть ниже task-005 (нет review = ~$0.5 экономия).

## Где транскрипты и cost JSON

- Workflow: `~/.claude/projects/-Users-vadim-Documents-Pet-vireo/d53dd969-e09f-4eda-b1dd-8e4d22f4286b/subagents/workflows/wf_d2f62f4d-2eb/`
- Raw cost JSON: `/Users/vadim/Documents/Pet/vireo/.claude/task-005-cost-analysis.json`
- Token counting metodology: [[feedback-token-counting-jsonl]] (memory)
