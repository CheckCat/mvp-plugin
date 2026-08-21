# SDD ledger — plan: /Users/vadim/Documents/tools/claude/mvp-plugin/docs/plans/2026-08-21-mvp-pipeline-v2.md

Branch: pipeline-v2 (base 088ba1b). Spec: docs/specs/2026-08-21-mvp-pipeline-v2-design.md.

## Pre-flight scan (2026-08-21)

| Pair / task | Produces vs consumes | Finding |
|---|---|---|
| T1 run.sh ↔ T2–8 tests | run.sh globs tests/lib/*.test.sh; tasks create there | OK |
| T2 brief-contract ↔ T4 gate, T9 brief | validate_headers, layout_for_stack names match | OK |
| T3 state.sh ↔ T4/T9–T12 | T3 lists phase enum `brief|clarify|…`; consumers use `brief-done`, `bootstrap-done`, `plan-done` | conflict → Ruling R1 |
| T5 finalize ↔ spec §5/§6.5 | plan: `<scope> <msg-file> [--files]`; spec: `<scope> <prefix> <msg-file>` | conflict → Ruling R2 |
| T7 plan-io next ↔ T14 workflow | data keys task_id/brief_path/boundary/role/model_class match (spec §6.5 says `model`) | plan-internal OK → Ruling R3 |
| T8 review-package ↔ spec §5 | plan: `<task-id> --base <sha>`; spec: `<base> <head>` | conflict → Ruling R4 |
| T8 validate-task ↔ T14 | `--boundary/--files` flags match | OK |
| T12 role enum ↔ T14 dryrun fixture | fixture role `general-purpose` not in schema enum | → Ruling R5 |
| T13 placeholders ↔ T14 | {{BRIEF_PATH}} etc. consumed identically | OK |
| T7/T12 | estimate_tokens ≤ 25000, complexity_class enum identical | OK |
| T9 within-task | step 7 `state.sh set phase brief-done` but no `state.sh init` earlier; gate brief требует отсутствия .claude/state | → Ruling R6 |
| T9/T5 | brief finalize preset не стейджит state.json → untracked после brief | → Ruling R7 |
| T1 within-task | Step 5 «новая сессия» недоступна субагенту | → Ruling R8 |
| T2 within-task | тест-кейсы (a)–(e) ↔ приведённый код согласованы | OK |
| T4,T6,T10,T11,T15–T19 | самосогласованы, внешних контрактов не ломают | OK |

## Preflight rulings

- Ruling R1: значения phase — строки вида `<stage>-done` (как у потребителей gate.sh/скиллов); перечисление в T3 — информативное, state.sh значения не валидирует. Цена ошибки: расхождение в тестах gate — правится локально.
- Ruling R2: сигнатура finalize.sh — по плану `<scope> <msg-file> [--files…]`, prefix проверяется по первой строке msg-file. Отдельный аргумент prefix из спеки — дублирующий источник правды. Цена ошибки: переделка CLI-обвязки одного скрипта.
- Ruling R3: ключ называется `model_class` (по плану, T7↔T14 согласованы). Цена ошибки: rename в двух файлах.
- Ruling R4: сигнатура review-package.sh — по плану `<task-id> --base <sha>` (HEAD implied). Цена ошибки: rename флагов.
- Ruling R5: dryrun-фикстура с ролью `general-purpose` не обязана проходить plan-schema (build не ревалидирует план); схема остаётся строгой. Цена ошибки: правка фикстуры при появлении ревалидации.
- Ruling R6: mvp:brief выполняет `state.sh init` перед `set phase brief-done` (init идемпотентен); gate brief проверяется ДО создания state. Внести в диспатч Task 9. Цена ошибки: лишний идемпотентный вызов.
- Ruling R7: незакоммиченный state.json после mvp:brief допустим — его закоммитит clarify (его preset включает state.json). Пресеты T5 не расширяем. Цена ошибки: untracked-файл между фазами.
- Ruling R8: проверка установки в Task 1 — через `claude plugin`-CLI/конфиг-файлы, не через «новую сессию»; финальную видимость скиллов подтверждает контроллер/оператор в Task 18. Цена ошибки: поздно замеченная ошибка установки — ловится до Task 9.

## Progress

- Ruling R9: `claude plugin install` копирует репо в кэш (`~/.claude/plugins/cache/mvp-local/mvp/2.0.0`, пиннится на git sha) — установка НЕ живая ссылка на worktree. Перед Task 18 (и при проверках видимости скиллов в Tasks 9–16, если нужны) обновлять кэш: `claude plugin update mvp@mvp-local` либо reinstall. Проверено контроллером: installed_plugins.json пиннит sha 088ba1b. Цена ошибки: живой прогон на устаревших скиллах — ловится проверкой Task 17/18.
- Task 1: implementer DONE (67b2d87). Review: 1 Important (README 24 строки > лимита 10–15). Fix round 1/5 (1 addressed, 0 open; commits 67b2d87..3c56de4)
- Task 1: minor (deferred): marketplace.json без top-level description — warning `claude plugin validate`; оставлен ради вербатим-соответствия брифу
- Task 1: minor (deferred): README:8 `mvp:resume` без backticks
- Task 1: complete (commits 088ba1b..3c56de4, review clean)
- Task 2: implementer DONE (c4e41d1). Review: Approved + 1 Important plan-mandated (hint в validate_stack без JSON-escape).
- Task 2: Ruling: код validate_stack из плана нарушает спековый JSON-контракт при `"`/`\` во входе — чиним через python3 json.dumps, план в этой букве отменён. Цена ошибки: расхождение с кодом в тексте плана (документировано здесь).
- Task 2: minor (deferred): тест пишет stderr в /tmp/mvp-bc-test-err вне tmpdir, без cleanup
- Task 2: minor (deferred): нет теста validate_headers с multi-word заголовком; callers должны звать validate_headers без word-splitting (интеграционный риск для Tasks 4/9)
- Task 2: minor (deferred): awk/grep вне заявленного deps-списка — унаследовано от v1, POSIX-базовые, принято
- Task 2: fix round 1/5 (1 addressed, 0 open; commits c4e41d1..3a4c299)
- Task 2: minor (deferred): success/fail JSON различаются пробельным стилем (printf compact vs json.dumps) — оба валидны
- Task 2: complete (commits 3c56de4..3a4c299, review clean)
- Task 3: implementer DONE (51d4b37). Review: Approved + 2 Important plan-mandated (traceback при missing argv; неатомарная запись state.json).
- Task 3: Ruling: код state.sh из брифа отменён в двух точках — argv-guard с контрактным JSON и atomic write (tmp+os.replace); спековый контракт важнее буквы плана. Цена ошибки: расхождение с кодом в тексте плана.
- Task 3: minor (deferred): дублирующий `trap EXIT` затирает первый — tmpdir теста утекает; /tmp/state-test-out hardcoded; dead helpers (assert_eq и др.) в state.test.sh
- Task 3: fix round 1/5 (2 addressed, 0 open; commits 51d4b37..f2d6a29)
- Task 3: complete (commits 3a4c299..f2d6a29, review clean)
- Task 4: implementer DONE (faa313b, 274 строки vs «~100» — обосновано). Review: Approved + 1 Important (no-git молча проходит гейты plan/build).
- Task 4: Ruling: без git-репо гейты plan/build обязаны fail (build коммитит каждую задачу через finalize.sh — git обязателен с plan-фазы). Цена ошибки: no-git проекты режутся раньше — это желаемое.
- Task 4: minor (deferred): порядок проверок gate_plan (recovery раньше phase) маскирует wrong-phase в комбинированном случае; 4 из 5 fail-веток brief без индивидуальных тестов
- Task 4: fix round 1/5 (1 addressed, 0 open; commits faa313b..d26d596)
- Task 4: complete (commits f2d6a29..d26d596, review clean)
- Task 5: implementer DONE (829bfc6). Review: Approved + 1 Important (fixed /tmp путь для git-add stderr — race при параллельных finalize). Fix round 1/5 запущен.
- Task 5: minor (deferred): преset-тесты brief/clarify/bootstrap/plan проверяют только exit 0, не состав коммита; single-line-JSON-проверка в тесте фактически no-op цикл; deleted-but-tracked файлы не стейджатся через presets ([[ -e ]] фильтр) — важно если будущая стадия коммитит удаления; v1 stderr-диагностика об out-of-scope staged файлах не перенесена
- Task 5: fix round 1/5 (2 addressed, 0 open; commits 829bfc6..84f3672)
- Task 5: complete (commits d26d596..84f3672, review clean)
- Task 6: implementer DONE (7f3a981). Review: Approved, 0 Important.
- Task 6: minor (deferred): ok:false возможен при пустом failed (git-add fail при --stage) — расширение контракта, не задокументировано и не тестировано; data.applied не дедуплицирован (staged — да); CRLF→LF при успешном патче (universal newlines); undecodable file → label not-found; disk-full mid-run → data:null при частично применённых патчах
- Task 6: complete (commits 84f3672..7f3a981, review clean)
- Task 7: implementer DONE (61a7685, 516 строк). Ruling R11: id задач — bare (`001`, без префикса `task-`); файлы briefs/reports `task-001.md`, ledger `Task 001: complete`. ОБЯЗАТЕЛЬНО согласовать в Task 12 (planner prompt: ids без префикса) и Task 14 (dryrun-фикстура). Цена ошибки: `task-task-001.md` в именах — косметика, но ломает тесты.
- Task 7: review (opus): Needs fixes — C-1 all-done при failed/in_progress; I-1 validate пропускает не-массив tasks; I-2 --schema молча игнорит незнакомый формат; I-3 boundary без нормализации путей; M-1 interrupt-check после чтения plan.json. Fix round 1/5 запущен (все 5).
- Task 7: minor (deferred): дубликаты id не детектятся (M-2); --tokens принимает ''/отрицательные (M-3); next --task без статус-гарда — повторный диспатч done-задачи (M-4); rename-строки porcelain: только destination проверяется, C-quoted пути (M-5); appendTextAtomic = read-modify-write — гонка на events.jsonl/plan.json при параллельных complete, O(n²) (M-6, важно если build когда-то параллелится); writeBrief не использует byId, nested поля → [object Object], пустой Boundary при отсутствии service_path (M-7); coverage-гэпы (M-8); фикстура с доменными названиями Add auth routes (M-9)
- Task 7: fix round 1/5 (5 addressed, 0 open; commits 61a7685..89c6d39)
- Task 7: complete (commits 7f3a981..89c6d39, review clean)
- Task 8: implementer DONE (f23e4ed). Review: Needs fixes — 1 Important (no-op single-line-JSON цикл в обоих тестах, покрыт только последний кейс). Fix round 1/5 запущен; ruling: тот же дефект чинится и в finalize.test.sh (одним классом).
- Task 8: untracked-файлы включены в boundary-check (документированное расширение брифа) — принято.
- Task 8: minor (deferred): нет теста с двумя типами violations в одном вызове; tail-40 граница не проверена (>40 строк вывода)
- Task 8: fix round 1/5 (2 addressed, 0 open; commits f23e4ed..5fbd2cf)
- Task 8: complete (commits 89c6d39..5fbd2cf, review clean). lib/ полностью готов.
- Task 9: implementer DONE (c69ac65). Review: Needs fixes — 1 Important (Step 4: replace-vs-append неоднозначность для ## Stack при first-match-wins экстракторе). Fix round 1/5 запущен.
- Ruling R12 (forward): конвенция Stack-секции `- key: value` парсится ТОЛЬКО package-brief.sh (`_extract_stack_value`, first-match-wins) — Tasks 10/11 (clarify/bootstrap) обязаны переиспользовать этот парсер/конвенцию, не изобретать свой. Цена ошибки: расхождение парсеров стека между стадиями.
- Task 9: minor (deferred): Step 8 (finalize) без step-specific ok:false ветки (генерик-правило покрывает, но последний шаг); SKILL.md 8314 B — чуть выше soft 8KB; archive dest hardcoded project_brief.raw
- Task 9: fix round 1/5 (1 addressed, 0 open; commits c69ac65..f5e46ca)
- Task 9: complete (commits 5fbd2cf..f5e46ca, review clean)
- Task 10: implementer DONE (4845ad4). Review: Needs fixes — Critical (null recommended у low-записей вне hard + human-override десинхронизирует инвариант options[0]===recommended), Important×2 (prose-counting в Step 5; несуществующее поле answer). Fix round 1/5 запущен.
- Task 10: Ruling R13: recommended никогда не null — skip-refute записи получают recommended_v1 + verdict skipped; ответ оператора пишется в recommended с реордером options; поля answer нет в схеме. Цена ошибки: аудит-трейл recommended_v1 vs recommended остаётся достаточным.
- Task 10: minor (deferred): queue-check.sh ловит только JSONDecodeError вокруг чтения файла (PermissionError → traceback); 3 отдельных python3-спавна для state.sh set
- Task 10: fix round 1/5 (3 addressed, 0 open; commits 4845ad4..cc3b21d). SKILL.md 10235/10240 B — при любой правке проверять wc -c.
- Task 10: complete (commits f5e46ca..cc3b21d, review clean)
- Task 11: implementer DONE (29a2336, 17 файлов). Review: Needs fixes — 1 Important (mermaid-lint не скипает %% комментарии → false-positive Stop&Ask). Fix round 1/5 запущен.
- Task 11: {{PROJECT}} по умолчанию из имени каталога проекта (env-override) — принято, задокументировано.
- Task 11: minor (deferred): drift-warning не байт-в-байт verbatim (стухшая ссылка обновлена — оправдано); SKILL.md 10193/10240 B; ci-mirror.sh генерится LLM без валидирующего скрипта — детерминизм-гэп, закрыть позже если validate-task увидит кривые команды
- Task 11: fix round 1/5 (1 addressed, 0 open; commits 29a2336..379997f)
- Task 11: complete (commits cc3b21d..379997f, review clean)
- Task 12: implementer DONE (07daf7e). Review: Needs fixes — 1 Important (Planner prompt не задаёт top-level форму plan.json `{"tasks":[…]}`). Fix round 1/5 запущен.
- Ruling R9-обновление: `claude plugin update` НЕ обновляет dir-source кэш — нужен uninstall+reinstall (`claude plugin uninstall mvp@mvp-local && claude plugin install mvp@mvp-local`). Учесть в Task 17/18.
- Task 12: minor (deferred): FALLBACK_ROLE_ENUM — ручная копия enum'а из схемы (drift-footgun); compact-substring ветка is_api_client_path; argv-guard тест не покрывает `--schema` без значения; rationalization table тонкая (2 строки vs 10 у v1)
- Task 12: fix round 1/5 (1 addressed, 0 open; commits 07daf7e..e7053bd)
- Task 12: complete (commits 379997f..e7053bd, review clean)
- Task 13: implementer DONE (e97cf62). Review: Needs fixes — Important×3 (reviewer.md без явного Read отчёта; re-review теряет severity в выходной FINDINGS-форме; нет гайда на неполный дифф). Fix round 1/5 запущен.
- Task 13: minor (deferred): reviewer.md хардкодит report-путь вместо {{REPORT_PATH}} (принято — единая деривация)
- Task 13: fix round 1/5 (3 addressed, 0 open; commits e97cf62..1f8206f)
- Task 13: complete (commits e7053bd..1f8206f, review clean)
- Ruling R14: dry-run Task 14 Step 3 исполняет КОНТРОЛЛЕР через Workflow tool основной сессии (субагенту Workflow может быть недоступен/вложен); implementer сдаёт workflow.mjs + фикстуру. Цена ошибки: лишний цикл обратной связи контроллер→implementer.
- Task 14: implementer DONE (bc32c38; +additive files в plan-io next). Review (opus): Needs fixes — Critical×3 (export default не исполняется в Workflow-sandbox; park() падает на JSON.parse(""); review-package диффит base..HEAD → пустой ревью-дифф), Important×5 (token delta без implementer'а; request-changes с пустыми findings → approve; failed patch на review-пути финализируется; park не чистит untracked; agentType fallback на throw вместо null). Fix round 1/5 запущен со всеми + ruled minors.
- Task 14: Ruling R15: review-package.sh переделан на base→worktree дифф (uncommitted+untracked с содержимым, cap 400 строк/файл) — авторизованное cross-file изменение. Цена ошибки: больше содержимого в ревью-пакете.
- Task 14: Ruling R16: relay-retry только для идемпотентных команд; finalize/apply-patches — single attempt, parse-fail → halt error. Цена ошибки: чуть больше halt'ов вместо тихих повторов.
- Task 14: Ruling R17: halt-словарь: all-done|dag-stuck|interrupt|dirty-tree|stop-and-ask|bad-args|error; все throw-пути → {halt:'error'}. Внести в halt-таблицу Task 15.
- Task 14: minor (deferred): пустой declaredFiles → `--files` без значения (schema-guarded)
- Task 14: fix round 1/5 (13 addressed, 0 open; commits bc32c38..ef2b58e). Re-review: чисто; halt:null = tasks-cap успех (учесть в Task 15); untracked-листинг review-package repo-wide.
- Task 14: Ruling R18: entry-point `export default await (async()=>{...})()` — эмпирически недоказуем чтением; решает dry-run контроллера. Цена ошибки: round 3 с top-level return + отказ от node --check для этого файла.
- Task 14: Ruling R19 (round 2): опциональный args.project_root (cd-префикс в relay, явный working-dir в промптах агентов) — без него dry-run исполнялся бы в cwd контроллера (vireo!). Цена ошибки: чуть длиннее промпты.
- Task 14: round 2 complete (d6e25e6, project_root). Dry-run попытка №1: runner отверг `export default` (SyntaxError) → R18 разрешён эмпирически: meta export + top-level async body + top-level return; node --check неприменим к workflow.mjs (заменён AsyncFunction-проверкой). Round 3 запущен.
- Task 14: round 3 complete (9aade60, top-level return; node --check → AsyncFunction-проверка). Dry-run №2: скрипт принят, но args доставлены строкой → bad-args. Round 4 запущен (string-coerce).
- Task 14: Ruling R20: fix-раунды 4+ продолжают ТОГО ЖЕ implementer'а вопреки правилу эскалации модели — цикл не застрял (каждый раунд закрывает 100% находок, новые — интеграционные открытия dry-run'а, не непонимание). Цена ошибки: ещё раунд без эскалации.
- Task 14: round 4 complete (69dd17a, string-args coerce). Dry-run №3 (wf_c899df53-87f): SUCCESS — 2 задачи, 18 агентов, 0 ошибок; коммиты 226908e/60278eb, ledger header+2 строки, events.jsonl реальные разные ts, дельты 5015/3900. Acceptance плана Step 3 выполнен.
- Task 14: complete (commits 1f8206f..69dd17a, 4 fix-раунда, dry-run verified)
- Task 15: implementer DONE (f41fff4+2358b3c). Review: Needs fixes — 1 Important (partial-results каveat только в 1 из 5 затронутых halt-строк). Fix round 1/5 запущен.
- Task 15: minor (deferred, workflow-гэпы найденные implementer'ом): dirty-tree halt теряет files-список (workflow пропагирует только detail — SKILL fallback git status); halt'ы без частичных results (SKILL fallback ledger/git log); dag-stuck строка утверждает про обход status-фильтра при явном task_id — не перепроверено
- Task 15: fix round 1/5 (1 addressed, 0 open; commits 2358b3c..278b8f3)
- Task 15: complete (commits 69dd17a..278b8f3, review clean)
- Task 16: implementer DONE (b59c9c7+2f463a8). Review: Approved, 0 Important. Оба файла 4091/4096 B.
- Task 16: complete (commits 278b8f3..2f463a8, review clean)
- Task 17: implementer DONE (28cdc13, 31 файл, source пуст). Review: Approved.
- Task 17: complete (commits 2f463a8..28cdc13, review clean). Плагин-репо готов: Tasks 1–17.
- Task 17: minor (deferred): plan (43 B) и resume/retro (5 B) headroom до хард-капов — при будущих правках сначала wc -c
## Final review (opus, 088ba1b..28cdc13)

- Вердикт: With fixes. C1 (files-HINT vs exhaustive enforcement — трёхфайловый конфликт), C2 (_common.md — непортированный v1), I1 (park clean wipe при boundary='.'), I2 (ci-mirror без валидатора), I3 (finalize пропускает deleted-tracked), I4 (мертвые validator/code-reviewer агенты), I5 (спека телеметрии шире реальности), M1/M4/M5. Seams 1–13 чистые.
- Fix wave (один диспатч, opus): 55bcb4d + 74f209e + e32c00d — все 9 findings ADDRESSED (re-review sonnet, 13/13 тестов).
- Ruling R21 (C1): declared-only violations → concerns, не блок; finalize стейджит boundary. Цена ошибки: недекларированный мусор в коммите задачи — ловится ревьюером.
- Ruling R22 (I4): validator/code-reviewer шаблоны удалены; bootstrap собирает только 5 role-агентов. Цена ошибки: если будущий workflow захочет agentType-валидатора — вернуть из git-истории.
- Ruling R23 (I5): спека ужата до реальной телеметрии (task_complete only), остальное — «future». Цена ошибки: нет.
- Parked: park() checkout/restore при boundary='.' затрагивает tracked .claude/state — Ruling: bounded (set-status failed перезаписывает plan.json после reset; потеря trailing ledger-строки толерируется resume по дизайну). Follow-up pathspec-исключение — в backlog.
- Parked: skills/brief/SKILL.md:48 упоминает ~/.claude/agents/templates как сигнал — Ruling: удалить одной строкой в Task 19 (когда путь умрёт).
- Parked: root-boundary finalize стейджит всё дерево — Ruling: согласовано с validate-scope, принято.
- Parked (deferred из final review): M2 (хвост ledger/phase не закоммичен в конце run — resume толерирует), M3 (archive-only recovery не видит каталоги-источники), M6 (review-package инлайнит свой прошлый пакет при re-review, cap 2×), M7 (next --task без статус-гарда — РЕКЛАССИФИЦИРОВАН как intentional: на нём держится dag-stuck recovery в build SKILL), M8 (дубликаты id не детектятся — дёшево добавить в validate-plan.py позже).

- Final review: clean после fix wave. Регрессионный dry-run wf_6e5c2e7b-5fb: SUCCESS (2 задачи, 18 агентов, 0 ошибок, дельты 5280/4032). Ветка pipeline-v2 готова к merge (merge — в самом конце, после Tasks 18–19).
- Task 18 start: reinstall плагина (кэш на e32c00d), wipe vireo, live run brief→plan с операторскими гейтами (AskUserQuestion реальному пользователю).

- Task 18: complete (vireo: wipe 159b08a → brief 7c60ef0 → clarify edb4f58 → bootstrap 681c752 → plan 4147fac; все операторские гейты прожиты вживую; наблюдения 53eb74e в плагине). Ruling R24: archive no-op при SOURCE==project_brief.raw (rerun-кейс) — вопрос overwrite/rename/abort оператору бессмыслен; кандидат-фикс записан в observations. Цена ошибки: нет.
- Task 19: PARKED — оператор на главном гейте выбрал «план принят, build позже». По плану зачистка v1 (~/.claude/skills/*-mvp, playbooks/, agents/templates/) и переписывание памяти разрешены ТОЛЬКО после успешного build smoke — НЕ выполнены, v1 остаётся на диске. Resume: mvp:build --tasks 2 в vireo → проверка ledger/telemetry → Task 19 Steps 3–5.
- Ветка pipeline-v2 плагина НЕ смержена в main (merge — отдельное решение оператора; установленный кэш собран из ветки и работает).

## Progress (продолжение)

- Ruling R10 (forward, из паттерна Task 2–3): во всех последующих lib-задачах спековый JSON-контракт главнее буквенных код-блоков плана: обязательны argv-guard с контрактным JSON, JSON-escape всех интерполяций, атомарная запись state-файлов (tmp+rename). Вносится в диспатчи Tasks 4–8. Цена ошибки: лёгкое расхождение реализации с код-блоками плана.
- Task 19: complete — smoke: 001 (f2d08ad, run 003), 002 (49ac61c, run 006); 6 прогонов, 4 фикс-раунда (park root-boundary, greenfield ci-mirror, structured relay + коэрция + unwrap); независимый анализ (opus): рабочее, критических нет; v1 удалён из ~/.claude (архив docs/attic/), память переписана, merge pipeline-v2→main (7d02c0c). DoD спеки §9: все пункты выполнены.
