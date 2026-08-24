# MVP Pipeline v2 — дизайн-спецификация

Дата: 2026-08-21. Статус: approved-pending-review.
Заменяет: скиллы `*-mvp` в `~/.claude/skills/`, `~/.claude/playbooks/`.

## 1. Цель и не-цели

**Цель.** Плагин `mvp` для Claude Code: пайплайн «от сырого описания идеи до работающего MVP» —
упаковка brief'а, аудит качества, кодогенерация мета-файлов, DAG-план, автономная имплементация
с коммитом на задачу. Оператор участвует на границах фаз; внутри фаз — автономия.

**Не-цели (YAGNI):**
- Brownfield-проекты (существующая кодовая база) — вне scope, как и в v1.
- Обратная совместимость с данными v1 (`plan.json`, `clarify_queue.jsonl` старой схемы) — не поддерживается.
- Кодовый граф (graphify) — исключён из пайплайна; возможное будущее — опция plan-фазы для brownfield.
- Параллельная имплементация задач DAG (worktrees) — v2 последовательный; параллелизм — будущая итерация.
- Биллинг в точных $ — бюджет в honest-единицах (см. §6.7).

## 2. Принятые решения (зафиксированы оператором)

| Вопрос | Решение |
|---|---|
| Автономность | Human-гейты на границах фаз; внутри фаз автономия + закрытый список Stop&Ask |
| Стеки | Allowlist как в v1: backend ∈ {nestjs, fastapi}, frontend ∈ {nextjs, react, none}, deploy ∈ {docker-dokploy}, db = postgresql (+redis/timescaledb) |
| Форма | Локальный plugin + git-репо: `~/Documents/tools/claude/mvp-plugin`, namespace `mvp:*` |
| Vireo | Полная зачистка; остаётся ТОЛЬКО `project_brief.raw/` — прогон v2 с `mvp:brief` заново |
| Деприкейт v1 | Удаление (не rename): всё что переезжает — move, не copy |

## 3. Корневая философия (Iron Law плагина)

> **LLM думает — скрипты двигают данные.**
> Любая операция с однозначно правильным результатом (парсинг, валидация, staging, выбор
> задачи из DAG, подсчёт) исполняется скриптом с exit-code. LLM-вызов — только там, где
> нужно суждение: написать код, отревьюить, сформулировать вопрос.

Обоснование (аудит v1): inline-bash в SKILL.md содержал нетестированный awk-баг (Layout
всегда неверен для multi-service fastapi); транспорт plan.json через haiku StructuredOutput
дважды терял поля (`service`, латентно `service_path`); persist плана через LLM стоил
~700k токенов на 58-задачном плане.

Следствия:
1. Весь bash/псевдокод из SKILL.md → исполняемые скрипты в `lib/` и `skills/*/scripts/`.
2. Каждый скрипт имеет smoke-тест в `tests/`.
3. Скрипт отвечает одной строкой JSON `{ok, reason, hint, data}`; SKILL предписывает ровно
   два исхода на `ok:false` — исправить по hint или Stop&Ask.
4. LLM никогда не переписывает JSON состояния. I/O-агенты в workflow — «тупые реле»:
   «выполни команду X, верни stdout дословно».

## 4. Анатомия плагина

```
mvp-plugin/
  .claude-plugin/plugin.json        # {"name": "mvp", ...} → namespace mvp:*
  .claude-plugin/marketplace.json   # локальная установка (source: "./")
  README.md                         # карта пайплайна (замена mvp.md, кратко)
  lib/                              # общие скрипты — единственный экземпляр каждого
    brief-contract.sh
    gate.sh
    finalize.sh
    plan-io.mjs
    apply-patches.py
    validate-task.sh
    review-package.sh
    state.sh
  skills/
    brief/      SKILL.md, scripts/
    clarify/    SKILL.md, references/(queue-schema.md, refute-prompt.md), scripts/
    bootstrap/  SKILL.md, scripts/(assemble-agent.sh, verify-agents-drift.sh), templates/
    plan/       SKILL.md, references/plan-schema.json, scripts/validate-plan.py
    build/      SKILL.md, workflow.mjs, agents/(implementer.md, validator.md, reviewer.md,
                fix.md, re-review.md)
    resume/     SKILL.md
    retro/      SKILL.md
  docs/
    specs/                          # этот документ и будущие
    observations/                   # переезд из ~/.claude/playbooks/observations/ + новые прогоны
  tests/
    lib/*.test.sh                   # smoke на каждый lib-скрипт, с фикстурами
    fixtures/                       # plan-3tasks.json, brief-минимум, синтетический репо dry-run
```

