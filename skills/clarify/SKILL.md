---
name: clarify
description: Use after mvp:brief to audit docs/product/ for gaps, contradictions and grey zones before bootstrap
---

# mvp:clarify

**Announce at start:** «Using mvp:clarify to audit the project brief».

**Iron Law: Не выдумывай факты и не выдумывай дыры; каждая находка обязана иметь evidence-цитату из brief'а.** `evidence[]` — либо буквальная цитата из `docs/product/*.md`, либо явное «секция X пуста» (тоже сигнал, не выдумка).

Каждый результат скрипта — последняя строка stdout, JSON `{"ok","reason","hint","data"}`. При `ok:false` — два исхода: почини по `hint` и повтори, либо Stop&Ask. `state.json` руками не редактируется — только через `state.sh`.

**Разделение труда:** находки (Pass 1) и refute (Pass 2) — суждение, ты пишешь `clarify-queue.jsonl` сам через Edit/Write. Всякий **подсчёт и верификация** (сколько critical, что не applied, инвариант) — только `scripts/queue-check.sh`, никогда прикидка в prose. Оператор видит цифры из `data.counts`, не твой пересчёт в чате.

## Шаг 1 — гейт

```
${CLAUDE_PLUGIN_ROOT}/lib/gate.sh clarify
```

`ok:false` — Stop&Ask с `reason`/`hint`.

## Шаг 2 — resume-check

```bash
test -f docs/product/clarify-queue.jsonl
```

Очередь уже существует → **резюмируй**: пропусти Шаги 3–4 (аудит и refute уже сделаны), иди сразу в Шаг 5. **Никакого `--force`/`--restart`** — v2 не пересоздаёт очередь с нуля флагом; хочет заново — ручной `rm` + Stop&Ask подтверждение.

Очереди нет → `RESUME=0`, иди в Шаг 3.

## Шаг 3 — аудит brief'а (Pass 1: formulate)

Прочитай `business-logic.md`, `technical-solutions.md`, `glossary.md`/`analysis-grey-zones.md` (если есть). Ищи противоречия, пустые обязательные секции, дыры в бизнес-логике/стеке — три класса находок, как в v1 (inconsistency / business / stack). Для каждой: `2 ≤ len(options) ≤ 4`, `severity` по критерию из `references/refute-prompt.md` (Severity-классификация). Запиши в `docs/product/clarify-queue.jsonl` (схема — `references/queue-schema.md`, load lazily) сразу в форме, где инвариант держится: `options[0] = recommended_v1`, `recommended = recommended_v1`, `rationale = rationale_v1`, `status: pending`. **Ни одна запись не покидает этот шаг с `recommended: null`** — Шаг 4 перезаписывает эти поля результатом refute, но не обязан заполнять их впервые.

Ноль находок — валидный исход. Не выдумывай дыры в полном brief'е.

## Шаг 4 — self-critique (Pass 2: refute)

Load `references/refute-prompt.md` и прогони каждую находку через обязательную форму промпта оттуда — **отдельным** проходом рассуждения, не продолжением Шага 3.

- **critical + medium — всегда refute здесь.** Перезапиши `recommended`/`rationale`/`self_critique` реальным вердиктом (`confirmed`/`changed`); при `changed` — переставь новый `recommended` в `options[0]`.
- **low — refute только если позже выбран режим `hard`** (Шаг 5; режим тут ещё не известен). Пока выставь `self_critique: {"verdict":"skipped","reason":"low severity, mode != hard"}` — `recommended`/`rationale` не трогай, они уже `*_v1` из Шага 3. Выбрали `hard` на Шаге 5 → вернись и прогони настоящий refute по low, перезаписав эту метку (и `options[0]` при `changed`). Не жги токены на low заранее (см. Red flags).
- Sanity: `changed_rate` по critical. `== 0` на ≥5 critical → предупреди оператора в сводке Шага 5 — Pass 2, возможно, деградировал в перефраз Pass 1. Не блокер.

К концу Шага 4 (и отложенного low-refute при `hard`) у КАЖДОЙ записи `options[0] === recommended` держится по построению — это проверит `queue-check.sh` на Шагах 5 и 8.

