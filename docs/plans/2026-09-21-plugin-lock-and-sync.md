# plugin-lock + mvp:sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать проекту память о том, от какого состояния плагина собраны его артефакты, чинить производное автоматически и докладывать об изменившихся требованиях.

**Architecture:** Новый скрипт `lib/plugin-lock.sh` с тремя глаголами (`record`/`check`/`seal`) — единственный владелец формата `.mvp/plugin-lock.json`. Запись в секцию `derived` делает `assemble-agent.sh` при сборке агента; запись в `normative` — явный акт `seal`. Политика (что блокирует прогон, а что только докладывается) живёт в `lib/gate.sh build`, не в скрипте. Скилл `mvp:sync` склеивает это в операторский сценарий.

**Tech Stack:** bash + python3 (hashlib, json) — ровно то, на чём написан весь остальной плагин. Никаких новых зависимостей.

**Spec:** `docs/specs/2026-09-21-plugin-lock-and-sync-design.md`

## Global Constraints

- Каждый скрипт печатает последней строкой stdout `{"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}`. `ok:false` **всегда** выходит 1.
- Значения в JSON передаются в python через переменные окружения, никогда не интерполируются в текст программы (правило из `lib/gate.sh`).
- Все скрипты запускаются из корня **целевого проекта**, не из репозитория плагина. Путь к плагину — от `BASH_SOURCE`, переопределяется env `PLUGIN_ROOT`.
- Тесты: конвенция `tests/run.sh` — exit 0 значит pass. Фикстуры под `mktemp -d`, уборка через `trap`.
- **Негативный контроль обязателен на каждый тест.** После того как тест написан и зелёный — сломай код намеренно и убедись, что тест красный. Тест, который ни разу не падал, ничего не проверяет.
- `git add` — только явными путями. Никогда `git add -A` и `git add .`.
- Запись JSON-файлов атомарна: `tempfile` в той же директории + `os.replace` (как в `lib/state.sh`).
- Хэш записывается строкой вида `sha256:<hex>`.
- Пути внутри `sources` и `normative` — относительно корня плагина. Ключ записи в `derived` — путь артефакта относительно корня проекта.

---

## File Structure

**Создаётся:**
- `lib/plugin-lock.sh` — весь формат lock-файла, три глагола. Единственное место, которое знает структуру `.mvp/plugin-lock.json`.
- `tests/lib/plugin-lock.test.sh` — десять случаев из §11 спеки.
- `skills/sync/SKILL.md` — операторский сценарий.

**Изменяется:**
- `skills/bootstrap/scripts/assemble-agent.sh` — вызов `record` после `mv "$TMP" "$OUT"`.
- `lib/gate.sh` — политика в `gate_build`.
- `lib/finalize.sh` — пресет scope `sync`.
- `skills/bootstrap/SKILL.md` — вызов `seal` на Шаге 7.
- `tests/lib/gate.test.sh`, `tests/lib/finalize.test.sh`, `tests/lib/skill-size.test.sh` — по одному случаю каждый.

---

### Task 1: `lib/plugin-lock.sh` — скелет и глагол `record`

**Files:**
- Create: `lib/plugin-lock.sh`
- Test: `tests/lib/plugin-lock.test.sh`

**Interfaces:**
- Consumes: ничего (первая задача).
- Produces: `lib/plugin-lock.sh record <role> [stack]` — upsert записи в `derived`. Читает env `PLUGIN_ROOT` (default: директория скрипта `/..`), `STATE_DIR` (default `.mvp`), `OUT_DIR` (default `.claude/agents`), `PROJECT`, `SERVICE_API`, `SERVICE_WORKER`. Пишет `${STATE_DIR}/plugin-lock.json`. Успех: `data = {"path": "<путь артефакта>", "template": "<basename шаблона>"}`.

- [ ] **Step 1: Написать падающий тест**

Создай `tests/lib/plugin-lock.test.sh`. Этот файл будет расти в Task 2 и Task 3 — хелперы пиши так, чтобы их переиспользовать.

```bash
#!/usr/bin/env bash
# Tests for lib/plugin-lock.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
LOCK_SH="$repo_root/lib/plugin-lock.sh"

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() { # <desc> <expected> <actual>
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1 — expected [$2], got [$3]" >&2
    fail=1
  fi
}

# Последняя строка stdout — JSON-контракт. Всё, что скрипт напечатал раньше,
# к контракту не относится и в тестах не участвует.
last_line() { printf '%s\n' "$1" | tail -n1; }

jq_py() { # <json> <python-выражение над d>
  PL_J="$1" PL_E="$2" python3 -c '
import json, os
d = json.loads(os.environ["PL_J"])
print(eval(os.environ["PL_E"]))
'
}

# Минимальный поддельный плагин: ровно те файлы, которые скрипт читает.
# Настоящий плагин не трогаем — тесты мутируют шаблоны.
make_fake_plugin() { # <dir>
  local p="$1"
  mkdir -p "$p/skills/bootstrap/templates" "$p/skills/bootstrap/scripts" \
           "$p/skills/build" "$p/lib" "$p/.claude-plugin"
  printf '%s\n' '{"name":"mvp","version":"9.9.9"}' > "$p/.claude-plugin/plugin.json"
  printf 'COMMON v1\n' > "$p/skills/bootstrap/templates/_common.md"
  printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nBODY devops v1\n' \
    > "$p/skills/bootstrap/templates/devops-engineer.docker-compose.fastify.template.md"
  printf -- '---\nname: integration-specialist\ndescription: d\ntools: Read\n---\n\nBODY integ v1\n' \
    > "$p/skills/bootstrap/templates/integration-specialist.template.md"
  printf 'SKILL bootstrap v1\n' > "$p/skills/bootstrap/SKILL.md"
  printf 'SKILL build v1\n'     > "$p/skills/build/SKILL.md"
  printf 'echo hi\n'            > "$p/lib/validate-task.sh"
  printf 'echo meta\n'          > "$p/skills/bootstrap/scripts/check-meta.sh"
}

make_fake_project() { # <dir>
  mkdir -p "$1/.claude/agents" "$1/.mvp"
}

# --- Test 1: record создаёт lock с одной записью derived ------------------

t1_plugin="$tmpdir/t1-plugin"; t1_proj="$tmpdir/t1-proj"
make_fake_plugin "$t1_plugin"; make_fake_project "$t1_proj"
printf 'ASSEMBLED devops\n' > "$t1_proj/.claude/agents/devops-engineer.md"

out1="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" PROJECT=trellis \
  SERVICE_API=trellis-api SERVICE_WORKER=trellis-worker \
  bash "$LOCK_SH" record devops-engineer docker-compose.fastify 2>/dev/null)"
rc1=$?
assert_eq "test 1: record exit" "0" "$rc1"
assert_eq "test 1: ok" "True" "$(jq_py "$(last_line "$out1")" 'd["ok"]')"

lock1="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 1: lock_version" "1" "$(jq_py "$lock1" 'd["lock_version"]')"
assert_eq "test 1: ключ derived" ".claude/agents/devops-engineer.md" \
  "$(jq_py "$lock1" 'list(d["derived"])[0]')"
assert_eq "test 1: stack" "docker-compose.fastify" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
assert_eq "test 1: template" "devops-engineer.docker-compose.fastify.template.md" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["template"]')"
assert_eq "test 1: PROJECT" "trellis" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["placeholders"]["PROJECT"]')"
assert_eq "test 1: два источника" "2" \
  "$(jq_py "$lock1" 'len(d["derived"][".claude/agents/devops-engineer.md"]["sources"])')"
assert_eq "test 1: output_sha256 есть" "True" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["output_sha256"].startswith("sha256:")')"
assert_eq "test 1: plugin.version" "9.9.9" "$(jq_py "$lock1" 'd["plugin"]["version"]')"
assert_eq "test 1: normative пуста" "0" "$(jq_py "$lock1" 'len(d["normative"])')"

# --- Test 8: record одной роли не ломает записи остальных ------------------

printf 'ASSEMBLED integ\n' > "$t1_proj/.claude/agents/integration-specialist.md"
(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" bash "$LOCK_SH" record integration-specialist >/dev/null 2>&1)

lock8="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 8: две записи" "2" "$(jq_py "$lock8" 'len(d["derived"])')"
assert_eq "test 8: devops уцелел" "docker-compose.fastify" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
assert_eq "test 8: роль без стека" "" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/integration-specialist.md"]["stack"]')"
assert_eq "test 8: шаблон без стека" "integration-specialist.template.md" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/integration-specialist.md"]["template"]')"

# --- Test 8b: record при отсутствующем собранном агенте — ok:false ---------

out8b="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" \
  bash "$LOCK_SH" record test-writer fastify 2>/dev/null)"
rc8b=$?
assert_eq "test 8b: exit" "1" "$rc8b"
assert_eq "test 8b: ok" "False" "$(jq_py "$(last_line "$out8b")" 'd["ok"]')"

exit $fail
```

- [ ] **Step 2: Прогнать тест — убедиться, что он падает**

Run: `bash tests/lib/plugin-lock.test.sh`
Expected: FAIL. Скрипта нет, поэтому `bash: .../lib/plugin-lock.sh: No such file or directory` и несовпадения по каждому assert.

- [ ] **Step 3: Написать `lib/plugin-lock.sh`**