Правила оформления скиллов (по writing-skills):
- **description = только триггер**, никогда workflow. Пример: `mvp:build` → «Use when
  .claude/state/plan.json exists and implementation should proceed».
- SKILL.md ссылается на свои файлы относительными markdown-ссылками; `@`-ссылки запрещены.
- Кросс-ссылки между скиллами — по имени: `**NEXT:** Use mvp:<next>`.
- Размер: gate-скиллы (resume, retro) 2–4 КБ; оркестраторы (build, clarify) ≤ 10–12 КБ SKILL.md,
  тяжёлое — в references/ («Load when: ...») и scripts/ (не грузятся в контекст).
- Каждый скилл начинается с «Announce at start: "Using mvp:<name> to <purpose>"».

## 5. Общая библиотека `lib/`

| Скрипт | Контракт |
|---|---|
| `brief-contract.sh` | Единственный владелец: обязательные заголовки business_logic/technical_solutions, **allowlist стеков** (в v1 — 5 копий), layout-mapping (stack → service_path-схема). Функции source'ятся остальными скриптами. |
| `gate.sh <stage>` | Детерминированные предусловия этапа: brief=«проект пуст?» (сигналы: .claude/state, CLAUDE.md, root-манифесты), clarify/bootstrap=«brief валиден?», plan=«bootstrap done? незакоммиченный plan.json?» (crash-recovery: предлагает дозавершить finalize вместо тупика), build=«plan закоммичен?». Выход: `{ok, reason, hint}`. |
| `finalize.sh <scope> <prefix> <msg-file>` | Один механизм коммита на все этапы (в v1 — три). Explicit staging по списку файлов (никогда `-A`), verify subject-prefix **до** коммита, `git commit -F <msg> -- <files>`, JSON-ответ. Scope-пресеты: brief, clarify, bootstrap, plan, build-task. |
| `plan-io.mjs <cmd>` | Весь I/O plan.json. Команды: `validate` (схема + boundary + инварианты — бывший псевдокод plan-mvp Шага 3, включая crypto/frontend-test-проверки по полям задач, не по эвристикам названий), `next` (см. §6.2), `complete <id> --tokens <delta>`, `set-status <id> <status>`, `summary` (для гейта план→build). |
| `apply-patches.py` | Как в v1 (uniqueness-check, атомарность) + re-stage ВСЕХ патченых файлов (в v1 — только «чистых») + patches.json пишется вызывающим агентом через Write tool (не haiku-heredoc). |
| `validate-task.sh <task-id>` | Детерминированная часть валидации: lint/build/test командами из CI-зеркала проекта (генерирует bootstrap → invariants.md), boundary-check `git diff` против service_path, сверка заявленных файлов с фактическими. Выход: структурированный список нарушений или ok. |
| `review-package.sh <base> <head>` | Дифф+стат+список коммитов в один файл, печатает путь (по образцу SDD). |
| `state.sh` | Чтение/запись `state.json` (фаза, курсор, clarify-маркер c `pending_critical` и `auto_closed_critical`). Убирает HTML-маркеры в markdown и grep по прозе. |

## 6. Этапы пайплайна

Цепочка: `mvp:brief → mvp:clarify → mvp:bootstrap → mvp:plan → mvp:build → mvp:retro`;
сервисный `mvp:resume`. Каждый SKILL.md завершается terminal-state binding:
«**NEXT:** Use mvp:<следующий>» + запрет остальных переходов.

### 6.1 mvp:brief (бывший prepare-mvp)