## Шаг 5 — сводка и выбор режима

Очередь уже полная и согласованная (инвариант — см. Шаг 3/4). Вызови:

```
${CLAUDE_PLUGIN_ROOT}/skills/clarify/scripts/queue-check.sh
```

Ожидай `ok:true` (никто ещё не `answered_*`, либо resume — прошлая сессия уже закрыла всё до коммита; `unapplied` в обоих случаях пуст). Покажи оператору `data.counts` как есть — **не пересчитывай в prose**. `critical`/`medium`/`low` — сколько найдено всего; `pending_*` — сколько реально осталось сейчас (корректно и на resume, где часть уже отвечена раньше).

Затем **Stop&Ask** через `AskUserQuestion` — режим = кто отвечает, числа из `pending_*`:

| mode | кто отвечает |
|---|---|
| `auto` | никто — все → `answered_auto` с `recommended`. |
| `light` | `critical` (`pending_critical` шт.). |
| `medium` | `critical`+`medium` (`pending_critical`+`pending_medium` шт.). |
| `hard` | всё, включая `low` (`pending_total` шт.) — сначала refute для low (Шаг 4, отложенная ветка). |

## Шаг 6 — вопросы оператору (HARD-GATE)

Батчами (3–4 за раз) через `AskUserQuestion`, только записи уровня режима и выше (critical всегда; medium если `medium`/`hard`; low если `hard`). Остальное — `status: answered_auto`, `source: auto` (`recommended`/`options` не трогай — уже согласованы Шагом 3/4).

В схеме нет отдельного поля `answer` — выбор оператора живёт в `recommended` (см. `references/queue-schema.md`). Для каждой отвеченной записи: запиши выбор в `recommended` (даже если он отличается от значения после refute; свободный ответ вне `options[]` — допиши его текстом в `options[]`), переставь `options[]` так, чтобы `options[0] === recommended`, `rationale` — коротко «operator choice» (+ пояснение, если было), `status: answered_human`, `source: human`.

Инвариант держится по построению для каждой терминальной записи — не отдельным полем. Это HARD-GATE — не пропускай батч без реального ответа оператора (или явного auto-режима).

## Шаг 7 — применение ответов к brief'у

Для каждой `answered_human`/`answered_auto` записи — Edit точечно в нужную секцию `docs/product/*.md` (переопределяет факт → перепиши секцию целиком; уточняет → append с `<!-- clarify <date>: <Q-id> -->` маркером), затем сразу переведи статус этой записи в `applied`. Не пачкой в конце — крэш посередине не должен молча терять факт «применено, но статус не обновлён» (см. Red flags).

## Шаг 8 — queue-check

```
${CLAUDE_PLUGIN_ROOT}/skills/clarify/scripts/queue-check.sh
```

`ok:false` (unapplied непуст либо инвариант нарушен) → почини по `data`, **не коммить**, повтори. Единственный источник цифр `pending_critical`/`pending_total`/`auto_closed_critical` — он же пишет их в `state.json`.

## Шаг 9 — state: phase

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh set phase clarify-done
```

Только после `queue-check.sh` ok:true — счётчики уже записаны им на Шаге 8.

## Шаг 10 — finalize

```
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh clarify <msg-file>
```

`<msg-file>` первой строкой: `chore: clarify brief`. Коммитит `docs/product` + `state.json`.

## Rationalization table (red flags)

| Соблазн | Почему нет |
|---|---|
| «Помечу applied заранее, всё равно сейчас применю» | crash между answered и applied в v1 молча терял решения |
| «Low-находки тоже прогоню через refute» | в v1 это жгло десятки тысяч токенов на вопросы, не влияющие на код |

## HARD-GATE

Шаг 6 — очередь вопросов оператору по режиму — обязателен для всех severity уровня режима и выше; молчаливый auto-close без Stop&Ask допустим только для `mode=auto` или для severity ниже выбранного уровня.

Прежде чем объявить шаг завершённым, покажи оператору: цифры из `queue-check.sh` (`data.counts`), достигнутый режим, что закрыто/осталось pending.

**NEXT:** Use mvp:bootstrap