```bash
#!/usr/bin/env bash
# plugin-lock.sh <record|check|seal>
#
# Единственный владелец формата .mvp/plugin-lock.json — отметки о том, от
# какого состояния плагина собраны артефакты проекта. Спека:
# docs/specs/2026-09-21-plugin-lock-and-sync-design.md
#
# Запускается из корня ЦЕЛЕВОГО ПРОЕКТА (не из репозитория плагина).
# Контракт вывода — как у lib/gate.sh: последняя строка stdout это
# {"ok","reason","hint","data"}; ok:false всегда выходит 1.
#
#   record <role> [stack]  upsert записи в derived. Зовётся из
#                          assemble-agent.sh, снаружи не нужен.
#   check                  чистая диагностика, ничего не пишет.
#   seal                   переписывает normative текущими хэшами плагина.
#
# env:
#   PLUGIN_ROOT     корень плагина (default: директория этого скрипта /..)
#   STATE_DIR       где лежит lock (default: .mvp)
#   OUT_DIR         где лежат собранные агенты (default: .claude/agents)
#   PROJECT / SERVICE_API / SERVICE_WORKER
#                   значения плейсхолдеров, записываются в derived (record)
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
LOCK="${STATE_DIR:-.mvp}/plugin-lock.json"
OUT_DIR="${OUT_DIR:-.claude/agents}"

# Справочная метка: даёт mvp:sync возможность показать настоящий git diff,
# когда плагин — чекаут. Пусто, если плагин установлен из кэша (нет .git).
# Гейт по ней НЕ судит — судит по хэшам (спека §4.1).
GIT_SHA="$(git -C "$PLUGIN_ROOT" rev-parse HEAD 2>/dev/null || true)"

emit_result() { # <ok:true|false> <reason> <hint> <data-json>
  PL_OK="$1" PL_REASON="$2" PL_HINT="$3" PL_DATA="$4" python3 -c '
import json, os
ok = os.environ["PL_OK"] == "true"
reason = os.environ.get("PL_REASON") or None
hint = os.environ.get("PL_HINT") or None
data_raw = os.environ.get("PL_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

cmd="${1:-}"; shift || true

case "$cmd" in
  record)
    ROLE="${1:-}"; STACK="${2:-}"
    if [ -z "$ROLE" ]; then
      emit_result false "missing role" "usage: plugin-lock.sh record <role> [stack]" ""
      exit 1
    fi
    PL_PLUGIN_ROOT="$PLUGIN_ROOT" PL_LOCK="$LOCK" PL_OUT_DIR="$OUT_DIR" \
    PL_ROLE="$ROLE" PL_STACK="$STACK" PL_GIT_SHA="$GIT_SHA" \
    PL_PROJECT="${PROJECT:-}" PL_SERVICE_API="${SERVICE_API:-}" \
    PL_SERVICE_WORKER="${SERVICE_WORKER:-}" python3 -c '
import hashlib, json, os, pathlib, sys, tempfile

plugin_root = pathlib.Path(os.environ["PL_PLUGIN_ROOT"])
lock_path   = pathlib.Path(os.environ["PL_LOCK"])
out_dir     = os.environ["PL_OUT_DIR"]
role        = os.environ["PL_ROLE"]
stack       = os.environ["PL_STACK"]

def die(reason, hint):
    print(json.dumps({"ok": False, "reason": reason, "hint": hint, "data": None}))
    sys.exit(1)

def sha(path):
    return "sha256:" + hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def rel(path):
    return str(pathlib.Path(path).relative_to(plugin_root))

tpl_dir = plugin_root / "skills" / "bootstrap" / "templates"
common  = tpl_dir / "_common.md"
if not common.is_file():
    die("_common.md missing: %s" % common, "check PLUGIN_ROOT / plugin install")

# Тот же порядок предпочтения, что в assemble-agent.sh: сначала
# <role>.<stack>, затем <role>. Если стековый шаблон не нашёлся, стек в
# записи обнуляется — иначе lock утверждал бы сборку, которой не было.
staged = tpl_dir / ("%s.%s.template.md" % (role, stack)) if stack else None
if staged is not None and staged.is_file():
    template = staged
elif (tpl_dir / ("%s.template.md" % role)).is_file():
    template = tpl_dir / ("%s.template.md" % role)
    stack = ""
else:
    die("no template for role=%s stack=%s" % (role, stack),
        "check role/stack spelling, or PLUGIN_ROOT")

out = os.path.join(out_dir, "%s.md" % role)
if not os.path.isfile(out):
    die("assembled agent missing: %s" % out,
        "run assemble-agent.sh before record")

try:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    lock = {}
except ValueError:
    die("plugin-lock.json is not valid JSON: %s" % lock_path,
        "delete it and rerun mvp:sync — it is regenerable")

lock.setdefault("lock_version", 1)
lock.setdefault("derived", {})
lock.setdefault("normative", {})

try:
    meta = json.loads((plugin_root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
except Exception:
    meta = {}
lock["plugin"] = {
    "name": meta.get("name"),
    "version": meta.get("version"),
    "git_sha": os.environ["PL_GIT_SHA"] or None,
}

lock["derived"][out] = {
    "role": role,
    "stack": stack,
    "template": template.name,
    "placeholders": {
        "PROJECT": os.environ["PL_PROJECT"],
        "SERVICE_API": os.environ["PL_SERVICE_API"],
        "SERVICE_WORKER": os.environ["PL_SERVICE_WORKER"],
    },
    "sources": {rel(common): sha(common), rel(template): sha(template)},
    "output_sha256": sha(out),
}

lock_path.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(mode="w", dir=str(lock_path.parent),
                                 delete=False, encoding="utf-8") as tmp:
    json.dump(lock, tmp, indent=1, ensure_ascii=False, sort_keys=True)
    tmp.write("\n")
    tmp_path = tmp.name
os.replace(tmp_path, str(lock_path))

print(json.dumps({"ok": True, "reason": None, "hint": None,
                  "data": {"path": out, "template": template.name}}))
'
    exit $?
    ;;
  *)
    emit_result false "unknown cmd: ${cmd:-<missing>}" "record|check|seal" ""
    exit 1
    ;;
esac
```

- [ ] **Step 4: Прогнать тест — убедиться, что он зелёный**

Run: `chmod +x lib/plugin-lock.sh && bash tests/lib/plugin-lock.test.sh && echo PASS`
Expected: `PASS`, без строк `FAIL:` на stderr.

- [ ] **Step 5: Негативный контроль**

Сломай три вещи по очереди, каждый раз прогоняя тест и возвращая правку назад:

1. В `record` замени `sort_keys=True` на `sort_keys=False` — тест должен остаться **зелёным** (порядок ключей ни на что не влияет, и это правильно). Верни.
2. Убери строку `lock["derived"][out] = {` … целиком (не пиши запись) — тест 1 обязан упасть на «ключ derived».
3. В ветке выбора шаблона поменяй `stack = ""` на `pass` — тест 8 обязан упасть на «роль без стека», потому что для `integration-specialist` стек не передавался и обнулять нечего, а вот запись `template` уедет.

Если пункт 2 или 3 остался зелёным — тест не проверяет то, что должен. Чини тест, не код.

- [ ] **Step 6: Коммит**

```bash
git add lib/plugin-lock.sh tests/lib/plugin-lock.test.sh
git commit -m "feat(plugin-lock): record — отметка о том, из чего собран агент

Собранный .claude/agents/<role>.md не помнит своего шаблона: по фронтматтеру
docker-compose.fastify и docker-dokploy.nestjs неразличимы, а PROJECT берётся
из имени директории и нигде не сохраняется. record фиксирует role/stack/
template/placeholders плюс хэши источников и самого артефакта."
```

---

### Task 2: `lib/plugin-lock.sh` — глагол `check`, секция `derived`

**Files:**
- Modify: `lib/plugin-lock.sh` (новая ветка `check)` в `case`)
- Test: `tests/lib/plugin-lock.test.sh` (дописать перед `exit $fail`)

**Interfaces:**
- Consumes: `record` из Task 1 — формат записи `derived` и env-переопределения.
- Produces: `lib/plugin-lock.sh check` → `data` с ключами `lock_present` (bool), `derived_stale` (список `{path, role, stack, changed_sources[]}`), `derived_tampered` (список `{path, role, stack}`), `derived_missing` (список `{path, role}`), `normative_changed`/`normative_added`/`normative_removed` (списки строк). В этой задаче три нормативных списка всегда пустые — их наполняет Task 3. `ok:false` на любое непустое расхождение и на отсутствие lock-файла.

- [ ] **Step 1: Написать падающие тесты**

Вставь в `tests/lib/plugin-lock.test.sh` перед строкой `exit $fail`:

