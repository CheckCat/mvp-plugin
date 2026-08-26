# Observations: vireo epoch 3 (мультипровайдерность видео/LLM) — 2026-08-26

## Run summary

19/19 done, 0 failed (эпоха 3, задачи 058–076; plan summary: 76/76 total, epochs 1/2/3 = 55/2/19).
Сумма delta_tokens: 1 340 260 (min 25 624, max 244 714, avg 70 540). Сумма dispatches: 122.
Реальная стоимость по workflow-телеметрии: ~9,2M subagent-токенов за 7 запусков —
расхождение с delta_tokens снова ~7×, подтверждает калибровку 2026-08-24 (8.4×).

**Внимание к строке 074**: её delta_tokens (244 714) — это РЕАЛЬНЫЕ subagent-токены,
подсчитанные оператором из workflowProgress при ручном закрытии, тогда как остальные
18 строк — controller-only. Шкалы несопоставимы; при калибровке 074 исключать.

Форма прогона: 12 задач — чистый путь (5 диспатчей), 7 — лестница валидации (8–11).
Ни одного failed-финала; все срывы запусков — внешние по отношению к задачам
(классификатор харнеса, долг ruff, гонка ryuk, 2× лимит сессии).

## Token calibration data

| task | delta_tokens | dispatches |
|---|---|---|
| 058 | 25624 | 5 |
| 059 | 63195 | 5 |
| 060 | 56420 | 5 |
| 061 | 47633 | 9 |
| 062 | 147978 | 8 |
| 063 | 41630 | 9 |
| 064 | 95125 | 8 |
| 065 | 49981 | 5 |
| 066 | 48795 | 8 |
| 067 | 78057 | 5 |
| 068 | 76841 | 11 |
| 069 | 73704 | 9 |
| 070 | 51890 | 5 |
| 071 | 42212 | 5 |
| 072 | 69639 | 5 |
| 073 | 38968 | 5 |
| 074 | 244714* | 5 |
| 075 | 57216 | 5 |
| 076 | 30638 | 5 |

*операторский real-tokens, не controller-only — см. Run summary.

## Rationalization-table / workflow candidates (verbatim)

