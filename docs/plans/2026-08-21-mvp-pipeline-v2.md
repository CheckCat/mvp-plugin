# MVP Pipeline v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Собрать plugin `mvp` (namespace `mvp:*`) — пайплайн от сырого описания идеи до работающего MVP, с детерминированным ядром на скриптах.

**Architecture:** Plugin для Claude Code: `lib/` — общие скрипты (весь I/O данных), `skills/{brief,clarify,bootstrap,plan,build,resume,retro}` — семь скиллов цепочки, `tests/` — smoke-тесты каждого скрипта + dry-run build-цикла. LLM никогда не транспортирует данные; workflow build-фазы использует haiku-агентов только как реле stdout.

**Tech Stack:** bash + python3 + node (mjs), Claude Code plugin conventions (см. superpowers 6.3.0 как референс), Workflow tool для build-фазы.

**Spec:** `docs/specs/2026-08-21-mvp-pipeline-v2-design.md` — план аргументирует от спеки; исполнитель читает обе.

## Global Constraints

- **Iron Law:** LLM думает — скрипты двигают данные. Операция с однозначным результатом = скрипт с exit-code, не инструкция модели.
- **Контракт вывода скриптов:** последняя строка stdout — одна строка JSON `{"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}`. Ошибка → `ok:false` + exit code 1. Никакого другого формата.
- **Frontmatter скиллов:** ровно два поля `name`, `description`; description — ТОЛЬКО триггер («Use when …»), никогда workflow. Суммарно ≤ 1024 символов.
- **Размеры:** SKILL.md ≤ 12 КБ для оркестраторов (build, clarify), ≤ 4 КБ для gate-скиллов (resume, retro). Тяжёлое — в `references/` («Load when: …») и `scripts/`.
- **Коммиты:** только через `lib/finalize.sh` в целевых проектах; в самом репо плагина — обычный git, explicit staging (никогда `git add -A`), prefix ∈ {feat, fix, docs, test, chore, refactor}.
- **Тесты:** каждый lib-скрипт имеет `tests/lib/<name>.test.sh`; тест создаёт tmpdir-фикстуру, зовёт скрипт, проверяет JSON-выход; exit 0 = pass. `tests/run.sh` гоняет все. Зависимости окружения: bash, git, python3, node — ничего больше.
- **Allowlist стеков (verbatim из спеки):** backend ∈ {nestjs, fastapi}; frontend ∈ {nextjs, react, none}; deploy ∈ {docker-dokploy}; db = postgresql (+ опц. redis, timescaledb).
- **Пути:** плагин — `~/Documents/tools/claude/mvp-plugin`. Состояние целевого проекта — `.claude/state/{plan.json,state.json,ledger.md,invariants.md,ci-mirror.sh,briefs/,reports/,review/,telemetry/}`.
- **Никакой vireo-специфики** в файлах плагина: `grep -ri vireo` по репо (вне docs/observations) обязан быть пустым.

---

## Файловая структура (итог всех задач)

```
mvp-plugin/
  .claude-plugin/plugin.json  .claude-plugin/marketplace.json  README.md
  lib/  brief-contract.sh gate.sh state.sh finalize.sh apply-patches.py
        plan-io.mjs validate-task.sh review-package.sh
  skills/brief/{SKILL.md,scripts/package-brief.sh}
  skills/clarify/{SKILL.md,references/{queue-schema.md,refute-prompt.md},scripts/queue-check.sh}
  skills/bootstrap/{SKILL.md,scripts/{assemble-agent.sh,verify-agents-drift.sh,check-meta.sh},templates/*}
  skills/plan/{SKILL.md,references/plan-schema.json,scripts/validate-plan.py}
  skills/build/{SKILL.md,workflow.mjs,agents/{implementer.md,validator.md,reviewer.md,fix.md,re-review.md}}
  skills/resume/SKILL.md   skills/retro/SKILL.md
  docs/{specs/,plans/,observations/}
  tests/{run.sh,lib/*.test.sh,fixtures/{plan-3tasks.json,brief-minimal/,dryrun/}}
```

---

### Task 1: Скелет плагина и локальная установка