```bash
# --- Общая фикстура для check-тестов --------------------------------------
# Плагин и проект с двумя записанными ролями. Каждый тест получает СВОЮ
# копию: тесты мутируют шаблоны, общая фикстура склеила бы их между собой.
make_recorded_pair() { # <prefix> -> печатает "<plugin-dir> <proj-dir>"
  local p="$tmpdir/$1-plugin" j="$tmpdir/$1-proj"
  make_fake_plugin "$p"; make_fake_project "$j"
  printf 'ASSEMBLED devops\n' > "$j/.claude/agents/devops-engineer.md"
  printf 'ASSEMBLED integ\n'  > "$j/.claude/agents/integration-specialist.md"
  (cd "$j" && PLUGIN_ROOT="$p" bash "$LOCK_SH" record devops-engineer docker-compose.fastify >/dev/null 2>&1)
  (cd "$j" && PLUGIN_ROOT="$p" bash "$LOCK_SH" record integration-specialist >/dev/null 2>&1)
  printf '%s %s\n' "$p" "$j"
}

run_check() { # <plugin-dir> <proj-dir>
  (cd "$2" && PLUGIN_ROOT="$1" bash "$LOCK_SH" check 2>/dev/null) | tail -n1
}

# --- Test 2 (часть 1): всё чисто ------------------------------------------

read -r p2 j2 <<< "$(make_recorded_pair t2)"
c2="$(run_check "$p2" "$j2")"
assert_eq "test 2a: ok при чистом плагине" "True" "$(jq_py "$c2" 'd["ok"]')"
assert_eq "test 2a: lock_present" "True" "$(jq_py "$c2" 'd["data"]["lock_present"]')"
assert_eq "test 2a: stale пуст" "0" "$(jq_py "$c2" 'len(d["data"]["derived_stale"])')"

# --- Test 2 (часть 2): правка _common.md поднимает ОБЕ роли ---------------

printf 'COMMON v2\n' > "$p2/skills/bootstrap/templates/_common.md"
c2b="$(run_check "$p2" "$j2")"
assert_eq "test 2b: ok:false" "False" "$(jq_py "$c2b" 'd["ok"]')"
assert_eq "test 2b: обе роли stale" "2" "$(jq_py "$c2b" 'len(d["data"]["derived_stale"])')"
assert_eq "test 2b: changed_sources называет _common.md" "True" \
  "$(jq_py "$c2b" 'all(x["changed_sources"] == ["skills/bootstrap/templates/_common.md"] for x in d["data"]["derived_stale"])')"
assert_eq "test 2b: tampered пуст" "0" "$(jq_py "$c2b" 'len(d["data"]["derived_tampered"])')"

# --- Test 3: правка одного шаблона роли поднимает ТОЛЬКО эту роль ---------

read -r p3 j3 <<< "$(make_recorded_pair t3)"
printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nBODY devops v2\n' \
  > "$p3/skills/bootstrap/templates/devops-engineer.docker-compose.fastify.template.md"
c3="$(run_check "$p3" "$j3")"
assert_eq "test 3: ровно одна роль" "1" "$(jq_py "$c3" 'len(d["data"]["derived_stale"])')"
assert_eq "test 3: это devops" "devops-engineer" \
  "$(jq_py "$c3" 'd["data"]["derived_stale"][0]["role"]')"
assert_eq "test 3: стек в находке" "docker-compose.fastify" \
  "$(jq_py "$c3" 'd["data"]["derived_stale"][0]["stack"]')"

# --- Test 4: правка собранного агента руками = tampered, не stale ---------

read -r p4 j4 <<< "$(make_recorded_pair t4)"
printf 'ASSEMBLED devops — HAND EDITED\n' > "$j4/.claude/agents/devops-engineer.md"
c4="$(run_check "$p4" "$j4")"
assert_eq "test 4: ok:false" "False" "$(jq_py "$c4" 'd["ok"]')"
assert_eq "test 4: stale пуст" "0" "$(jq_py "$c4" 'len(d["data"]["derived_stale"])')"
assert_eq "test 4: ровно один tampered" "1" "$(jq_py "$c4" 'len(d["data"]["derived_tampered"])')"
assert_eq "test 4: это devops" "devops-engineer" \
  "$(jq_py "$c4" 'd["data"]["derived_tampered"][0]["role"]')"

# --- Test 9: агент удалён из проекта = missing, не stale ------------------

read -r p9 j9 <<< "$(make_recorded_pair t9)"
rm "$j9/.claude/agents/integration-specialist.md"
c9="$(run_check "$p9" "$j9")"
assert_eq "test 9: ровно один missing" "1" "$(jq_py "$c9" 'len(d["data"]["derived_missing"])')"
assert_eq "test 9: это integ" "integration-specialist" \
  "$(jq_py "$c9" 'd["data"]["derived_missing"][0]["role"]')"
assert_eq "test 9: stale пуст" "0" "$(jq_py "$c9" 'len(d["data"]["derived_stale"])')"
assert_eq "test 9: tampered пуст" "0" "$(jq_py "$c9" 'len(d["data"]["derived_tampered"])')"

# --- Test 6: lock-файла нет — отдельный reason, не дрейф ------------------

p6="$tmpdir/t6-plugin"; j6="$tmpdir/t6-proj"
make_fake_plugin "$p6"; make_fake_project "$j6"
printf 'ASSEMBLED devops\n' > "$j6/.claude/agents/devops-engineer.md"
c6="$(run_check "$p6" "$j6")"
assert_eq "test 6: ok:false" "False" "$(jq_py "$c6" 'd["ok"]')"
assert_eq "test 6: reason" "no plugin-lock.json" "$(jq_py "$c6" 'd["reason"]')"
assert_eq "test 6: lock_present" "False" "$(jq_py "$c6" 'd["data"]["lock_present"]')"
assert_eq "test 6: списки пусты" "True" \
  "$(jq_py "$c6" 'all(len(d["data"][k]) == 0 for k in ("derived_stale","derived_tampered","derived_missing"))')"
```

- [ ] **Step 2: Прогнать тест — убедиться, что он падает**

Run: `bash tests/lib/plugin-lock.test.sh`
Expected: FAIL. `check` ещё не реализован — скрипт отвечает `unknown cmd: check`, и все assert'ы этой группы не сходятся.

- [ ] **Step 3: Реализовать `check`**

Вставь новую ветку в `case "$cmd" in`, между `record)` и `*)`:

```bash
  check)
    PL_PLUGIN_ROOT="$PLUGIN_ROOT" PL_LOCK="$LOCK" python3 -c '
import hashlib, json, os, pathlib, sys

plugin_root = pathlib.Path(os.environ["PL_PLUGIN_ROOT"])
lock_path   = pathlib.Path(os.environ["PL_LOCK"])

def sha(path):
    return "sha256:" + hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

empty = {
    "lock_present": False,
    "derived_stale": [], "derived_tampered": [], "derived_missing": [],
    "normative_changed": [], "normative_added": [], "normative_removed": [],
}

try:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    print(json.dumps({"ok": False, "reason": "no plugin-lock.json",
                      "hint": "run mvp:sync — the project has no plugin stamp to compare against",
                      "data": empty}))
    sys.exit(1)
except ValueError:
    print(json.dumps({"ok": False, "reason": "plugin-lock.json is not valid JSON",
                      "hint": "delete it and run mvp:sync — it is regenerable",
                      "data": empty}))
    sys.exit(1)

data = dict(empty, lock_present=True)

for out_path, entry in sorted(lock.get("derived", {}).items()):
    role  = entry.get("role")
    stack = entry.get("stack", "")

    changed = []
    for src, want in sorted(entry.get("sources", {}).items()):
        full = plugin_root / src
        got = sha(full) if full.is_file() else None
        if got != want:
            changed.append(src)

    if not os.path.isfile(out_path):
        data["derived_missing"].append({"path": out_path, "role": role})
        continue

    if changed:
        # Источник уехал — это "плагин обновился". Даже если артефакт вдобавок
        # правили руками, лечение одно и то же (пересборка), поэтому второй
        # диагноз здесь не добавляется: он был бы шумом, а не информацией.
        data["derived_stale"].append({"path": out_path, "role": role,
                                      "stack": stack, "changed_sources": changed})
    elif sha(out_path) != entry.get("output_sha256"):
        data["derived_tampered"].append({"path": out_path, "role": role, "stack": stack})

problems = []
if data["derived_stale"]:
    problems.append("%d agent(s) stale vs plugin" % len(data["derived_stale"]))
if data["derived_tampered"]:
    problems.append("%d agent(s) hand-edited" % len(data["derived_tampered"]))
if data["derived_missing"]:
    problems.append("%d agent file(s) missing" % len(data["derived_missing"]))

if problems:
    print(json.dumps({"ok": False, "reason": "; ".join(problems),
                      "hint": "run mvp:sync", "data": data}))
    sys.exit(1)

print(json.dumps({"ok": True, "reason": None, "hint": None, "data": data}))
'
    exit $?
    ;;
```

- [ ] **Step 4: Прогнать тест — убедиться, что он зелёный**

Run: `bash tests/lib/plugin-lock.test.sh && echo PASS`
Expected: `PASS`.

- [ ] **Step 5: Негативный контроль**

По очереди, возвращая каждую правку:

1. Поменяй `elif sha(out_path) != entry.get("output_sha256"):` на `elif False:` — тест 4 обязан упасть на «ровно один tampered».
2. Поменяй ветку `if not os.path.isfile(out_path):` так, чтобы она добавляла в `derived_stale` вместо `derived_missing` — тест 9 обязан упасть на обоих assert'ах.
3. Убери `sys.exit(1)` из ветки `FileNotFoundError` — тест 6 обязан упасть: `ok` всё ещё `False`, но проверка `rc` в gate-тестах Task 5 поймает это позже; здесь добавь в тест 6 явную проверку кода возврата, если она не поймала. **Это указание на возможную дыру в тесте — если пункт 3 прошёл зелёным, допиши в тест 6 assert на exit code.**

- [ ] **Step 6: Коммит**

```bash
git add lib/plugin-lock.sh tests/lib/plugin-lock.test.sh
git commit -m "feat(plugin-lock): check — диагностика дрейфа производных артефактов

Три разных диагноза, которые нельзя смешивать: stale (уехал источник в
плагине), tampered (артефакт правили руками при чистых источниках), missing
(запись есть, файла нет). check — диагност, не политика: ok:false на любое
расхождение, решение принимает вызывающий."
```

---

### Task 3: `lib/plugin-lock.sh` — секция `normative` в `check` и глагол `seal`

**Files:**
- Modify: `lib/plugin-lock.sh` (наполнение трёх нормативных списков в `check`, новая ветка `seal)`)
- Test: `tests/lib/plugin-lock.test.sh`

