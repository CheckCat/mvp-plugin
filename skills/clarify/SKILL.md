---
name: clarify
description: Use after mvp:brief to audit project_brief/ for gaps, contradictions and grey zones before bootstrap
---

# mvp:clarify

**Announce at start:** «Using mvp:clarify to audit the project brief».

**Iron Law: Не выдумывай факты и не выдумывай дыры; каждая находка обязана иметь evidence-цитату из brief'а.** `evidence[]` — либо буквальная цитата из `project_brief/*.md`, либо явное «секция X пуста» (тоже сигнал, не выдумка).

Каждый результат скрипта — последняя строка stdout, JSON `{"ok","reason","hint","data"}`. При `ok:false` — два исхода: почини по `hint` и повтори, либо Stop&Ask. `state.json` руками не редактируется — только через `state.sh`.

**Разделение труда:** формулировка находок (Pass 1) и refute (Pass 2) — это суждение, ты пишешь `clarify_queue.jsonl` сам через Edit/Write. Но всякий **подсчёт и верификация** (сколько critical, что не applied, инвариант `options[0]===recommended`) — это `scripts/queue-check.sh`, никогда не прикидка в prose. Не пиши в чате «нашёл 5 critical» без вызова скрипта — оператор должен видеть цифры из `data.counts`, не из твоего пересчёта.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh clarify
```

`ok:false` — Stop&Ask с `reason`/`hint` как есть.

## Шаг 2 — resume-check

```bash
test -f project_brief/clarify_queue.jsonl
```

Очередь уже существует → **резюмируй**: пропусти Шаги 3–4 (аудит и refute уже сделаны и лежат в файле), иди сразу в Шаг 5 с текущими `pending`-записями. **Никакого `--force`/`--restart`** — v2 не поддерживает пересоздание очереди с нуля; если оператор реально хочет начать заново, это ручной `rm` + явное подтверждение через Stop&Ask, не флаг скилла.

Очереди нет → `RESUME=0`, иди в Шаг 3.

## Шаг 3 — аудит brief'а (Pass 1: formulate)

Прочитай `business_logic.md`, `technical_solutions.md`, `glossary.md`/`analysis_grey_zones.md` (если есть). Ищи противоречия, пустые обязательные секции, дыры в бизнес-логике/стеке — три класса находок, как в v1 (inconsistency / business / stack). Для каждой: `2 ≤ len(options) ≤ 4`, `severity` по критерию из `references/refute-prompt.md` (раздел Severity-классификация). Запиши в `project_brief/clarify_queue.jsonl` (схема — `references/queue-schema.md`, load lazily). Все записи на этом шаге: `recommended_v1`/`rationale_v1` заполнены, `recommended`/`self_critique` — ещё пустые, `status: pending`.

Ноль находок — валидный исход. Не выдумывай дыры в полном brief'е.

## Шаг 4 — self-critique (Pass 2: refute)

Load `references/refute-prompt.md` и прогони каждую находку через обязательную форму промпта оттуда — **отдельным** проходом рассуждения, не продолжением Шага 3.

- **critical + medium — всегда.**
- **low — только если позже выбран режим `hard`** (Шаг 5). До выбора режима ты не знаешь, будет ли `hard` — поэтому refute low-находок делай последним, после Шага 5, только если оператор выбрал `hard`. Не трать токены на refute low заранее (см. Red flags).
- После refute — `recommended`/`rationale`/`self_critique` заполнены; если `verdict: changed`, переставь новый `recommended` в `options[0]` (инвариант, см. `references/queue-schema.md`).
- Sanity: посчитай `changed_rate` по critical-находкам. `changed_rate == 0` на ≥5 critical → предупреди оператора в сводке Шага 5, что Pass 2, возможно, деградировал в перефраз Pass 1. Не блокер — просто предупреждение.

## Шаг 5 — сводка и выбор режима

Покажи оператору находки по severity/категории (цифры — из твоего подсчёта на этом шаге, `queue-check.sh` ещё рано звать — очередь не дописана). Затем **Stop&Ask** через `AskUserQuestion` — режим = кто отвечает:

| mode | кто отвечает |
|---|---|
| `auto` | никто — все → `answered_auto` с `recommended`. |
| `light` | оператор отвечает на `critical`. |
| `medium` | оператор отвечает на `critical` + `medium`. |
| `hard` | оператор отвечает на всё, включая `low` — сначала прогони refute для low-находок (Шаг 4, отложенная ветка). |

## Шаг 6 — вопросы оператору (HARD-GATE)

Батчами (3–4 за раз) через `AskUserQuestion`, только записи уровня режима и выше (critical всегда; medium если `medium`/`hard`; low если `hard`). Остальное — `answered_auto` с `answer = options[0]`, `source: auto`.

Для отвеченных оператором: `answer = полный label из options[]`, `status: answered_human`, `source: human`. Не объединяй уточнение с `answer` — отдельное поле `operator_note`, если оно понадобится в схеме твоего конкретного проекта.

Это HARD-GATE — не пропускай батч без реального ответа оператора (или явного auto-режима).

## Шаг 7 — применение ответов к brief'у

Для каждой `answered_human`/`answered_auto` записи — Edit точечно в нужную секцию `project_brief/*.md` (переопределяет факт → перепиши секцию целиком; уточняет → append с `<!-- clarify <date>: <Q-id> -->` маркером). После записи в brief — переведи статус записи в очереди в `applied`. Делай это для КАЖДОЙ записи сразу после её применения, не пачкой в конце — крэш посередине не должен молча терять факт «ответ применён, но статус не обновлён» (см. Red flags).

## Шаг 8 — queue-check

```
${CLAUDE_PLUGIN_ROOT}/skills/clarify/scripts/queue-check.sh
```

`ok:false` (unapplied непуст, либо инвариант `options[0]!==recommended` нарушен) → почини записи по `data`, **не коммить**, повтори. Это единственный источник цифр `pending_critical`/`pending_total`/`auto_closed_critical` — он же пишет их в `state.json`.

## Шаг 9 — state: phase

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh set phase clarify-done
```

Только после `queue-check.sh` ok:true — `pending_critical`/`pending_total`/`auto_closed_critical` уже записаны им на Шаге 8.

## Шаг 10 — finalize

```
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh clarify <msg-file>
```

`<msg-file>` первой строкой: `chore: clarify brief`. Коммитит `project_brief` + `.claude/state/state.json`.

## Rationalization table (red flags)

| Соблазн | Почему нет |
|---|---|
| «Помечу applied заранее, всё равно сейчас применю» | crash между answered и applied в v1 молча терял решения |
| «Low-находки тоже прогоню через refute» | в v1 это жгло десятки тысяч токенов на вопросы, не влияющие на код |

## HARD-GATE

Шаг 6 — очередь вопросов оператору по режиму — обязателен для всех severity уровня режима и выше; молчаливый auto-close без Stop&Ask допустим только для `mode=auto` или для severity ниже выбранного уровня.

Прежде чем объявить шаг завершённым, покажи оператору: цифры из `queue-check.sh` (`data.counts`), достигнутый режим, что закрыто/осталось pending.

**NEXT:** Use mvp:bootstrap