Вход: сырые описания (md/txt/json, discovery по стандартным локациям или явный путь).
Выход: каноническая `project_brief/` (skeleton всех обязательных секций, auto-Layout по
стеку), `project_brief.raw/` (move исходников), коммит через finalize.sh.

Сохраняется из v1: atomic tmp→swap + `.bak.<ts>` при recreate; recreate через Stop&Ask
(без `--force`); no-clobber архивация; git Stop&Ask («git init?»); Stop&Ask по стеку с
4 триггерами (стек не в allowlist / не указан / противоречив / неоднозначен) и Iron Law
«Стек не выбирается за оператора».

Изменения:
- Весь inline-bash (~120 строк) → `skills/brief/scripts/` + `lib/gate.sh brief`
  (включая починку awk-бага подсчёта сервисов).
- Multi-candidate discovery → выбор через AskUserQuestion options (в v1 — «перенабери команду»).
- Конфликт имён при архивации → AskUserQuestion (в v1 — exit 1 с невыполнимой инструкцией
  «перезапусти Шаг 5»).
- Crash между swap и архивацией: gate детектит «валидный brief + исходники в корне» →
  предлагает только доархивировать, не пересоздавать.
- HARD-GATE: показ упаковки оператору (что куда легло, какой стек распознан) → подтверждение → NEXT clarify.

### 6.2 mvp:clarify

Вход: `project_brief/`. Выход: обновлённый brief, `project_brief/clarify_queue.jsonl`,
маркер в `state.json`, коммит.

Сохраняется из v1: persistent AskQueue с иммутабельным audit-trail
(recommended_v1 / self_critique / recommended); режимы auto/light/medium/hard как «кто
отвечает», выбор режима ПОСЛЕ аудита (оператор видит цифры находок); refute-промпт с 5
пунктами и примерами (→ `references/refute-prompt.md`); severity-критерии
critical/medium/low; sanity-сигнал `changed_rate==0`; resume вместо `--force`.

Изменения:
- Схема записи получает статус **`applied`** (v1-дыра: crash между «answered» и
  «применено к brief» → записи молча выпадали при resume). Скрипт
  `scripts/queue-check.sh` сверяет queue↔brief перед finalize: answered-без-applied = fail.
- Self-critique по severity: critical+medium — всегда; low — только в режиме hard
  (v1 жёг refute на находках «не влияет на код» по определению).
- Маркер: `pending_critical`, `pending_total`, `auto_closed_critical` — в `state.json`
  через `state.sh` (не HTML-коммент в markdown).
- Схема очереди и примеры → `references/queue-schema.md` (resume-путь не платит за них).
- Секция «Будущие расширения» — удалена.
- Гейт: очередь вопросов согласно режиму → ответы оператора → применение → NEXT bootstrap.

### 6.3 mvp:bootstrap

Вход: валидный brief (+ clarify-маркер: при `pending_critical>0` — Stop&Ask; показывается
и `auto_closed_critical`). Выход: `CLAUDE.md`, `ARCHITECTURE.md`, `.claude/agents/*`,
`.claude/state/` skeleton, **`invariants.md`**, коммит.

Сохраняется из v1: слоёная валидация brief (presence → non-emptiness через
brief-contract.sh); `assemble-agent.sh` + `verify-agents-drift.sh` (byte-substring
инвариант — лучший анти-drift паттерн v1, переносится как есть).

Изменения:
- **Канал проектных инвариантов**: bootstrap генерирует `.claude/state/invariants.md`
  из brief'а (архитектурные инварианты, service-границы, CI-зеркало команд). plan и build
  потребляют его. Vireo-специфика удаляется из глобальных шаблонов и промптов навсегда;
  уроки прогонов попадают в invariants.md проекта, не в плагин.