**Interfaces:**
- Consumes: `check` из Task 2 — структура `data`.
- Produces: `lib/plugin-lock.sh seal` — перезапись секции `normative`; `derived` не трогает. Состав нормативки задаётся глобами `skills/*/SKILL.md`, `skills/*/scripts/*`, `lib/*` относительно `PLUGIN_ROOT`, только обычные файлы.

- [ ] **Step 1: Написать падающие тесты**

Вставь перед `exit $fail`:

```bash
# --- Test 5: правка SKILL.md — только normative_changed ------------------

read -r p5 j5 <<< "$(make_recorded_pair t5)"
(cd "$j5" && PLUGIN_ROOT="$p5" bash "$LOCK_SH" seal >/dev/null 2>&1)
c5a="$(run_check "$p5" "$j5")"
assert_eq "test 5a: после seal чисто" "True" "$(jq_py "$c5a" 'd["ok"]')"

printf 'SKILL retro v2 — новое требование\n' > "$p5/skills/build/SKILL.md"
c5="$(run_check "$p5" "$j5")"
assert_eq "test 5: ok:false" "False" "$(jq_py "$c5" 'd["ok"]')"
assert_eq "test 5: ровно один changed" "1" "$(jq_py "$c5" 'len(d["data"]["normative_changed"])')"
assert_eq "test 5: это build/SKILL.md" "skills/build/SKILL.md" \
  "$(jq_py "$c5" 'd["data"]["normative_changed"][0]')"
assert_eq "test 5: derived не тронут" "0" \
  "$(jq_py "$c5" 'len(d["data"]["derived_stale"]) + len(d["data"]["derived_tampered"]) + len(d["data"]["derived_missing"])')"

# --- Test 10: новый файл под глоб lib/* = normative_added ----------------

printf 'echo new\n' > "$p5/lib/brand-new.sh"
c10="$(run_check "$p5" "$j5")"
assert_eq "test 10: ровно один added" "1" "$(jq_py "$c10" 'len(d["data"]["normative_added"])')"
assert_eq "test 10: это brand-new.sh" "lib/brand-new.sh" \
  "$(jq_py "$c10" 'd["data"]["normative_added"][0]')"

# --- Test 10b: удалённый файл = normative_removed ------------------------

rm "$p5/lib/validate-task.sh"
c10b="$(run_check "$p5" "$j5")"
assert_eq "test 10b: ровно один removed" "1" "$(jq_py "$c10b" 'len(d["data"]["normative_removed"])')"
assert_eq "test 10b: это validate-task.sh" "lib/validate-task.sh" \
  "$(jq_py "$c10b" 'd["data"]["normative_removed"][0]')"

# --- Test 5b: глоб не захватывает agents/ и references/ ------------------

read -r p5b j5b <<< "$(make_recorded_pair t5b)"
mkdir -p "$p5b/skills/build/agents" "$p5b/skills/retro/references"
printf 'reviewer v1\n' > "$p5b/skills/build/agents/reviewer.md"
printf 'handbook v1\n' > "$p5b/skills/retro/references/retro-handbook.md"
(cd "$j5b" && PLUGIN_ROOT="$p5b" bash "$LOCK_SH" seal >/dev/null 2>&1)
printf 'reviewer v2\n' > "$p5b/skills/build/agents/reviewer.md"
printf 'handbook v2\n' > "$p5b/skills/retro/references/retro-handbook.md"
c5b="$(run_check "$p5b" "$j5b")"
assert_eq "test 5b: agents/ и references/ вне наблюдения" "True" \
  "$(jq_py "$c5b" 'd["ok"]')"

# --- Test 7: seal гасит нормативку и не трогает derived ------------------

read -r p7 j7 <<< "$(make_recorded_pair t7)"
(cd "$j7" && PLUGIN_ROOT="$p7" bash "$LOCK_SH" seal >/dev/null 2>&1)
derived_before="$(jq_py "$(cat "$j7/.mvp/plugin-lock.json")" 'json.dumps(d["derived"], sort_keys=True)')"

printf 'SKILL bootstrap v2\n' > "$p7/skills/bootstrap/SKILL.md"
c7a="$(run_check "$p7" "$j7")"
assert_eq "test 7a: дрейф виден" "1" "$(jq_py "$c7a" 'len(d["data"]["normative_changed"])')"

out7="$(cd "$j7" && PLUGIN_ROOT="$p7" bash "$LOCK_SH" seal 2>/dev/null)"
assert_eq "test 7: seal ok" "True" "$(jq_py "$(last_line "$out7")" 'd["ok"]')"

c7b="$(run_check "$p7" "$j7")"
assert_eq "test 7b: после seal чисто" "True" "$(jq_py "$c7b" 'd["ok"]')"

derived_after="$(jq_py "$(cat "$j7/.mvp/plugin-lock.json")" 'json.dumps(d["derived"], sort_keys=True)')"
assert_eq "test 7c: derived не изменился" "$derived_before" "$derived_after"
```

Хелпер `jq_py` вычисляет выражение через `eval`, поэтому `json.dumps` в нём доступен — модуль `json` уже импортирован в теле хелпера.

- [ ] **Step 2: Прогнать тест — убедиться, что он падает**

Run: `bash tests/lib/plugin-lock.test.sh`
Expected: FAIL. `seal` отвечает `unknown cmd`, нормативные списки в `check` всегда пусты.

- [ ] **Step 3: Реализовать глоб, наполнение нормативки и `seal`**

Сначала — общий кусок, который нужен обоим глаголам. Добавь в `lib/plugin-lock.sh` перед `cmd="${1:-}"` переменную с глобами, чтобы состав нормативки был записан ровно один раз:

```bash
# Состав нормативки — глобами, не списком: новый файл плагина попадает под
# наблюдение сам. Список был бы третьим источником правды рядом с кодом и
# шаблонами и начал бы врать с первого забытого обновления (спека §4.4).
# Намеренно снаружи: skills/*/agents/*, skills/*/references/* (меняют
# поведение плагина, но не требуют изменений в проекте), docs/, tests/.
NORMATIVE_GLOBS='skills/*/SKILL.md skills/*/scripts/* lib/*'
```

В ветке `check)` добавь `PL_GLOBS="$NORMATIVE_GLOBS"` к переменным окружения, и вставь в python перед блоком `problems = []`:

```python
def normative_map():
    found = {}
    for pattern in os.environ["PL_GLOBS"].split():
        for path in sorted(plugin_root.glob(pattern)):
            if path.is_file():
                found[str(path.relative_to(plugin_root))] = sha(path)
    return found

want_norm = lock.get("normative", {})
have_norm = normative_map()
data["normative_changed"]  = sorted(k for k in want_norm if k in have_norm and have_norm[k] != want_norm[k])
data["normative_added"]    = sorted(k for k in have_norm if k not in want_norm)
data["normative_removed"]  = sorted(k for k in want_norm if k not in have_norm)
```

И расширь сбор `problems` (после трёх существующих веток, до `if problems:`):

```python
n_drift = len(data["normative_changed"]) + len(data["normative_added"]) + len(data["normative_removed"])
if n_drift:
    problems.append("%d normative file(s) changed in plugin" % n_drift)
```

Затем добавь ветку `seal)` между `check)` и `*)`:

```bash
  seal)
    PL_PLUGIN_ROOT="$PLUGIN_ROOT" PL_LOCK="$LOCK" PL_GLOBS="$NORMATIVE_GLOBS" \
    PL_GIT_SHA="$GIT_SHA" python3 -c '
import hashlib, json, os, pathlib, sys, tempfile

plugin_root = pathlib.Path(os.environ["PL_PLUGIN_ROOT"])
lock_path   = pathlib.Path(os.environ["PL_LOCK"])

def sha(path):
    return "sha256:" + hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

try:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    lock = {}
except ValueError:
    print(json.dumps({"ok": False, "reason": "plugin-lock.json is not valid JSON",
                      "hint": "delete it and run mvp:sync — it is regenerable",
                      "data": None}))
    sys.exit(1)

lock.setdefault("lock_version", 1)
lock.setdefault("derived", {})

norm = {}
for pattern in os.environ["PL_GLOBS"].split():
    for path in sorted(plugin_root.glob(pattern)):
        if path.is_file():
            norm[str(path.relative_to(plugin_root))] = sha(path)
lock["normative"] = norm

try:
    meta = json.loads((plugin_root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
except Exception:
    meta = {}
lock["plugin"] = {
    "name": meta.get("name"),
    "version": meta.get("version"),
    "git_sha": os.environ["PL_GIT_SHA"] or None,
}

lock_path.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(mode="w", dir=str(lock_path.parent),
                                 delete=False, encoding="utf-8") as tmp:
    json.dump(lock, tmp, indent=1, ensure_ascii=False, sort_keys=True)
    tmp.write("\n")
    tmp_path = tmp.name
os.replace(tmp_path, str(lock_path))

print(json.dumps({"ok": True, "reason": None, "hint": None,
                  "data": {"sealed": len(norm)}}))
'
    exit $?
    ;;
```

- [ ] **Step 4: Прогнать тест — убедиться, что он зелёный**

Run: `bash tests/lib/plugin-lock.test.sh && echo PASS`
Expected: `PASS`.

- [ ] **Step 5: Негативный контроль**

1. Убери из `NORMATIVE_GLOBS` подстроку `skills/*/SKILL.md` — тест 5 обязан упасть.
2. Добавь в `NORMATIVE_GLOBS` `skills/*/agents/*` — тест 5b обязан упасть.
3. В `seal)` добавь строку `lock["derived"] = {}` перед записью — тест 7c обязан упасть.
4. Поменяй в `check` `data["normative_added"]` на пустой список — тест 10 обязан упасть.