**Files:**
- Create: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md`, `tests/run.sh`

**Interfaces:**
- Produces: установленный plugin `mvp` — все последующие скиллы становятся видимыми как `mvp:<dir>` по мере появления каталогов `skills/*/SKILL.md`.

- [ ] **Step 1: манифесты** (образец — `~/.claude/plugins/cache/claude-plugins-official/superpowers/6.3.0/.claude-plugin/`):

```json
// .claude-plugin/plugin.json
{
  "name": "mvp",
  "description": "Greenfield MVP pipeline: brief packaging, clarification, bootstrap, DAG planning, autonomous build",
  "version": "2.0.0",
  "author": {"name": "vadim"},
  "license": "MIT",
  "keywords": ["mvp", "pipeline", "workflow"]
}
```

```json
// .claude-plugin/marketplace.json
{
  "name": "mvp-local",
  "owner": {"name": "vadim"},
  "plugins": [{"name": "mvp", "source": "./", "description": "MVP pipeline v2"}]
}
```

- [ ] **Step 2: README.md** — карта цепочки (10–15 строк): `mvp:brief → mvp:clarify → mvp:bootstrap → mvp:plan → mvp:build → mvp:retro`, сервисный `mvp:resume`; ссылка на спеку; правило Iron Law. Не дублировать содержимое скиллов.

- [ ] **Step 3: tests/run.sh**

```bash
#!/usr/bin/env bash
set -u; fail=0
for t in "$(dirname "$0")"/lib/*.test.sh; do
  [ -e "$t" ] || continue
  if bash "$t" >/tmp/mvp-test-out 2>&1; then echo "PASS $(basename "$t")"
  else echo "FAIL $(basename "$t")"; cat /tmp/mvp-test-out; fail=1; fi
done
exit $fail
```

- [ ] **Step 4: установка.** Выясни механику: `claude plugin --help` (ожидаемо: `claude plugin marketplace add ~/Documents/tools/claude/mvp-plugin` + `claude plugin install mvp@mvp-local`). Fallback, если CLI-команд нет: изучи `~/.claude/plugins/known_marketplaces.json` и `installed_plugins.json`, добавь записи по образцу существующих (superpowers), с `installPath`, указывающим на репо плагина.
- [ ] **Step 5: проверка** — новая сессия/`/plugin`-список: плагин `mvp` виден (скиллов пока нет — это ок). Временно создай `skills/resume/SKILL.md` c минимальным frontmatter, проверь что `mvp:resume` появился в списке скиллов, удали временный файл.
- [ ] **Step 6: Commit** `chore: plugin skeleton + local install`

---

### Task 2: lib/brief-contract.sh

**Files:** Create: `lib/brief-contract.sh`, `tests/lib/brief-contract.test.sh`

**Interfaces:**
- Produces (bash-функции, source'ятся): `required_headers_tech` / `required_headers_biz` (списки по одному на строку); `validate_headers <file> <h1> <h2>…` (exit 0/1, stderr — какие отсутствуют/пусты); `validate_stack <backend> <frontend> <deploy> <db-csv>` (exit 0/1 + JSON-строка); `layout_for_stack <backend> <frontend> <services_count>` (печатает `packages` | `services` | `app`).

- [ ] **Step 1: тест.** Фикстура: tmpdir с `technical_solutions.md` (все заголовки, непустые) и вариант с пустой секцией. Кейсы: (a) валидный файл → exit 0; (b) пустая секция → exit 1; (c) `validate_stack fastapi react docker-dokploy postgresql,redis` → exit 0; (d) `validate_stack django …` → exit 1; (e) `layout_for_stack fastapi react 3` → `services`; `… 1` → `app`; `layout_for_stack nestjs nextjs 2` → `packages`.
- [ ] **Step 2:** прогнать → FAIL (файла нет).
- [ ] **Step 3: реализация.** База — `~/.claude/playbooks/scripts/brief-contract.sh` (скопировать, затем править): сохранить `required_headers_*` и `validate_headers` (там решены word-splitting/CRLF); **добавить** `validate_stack` и `layout_for_stack`:

```bash
ALLOWED_BACKEND="nestjs fastapi"; ALLOWED_FRONTEND="nextjs react none"
ALLOWED_DEPLOY="docker-dokploy"
validate_stack() { # $1 backend $2 frontend $3 deploy $4 db csv
  local errs=()
  case " $ALLOWED_BACKEND "  in *" $1 "*) ;; *) errs+=("backend '$1' not in [$ALLOWED_BACKEND]");; esac
  case " $ALLOWED_FRONTEND " in *" $2 "*) ;; *) errs+=("frontend '$2' not in [$ALLOWED_FRONTEND]");; esac
  case " $ALLOWED_DEPLOY "   in *" $3 "*) ;; *) errs+=("deploy '$3' not in [$ALLOWED_DEPLOY]");; esac
  case ",$4," in *,postgresql,*) ;; *) errs+=("db must contain postgresql");; esac
  if [ ${#errs[@]} -gt 0 ]; then
    printf '{"ok":false,"reason":"stack not allowed","hint":"%s","data":null}\n' "${errs[*]}"; return 1
  fi
  printf '{"ok":true,"reason":null,"hint":null,"data":null}\n'
}
layout_for_stack() { # $1 backend $2 frontend $3 services_count
  if [ "$1" = nestjs ]; then echo packages
  elif [ "${3:-1}" -gt 1 ]; then echo services
  else echo app; fi
}
```

- [ ] **Step 4:** тест → PASS. **Step 5: Commit** `feat: brief-contract with stack allowlist and layout mapping`

---

### Task 3: lib/state.sh

**Files:** Create: `lib/state.sh`, `tests/lib/state.test.sh`

**Interfaces:**
- Produces (CLI): `state.sh get <key>` / `state.sh set <key> <value>` / `state.sh init` над `.claude/state/state.json`. Ключи плоские: `phase` (brief|clarify|bootstrap|plan|build|done), `clarify_mode`, `pending_critical`, `pending_total`, `auto_closed_critical`, `current_task`. Числа хранятся числами. `get` несуществующего ключа → `ok:true, data:{"value":null}`.

- [ ] **Step 1: тест.** tmpdir: `init` создаёт `{"phase":"brief"}`; `set pending_critical 2` затем `get pending_critical` → `"value":2`; `set` без init → `ok:false` c hint «run state.sh init».
- [ ] **Step 2:** FAIL. **Step 3: реализация** — bash-обёртка над python3:

```bash
#!/usr/bin/env bash
set -eu
STATE="${STATE_DIR:-.claude/state}/state.json"
cmd="${1:-}"; shift || true
case "$cmd" in
  init) mkdir -p "$(dirname "$STATE")"; [ -f "$STATE" ] || echo '{"phase":"brief"}' > "$STATE"
        printf '{"ok":true,"reason":null,"hint":null,"data":null}\n' ;;
  get|set) python3 - "$cmd" "$STATE" "$@" <<'PY'
import json,sys
cmd,path=sys.argv[1],sys.argv[2]
try: s=json.load(open(path))
except FileNotFoundError:
    print(json.dumps({"ok":False,"reason":"no state.json","hint":"run state.sh init","data":None})); sys.exit(1)
if cmd=="get":
    print(json.dumps({"ok":True,"reason":None,"hint":None,"data":{"value":s.get(sys.argv[3])}}))
else:
    v=sys.argv[4]
    try: v=json.loads(v)
    except ValueError: pass
    s[sys.argv[3]]=v; json.dump(s,open(path,"w"),indent=1)
    print(json.dumps({"ok":True,"reason":None,"hint":None,"data":None}))
PY
  ;;
  *) printf '{"ok":false,"reason":"unknown cmd","hint":"init|get|set","data":null}\n'; exit 1;;
esac
```

- [ ] **Step 4:** PASS. **Step 5: Commit** `feat: state.sh single-owner state.json`

---

### Task 4: lib/gate.sh

**Files:** Create: `lib/gate.sh`, `tests/lib/gate.test.sh`

**Interfaces:**
- Consumes: `state.sh get phase`, `brief-contract.sh::validate_headers`.
- Produces: `gate.sh <brief|clarify|bootstrap|plan|build>` из корня проекта → JSON-контракт.

Правила по стадиям (verbatim из спеки §5):
- `brief`: fail если найден любой из: `.claude/state/`, `CLAUDE.md`, `ARCHITECTURE.md`, root-манифест (`package.json|pyproject.toml|Cargo.toml|go.mod`), непустые `apps/*/`|`services/*/`. Особый случай: валидный `project_brief/` + сырые файлы в корне → `data:{"recovery":"archive-only"}` (crash между swap и архивацией).
- `clarify`: fail если нет `project_brief/` или `validate_headers` не проходит presence.
- `bootstrap`: как clarify + non-emptiness + fail если `state.sh get pending_critical` > 0 (`hint`: «resolve criticals via mvp:clarify or confirm override»).
- `plan`: fail если phase ≠ bootstrap-done; отдельный кейс: `plan.json` существует, но не закоммичен (`git status --porcelain` его показывает) → `data:{"recovery":"finalize-plan"}`.
- `build`: fail если `plan.json` отсутствует/не закоммичен или `validate` плана не проходил (phase ≠ plan-done).

- [ ] **Step 1: тест** — фикстуры-tmpdir на каждый кейс (пустой дир → brief ok; дир с CLAUDE.md → brief fail; brief+сырьё → recovery archive-only; plan.json незакоммичен в tmp-git → recovery finalize-plan).
- [ ] **Step 2:** FAIL. **Step 3: реализация** (~100 строк bash, source brief-contract.sh; каждый кейс — прямой перенос правил выше; recovery-кейсы возвращают `ok:false` + `data.recovery`).
- [ ] **Step 4:** PASS. **Step 5: Commit** `feat: gate.sh deterministic stage preconditions`

---

### Task 5: lib/finalize.sh

**Files:** Create: `lib/finalize.sh`, `tests/lib/finalize.test.sh`

**Interfaces:**
- Produces: `finalize.sh <scope> <msg-file> [--files f1 f2 …]` → `data:{"sha":"…"}`. Scope-пресеты списков staged-файлов: `brief`=(project_brief project_brief.raw), `clarify`=(project_brief .claude/state/state.json), `bootstrap`=(CLAUDE.md ARCHITECTURE.md .claude/agents .claude/state), `plan`=(.claude/state PROJECT_PLAN.md), `build-task`=(--files обязателен, плюс всегда .claude/state). Subject-prefix проверяется **до** коммита: первая строка msg-file обязана матчить `^(feat|fix|ci|chore|test|docs|refactor)(\(.+\))?: `.

- [ ] **Step 1: тест.** tmp-git-репо: (a) валидный msg + файлы → коммит создан, sha в JSON, посторонний staged-файл оператора НЕ попал в коммит (path-restricted `git commit -F msg -- <paths>`); (b) msg с subject `WIP: x` → `ok:false`, коммита нет; (c) отсутствующий файл из списка — пропускается молча, если не существует, но fail если в итоге нечего коммитить.
- [ ] **Step 2:** FAIL. **Step 3: реализация.** База — `~/.claude/playbooks/scripts/finalize.sh` (перенести verify/цепочку), изменения: prefix-check ДО `git commit`; scope-пресеты; убрать graphify-инвалидацию (граф исключён из v2); output — единый JSON-контракт.
- [ ] **Step 4:** PASS. **Step 5: Commit** `feat: unified finalize.sh for all stages`

---

### Task 6: lib/apply-patches.py

**Files:** Create: `lib/apply-patches.py`, `tests/lib/apply-patches.test.sh`

**Interfaces:**
- Produces: `apply-patches.py <patches.json> [--stage]` ; формат patches.json: `[{"file":str,"search":str,"replace":str}]`. Гарантии: search обязан встречаться ровно 1 раз, иначе весь файл не трогается; `--stage` → `git add` каждого успешно патченного файла; выход — JSON-контракт c `data:{"applied":[…],"failed":[{"file":…,"reason":"not-found|ambiguous"}]}`; `ok:false` если failed непуст.

- [ ] **Step 1: тест:** (a) уникальный search → применён, файл в staged при `--stage`; (b) search дважды → файл байт-в-байт нетронут, `reason:"ambiguous"`; (c) search отсутствует → `not-found`.
- [ ] **Step 2:** FAIL. **Step 3:** перенести `~/.claude/playbooks/scripts/apply-patches.py`, добавить `--stage` и новый выходной контракт.
- [ ] **Step 4:** PASS. **Step 5: Commit** `feat: apply-patches with staging`

---

### Task 7: lib/plan-io.mjs + фикстура плана

**Files:** Create: `lib/plan-io.mjs`, `tests/fixtures/plan-3tasks.json`, `tests/lib/plan-io.test.sh`

**Interfaces (CLI, всё из корня проекта, state в `.claude/state/`):**
- `plan-io.mjs validate --schema <path>` → проверяет plan.json: JSON-schema-поля (id, title, service, service_path, role, files[], depends_on[], estimate_tokens ≤ 25000, status, complexity_class ∈ {boilerplate,follow-pattern,novel-design}), DAG ацикличен, все depends_on существуют, каждый files[] лежит под своим service_path. `data:{"errors":[…]}`.
- `plan-io.mjs next [--task <id>]` → атомарно: (1) interrupt: существует `.claude/state/user-interrupt.md` → `data:{"halt":"interrupt"}`; (2) dirty-tree: `git status --porcelain` содержит файлы вне `.claude/state` → `data:{"halt":"dirty-tree","files":[…]}`; (3) выбор: явный `--task` (проверить deps) или первый `pending` со всеми deps `done`; нет такого + есть pending → `halt:"dag-stuck"`; все done → `halt:"all-done"`; (4) генерирует `briefs/task-<id>.md`: секции `## Task` (все поля задачи), `## Boundary` (service_path verbatim), `## Interfaces from dependencies` (конкатенация `reports/task-<dep>.md` для всех depends_on), `## Project invariants` (содержимое invariants.md); (5) ответ `data:{"task_id","brief_path","boundary","role","model_class"}`.
- `plan-io.mjs complete <id> --tokens <n>` → status=done, `actual_tokens=<n>` (дельта, не кумулятив), телеметрия-событие `task_complete` c реальным `new Date().toISOString()` в `telemetry/events.jsonl`.
- `plan-io.mjs set-status <id> <pending|in_progress|done|failed>`.
- `plan-io.mjs ledger --task <id> --sha <sha>` → append в `ledger.md`: `Task <id>: complete (<sha>)`. Если ledger.md нет — создать с первой строкой `# Ledger <абс.путь plan.json> sha256:<hash плана>`.
- `plan-io.mjs summary` → `data:{"total","done","pending","failed","phases":{…по level…}}` — для гейта план→build.

- [ ] **Step 1: фикстура** `tests/fixtures/plan-3tasks.json` — минимальный валидный план: task-001 (role backend-implementer, service api, service_path `app`, deps []), task-002 (deps [task-001]), task-003 (deps [task-002]); один с невалидным вариантом рядом в тесте (циклическая зависимость) генерируется тестом на лету.
- [ ] **Step 2: тест:** (a) validate фикстуры → ok; validate с циклом → errors; validate с files вне service_path → errors; (b) next в tmp-git с фикстурой → task-001, brief-файл существует и содержит `## Boundary`; (c) после `set-status task-001 done` + report-файла → next даёт task-002, его brief содержит текст report'а task-001; (d) interrupt-файл → halt interrupt; (e) грязный файл вне state → halt dirty-tree; (f) complete → status done в plan.json, событие в events.jsonl с полем ts ISO-формата; (g) ledger дважды → две строки, заголовок один.
- [ ] **Step 3:** FAIL → **Step 4: реализация** (~250 строк node, без зависимостей; каждый подпункт — прямой перенос контракта выше; никакого чтения plan.json кем-либо кроме этого скрипта в рантайме пайплайна).
- [ ] **Step 5:** PASS. **Step 6: Commit** `feat: plan-io deterministic plan/ledger/brief IO`

---

### Task 8: lib/validate-task.sh и lib/review-package.sh

**Files:** Create: `lib/validate-task.sh`, `lib/review-package.sh`, `tests/lib/validate-task.test.sh`, `tests/lib/review-package.test.sh`

**Interfaces:**
- `validate-task.sh <task-id> --boundary <path> --files <csv>` → запускает `.claude/state/ci-mirror.sh` (генерирует bootstrap; контракт: набор строк-команд, выполняются по порядку, первая ошибка = fail с её stdout-хвостом ≤ 40 строк); затем boundary-check: `git diff --name-only HEAD` + staged — все файлы обязаны быть под boundary или в `.claude/state`; затем сверка фактических изменённых файлов с заявленным списком (`--files`) — расхождение = violation `undeclared-files` / `missing-declared`. `data:{"violations":[{"check":"ci|boundary|declared","detail":…}]}`; ok:true при пустом списке.
- `review-package.sh <task-id> --base <sha>` → пишет `.claude/state/review/task-<id>.md`: список коммитов base..HEAD + `git diff --stat` + полный дифф (unified). Печатает `data:{"path":…}`.

- [ ] **Step 1: тесты.** tmp-git: ci-mirror.sh-фикстура из `true`/`false` команд; кейсы: чистый прогон → ok; падающая команда → violation ci; файл вне boundary → violation boundary; не заявленный файл → undeclared-files. Для review-package: два коммита → файл содержит оба subject и дифф.
- [ ] **Step 2:** FAIL → **Step 3: реализация** → **Step 4:** PASS. **Step 5: Commit** `feat: validate-task and review-package scripts`

---

### Task 9: mvp:brief (SKILL.md + scripts)

**Files:** Create: `skills/brief/SKILL.md`, `skills/brief/scripts/package-brief.sh`

**Interfaces:**
- Consumes: `lib/gate.sh brief`, `lib/brief-contract.sh`, `lib/finalize.sh brief`.
- Produces: `project_brief/{business_logic.md,technical_solutions.md,glossary.md,analysis_grey_zones.md}` + `project_brief.raw/`; state.json phase=`brief-done`.

- [ ] **Step 1: scripts/package-brief.sh** — детерминированные под-операции, которые в v1 были inline-bash (это тот код, где жил awk-баг): `discover [path]` (поиск кандидатов-исходников по стандартным локациям, JSON-список), `skeleton <dir>` (создание tmp-структуры со всеми обязательными заголовками из brief-contract + auto-`## Layout` через `layout_for_stack`; подсчёт сервисов — `grep -c '^- '` ТОЛЬКО внутри секции Services, выделенной awk-флагом как в `export-brief-decisions.sh` v1, НЕ range-паттерном), `swap <tmpdir>` (atomic mv + `.bak.<ts>`), `archive` (no-clobber move исходников в raw, dotglob, pre-check коллизий → JSON-список конфликтов вместо exit 1).
- [ ] **Step 2: SKILL.md.** Frontmatter: `name: brief`, `description: Use when starting the MVP pipeline on a fresh project from raw idea/description files (any format) that need packaging into project_brief/`. Тело (цель ≤ 8 КБ):
  - Announce; Iron Law: **«Стек не выбирается за оператора»**.
  - Шаги: 1) `lib/gate.sh brief` (обработка `recovery:archive-only`); 2) discover → если кандидатов > 1, выбор через AskUserQuestion (options = пути); 3) LLM-упаковка содержимого в skeleton (единственное творческое место: раскладка фактов по секциям; **не выдумывать факты**); 4) Stop&Ask по стеку при любом из 4 триггеров: не в allowlist / не указан / противоречив / неоднозначен — вопрос с options из allowlist; 5) `package-brief.sh swap` + `archive` (конфликты → AskUserQuestion: перезаписать/переименовать/прервать); 6) git Stop&Ask если репо нет («git init?» / SKIP); 7) `state.sh set phase brief-done`; 8) `lib/finalize.sh brief` (msg: `chore: package project brief`).
  - Recreate существующего brief — только через Stop&Ask, atomic через `.bak.<ts>`.
  - Rationalization table (вербатим v1-эмпирика): «Стек очевиден из упоминаний библиотек — выберу сам» → «v1 требовал Stop&Ask даже здесь: выбор за тебя ломал доверие к пайплайну»; «Посчитаю сервисы прямо в чате» → «awk-однострочник в v1 всегда возвращал мусор — считает только package-brief.sh».
  - HARD-GATE: показать оператору что куда легло + распознанный стек → подтверждение → «**NEXT:** Use mvp:clarify».
- [ ] **Step 3: проверка** — `mvp:brief` виден в списке скиллов; `bash tests/run.sh` зелёный. **Step 4: Commit** `feat: mvp:brief skill`

---

### Task 10: mvp:clarify (SKILL.md + references + queue-check)

**Files:** Create: `skills/clarify/SKILL.md`, `skills/clarify/references/queue-schema.md`, `skills/clarify/references/refute-prompt.md`, `skills/clarify/scripts/queue-check.sh`

**Interfaces:**
- Produces: `project_brief/clarify_queue.jsonl` (схема ниже), обновлённый brief, state.json: `pending_critical`, `pending_total`, `auto_closed_critical`, phase=`clarify-done`.
- Схема записи очереди (queue-schema.md, verbatim): `{id, summary, evidence[], severity: critical|medium|low, category, options[], recommended_v1, rationale_v1, self_critique:{verdict, reason}, recommended, rationale, status: pending|answered_human|answered_auto|applied|skipped, source}`. **Инвариант: options[0] === recommended.**

- [ ] **Step 1: scripts/queue-check.sh** — детерминированная сверка перед finalize: каждая запись `answered_*` обязана иметь статус `applied` (переводится скиллом после правки brief); `data:{"unapplied":[ids],"counts":{critical:…,…}}`; обновляет state.json счётчики. Тест — в том же файле скилла не нужен, добавить кейс в `tests/lib/` по образцу остальных.
- [ ] **Step 2: references/refute-prompt.md** — перенос refute-промпта v1 (5 пунктов опровержения + примеры хорошего/плохого критика) из `~/.claude/skills/clarify-mvp/SKILL.md`; шапка «Load when: running self-critique pass».
- [ ] **Step 3: SKILL.md.** Frontmatter: `name: clarify`, `description: Use after mvp:brief to audit project_brief/ for gaps, contradictions and grey zones before bootstrap`. Тело (≤ 10 КБ):
  - Iron Law: **«Не выдумывай факты и не выдумывай дыры; каждая находка обязана иметь evidence-цитату из brief»**.
  - Шаги: 1) gate; 2) resume-check: очередь существует → продолжить с pending (никакого --force); 3) аудит brief → находки в очередь (pass 1: formulate); 4) self-critique (pass 2: refute по references/refute-prompt.md) — **critical+medium всегда, low только в режиме hard**; sanity: changed_rate==0 на ≥5 находках → предупредить оператора; 5) показать цифры находок по severity → оператор выбирает режим (auto/light/medium/hard = кто отвечает); 6) вопросы оператору батчами AskUserQuestion согласно режиму, остальное — answered_auto с recommended; 7) применить ответы к brief, статус → applied; 8) `queue-check.sh` (unapplied непуст = fail, чинить, не коммитить); 9) `state.sh set …` счётчики + phase; 10) `finalize.sh clarify`.
  - Red flags: «Помечу applied заранее, всё равно сейчас применю» → «crash между answered и applied в v1 молча терял решения»; «Low-находки тоже прогоню через refute» → «в v1 это жгло десятки тысяч токенов на вопросы, не влияющие на код».
  - HARD-GATE: очередь вопросов оператору по режиму; «**NEXT:** Use mvp:bootstrap».
- [ ] **Step 4:** тест queue-check зелёный; skill виден. **Step 5: Commit** `feat: mvp:clarify skill`

---

### Task 11: mvp:bootstrap (SKILL.md + scripts + templates)

**Files:**
- Create: `skills/bootstrap/SKILL.md`, `skills/bootstrap/scripts/check-meta.sh`
- Move+edit: `~/.claude/agents/templates/*` → `skills/bootstrap/templates/`; `assemble-agent.sh`, `verify-agents-drift.sh` из v1 bootstrap-mvp/scripts → `skills/bootstrap/scripts/`

**Interfaces:**
- Produces: `CLAUDE.md`, `ARCHITECTURE.md`, `.claude/agents/*`, `.claude/state/` skeleton, `.claude/state/invariants.md`, `.claude/state/ci-mirror.sh` (потребляет validate-task.sh), phase=`bootstrap-done`.

- [ ] **Step 1: перенос шаблонов** (`git mv`-семантика: копия в плагин, удаление источника — в Task 19). Очистка: `grep -rn vireo templates/` → каждое вхождение заменить плейсхолдером `{{PROJECT}}` / `{{SERVICE_*}}` (подстановка — в assemble-agent.sh из brief'а); повторить grep → пусто. В шаблонах агентов зафиксировать: `tools: Read, Edit, Write, Bash` (без Skill), блоки статус-контракта.
- [ ] **Step 2: scripts/check-meta.sh** — детерминированные гейты LLM-выходов: CLAUDE.md ≤ 150 строк + обязательные секции (Стек, Команды, Правила); ARCHITECTURE.md — mermaid-lint: запрещённые рёбра из invariants.md (строки вида `FORBIDDEN_EDGE: integration-* --> (DB|PG)`) грепаются по диаграмме → violation. JSON-контракт.
- [ ] **Step 3: SKILL.md.** `name: bootstrap`, `description: Use after mvp:clarify to generate project meta-files, agents and state from a validated brief`. Тело:
  - Шаги: 1) `gate.sh bootstrap` (внутри — non-emptiness + pending_critical; при override оператора показать `auto_closed_critical`); 2) `state.sh init` + skeleton state-каталогов; 3) генерация **invariants.md** из brief'а (архитектурные инварианты, границы сервисов, FORBIDDEN_EDGE-строки) и **ci-mirror.sh** (команды линта/тестов стека — из брифа/шаблона стека); 4) сборка агентов `assemble-agent.sh` + `verify-agents-drift.sh` (byte-substring, НЕ ослаблять — перенести предупреждение из v1 verbatim); 5) LLM: CLAUDE.md, ARCHITECTURE.md; 6) `check-meta.sh` — fail → правка → повтор (макс 2, затем Stop&Ask); 7) phase + `finalize.sh bootstrap`.
  - Iron Law: **«Уроки прогонов попадают в invariants.md проекта, не в плагин»** (v1: vireo-фичи проросли в глобальные промпты).
  - HARD-GATE: показать сгенерированные мета-файлы → подтверждение → «**NEXT:** Use mvp:plan».
- [ ] **Step 4:** `grep -ri vireo skills/ lib/` пуст; tests зелёные. **Step 5: Commit** `feat: mvp:bootstrap skill with project invariants channel`

---

### Task 12: mvp:plan (SKILL.md + schema + validate-plan.py)

**Files:** Create: `skills/plan/SKILL.md`, `skills/plan/references/plan-schema.json`, `skills/plan/scripts/validate-plan.py`

**Interfaces:**
- Consumes: invariants.md, brief, мета-файлы; `plan-io.mjs validate`, `summary`.
- Produces: `.claude/state/plan.json` (схема ниже), `PROJECT_PLAN.md`, phase=`plan-done`.
- plan-schema.json (required-поля задачи, verbatim): `id, title, level, service, service_path, role, files, depends_on, estimate_tokens, status, complexity_class`. `estimate_tokens ≤ 25000`. Поля `blocks` НЕТ. role ∈ {backend-implementer, frontend-implementer, test-writer, devops-engineer, integration-specialist}.

- [ ] **Step 1: validate-plan.py** — обёртка: зовёт `plan-io.mjs validate --schema references/plan-schema.json` + доп. проверки уровня плана: каждая задача с ролью frontend-* имеет в DAG предшествующий backend-контракт если files содержат api-клиент (эвристики по **полям** задач, не по подстрокам названий); суммарный estimate; JSON-контракт. Тест на фикстуре plan-3tasks.
- [ ] **Step 2: SKILL.md.** `name: plan`, `description: Use after mvp:bootstrap to produce plan.json (task DAG) and PROJECT_PLAN.md`. Тело:
  - Iron Law: **«Каждый гейт плана — скрипт, не намерение»**.
  - Шаги: 1) gate (+recovery finalize-plan); 2) диспатч планнер-субагента: промпт из секции «Planner prompt» ниже по файлу, передаются ПУТИ (brief, invariants.md, ARCHITECTURE.md) — не содержимое; требования: молекулы ≤ 25k, hybrid boundary (service HARD / files HINT), complexity_class на каждой задаче, фазы выводить из brief (никаких предзаданных фич); 3) `validate-plan.py` → fail: один re-dispatch с текстом ошибок → снова fail: Stop&Ask; 4) PROJECT_PLAN.md (человекочитаемая сводка из `plan-io.mjs summary`); 5) phase + `finalize.sh plan`.
  - Секция «Planner prompt» — полный текст промпта планнера (перенос из v1 plan-mvp Шаг 2 С УДАЛЕНИЕМ vireo-фаз и fastapi-хардкода; фазы и терминология — из brief/invariants).
  - HARD-GATE (главный гейт пайплайна): вывести summary (фазы, число задач, оценки) → **build стартует только явной командой оператора**. «**NEXT:** Use mvp:build».
- [ ] **Step 3:** тесты зелёные. **Step 4: Commit** `feat: mvp:plan skill with scripted validation`

---

### Task 13: mvp:build — agents/*.md (диспатч-промпты)

**Files:** Create: `skills/build/agents/{implementer.md,validator.md,reviewer.md,fix.md,re-review.md}`

**Interfaces:**
- Produces: шаблоны с плейсхолдерами `{{BRIEF_PATH}}, {{BOUNDARY}}, {{TASK_ID}}, {{REPORT_PATH}}, {{PACKAGE_PATH}}, {{VIOLATIONS}}, {{FINDINGS}}` (блок Placeholders внизу каждого файла). Контракты — консюмит workflow.mjs (Task 14).

Обязательное содержимое (по образцу superpowers SDD: `subagent-driven-development/implementer-prompt.md` и `task-reviewer-prompt.md`):
- **implementer.md**: читай {{BRIEF_PATH}} первым — это твои требования; HARD boundary {{BOUNDARY}} (файлы вне — запрещены, кроме .claude/state/reports/); TOKEN EFFICIENCY (батч Read/Write, без re-Read, suppress verbose flags); пиши код + прогоняй `bash .claude/state/ci-mirror.sh` до зелёного; запиши `{{REPORT_PATH}}` — интерфейс-дайджест (создание/изменение эндпоинтов, типов, экспортов — то, что нужно зависимым задачам); финал ≤ 15 строк: `STATUS: DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT` + `FILES:` список. «You Do Not Dispatch Subagents»; «Never silently produce work you're unsure about — use BLOCKED/NEEDS_CONTEXT».
- **validator.md** (вызывается только при violations от validate-task.sh): вход {{VIOLATIONS}}; суди; для тривиальных фиксов (unused import, форматирование) верни `PATCHES: <json>` (формат apply-patches); иначе `VERDICT: retry|park` + причина. Read-only к продуктовым файлам.
- **reviewer.md**: читай {{PACKAGE_PATH}} (дифф) и {{BRIEF_PATH}}; **Do Not Trust the Report** — отчёт implementer'а это unverified claims; каждый finding: severity ∈ {bug, security, pattern-violation, minor} + **обязательные file:line + цитата кода**; не перегоняй тесты (validate-скрипт уже прогнал); финал: `VERDICT: approve|request-changes` + `FINDINGS: <json>`; тривиальные фиксы — `PATCHES:`.
- **fix.md**: scoped-фикс по {{FINDINGS}} внутри {{BOUNDARY}}, ничего кроме; тот же статус-контракт.
- **re-review.md**: строго по списку {{FINDINGS}}: каждому `ADDRESSED|NOT ADDRESSED`; новое вне списка → секция Out-of-Scope (не блокирует).

- [ ] **Step 1:** написать все 5 файлов. **Step 2:** self-check: у каждого есть блок Placeholders и явный контракт финальной строки. **Step 3: Commit** `feat: build dispatch prompt templates`

---

### Task 14: mvp:build — workflow.mjs

**Files:** Create: `skills/build/workflow.mjs`, `tests/fixtures/dryrun/` (синтетический git-репо: ci-mirror.sh из `true`, план 2 задач роли general)

**Interfaces:**
- Consumes: `plan-io.mjs`, `validate-task.sh`, `review-package.sh`, `apply-patches.py`, `finalize.sh`, `agents/*.md`.
- Produces: workflow, запускаемый `Workflow({scriptPath, args:{run_id, now, max_tasks, task_id?, plugin_root}})`.

Структура (полный перенос семантики спеки §6.5; ~300 строк):

```js
export const meta = { name: 'mvp-build', description: 'DAG task loop: advance→implement→validate→review→finalize', phases: [...] }
// 0) fail fast: run_id, now, plugin_root обязательны — иначе throw до первого agent()
// relay(cmd): agent(`Run exactly: ${cmd}\nReturn the LAST stdout line verbatim.`,
//   {model:'haiku', effort:'low', schema:{type:'object',properties:{line:{type:'string'}},required:['line']}})
//   → JSON.parse(line); relay никогда не получает содержимое файлов данных.
// Цикл while (tasksDone < args.max_tasks):
//   adv = relay(`node ${lib}/plan-io.mjs next${args.task_id?` --task ${args.task_id}`:''}`)
//   if (adv.data.halt) → halt(adv.data.halt)   // all-done|dag-stuck|interrupt|dirty-tree
//   impl = agent(implementerPrompt(adv.data), {model: adv.data.model_class==='novel-design'?'opus':'sonnet', agentType: adv.data.role})
//   switch STATUS: BLOCKED|NEEDS_CONTEXT → park(adv.data, impl) ; DONE|DONE_WITH_CONCERNS → дальше (CONCERNS → в ledger Ruling)
//   val = relay(`bash ${lib}/validate-task.sh ${id} --boundary ... --files ...`)
//   if (!val.ok): вердикт валидатора (agents/validator.md) → PATCHES → workflow пишет patches.json
//     СВОИМ агентом через Write (не heredoc!) → relay apply-patches --stage → re-run validate-task
//     → иначе ОДИН retry implementer (opus, с текстом violations) → re-validate → иначе park
//   rp = relay(`bash ${lib}/review-package.sh ${id} --base ${baseSha}`)
//   rev = agent(reviewerPrompt(...), {model:'sonnet'})
//   if request-changes: PATCHES-путь как выше → иначе fix-dispatch (agents/fix.md) →
//     re-review (agents/re-review.md, только вердикты) → NOT ADDRESSED остались → park
//   fin = relay(`node ${lib}/plan-io.mjs complete ${id} --tokens ${delta} && bash ${lib}/finalize.sh build-task msgfile --files ...`)
//   relay(`node ${lib}/plan-io.mjs ledger --task ${id} --sha ${fin.data.sha}`)
//   tasksDone++; if (args.task_id) break
// park(task, why): relay(`git checkout -- <boundary> && git restore --staged <boundary>`),
//   ledger `Parked: …`, запись blockers.md через relay-скрипт, halt('stop-and-ask')
// Все halt → return {halt, task_id?, detail} — основная сессия разбирает.
// Числа: retry implementer = 1; total attempts per task = 2; re-review циклов = 1.
```

- [ ] **Step 1: dry-run фикстура** `tests/fixtures/dryrun/`: скрипт `make-dryrun.sh` создаёт tmp-git с планом 2 задач (role: `general-purpose`, tasks: «создай файл a.txt с текстом X» — задачи, которые implementer решает тривиально), ci-mirror.sh = `true`.
- [ ] **Step 2:** написать workflow.mjs по структуре выше.
- [ ] **Step 3: dry-run:** из фикстуры запустить Workflow → обе задачи закоммичены, ledger содержит 2 строки `Task …: complete`, events.jsonl — 2 `task_complete` с разными реальными ts, дельты токенов различаются (не кумулятив). Найденные несоответствия чинить и повторять.
- [ ] **Step 4: Commit** `feat: build workflow v2 with relay IO`

---

### Task 15: mvp:build — SKILL.md

**Files:** Create: `skills/build/SKILL.md`

- [ ] **Step 1:** `name: build`, `description: Use when .claude/state/plan.json exists and implementation should proceed`. Тело (≤ 12 КБ):
  - Iron Law: **«LLM думает — скрипты двигают данные»**.
  - Preconditions: `gate.sh build`; парсинг аргументов (`--tasks N`, `--task <id>`, токен-потолок `+NNNk` — прямо в args Workflow, валидируются workflow'ом fail-fast).
  - Запуск: `Workflow({scriptPath: <plugin>/skills/build/workflow.mjs, args:{run_id, now, max_tasks, task_id, plugin_root}})` — run_id/now генерятся здесь (модель) и передаются один раз.
  - Halt-таблица: причина → действие основной сессии (all-done → NEXT retro; stop-and-ask → AskUserQuestion с контекстом из blockers.md, решение в decisions.log, перезапуск; dirty-tree → показать файлы, предложить reset; budget → отчёт и стоп; interrupt → подтвердить).
  - «Rulings, not stalls»: закрытый список Stop&Ask из спеки §6.5 verbatim (4 пункта); всё остальное — ruling в ledger.
  - Rationalization table: «План почти валиден, поправлю поле на лету» → «так v1 терял service и валил рабочий код — только plan-io»; «Ревью можно скипнуть, молекула тривиальная» → «7/16 тривиальных молекул baseline содержали реальные баги»; «git add -A, файлов много» → «finalize.sh стейджит explicit-списком, всегда».
  - Red flags: «перепишу этот JSON сам», «вызову git commit напрямую», «запущу второй workflow параллельно».
  - «**NEXT:** Use mvp:retro» (после all-done).
- [ ] **Step 2:** wc -c ≤ 12288. **Step 3: Commit** `feat: mvp:build skill`

---

### Task 16: mvp:resume и mvp:retro

**Files:** Create: `skills/resume/SKILL.md`, `skills/retro/SKILL.md`

- [ ] **Step 1: resume** (≤ 4 КБ). `description: Use to resume an MVP pipeline run from a cold context or after an interruption`. Тело: прочитать `state.sh get phase`, ledger (правило: **задача с complete-строкой не диспатчится повторно**), blockers.md → таблица диспатча: phase brief-done → mvp:clarify … plan-done → гейт build; blockers непуст → AskUserQuestion → decisions.log → перезапуск build; state.json потерян → восстановить фазу из plan.json/git. Никогда не использовать resumeFromRunId.
- [ ] **Step 2: retro** (≤ 4 КБ). `description: Use after a finished mvp:build run to harvest telemetry into template and skill improvements`. Тело: читать `telemetry/events.jsonl` (только реально существующие поля: ts, task, delta tokens, ms, attempts, halt, validator/review классы) → выход: кандидаты в rationalization-таблицы (вербатим), правки шаблонов, калибровка коэффициента workflow-токен→$, observation-файл в `<plugin>/docs/observations/<date>-<project>.md`.
- [ ] **Step 3: Commit** `feat: resume and retro gate skills`

---

### Task 17: перенос observations + финальная проверка репо плагина

- [ ] **Step 1:** `mv ~/.claude/playbooks/observations/* → docs/observations/` (включая vireo-baseline).
- [ ] **Step 2:** полный прогон `bash tests/run.sh` → всё PASS; `grep -ri vireo lib skills` → пусто; wc -c всех SKILL.md в пределах лимитов; description каждого — триггер без workflow.
- [ ] **Step 3: Commit** `chore: migrate observations, full test pass`

---

### Task 18: vireo — зачистка и живой прогон brief→plan

**Files (в `~/Documents/Pet/vireo`):** Delete: `.claude/state/`, `.claude/agents/`, `CLAUDE.md`, `ARCHITECTURE.md`, `project_brief/`, `PROJECT_PLAN.md` (если есть). Остаётся: `project_brief.raw/`, git-история.

- [ ] **Step 1:** зачистка (явные `git rm`/rm по списку; `git status` до и после; коммит `chore: reset for pipeline v2 rerun`).
- [ ] **Step 2:** `mvp:brief` на `project_brief.raw/` → гейт оператора.
- [ ] **Step 3:** `mvp:clarify` → вопросы по режиму → гейт.
- [ ] **Step 4:** `mvp:bootstrap` → проверка: invariants.md и ci-mirror.sh существуют, verify-agents-drift зелёный, grep vireo в `.claude/agents` находит ТОЛЬКО подстановки из brief'а (не из шаблонов) → гейт.
- [ ] **Step 5:** `mvp:plan` → validate-plan зелёный → показать summary → гейт. Фиксация наблюдений этапов в `docs/observations/`.

---

### Task 19: vireo — build smoke и зачистка v1

- [ ] **Step 1:** `mvp:build --tasks 2` → обе задачи: commit есть, ledger-строки есть, events.jsonl с реальными ts и per-task дельтами (ручная проверка).
- [ ] **Step 2:** любой parking/halt — разобрать по halt-таблице, зафиксировать в observations.
- [ ] **Step 3: зачистка v1** (только после успешного Step 1): удалить из `~/.claude/skills/`: prepare-mvp, clarify-mvp, bootstrap-mvp, plan-mvp, execute-mvp, continue-mvp, analyze-telemetry, refresh-graph, managing-agents, verification-before-completion, git-commit-contract; удалить `~/.claude/playbooks/` целиком; удалить `~/.claude/agents/templates/` (перенесены). Проверить: глобальный `~/.claude/CLAUDE.md` и RTK.md не ссылаются на удалённые пути (при ссылках — предложить оператору правку).
- [ ] **Step 4: память:** переписать `feedback-mvp-pipeline.md` и `feedback-clarify-architecture.md` под v2 (архитектура, пути плагина, Iron Law, ссылки на спеку), обновить `MEMORY.md`.
- [ ] **Step 5:** финальный отчёт по DoD спеки §9, коммит наблюдений в репо плагина.

---

## Self-review (выполнен)

- Spec coverage: §4 анатомия → Tasks 1,9–16; §5 lib → Tasks 2–8; §6.1–6.7 → Tasks 9–16; §7 дисциплина → внутри Tasks 9–16 (таблицы/контракты); §8 миграция → Tasks 11 (templates), 17–19; §9 DoD → Task 19 Step 5. Разрывов нет.
- Placeholder scan: команды и контракты конкретны; крупные реализации (plan-io, workflow) заданы контрактом+тестами+структурой — тесты выступают исполняемой спекой.
- Type consistency: JSON-контракт скриптов един (§Global Constraints); статусы задач pending|in_progress|done|failed сквозные (Tasks 7,14); статусы очереди clarify согласованы (Task 10 ↔ queue-check); плейсхолдеры agents/*.md ↔ workflow.mjs (Tasks 13↔14).
