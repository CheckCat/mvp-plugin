# Test-run review checklist

Идеи улучшения тестирования и наблюдения за прогоном плейбука MVP. Прогоняй сверху вниз по ходу учебного run'а; ставь `[x]` когда сделано.

---

## Pre-run

- [x] `git init` сделан, `project_prompt_files/` закоммичены первой ревизией
- [x] Проверил наличие memory-записи `feedback-mvp-playbook-observations` (`/memory`)
- [x] Решил судьбу старой memory `project-vireo` (удалить / переписать под Snippet Stash)
- [x] Журнал `~/.claude/playbooks/observations/snippet-stash-run-1.md` открыт во вкладке — буду в него писать по ходу

---

## После `/bootstrap-mvp`

- [x] `.claude/agents/` содержит все 7 ролей (backend-implementer, frontend-implementer, devops-engineer, integration-specialist, code-reviewer, validator, test-writer)
- [x] В каждом файле агента есть склейка `_common.md` (раздел `# Common Agent Principles`)
- [x] `CLAUDE.md` ≤ 150 строк, не дублирует содержимое `project_prompt_files/`
- [x] `ARCHITECTURE.md` содержит секцию living document
- [x] `.claude/state/telemetry/*.jsonl` существуют пустыми
- [x] Время bootstrap зафиксировано в журнале

---

## После `/plan-mvp` (Dry-run)

- [x] Глазами прочитал `PROJECT_PLAN.md`
- [x] DAG имеет осмысленные зависимости (не один линейный список и не плоский граф без рёбер)
- [x] Узлов в DAG: 16  (записать число)
- [x] Estimated tokens из planner'а: ~253k
- [всеок] Если узлов > 30 или зависимости подозрительные — Stop&Ask, правка `project_prompt_files/`, перезапуск
- [всеок] Запись в журнал: «глазами проверил DAG, ок / переделал потому что …»

---

## `/execute-mvp` — бюджет-ограничитель

- [ ] Первый запуск execute с явным `+50k` или `+100k` на старте
- [ ] Зафиксировал `budget.total`: __________
- [ ] Зафиксировал `budget.spent()` по завершении: __________
- [ ] Если вышел за бюджет — отметить в журнале, проверить planner.estimate vs actual

---

## Заранее подготовленная «фейк-ошибка» (опционально)

- [ ] Перед прогоном внёс одну осознанно-двусмысленную фразу в `business_logic.md` (например: «cookie может жить либо в session, либо postMessage»)
- [ ] Зафиксировал что внёс: __________
- [ ] Проверил поднял ли planner или один из агентов Stop&Ask из-за этой неоднозначности
- [ ] Если НЕ поднял — это open-item плейбука, записать в журнал

---

## Локальный запуск через Docker

- [ ] `.env` файл создан с `BACKEND_API_KEY=` и `POSTGRES_PASSWORD=`
- [ ] `docker compose up --build` собирает все три контейнера без ошибок
- [ ] `http://localhost:3000/login` отдаёт страницу логина
- [ ] Логин с API-key из `.env` успешен, редирект на список сниппетов
- [ ] Создал тестовый сниппет с тегом — отображается в списке
- [ ] Поиск по подстроке title работает
- [ ] Фильтр по тегу работает
- [ ] Удаление сниппета работает
- [ ] Без cookie защищённые страницы редиректят на `/login`
- [ ] `/api/health` отдаёт `{ status: "ok" }`

---

## После `/analyze-telemetry`

- [ ] Получил markdown-отчёт
- [ ] Записал в журнал топ-3 системных проблемы из отчёта
- [ ] Решил какие фиксы шаблонов делать сейчас, какие отложить

---

## Сравнительный прогон #2 (опционально, после фиксов)

- [ ] Снёс проект (`rm -rf .claude packages/* docker-compose.yml … `), оставил `project_prompt_files/`
- [ ] Заново `git init` + bootstrap → plan → execute
- [ ] Сравнил `plan.json.budget` между run-1 и run-2
- [ ] Зафиксировал разницу в `~/.claude/playbooks/observations/snippet-stash-run-2.md`
- [ ] Если DAG сильно изменился между прогонами — записать как red flag (планер нестабилен)

---

## Замер «без graphify» (опционально, run #3)

- [ ] Временно переименовал `~/.claude/skills/refresh-graph` → `refresh-graph.disabled`
- [ ] Прогнал ещё раз, замерил суммарные токены
- [ ] Сравнил с run-1: разница в токенах: __________ %
- [ ] Если < 10% — заявление в `playbooks/mvp.md` «3-5× экономия от Graphify» нужно переписать
- [ ] Вернул скилл обратно

---

## Идеи на будущее (не в текущем прогоне)

- [ ] Подумать про `EnterPlanMode` обёртку для `/plan-mvp` чтобы пользователь мог редактировать DAG до execute
- [ ] Подумать про MCP wrapper для graphify (отложено в Блоке 3)
- [ ] Подумать про worktree isolation в execute (сейчас выключено для надёжности)
- [ ] Подумать про lock-files whitelist в Check 4 валидатора (`pnpm-lock.yaml`)
- [ ] Подумать про настоящую async для code-reviewer через `run_in_background: true`

---

## Финальная сводка прогона

Заполнить после `phase: "all-done"` или после `halt_reason ≠ all-done`:

- Halt reason: __________
- Завершено задач: __________ / __________
- Общая стоимость (USD): __________
- Общее wall-clock время: __________
- Кол-во Stop&Ask: __________
- Кол-во validator-fails: __________
- Кол-во review request-changes: __________
- Топ-1 найденный баг плейбука: __________
- Топ-1 найденный баг шаблона роли: __________
- Что бы я поменял в плейбуке после этого прогона: __________