- [ ] **Step 6: Коммит**

```bash
git add lib/plugin-lock.sh tests/lib/plugin-lock.test.sh
git commit -m "feat(plugin-lock): normative в check и глагол seal

Состав нормативки задан глобами, а не списком: новый файл плагина попадает
под наблюдение сам. seal — явный акт со смыслом «оператор прочитал дифф и
принял его»; из гейта он не вызывается никогда, иначе печать молча догоняла
бы плагин и теряла смысл."
```

---

### Task 4: `assemble-agent.sh` штампует lock сам

**Files:**
- Modify: `skills/bootstrap/scripts/assemble-agent.sh` (после `mv "$TMP" "$OUT"`, перед `emit_result true`)
- Test: `tests/lib/plugin-lock.test.sh`

**Interfaces:**
- Consumes: `lib/plugin-lock.sh record <role> [stack]` из Task 1.
- Produces: контракт `assemble-agent.sh` не меняется — те же `{"ok","reason","hint","data":{"out","template"}}`. Побочный эффект: после успешной сборки в `.mvp/plugin-lock.json` гарантированно есть актуальная запись этой роли.

- [ ] **Step 1: Написать падающий тест**

Вставь перед `exit $fail`:

```bash
# --- Test 11: assemble-agent.sh сам записывает lock ----------------------
# Производитель штампует свой результат: он единственный знает роль,
# выбранный шаблон, значения плейсхолдеров и путь результата сразу.

ASSEMBLE_SH="$repo_root/skills/bootstrap/scripts/assemble-agent.sh"
p11="$tmpdir/t11-plugin"; j11="$tmpdir/t11-proj"
make_fake_plugin "$p11"; make_fake_project "$j11"

out11="$(cd "$j11" && PLUGIN_ROOT="$p11" \
  TEMPLATES_DIR="$p11/skills/bootstrap/templates" \
  bash "$ASSEMBLE_SH" devops-engineer docker-compose.fastify 2>/dev/null)"
rc11=$?
assert_eq "test 11: assemble exit" "0" "$rc11"
assert_eq "test 11: assemble ok" "True" "$(jq_py "$(last_line "$out11")" 'd["ok"]')"

if [ -f "$j11/.mvp/plugin-lock.json" ]; then
  lock11="$(cat "$j11/.mvp/plugin-lock.json")"
  assert_eq "test 11: запись появилась" "docker-compose.fastify" \
    "$(jq_py "$lock11" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
  # И сразу проверяем главное: свежесобранный агент не считается дрейфующим.
  c11="$(run_check "$p11" "$j11")"
  assert_eq "test 11: свежая сборка чиста по derived" "0" \
    "$(jq_py "$c11" 'len(d["data"]["derived_stale"]) + len(d["data"]["derived_tampered"])')"
else
  echo "FAIL: test 11 — assemble-agent.sh не создал .mvp/plugin-lock.json" >&2
  fail=1
fi
```

- [ ] **Step 2: Прогнать тест — убедиться, что он падает**

Run: `bash tests/lib/plugin-lock.test.sh`
Expected: FAIL со строкой `assemble-agent.sh не создал .mvp/plugin-lock.json`.

- [ ] **Step 3: Вызвать `record` из `assemble-agent.sh`**

Найди в `skills/bootstrap/scripts/assemble-agent.sh` концовку:

```bash
mv "$TMP" "$OUT"
trap - EXIT

DATA="$(python3 -c 'import json,sys; print(json.dumps({"out": sys.argv[1], "template": sys.argv[2]}))' "$OUT" "$(basename "$TEMPLATE")")"
emit_result true "" "" "$DATA"
exit 0
```

Замени на:

```bash
mv "$TMP" "$OUT"
trap - EXIT

# Отметка в .mvp/plugin-lock.json — часть сборки, а не отдельный шаг.
# Производитель штампует свой результат: только здесь одновременно известны
# роль, выбранный шаблон, значения плейсхолдеров и путь результата. Шаг,
# который можно забыть, забывается — см. docs/specs/2026-09-21-plugin-lock-
# and-sync-design.md §6.
LOCK_OUT="$(PROJECT="$PROJECT" SERVICE_API="$SERVICE_API" \
  SERVICE_WORKER="$SERVICE_WORKER" OUT_DIR="$OUT_DIR" \
  bash "$here/../../../lib/plugin-lock.sh" record "$ROLE" "$STACK" 2>&1 | tail -n1)"
LOCK_OK="$(PL_L="$LOCK_OUT" python3 -c '
import json, os
try:
    print("true" if json.loads(os.environ["PL_L"]).get("ok") else "false")
except Exception:
    print("false")
')"
if [ "$LOCK_OK" != "true" ]; then
  fail "plugin-lock record failed after assembling $OUT" \
    "see: $LOCK_OUT — the agent file IS written; rerunning assemble-agent.sh is idempotent"
fi

DATA="$(python3 -c 'import json,sys; print(json.dumps({"out": sys.argv[1], "template": sys.argv[2]}))' "$OUT" "$(basename "$TEMPLATE")")"
emit_result true "" "" "$DATA"
exit 0
```

Замечание про `PLUGIN_ROOT`: `assemble-agent.sh` его сам не пробрасывает, а `plugin-lock.sh` вычисляет корень от своего `BASH_SOURCE`. В бою это одно и то же дерево. В тесте выше `PLUGIN_ROOT` задан в окружении и наследуется дочерним процессом — поэтому тест работает с поддельным плагином, а `TEMPLATES_DIR` нужен отдельно, потому что `assemble-agent.sh` читает шаблоны по своей переменной.

- [ ] **Step 4: Прогнать тесты — убедиться, что они зелёные**

Run: `bash tests/lib/plugin-lock.test.sh && bash tests/lib/check-meta.test.sh && echo PASS`
Expected: `PASS`. Второй файл в команде — потому что `check-meta.test.sh` гоняет bootstrap-сценарий и мог опираться на прежнюю концовку `assemble-agent.sh`.

- [ ] **Step 5: Негативный контроль**

1. Закомментируй блок `LOCK_OUT=...` целиком — тест 11 обязан упасть.
2. Поменяй `"$ROLE" "$STACK"` на `"$ROLE"` (потеря стека) — тест 11 обязан упасть на «запись появилась», потому что `stack` станет пустым.
3. Поменяй условие на `if [ "$LOCK_OK" = "true" ]; then fail ...` (инверсия) — тест 11 обязан упасть на exit-коде assemble.

- [ ] **Step 6: Коммит**

```bash
git add skills/bootstrap/scripts/assemble-agent.sh tests/lib/plugin-lock.test.sh
git commit -m "feat(bootstrap): assemble-agent.sh штампует plugin-lock сам

Отметка становится частью сборки, а не отдельным шагом. Это убирает класс
расхождений «собрали агента, забыли отметить»: шаг, который можно забыть,
забывается."
```

---

### Task 5: политика в `lib/gate.sh build`

**Files:**
- Modify: `lib/gate.sh` — в `gate_build()`, после блока `missing_roles`, перед финальным `emit_result true "" "" ""`
- Test: `tests/lib/gate.test.sh`

**Interfaces:**
- Consumes: `lib/plugin-lock.sh check` из Task 2 и Task 3.
- Produces: `gate.sh build` при дрейфе `derived` даёт `ok:false`, `hint = "run mvp:sync"`. При дрейфе только в нормативке даёт `ok:true` и `data = {"normative_changed": [...], "normative_added": [...], "normative_removed": [...]}`. При полной чистоте `data` остаётся `null`, как сейчас.

- [ ] **Step 1: Написать падающие тесты**

Открой `tests/lib/gate.test.sh`, найди хелперы этого файла и переиспользуй их. Добавь перед финальным `exit`:

