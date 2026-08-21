# Живой прогон v2: vireo, brief → clarify → bootstrap → plan (2026-08-22)

Первый боевой прогон плагина `mvp` 2.0.0 (кэш e32c00d) на vireo после полной зачистки v1-артефактов (остался только `project_brief.raw/`). Все четыре стадии пройдены за одну сессию с оператором на гейтах.

## Итоги стадий

| Стадия | Коммит | Заметки |
|---|---|---|
| wipe | 159b08a | `git rm` v1-артефактов по списку плана |
| mvp:brief | 7c60ef0 | discover→skeleton→packaging→Stop&Ask стек (fastapi+react)→swap; services_count=13, layout=services — awk-фикс работает |
| mvp:clarify | edb4f58 | 9 находок (2 critical, 4 medium, 3 low), mode=medium, 6 ответов оператора (все = recommended), 3 auto; queue-check зелёный на обоих вызовах |
| mvp:bootstrap | 681c752 | 5 агентов, drift 0; check-meta зелёный с первой попытки; ci-mirror fastapi+react |
| mvp:plan | 4147fac | планнер (opus): 54 задачи / 10 фаз / 980k est; validate-plan 0 ошибок с первой попытки |

Build отложен решением оператора на главном гейте («план принят, build позже») — smoke `--tasks 2` и зачистка v1 ждут следующей сессии (см. ledger SDD-прогона плагина).

## Наблюдения (кандидаты в правки v2.x)

1. **archive при rerun-кейсе конфликтует сам с собой.** Если единственный discover-кандидат — `project_brief.raw/` (повторный прогон), `archive` возвращает конфликты по всем файлам: source == destination. Скилл предлагает Stop&Ask overwrite/rename/abort — все три бессмысленны. Обошли ruling'ом «уже заархивировано, no-op». Фикс: `package-brief.sh archive` должен распознавать `src == project_brief.raw` и возвращать ok с `data:{"note":"already-archived"}`; либо discover не должен предлагать сам архив как кандидата, требуя явного подтверждения rerun.
2. **Смена статусов очереди — многословная операция.** 9 длинных JSONL-строк переводились в `applied` python-однострочником как текст-тулом. Кандидат v2.1: `queue-check.sh transition <id...> --to applied` (детерминированная смена статуса скриптом, судьба-решения остаются за LLM).
3. **Гейт-вопросы хорошо батчатся.** 6 операторских вопросов clarify ушли двумя AskUserQuestion-батчами (4+2) — UX нормальный, расширение батча до 4 достаточно.
4. **check-meta и validate-plan прошли с первой попытки** — данные за то, что творческие шаги (invariants/CLAUDE/ARCHITECTURE/план) с детерминированными гейтами сходятся без ретраев, когда правила сформулированы в SKILL заранее.
5. **Планнер-опус выдал план, полностью прошедший схему с первого раза** (54 задачи, транзитивный frontend→backend чек, boundary-принадлежность) — вложение полного контракта полей в промпт окупилось.

## Телеметрия

Стадии до build телеметрию не пишут (контракт v2.0: только task_complete в build) — события появятся после smoke.

## Smoke-прогон build (продолжение)

- Task 001 (role devops, `service_path: "."`, первая задача DAG) корректно упал на структурном конфликте DAG-порядка: сгенерированный `ci-mirror.sh` ссылался на `services/` и `services/frontend/`, которых на первой задаче ещё нет — validator дал `VERDICT: park`, диагностика верная, это не баг validator'а.
- `park()` после этого пытался прогнать repo-wide reset (`git checkout/restore/clean` по boundary `.`) — платформенный safety-классификатор заблокировал команду как разрушительную для всего репозитория реального проекта, relay вернулся без `{line}`, и вместо чистого `stop-and-ask` воркфлоу падал в `halt:error`. Пофикшено: `park()` теперь пропускает reset-relay целиком, если boundary нормализуется в корень репозитория (`.`/`./`/пусто), оставляя working tree как есть для оператора.
- Маппинг команд в `skills/bootstrap/SKILL.md` шаг 3.2 пофикшен на greenfield-incremental: `mypy services` и все `npm --prefix services/frontend` команды обёрнуты в `if [ -d ... ]` existence-guard, `pytest` терпит exit 5 (no tests collected) — первая задача DAG теперь проходит ci-mirror на пустом дереве.
- Task 001 прошёл end-to-end на run 3 (коммит, ledger, дельта телеметрии 49743).
- string-in-string relay исказил ~1.5KB validate-JSON с вложенными экранированными `\n` (task 002) → заменён на structured-schema relay (платформенно-валидируемый объектный транспорт вместо `{line:string}` + `JSON.parse`).