- Шаблоны агентов: `skills/bootstrap/templates/`, очищены от vireo (имена сервисов —
  плейсхолдеры из brief'а). Pipeline-агенты объявляют tools: Read, Edit, Write, Bash —
  **без Skill tool** (структурная защита вместо лексической маскировки v1).
- LLM-выходы этапа получают детерминированные гейты: `scripts/check-meta.sh` — CLAUDE.md
  ≤150 строк и обязательные секции; lint mermaid-стрелок ARCHITECTURE.md по инвариантам
  (запрещённые рёбра типа `integration-* --> DB` — grep-проверка, не проза «рисуй дословно»).
- Pre-flight: node требуется только если стек его требует.
- Гейт: показ сгенерированных мета-файлов → подтверждение → NEXT plan.

### 6.4 mvp:plan

Вход: brief + мета-файлы + invariants.md. Выход: `plan.json` (DAG), `PROJECT_PLAN.md`,
курсор в state.json, коммит.

Сохраняется из v1: планировщик — отдельный субагент; молекулярная декомпозиция; hybrid
boundary (service = HARD, files = HINT); `complexity_class` на задаче
(boilerplate / follow-pattern / novel-design) для выбора модели.

Изменения:
- Промпт планнера параметризуется invariants.md; никаких vireo-фаз («strategies CRUD»)
  в глобальном промпте. Фазы выводятся из brief'а.
- Планнеру передаются пути + краткая сводка (не «родитель читает всё и вставляет» —
  двойная оплата контекста v1).
- Схема плана → `references/plan-schema.json` (файл, а не инлайн; `estimate_tokens`
  единый лимит 25k — v1 противоречил сам себе 50k/25k). Схема содержит `service_path`
  как required (латентный баг v1), без поля `blocks`.
- **Валидация — `scripts/validate-plan.py`** (запускаемый, с exit-code): схема, DAG-ацикличность,
  достижимость, boundary-принадлежность files, инварианты по полям задач (v1: Python-псевдокод
  в прозе + crypto-эвристика по подстроке названия).
- Формула бюджета/цены моделей — в конфиге скрипта, не в прозе.
- HARD-GATE (главный): `plan-io.mjs summary` → DAG-сводка (фазы, число задач, оценки)
  оператору → build стартует ТОЛЬКО явной командой оператора.

### 6.5 mvp:build (бывший execute-mvp) — цикл задачи

Движок: Workflow tool, `skills/build/workflow.mjs` через scriptPath. Ограничение среды:
workflow-скрипт не имеет FS-доступа → I/O-агенты (haiku) остаются, но как реле stdout
(§3.4), с батчингом.

Цикл (~4–5 LLM-вызовов на задачу против ~8–10 в v1):

1. **advance** (haiku-реле): `plan-io.mjs next` атомарно — interrupt-check (файл),
   git-сверка «предыдущая задача закоммичена», выбор ready из DAG, генерация
   `briefs/task-NNN.md` (контракт задачи + report'ы всех depends_on + invariants.md),
   ответ `{task_id, brief_path, boundary, role, model}` или halt-причина
   (all-done / dag-stuck / interrupt / budget).
2. **implement** (sonnet или opus по complexity_class; retry всегда opus): промпт из
   `agents/implementer.md`; агент сам читает brief-файл; HARD boundary; TOKEN
   EFFICIENCY-правила (batch tool calls — доказанные −45%); пишет
   `reports/task-NNN.md` (интерфейс-дайджест для будущих зависимых задач); возвращает
   ≤15 строк: статус DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT + файлы.
   Предписанные handlers: BLOCKED/NEEDS_CONTEXT → parking с вопросом (не слепой retry).
3. **validate**: сначала `validate-task.sh` (скрипт). Агент-валидатор (sonnet)
   вызывается ТОЛЬКО при нарушениях: судит, возвращает `patches[]` для тривиальных
   фиксов или вердикт. Лестница: patches → apply-patches.py → re-run скрипта →
   иначе ОДИН implementer-retry (opus, с текстом ошибок) → иначе parking.
4. **review** (sonnet, обязателен всегда — 44% catch rate в v1): читает
   review-package + brief; «Do Not Trust the Report»; каждый finding — цитата+file:line;
   блокируют только bug | security | pattern-violation. Лестница: patches → иначе один
   scoped fix-dispatch → scoped re-review (только ADDRESSED/NOT ADDRESSED, новое =
   Out-of-Scope, цикл не продлевает) → иначе parking.
5. **finalize** (haiku-реле): `plan-io.mjs complete <id> --tokens <delta> && finalize.sh
   build-task <subject> <msg-file>`: статус, строка ledger
   (`Task 012: complete (commits a1b2..c3d4)`), атомарный коммит код+state, телеметрия
   с реальным ts (скрипты вне песочницы) и per-task дельтой (v1 писал кумулятив и
   единый args.now на весь run).

**Parking** (закрывает каскадную дыру v1): `git checkout -- <boundary>` + unstage +
`Ruling:`/`Parked:` в ledger + blockers.md → halt stop-and-ask. Дерево чистое.

**Rulings, not stalls** — закрытый список Stop&Ask: (1) необратимая операция,
(2) security-выбор, (3) конфликт с планом/инвариантами, (4) двусмысленность, которую
brief не разрешает. Остальное — ruling в ledger с ценой ошибки, run продолжается.

**Caps**: retry=1, total-attempts=2 (как v1); cap run'а — `--tasks N` (жёсткий) и/или
потолок workflow-токенов, документированный как внутренняя валюта с калибровочным
коэффициентом к $ (уточняет retro). Аргументы workflow валидируются в первой строке
скрипта (fail fast при отсутствии run_id/budget — v1 молча писал "undefined" в телеметрию).

**Ledger** `.claude/state/ledger.md`: append-only, первая строка — идентичность плана
(путь+hash); форматные строки `Task N: complete (...)`, `Ruling: <что> — <почему> — <цена
ошибки>`, `Parked: ...`. Правило resume: задача с complete-строкой НЕ диспатчится повторно.

**Halt** → основная сессия: скилл читает причину, задаёт вопрос AskUserQuestion,
решение в decisions.log, перезапуск. Interrupt между молекулами — advance; посреди — TaskStop.

### 6.6 mvp:resume (бывший continue-mvp)

Тонкий gate-скилл (2–4 КБ): читает state.json + ledger + blockers → таблица диспатча
(фаза → следующий скилл; blocker → вопрос оператору → decisions.log → перезапуск build).
Никогда не использует resumeFromRunId (мёртвая фича v1 — args меняются между сессиями).
Восстановление курсора из plan.json при потере state.json.

### 6.7 mvp:retro (бывший analyze-telemetry)

Ужат до реально существующих данных: agent-errors, retries, per-task дельты, реальное
время, halt-причины. Выход: (1) кандидаты в rationalization-таблицы (вербатим-цитаты),
(2) правки шаблонов/промптов, (3) калибровка workflow-токен→$ коэффициента,
(4) observation-файл в docs/observations/ плагина. Метрики без данных (p50/p90 v1,
spent_usd, graph_refresh) — удалены из контракта.

### Телеметрия (контракт v2.0)

Пишут ТОЛЬКО скрипты (Defer&Continue printf от implementer'а — v1-бага — заменяется:
implementer пишет решение в свой report-файл, оттуда его забирает главная сессия и
`decisions.log`). У каждого события — реальный ISO ts.

**Реализовано в v2.0 — ровно одно событие.** `lib/plan-io.mjs complete` дописывает в
`.claude/state/telemetry/events.jsonl`:

```json
{"event":"task_complete","task":"<id>","delta_tokens":<n>,"ts":"<ISO-8601>"}
```

`mvp:retro` читает только его; других типов в файле не бывает, и додумывать их при
чтении запрещено.

**Будущие события (не реализованы в v2.0)**: session_start/end, task_start/parked (ms,
role, model, attempt), validator_fail (класс), review_findings (классы), halt. Это
направление, а не контракт: пока событие не пишет ни один скрипт, для retro и аналитики
его не существует.

## 7. Дисциплинарный слой

**Тройка в каждом SKILL.md** (строки — вербатим из observations/telemetry, не выдуманные):
- Iron Law этапа (build: «LLM думает — скрипты двигают данные»; clarify: «Не выдумывай
  факты и не выдумывай дыры; каждая находка — с evidence-цитатой»; brief: «Стек не
  выбирается за оператора»; plan: «Каждый гейт плана — скрипт, не намерение»).
- Rationalization table («мысль → реальность», с эмпирикой: «поправлю поле на лету» →
  «так haiku потерял service»; «ревью скипнуть, молекула тривиальная» → «7/16 тривиальных
  молекул baseline содержали баги»).
- Red flags (STOP-мысли: «перепишу этот JSON сам», «git add -A, файлов много»).

**Контракты диспатч-промптов** (`skills/build/agents/*`): статус-контракт из 4 исходов +
«Never silently produce work you're unsure about»; You Do Not Dispatch Subagents;
без Skill tool; Do Not Trust the Report (reviewer); reviewer/validator read-only, не
перегоняют тесты implementer'а (его отчёт + validate-скрипт = test evidence; убирает
2–3× прогон тулчейна v1). Блок Placeholders внизу каждого шаблона.

**Тестирование скиллов как кода**: pressure-тест субагентом перед правкой дисциплинарных
блоков (методика writing-skills: baseline без скилла → вербатим рационализаций → строки
таблиц); CREATION-LOG у нетривиальных скиллов; retro замыкает петлю.

## 8. Миграция и зачистка

Порядок сборки (каждый шаг верифицируется до следующего):
1. Скелет: репо, манифесты, локальная установка, `mvp:*` виден в списке скиллов.
2. `lib/`: порт + починка + smoke-тесты (`tests/lib/*.test.sh`); `plan-io.mjs` с нуля +
   фикстура «план из 3 задач».
3. Скиллы в порядке цепочки: brief → clarify → bootstrap → plan → build → resume → retro.
4. Dry-run build на синтетике: фикстурный репо с 2–3 задачами в tests/, полный цикл.
5. Живой smoke на vireo (см. ниже).
6. Зачистка старого — только после успешного smoke.

Манифест перемещений (move, не copy):

| Что | Куда |
|---|---|
| `~/.claude/playbooks/scripts/*` | → `lib/` (с переработкой) |
| `~/.claude/playbooks/observations/*` | → `docs/observations/` |
| `~/.claude/playbooks/mvp.md` | ✕ удалить (новый README) |
| `~/.claude/agents/templates/*` | → `skills/bootstrap/templates/` (очистка от vireo) |
| `~/.claude/skills/`: prepare-mvp, clarify-mvp, bootstrap-mvp, plan-mvp, execute-mvp, continue-mvp, analyze-telemetry, refresh-graph | ✕ удалить |
| `~/.claude/skills/`: managing-agents, verification-before-completion, git-commit-contract | ✕ удалить |

**Vireo — чистый старт**: удалить `.claude/state/`, `.claude/agents/`, `CLAUDE.md`,
`ARCHITECTURE.md`, `project_brief/` (включая clarify_queue.jsonl — обратная совместимость
не нужна). Остаётся ТОЛЬКО `project_brief.raw/` и git-история. Прогон v2 с нуля:
`mvp:brief` на raw → clarify → bootstrap → plan → build (≥2 задачи как smoke).

Память: после имплементации переписать `feedback-mvp-pipeline`, `feedback-clarify-architecture`
под v2 (ссылка на репо плагина), обновить MEMORY.md.

## 9. Definition of Done

- [ ] Плагин установлен; 7 скиллов видны как `mvp:*`.
- [ ] `tests/` зелёные: smoke каждого lib-скрипта + dry-run build-цикла на фикстуре.
- [ ] Vireo: brief→clarify→bootstrap→plan пройдены на v2; build закоммитил ≥2 задачи.
- [ ] Телеметрия прогона содержит реальные ts и per-task дельты (ручная проверка jsonl).
- [ ] Старые скиллы/playbooks удалены; глобальный CLAUDE.md/RTK и памятки не ссылаются
      на мёртвые пути.
- [ ] Memory-файлы обновлены.

## 10. Ключевые риски

| Риск | Митигация |
|---|---|
| Механика локальной установки плагина отличается от ожиданий (installed_plugins.json) | Шаг 1 порядка сборки — проверка установки до написания скиллов |
| I/O-реле всё же исказит однострочный JSON | Контракт «stdout дословно» + schema на agent(); критические поля перепроверяются следующим скриптом (git-сверка в advance) |
| Скрытые зависимости v1-скиллов, не найденные аудитом | Зачистка только после живого smoke на vireo |
| Workflow-токены как валюта бюджета непонятны оператору | `--tasks N` как основной cap; retro калибрует коэффициент к $ |

---

## Приложение A — поправки от 2026-08-25 (по итогам измерения прогона vireo)

Основание — `docs/observations/2026-08-24-pipeline-economics-and-review-yield.md`
(23 прогона, 473 диспатча, 22.1 M токенов; плюс контролируемые эксперименты).
Здесь только изменения контрактов; обоснование и цифры — в наблюдениях.

**A.1. Ревью-пакет обязан быть полным.** `review-package.sh` возвращает
`data.truncated: [{path, hidden_lines, total_lines}]`. Непустой список —
блокирующее условие: `workflow.mjs` паркует задачу, а не отдаёт ревьюеру
частичный дифф. `UNTRACKED_FILE_LINE_CAP` поднят 400 → 2000 и переопределяется
через env. Скрипт падает, если запись об обрезке не читается (fail closed).

**A.2. `CANNOT_VERIFY` — halt.** `agents/reviewer.md` печатает обязательную
строку `CANNOT_VERIFY: none | <что не проверено>`. Значение, отличное от
`none`, паркует задачу. Отсутствие строки трактуется как `none` — совместимость
со старым форматом ответа, а не лазейка: пакетную неполноту ловит A.1,
скриптовый гейт, который уговорить нельзя.

**A.3. Находка ревью — аргумент, не факт.** `agents/fix.md` обязан сначала
попытаться опровергнуть каждую находку и, если опроверг, не трогать код, а
изложить доказательство в отчёте. `agents/re-review.md` получает третий
вердикт `REFUTED` и судит опровержение; закрывают находку `ADDRESSED` и
`REFUTED`, всё остальное паркует. Fix не может закрыть собственную находку —
он только аргументирует. Принятое опровержение уходит в ledger как concern.

**A.4. Concerns пишет скрипт.** `plan-io.mjs ledger --concern <text>`
персистит их в `ledger.md`. Раньше это была инструкция SKILL'у и она была
проигнорирована на 36 задачах из 36 — прямое нарушение Iron Law внутри самого
плагина. Свободный текст уходит в команду через POSIX-квотирование.

**A.5. Релей-диета — 9 диспатчей на задачу вместо 6.** Каждый диспатч стоит
~30 200 токенов старта субагента независимо от полезной нагрузки, поэтому:
`next` возвращает `head_sha` (убит релей `git rev-parse HEAD`);
`complete --write-msg` пишет commit-subject сам (убит haiku-агент msg-writer, и
заодно снят риск интерполяции свободного заголовка задачи);
`ledger --sha HEAD` резолвит sha сам и чейнится за `finalize.sh` в одну
команду (убит отдельный релей ledger).

**A.6. Телеметрия — аддитивно.** К `delta_tokens` добавлены `controller_only:
true` и `dispatches: <n>`. Поле не переименовано намеренно: `events.jsonl`
append-only, история проекта может пересекать версии плагина. Измеренное
занижение `delta_tokens` против фактических записей рантайма — **8.4×**.

**A.7. Политика моделей implementer'а не меняется.** `novel-design → opus`
остаётся. Переигровка трёх novel-design задач на sonnet в изолированных
worktree'ах проиграна слепым судьям 3:0 при одинаковом характере отказа —
тесты, подтверждающие собственную реализацию вместо требования, при зелёном
CI. Экономия была бы ~4× в деньгах, но покупается систематическим дефектом.

**Прямо отвергнуто** (проверено, не гипотезы): скип ревью по
`complexity_class`; понижение модели ревьюера; второй проход ревью сам по себе
без шага опровержения.

**Открытый вопрос, эксперимент не ставился:** `sonnet-implementer +
независимый test-writer`. Все три проигрыша sonnet прошли через один механизм —
автор кода писал себе тесты. Роль `test-writer` в плане есть, но использована
в 4 задачах из 54. Проверять имеет смысл перед планированием следующего
проекта, потому что это правка уровня плана, а не прогона.