```bash
# --- plugin-lock: derived-дрейф валит gate build ------------------------
# Асимметрия намеренная (спека §7): устаревшие агенты не регистрируются,
# задачи уходят на general-purpose без контракта, и ревью это пропускает —
# оно судит дифф, а не автора. Нормативка так не вредит и не блокирует.

gl_proj="$tmpdir/gate-lock-proj"
gl_plugin="$tmpdir/gate-lock-plugin"
mkdir -p "$gl_plugin/skills/bootstrap/templates" "$gl_plugin/skills/build" \
         "$gl_plugin/lib" "$gl_plugin/.claude-plugin"
printf '%s\n' '{"name":"mvp","version":"9.9.9"}' > "$gl_plugin/.claude-plugin/plugin.json"
printf 'COMMON v1\n' > "$gl_plugin/skills/bootstrap/templates/_common.md"
printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nB\n' \
  > "$gl_plugin/skills/bootstrap/templates/devops-engineer.docker-compose.fastify.template.md"
printf 'SKILL build v1\n' > "$gl_plugin/skills/build/SKILL.md"
printf 'echo hi\n' > "$gl_plugin/lib/validate-task.sh"

# Проект, доведённый до состояния, в котором gate build проходит ВСЕ
# предыдущие проверки: git-репо, закоммиченный plan.json, phase=plan-done,
# агент на каждую роль плана.
mkdir -p "$gl_proj/.claude/agents" "$gl_proj/.mvp"
(cd "$gl_proj" && git init -q . && git config user.email t@t && git config user.name t)
printf 'ASSEMBLED devops\n' > "$gl_proj/.claude/agents/devops-engineer.md"
printf '%s\n' '{"tasks":[{"id":"001","role":"devops-engineer"}]}' > "$gl_proj/.mvp/plan.json"
printf '%s\n' '{"phase":"plan-done"}' > "$gl_proj/.mvp/state.json"
(cd "$gl_proj" && git add .mvp .claude && git commit -qm init)
(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" \
   record devops-engineer docker-compose.fastify >/dev/null 2>&1)
(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" \
   seal >/dev/null 2>&1)
(cd "$gl_proj" && git add .mvp && git commit -qm lock)

g_clean="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: чистый проект проходит" "True" \
  "$(PL_J="$g_clean" python3 -c 'import json,os; print(json.loads(os.environ["PL_J"])["ok"])')"

# derived-дрейф: правим _common.md в плагине
printf 'COMMON v2\n' > "$gl_plugin/skills/bootstrap/templates/_common.md"
g_stale="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: derived-дрейф валит" "False" \
  "$(PL_J="$g_stale" python3 -c 'import json,os; print(json.loads(os.environ["PL_J"])["ok"])')"
assert_eq "gate-lock: hint зовёт в mvp:sync" "run mvp:sync" \
  "$(PL_J="$g_stale" python3 -c 'import json,os; print(json.loads(os.environ["PL_J"])["hint"])')"

# Вернуть плагин, пересобрать отметку, испортить только нормативку
printf 'COMMON v1\n' > "$gl_plugin/skills/bootstrap/templates/_common.md"
printf 'SKILL build v2 — новое требование\n' > "$gl_plugin/skills/build/SKILL.md"
g_norm="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: нормативка НЕ валит" "True" \
  "$(PL_J="$g_norm" python3 -c 'import json,os; print(json.loads(os.environ["PL_J"])["ok"])')"
assert_eq "gate-lock: нормативка попала в data" "skills/build/SKILL.md" \
  "$(PL_J="$g_norm" python3 -c 'import json,os; print(json.loads(os.environ["PL_J"])["data"]["normative_changed"][0])')"

# Отсутствие lock при наличии агентов — валит
rm "$gl_proj/.mvp/plugin-lock.json"
g_nolock="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: нет lock при наличии агентов — валит" "False" \
  "$(PL_J="$g_nolock" python3 -c 'import json,os; print(json.loads(os.environ["PL_J"])["ok"])')"
```

Если в `tests/lib/gate.test.sh` нет хелпера `assert_eq` под этим именем — скопируй его определение из `tests/lib/state.test.sh` (оно приведено в Task 1, Step 1) в начало файла рядом с остальными хелперами, не переименовывая существующие.

- [ ] **Step 2: Прогнать тест — убедиться, что он падает**

Run: `bash tests/lib/gate.test.sh`
Expected: FAIL на «derived-дрейф валит» — гейт пока не знает про lock и возвращает `ok:true`.

- [ ] **Step 3: Добавить политику в `gate_build()`**

В `lib/gate.sh`, в функции `gate_build()`, между блоком `missing_roles` и финальным `emit_result true "" "" ""` вставь:

```bash
  # --- plugin-lock: производное блокирует, нормативка только докладывается --
  #
  # Асимметрия намеренная (docs/specs/2026-09-21-plugin-lock-and-sync-design.md
  # §7). derived блокирует, потому что цена известна: устаревшие агенты не
  # регистрируются, задачи уходят на general-purpose без контракта _common.md,
  # и ревью их одобряет — оно судит дифф, а не автора. Нормативка не
  # блокирует, потому что иначе любой коммит в плагин останавливает все
  # проекты сразу, и первое, чему научится оператор — обходить гейт.
  #
  # `check` возвращает ok:false на ЛЮБОЕ расхождение — он диагност, а не
  # политика. Политика здесь.
  local lock_json
  lock_json="$("$here/plugin-lock.sh" check 2>/dev/null | tail -n1)"
  local lock_verdict
  lock_verdict="$(GB_J="$lock_json" python3 -c '
import json, os, sys
raw = os.environ.get("GB_J") or ""
try:
    r = json.loads(raw)
except ValueError:
    # Скрипт не отдал контракт (нет python3? снесли файл?). Молча пропускать
    # нельзя, но и валить build из-за сломанного диагноста — хуже: сам гейт
    # тогда становится точкой отказа. Пропускаем, назвав причину.
    print(json.dumps({"verdict": "skip", "reason": "plugin-lock.sh gave no JSON contract"}))
    sys.exit(0)

d = r.get("data") or {}
if d.get("lock_present") is False:
    print(json.dumps({"verdict": "halt",
                      "reason": "no .mvp/plugin-lock.json — cannot tell if agents match the plugin"}))
    sys.exit(0)

hard = []
for key, label in (("derived_stale", "stale"), ("derived_tampered", "hand-edited"),
                   ("derived_missing", "missing")):
    for item in d.get(key) or []:
        hard.append("%s(%s)" % (item.get("role"), label))
if hard:
    print(json.dumps({"verdict": "halt",
                      "reason": "agent file(s) out of sync with plugin: " + ", ".join(sorted(hard))}))
    sys.exit(0)

soft = {k: d.get(k) or [] for k in ("normative_changed", "normative_added", "normative_removed")}
if any(soft.values()):
    print(json.dumps({"verdict": "warn", "data": soft}))
    sys.exit(0)

print(json.dumps({"verdict": "clean"}))
')"

  local lv
  lv="$(GB_V="$lock_verdict" python3 -c 'import json,os; print(json.loads(os.environ["GB_V"])["verdict"])')"
  if [ "$lv" = "halt" ]; then
    local lock_reason
    lock_reason="$(GB_V="$lock_verdict" python3 -c 'import json,os; print(json.loads(os.environ["GB_V"])["reason"])')"
    emit_result false "$lock_reason" "run mvp:sync" ""
    exit 1
  fi
  if [ "$lv" = "warn" ]; then
    local lock_data
    lock_data="$(GB_V="$lock_verdict" python3 -c 'import json,os; print(json.dumps(json.loads(os.environ["GB_V"])["data"]))')"
    emit_result true "" "" "$lock_data"
    exit 0
  fi
```

- [ ] **Step 4: Прогнать тесты — убедиться, что они зелёные**

Run: `bash tests/lib/gate.test.sh && bash tests/lib/plugin-lock.test.sh && echo PASS`
Expected: `PASS`.

- [ ] **Step 5: Негативный контроль**

1. Поменяй `if [ "$lv" = "halt" ]` на `if false` — тест «derived-дрейф валит» обязан упасть.
2. Добавь `hard` к мягкой ветке (чтобы нормативка тоже халтила) — тест «нормативка НЕ валит» обязан упасть. Это ровно та ошибка, ради которой асимметрия документирована в комментарии.
3. Убери ветку `lock_present is False` — тест «нет lock при наличии агентов» обязан упасть.

- [ ] **Step 6: Добавить упоминание в `skills/build/SKILL.md`**

В таблице halt'ов, в строке `bad-args / error`, ничего не меняется. Добавь в Шаг 1 («гейт») после существующего текста про `ok:false`:

```markdown
`ok:true` с непустым `data.normative_changed` / `normative_added` /
`normative_removed` — в плагине изменились нормативные файлы после того, как
проект их принял. Не блокер: покажи список оператору одной строкой и
продолжай. Разобраться — `mvp:sync`.
```

Проверь бюджет: `bash tests/lib/skill-size.test.sh` — `build` не должен выйти за `ORCH_MAX` (13312). Вышел — режь текст, а не поднимай лимит.

- [ ] **Step 7: Коммит**

```bash
git add lib/gate.sh skills/build/SKILL.md tests/lib/gate.test.sh
git commit -m "feat(gate): build не стартует на устаревших агентах

derived-дрейф блокирует: цена известна и измерена — устаревшие агенты не
регистрируются, задачи уходят на general-purpose без контракта, ревью их
одобряет, потому что судит дифф, а не автора. Нормативный дрейф не
блокирует: иначе любой коммит в плагин останавливает все проекты, и первое,
чему научится оператор — обходить гейт."
```

---

### Task 6: пресет scope `sync` в `lib/finalize.sh`

**Files:**
- Modify: `lib/finalize.sh` — `VALID_SCOPES`, `case "$SCOPE"` в блоке parse argv, `case "$SCOPE"` в блоке resolve preset, шапка файла
- Test: `tests/lib/finalize.test.sh`

**Interfaces:**
- Consumes: ничего нового.
- Produces: `finalize.sh sync <msg-file>` стейджит ровно `.claude/agents` и `.mvp/plugin-lock.json`.

- [ ] **Step 1: Написать падающий тест**

Добавь в `tests/lib/finalize.test.sh` перед финальным `exit`, переиспользуя хелперы файла:

```bash
# --- scope sync стейджит ровно два пути ---------------------------------
# Не переиспользуем пресет bootstrap: тот тянет CLAUDE.md и
# docs/architecture.md и затащил бы в sync-коммит несвязанные грязные файлы.

fs_proj="$tmpdir/finalize-sync-proj"
mkdir -p "$fs_proj/.claude/agents" "$fs_proj/.mvp" "$fs_proj/docs"
(cd "$fs_proj" && git init -q . && git config user.email t@t && git config user.name t)
printf 'v1\n' > "$fs_proj/.claude/agents/devops-engineer.md"
printf '{}\n'  > "$fs_proj/.mvp/plugin-lock.json"
printf 'v1\n' > "$fs_proj/CLAUDE.md"
printf 'v1\n' > "$fs_proj/docs/architecture.md"
printf 'v1\n' > "$fs_proj/.mvp/ledger.md"
(cd "$fs_proj" && git add . && git commit -qm init)

# Грязним всё: и то, что sync обязан взять, и то, что обязан оставить.
printf 'v2\n' > "$fs_proj/.claude/agents/devops-engineer.md"
printf '{"x":1}\n' > "$fs_proj/.mvp/plugin-lock.json"
printf 'v2\n' > "$fs_proj/CLAUDE.md"
printf 'v2\n' > "$fs_proj/.mvp/ledger.md"

printf 'chore: sync plugin artifacts\n' > "$tmpdir/fs-msg"
fs_out="$(cd "$fs_proj" && bash "$repo_root/lib/finalize.sh" sync "$tmpdir/fs-msg" 2>/dev/null | tail -n1)"
assert_eq "finalize sync: ok" "True" \
  "$(PL_J="$fs_out" python3 -c 'import json,os; print(json.loads(os.environ["PL_J"])["ok"])')"

fs_files="$(cd "$fs_proj" && git show --name-only --format= HEAD | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "finalize sync: ровно два пути в коммите" \
  ".claude/agents/devops-engineer.md .mvp/plugin-lock.json" "$fs_files"

fs_dirty="$(cd "$fs_proj" && git status --porcelain | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "finalize sync: остальное осталось грязным" "CLAUDE.md .mvp/ledger.md" "$fs_dirty"
```