| cite | source file | target |
|---|---|---|
| «park-clean и git checkout блокируются классификатором харнеса — очистка дерева при park теперь операторская обязанность (stash, не сброс)» | .mvp/decisions.log [058] | skills/build/workflow.mjs — **главный кандидат эпохи**: park() чистит дерево через `git checkout`+`git clean -fd` в сабагенте; классификатор харнеса блокирует это КАЖДЫЙ раз (3 инцидента: park-clean-058 ×2, park-clean-060, park-clean-067, park-clean-074) → workflow умирает `halt:error` вместо штатного `stop-and-ask`, статус задачи остаётся `pending`, дерево грязное. Замена: `git stash push -u -m "park task-<id>" -- <boundary>` — обратимо (классификатор пропускает), сохраняет работу для диагностики, и halt-таблица снова получает свой `stop-and-ask` |
| «CANNOT_VERIFY по вёрстке (таб без прокрутки) принят как остаточный риск до ручной проверки в браузере» | .mvp/ledger.md concern (task 074) | skills/plan/SKILL.md — правило авторинга задач: критерий, проверяемый только рендером («помещается в экран», «выглядит компактно»), даёт ревьюеру честный CANNOT_VERIFY → park навсегда, ни один re-dispatch это не чинит. Визуальные требования формулировать кодо-проверяемо (маркап-структура, количество элементов) либо явно помечать «не критерий ревью» |
| «ruff 0.16 (format md-фенсов) валил ci на 48 файлах .mvp/*.md — исключил .mvp в root pyproject» | .mvp/decisions.log [058] | templates bootstrap (генерация pyproject/ci-mirror): каталог состояния пайплайна исключать из форматтеров с первого дня — состояние генерируется LLM-ами и не обязано проходить чужие линтеры; инструмент, начавший форматировать новый класс файлов после апгрейда, ломает ВСЕ задачи разом |
| «Валидатор дважды падал на гонке ryuk testcontainers (port 8080 not available) при зелёном коде — отключил ryuk в .mvp/ci-mirror.sh» | .mvp/decisions.log [060] | templates bootstrap ci-mirror.sh: для стека с testcontainers добавлять `export TESTCONTAINERS_RYUK_DISABLED=true` в локальное зеркало (реапер нужен только после крашей; на Docker Desktop его старт гоняется с port-mapping и валит целые pytest-прогоны). Плюс наблюдение: Docker Desktop Resource Saver усыпляет VM при простое — на длинном прогоне держать keepalive-контейнер |
| «Закрыл как оператор: правки внесены в черновик имплементера, полный ci-mirror exit=0, complete/finalize/ledger через lib-скрипты» | .mvp/decisions.log [074] | skills/build/SKILL.md — задокументировать легальную операторскую цепочку ручного закрытия задачи: `plan-io complete <id> --tokens N --dispatches N --write-msg F && finalize.sh build-task F --files … && plan-io ledger --task <id> --sha HEAD --concern "…"`. В эту эпоху она понадобилась (074) и сработала без правки state руками |
| «[implementer-067] failed: You've hit your session limit · resets 7:10am» | task-notification build-20260825T220606Z-e3e | skills/build/SKILL.md halt-таблица: лимит сессии приходит как error-halt посреди задачи; операторская процедура — stash частичного черновика, дождаться сброса, перезапуск. Кандидат: различать в сводке «упал по лимиту» от прочих error |

## Template edit candidates (verbatim)

| cite | source file | target template |
|---|---|---|
| «Health writes join the caller's unit of work… `strategy/tasks.adapt_account_strategy` lets the LLM error escape its session block, so those increments roll back — LLM keys may never reach the threshold there. …needs a follow-up» | .mvp/ledger.md concern (task 059) | не шаблон — **кандидат в add-task эпохи 4** (баг продукта: health-инкременты LLM откатываются вместе с транзакцией) |
| «Veo's `video.uri` is a Files-API link needing `x-goog-api-key`; the unauthenticated pull in `orchestrator.publication_service` → `integration-*` will 403 for Veo assets — follow-up task needed» | .mvp/ledger.md concern (task 070) | **кандидат в add-task эпохи 4** (публикация Veo-ассетов сломана до скачивания с авторизацией) |
| «Aspect ratio (9:16) is not achievable via MiniMax's pure text2video endpoint… Task 071 must not claim 9:16 support» | .mvp/ledger.md concern (task 068) | сработавший механизм: контингентность в брифе 071 отработала — модель MiniMax не посеяна в каталог. Продуктовое следствие: дешёвый слот «Hailuo» пуст до появления image-to-video пайплайна |
| «Provider error codes match the vendor docs as of 2026-08 but could not be re-fetched (no network); each row is test-pinned» | .mvp/ledger.md concern (task 064) | наблюдение о среде: sandbox исполнителей без сети — маппинги ошибок закреплены тестами, но не сверены с живыми доками; сверить при первом реальном использовании ключей |

## Что сработало хорошо (для баланса)

- Лестница ревью дала один подтверждённый реальный баг (074: фронт глушил
  reason-specific 409-сообщение бэка) и поймала ложное утверждение имплементера
  («бэкенд ещё не шлёт 409») цитатой коммита 92c0c5d — это ровно та работа,
  ради которой ревью-сиденье оплачивается.
- Контингентные брифы (068 MiniMax 9:16, 069 Runway text2video) отработали как
  задумано: исполнители честно исследовали доки и исключили неподдерживаемое
  из каталога вместо выдумывания реализации.
- 12/19 задач прошли чистым путём без единого повтора; 0 failed-финалов.
- Операторская цепочка ручного закрытия (074) прошла без правки state руками —
  Iron Law выдержан всю эпоху.