- [ ] **Step 2: Прогнать тест — убедиться, что он падает**

Run: `bash tests/lib/finalize.test.sh`
Expected: FAIL. `finalize.sh` отвечает `unknown scope: sync` и выходит 1.

- [ ] **Step 3: Добавить пресет**

Три правки в `lib/finalize.sh`.

В шапке, в списке пресетов после строки про `plan`:

```
#   sync       = .claude/agents .mvp/plugin-lock.json
```

Переменную `VALID_SCOPES`:

```bash
VALID_SCOPES="brief clarify bootstrap plan sync build-task"
```

В блоке parse argv:

```bash
case "$SCOPE" in
  brief|clarify|bootstrap|plan|sync|build-task) ;;
  *) fail "unknown scope: ${SCOPE:-<missing>}" "$USAGE (scopes: $VALID_SCOPES)" ;;
esac
```

В блоке resolve preset, между `plan)` и `build-task)`:

```bash
  # Узко по построению: sync трогает только то, что сам чинит. Пресет
  # bootstrap шире (CLAUDE.md, docs/architecture.md) и затащил бы в коммит
  # несвязанные грязные файлы.
  sync) PATHS=(.claude/agents .mvp/plugin-lock.json) ;;
```

- [ ] **Step 4: Прогнать тест — убедиться, что он зелёный**

Run: `bash tests/lib/finalize.test.sh && echo PASS`
Expected: `PASS`.

- [ ] **Step 5: Негативный контроль**

1. Поменяй пресет на `PATHS=(.claude/agents .mvp)` — тест «остальное осталось грязным» обязан упасть: `.mvp/ledger.md` уедет в коммит.
2. Убери `sync` из `VALID_SCOPES`, оставив его в обоих `case` — тест обязан остаться **зелёным** (переменная только для текста ошибки). Это показывает, что тест не проверяет `VALID_SCOPES`; так и задумано, но знай об этом. Верни.

- [ ] **Step 6: Коммит**

```bash
git add lib/finalize.sh tests/lib/finalize.test.sh
git commit -m "feat(finalize): пресет scope sync

Стейджит ровно .claude/agents и .mvp/plugin-lock.json. Пресет bootstrap для
этого слишком широк: он тянет CLAUDE.md и docs/architecture.md."
```

---

### Task 7: скилл `mvp:sync`

**Files:**
- Create: `skills/sync/SKILL.md`
- Modify: `tests/lib/skill-size.test.sh` (добавить `sync` в цикл `GATE_MAX`)
- Modify: `docs/specs/2026-08-21-mvp-pipeline-v2-design.md` — секция «Размер», перечень gate-скиллов

**Interfaces:**
- Consumes: `lib/plugin-lock.sh check|seal`, `skills/bootstrap/scripts/assemble-agent.sh`, `skills/bootstrap/scripts/verify-agents-drift.sh`, `lib/finalize.sh sync`.
- Produces: скилл `mvp:sync`. Терминальный — `NEXT` отсутствует.

- [ ] **Step 1: Написать падающий тест**

В `tests/lib/skill-size.test.sh` поменяй строку:

```bash
for name in resume retro; do
```

на:

```bash
for name in resume retro sync; do
```

- [ ] **Step 2: Прогнать тест — убедиться, что он падает**

Run: `bash tests/lib/skill-size.test.sh`
Expected: FAIL со строкой `gate skill sync missing: .../skills/sync/SKILL.md`.

- [ ] **Step 3: Написать `skills/sync/SKILL.md`**

Бюджет — 4096 байт. Держись в нём; вылез — режь текст, а не поднимай лимит.

```markdown
---
name: sync
description: Use when the plugin was updated to rebuild derived project artifacts and report changed requirements
---

# mvp:sync

**Announce at start:** «Using mvp:sync to realign project artifacts with the current plugin».

**Iron Law: чинится только производное; нормативка докладывается, но никогда не применяется автоматически.** Производное — `.claude/agents/*.md`, собранные механически из шаблонов. Нормативное — требования из `SKILL.md`/`lib/*`, которые могут потребовать правок проектного кода; решает по ним оператор, не ты.

Скилл терминальный: **NEXT отсутствует**.

## Шаг 1 — проверка

```
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh check
```

`ok:true` → скажи «проект соответствует текущему плагину», останови скилл.

## Шаг 2 — нет отметки

`data.lock_present == false` → Stop&Ask. Перечисли роли из `.claude/agents/*.md`, предложи стек каждой из `## Stack` брифа (`docs/product/technical-solutions.md`) и дождись подтверждения оператора.

**Не угадывай.** Собранный агент не помнит своего шаблона: по фронтматтеру `docker-compose.fastify` и `docker-dokploy.nestjs` неразличимы. Неверный стек соберёт не того агента и ничем себя не выдаст.

Запрещено: печатать lock от текущего состояния без пересборки — это залочит существующее расхождение как норму.

## Шаг 3 — пересборка

На каждую роль из `data.derived_stale`, `derived_tampered`, `derived_missing`:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/assemble-agent.sh <role> [stack]
```

`stack` бери из самой находки (`data.derived_*[].stack`), пустой — не передавай. Отметку в lock скрипт обновит сам.

Роль из `derived_missing` стека не несёт — спроси оператора, как на Шаге 2.

Затем:

```
${CLAUDE_PLUGIN_ROOT}/skills/bootstrap/scripts/verify-agents-drift.sh
```

`ok:false` — НЕ правь `.claude/agents/*.md` руками, чини `assemble-agent.sh`.

## Шаг 4 — нормативка

Покажи `normative_changed` / `normative_added` / `normative_removed`. Если `plugin.git_sha` в `.mvp/plugin-lock.json` непуст и плагин — git-чекаут:

```
git -C ${CLAUDE_PLUGIN_ROOT} diff <git_sha>..HEAD -- <пути>
```

Коммита нет в чекауте (переустановка, force-push) — покажи только список путей, это не ошибка.

## Шаг 5 — Stop&Ask по нормативке

Спроси оператора: требует ли изменение правок в проекте. Требует — это **отдельная задача плана**, не работа sync'а:

```
${CLAUDE_PLUGIN_ROOT}/lib/plan-io.mjs add-task --json '{...}'
```

## Шаг 6 — печать и коммит

Только после подтверждения оператора:

```
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh seal
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh sync <msg-file>
```

`<msg-file>` первой строкой: `chore: sync project artifacts with plugin`.

## Rationalization table

| Соблазн | Почему нет |
|---|---|
| «Нормативка изменилась не сильно, запечатаю без чтения» | `seal` — заявление «я прочитал и принял»; без чтения механизм превращается в тихого догонялу плагина |
| «Подправлю `.claude/agents/*.md` руками, там одна строка» | `check` назовёт это `tampered`; правится шаблон в плагине, затем пересборка |
| «Стек роли не записан, но я его помню» | Шаг 2 — Stop&Ask; неверный стек собирает не того агента и ничем себя не выдаёт |
| «Перегенерирую заодно `ci-mirror.sh`, он тоже из шаблона» | пять строк маппинга внутри проектного кода, выросшего по инцидентам; перегенерация уничтожит работу |

## HARD-GATE

Покажи: что пересобрано, результат `verify-agents-drift.sh`, список нормативных изменений, sha коммита.

Если пересобран хоть один агент — скажи оператору **дословно**:

> Агенты зарегистрируются только в НОВОЙ сессии. Перед `mvp:build` перезапусти сессию, иначе задачи пойдут на `general-purpose` без контракта `_common.md`.

Скажи: «sync complete».
```

- [ ] **Step 4: Прогнать тест — убедиться, что он зелёный**

Run: `bash tests/lib/skill-size.test.sh && echo PASS`
Expected: `PASS`. Проверка «ровно два поля фронтматтера» пройдёт автоматически — цикл по `skills/*/SKILL.md` в этом же файле общий для всех скиллов.

- [ ] **Step 5: Синхронизировать спеку**

В `docs/specs/2026-08-21-mvp-pipeline-v2-design.md`, в секции «Размер», добавь `sync` в перечень gate-скиллов рядом с `resume` и `retro`. Бюджет там уже описан как 2–4 КБ — менять число не нужно, нужно, чтобы перечень скиллов не расходился с тестом.

- [ ] **Step 6: Негативный контроль**

1. Допиши в `skills/sync/SKILL.md` абзац на 1 КБ — тест обязан упасть с указанием перебора в байтах. Убери.
2. Добавь третье поле в фронтматтер (`model: opus`) — тест обязан упасть на «has 3 frontmatter field(s)». Убери.

- [ ] **Step 7: Коммит**

```bash
git add skills/sync/SKILL.md tests/lib/skill-size.test.sh docs/specs/2026-08-21-mvp-pipeline-v2-design.md
git commit -m "feat(sync): скилл mvp:sync

Чинит производное, докладывает нормативное, требует перезапуска сессии,
если пересобрал агентов. Шаг 5 — единственное место, где скилл думает, и
оно же предел механизма: sync не решает, что новое требование означает для
проектного кода, он гарантирует, что оператор это требование увидит."
```

---

### Task 8: `mvp:bootstrap` печатает нормативку

**Files:**
- Modify: `skills/bootstrap/SKILL.md` — Шаг 7
- Test: ручная проверка через `tests/lib/check-meta.test.sh` + прогон всего набора

**Interfaces:**
- Consumes: `lib/plugin-lock.sh seal` из Task 3.
- Produces: после `mvp:bootstrap` в проекте лежит lock-файл с обеими секциями, закоммиченный вместе с bootstrap-коммитом.

- [ ] **Step 1: Правка Шага 7**

В `skills/bootstrap/SKILL.md` найди Шаг 7 и замени блок команд на:

```
${CLAUDE_PLUGIN_ROOT}/lib/state.sh set phase bootstrap-done
${CLAUDE_PLUGIN_ROOT}/lib/plugin-lock.sh seal
${CLAUDE_PLUGIN_ROOT}/lib/finalize.sh bootstrap <msg-file>
```

И добавь абзацем ниже:

```markdown
`seal` — первичная печать нормативных файлов плагина: с этого момента
проект помнит, от каких требований он собран, и `mvp:sync` сможет показать,
что изменилось потом. Секцию `derived` печатать не нужно — её записал
`assemble-agent.sh` на Шаге 4. Пресет `bootstrap` стейджит `.mvp` целиком,
так что `plugin-lock.json` попадает в bootstrap-коммит без правки пресета.
```

- [ ] **Step 2: Проверить бюджет**

Run: `bash tests/lib/skill-size.test.sh`
Expected: PASS. `bootstrap` близок к `ORCH_MAX` (13312) — если вылез, сократи текст Шага 7, не поднимай лимит.

- [ ] **Step 3: Прогнать весь набор тестов**

Run: `bash tests/run.sh`
Expected: все строки `PASS`, exit 0.

- [ ] **Step 4: Негативный контроль на связку целиком**

Собери одноразовый проект на поддельном плагине и убедись, что цепочка замыкается:

```bash
T="$(mktemp -d)"
mkdir -p "$T/proj/.claude/agents" "$T/proj/.mvp"
# используй make_fake_plugin из tests/lib/plugin-lock.test.sh как образец
# для $T/plugin, затем:
cd "$T/proj"
PLUGIN_ROOT="$T/plugin" TEMPLATES_DIR="$T/plugin/skills/bootstrap/templates" \
  bash <путь>/skills/bootstrap/scripts/assemble-agent.sh devops-engineer docker-compose.fastify
PLUGIN_ROOT="$T/plugin" bash <путь>/lib/plugin-lock.sh seal
PLUGIN_ROOT="$T/plugin" bash <путь>/lib/plugin-lock.sh check   # ожидание: ok:true
printf 'COMMON v2\n' > "$T/plugin/skills/bootstrap/templates/_common.md"
PLUGIN_ROOT="$T/plugin" bash <путь>/lib/plugin-lock.sh check   # ожидание: ok:false, derived_stale
```

Второй `check` обязан дать `ok:false` с непустым `derived_stale`. Дал `ok:true` — где-то в цепочке отметка не записалась.

- [ ] **Step 5: Коммит**

```bash
git add skills/bootstrap/SKILL.md
git commit -m "feat(bootstrap): seal на Шаге 7 — первичная печать нормативки

С этого момента проект помнит, от каких требований плагина он собран."
```

---

### Task 9: миграция `trellis` — первый живой прогон

**Files:**
- Modify (в репозитории `/Users/vadim/Documents/Pet/trellis`): `.claude/agents/*.md`, `.mvp/plugin-lock.json`

**Interfaces:**
- Consumes: весь механизм из Task 1–8.
- Produces: `trellis` с корректным lock-файлом и агентами, собранными от текущего плагина.

Это не правка кода плагина, а его первый живой прогон. Разнести отладку механизма и миграцию проекта не получится: других проектов с собранными агентами нет.

- [ ] **Step 1: Зафиксировать исходное состояние**

```bash
cd /Users/vadim/Documents/Pet/trellis
git status --short
bash /Users/vadim/Documents/tools/claude/mvp-plugin/skills/bootstrap/scripts/verify-agents-drift.sh
```

Expected: дерево чистое; drift-check даёт `5/5 agent files drifted from _common.md`.

- [ ] **Step 2: Прогнать `mvp:sync`**

Запусти скилл. Он обязан пойти по Шагу 2 (lock отсутствует) и спросить стеки. Ответы для `trellis`:

| роль | стек |
|---|---|
| `backend-implementer` | `fastify` |
| `devops-engineer` | `docker-compose.fastify` |
| `frontend-implementer` | `react` |
| `integration-specialist` | (без стека) |
| `test-writer` | `fastify` |

- [ ] **Step 3: Проверить результат пересборки**

```bash
bash /Users/vadim/Documents/tools/claude/mvp-plugin/skills/bootstrap/scripts/verify-agents-drift.sh
bash /Users/vadim/Documents/tools/claude/mvp-plugin/lib/plugin-lock.sh check
```

Expected: drift-check — `✓ DRIFT-check passed: 5 agent files`; `check` — `ok:true`.

- [ ] **Step 4: Разобрать нормативку**

На Шаге 4 скилла в список попадут наши правки `_common.md` (раздел `## Not executed`, принцип про exit-code и недоступность `grep -P` на BSD grep) и шаблона devops (e2e-изоляция).

По e2e-изоляции сверься с тем, что проект уже сделал сам: прочитай `tests/e2e/helpers/compose.ts` и проверь, совпадает ли реализация с требованием шаблона — свой `--project-name`, свой именованный volume, удаление volume по имени, никогда `down -v`, ожидание через `up --wait`.

Совпадает — правок проекта не нужно, это записывается решением оператора. Не совпадает — `plan-io.mjs add-task`.

- [ ] **Step 5: Проверить гейт**

```bash
bash /Users/vadim/Documents/tools/claude/mvp-plugin/lib/gate.sh build
```

Expected: `phase` в `trellis` сейчас `done`, поэтому гейт закономерно упадёт на `phase != plan-done` — это ожидаемо и правильно. Важно другое: в `reason` **не должно** быть ни слова про `plugin-lock` и агентов.

- [ ] **Step 6: Коммит (внутри скилла, Шаг 6)**

Проверь, что коммит содержит ровно `.claude/agents/*.md` и `.mvp/plugin-lock.json`:

```bash
git show --name-only --format= HEAD
```

Ничего лишнего — `.mvp/ledger.md` и прочее остаются вне коммита.

---

## Self-Review

**Покрытие спеки.**

| Раздел спеки | Задача |
|---|---|
| §4 формат lock | Task 1 (derived), Task 3 (normative) |
| §4.1 хэши, не версия | Task 1 — `plugin` пишется справочно, ни один гейт по нему не судит |
| §4.2 ключ = путь артефакта, role/stack/template/placeholders | Task 1, тесты 1 и 8 |
| §4.3 `output_sha256` | Task 1 (запись), Task 2 (тест 4 — `tampered`) |
| §4.4 состав normative глобами | Task 3, тесты 5b, 10, 10b |
| §5.1 `record` | Task 1 |
| §5.2 `check` | Task 2 (derived), Task 3 (normative) |
| §5.3 `seal` | Task 3, тест 7 |
| §6 assemble-agent штампует сам | Task 4 |
| §7 политика гейта | Task 5 |
| §8 скилл | Task 7 |
| §8.1 rationalization table | Task 7 |
| §9 finalize scope sync | Task 6 |
| §10 bootstrap Шаг 7 | Task 8 |
| §11 тесты 1–10 | Task 1 (1, 8), Task 2 (2, 3, 4, 6, 9), Task 3 (5, 7, 10) |
| §12 миграция trellis | Task 9 |

Пробелов не осталось. Случай «lock есть, но невалидный JSON» в §11 не перечислен — он обрабатывается в Task 1 и Task 2 (ветка `ValueError`), отдельного теста на него нет сознательно: путь восстановления тот же, что при отсутствии файла.

**Согласованность имён.** `record`/`check`/`seal` — одни и те же во всех задачах. Ключи `data`: `lock_present`, `derived_stale`, `derived_tampered`, `derived_missing`, `normative_changed`, `normative_added`, `normative_removed` — Task 2 определяет, Task 3 наполняет, Task 5 читает, Task 7 использует в тексте скилла. Env: `PLUGIN_ROOT`, `STATE_DIR`, `OUT_DIR`, `PROJECT`, `SERVICE_API`, `SERVICE_WORKER` — одинаково в Task 1, 2, 3, 4. Поле `stack` в находке `derived_stale`/`derived_tampered` есть (Task 2) и читается скиллом на Шаге 3 (Task 7); в `derived_missing` его нет, поэтому Task 7 говорит «бери из самой находки» только там, где оно есть — для `missing` роль придётся уточнить у оператора, как на Шаге 2.

Это последнее — реальный шов, и он закрыт в тексте самого скилла: Шаг 3 в Task 7 содержит строку «роль из `derived_missing` стека не несёт — спроси оператора, как на Шаге 2». `derived_missing` намеренно несёт только `{"path", "role"}`: стек взять неоткуда, а выдуманный собрал бы не того агента молча.
