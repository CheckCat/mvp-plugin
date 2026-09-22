#!/usr/bin/env bash
# assemble-agent.sh <role> [stack]
#
# Механическая склейка проектного агент-файла из плагиновых шаблонов. Run
# from the TARGET PROJECT root (not this plugin repo) — writes into
# ./.claude/agents relative to cwd. Single-line JSON contract on every exit
# path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":{"out":str,"template":str}|null}
# ok:false always exits 1.
#
# Структура результата:
#   1. Frontmatter из <role>.<stack>.template.md (или <role>.template.md)
#   2. _common.md целиком
#   3. Разделитель ---
#   4. Тело шаблона роли (всё после второго ---)
#   5. Placeholder-подстановка: {{PROJECT}}, {{SERVICE_API}}, {{SERVICE_WORKER}}
#      заменяются буквенно (никакого generic "{{...}}" regex — некоторые
#      шаблоны легитимно содержат "${{ matrix.service }}" из GitHub Actions
#      YAML, который substitution обязан не трогать).
#
# Исключение — роли с префиксом mvp-: механика пайплайна (reviewer/validator/
# relay), а не инженер проекта. Шаблон копируется в OUT_DIR как есть, шаги
# 1-5 (и _common.md) для них пропускаются целиком.
#
# --capped <role>: эксперимент H1-cap-work-preservation (спека 2026-09-22
# §9) — берёт уже СОБРАННЫЙ .claude/agents/<role>.md (не шаблон — значит
# общий контракт _common.md в нём уже есть, verify-agents-drift.sh обязан
# продолжать его видеть), заменяет/вставляет "maxTurns: 30" во фронтматтере
# и "name:" на "<role>-capped", пишет .claude/agents/<role>-capped.md.
# Файл живёт, пока гипотеза H1 открыта — закрытие гипотезы удаляет его
# руками (см. experiments-handbook), поэтому record в plugin-lock.json НЕ
# зовётся: это экспериментальный артефакт, а не производное плагина.
# `plugin-lock.sh check` покажет его в derived_unstamped как foreign —
# lib/gate.sh не блокирует build по чужому unstamped-файлу, чья роль не
# диспатчится планом (см. коммент в lib/gate.sh про derived_unstamped_foreign).
#
# Использование:
#   assemble-agent.sh backend-implementer nestjs
#   assemble-agent.sh integration-specialist   # роли без стек-вариантов
#   assemble-agent.sh mvp-relay                # роль механики пайплайна
#   assemble-agent.sh --capped integration-specialist   # H1-эксперимент
#
# Переменные окружения:
#   TEMPLATES_DIR  — путь к шаблонам (default: <plugin>/skills/bootstrap/templates)
#   OUT_DIR        — куда писать (default: .claude/agents — относительно cwd)
#   PROJECT        — значение для {{PROJECT}} (default: basename cwd, slug'ифицированный)
#   SERVICE_API    — значение для {{SERVICE_API}} (default: "${PROJECT}-api")
#   SERVICE_WORKER — значение для {{SERVICE_WORKER}} (default: "${PROJECT}-worker")
#
# Источник значений (документировано в task-11 report): {{PROJECT}} в brief
# не хранится отдельным полем (docs/product-контракт его не требует) —
# поэтому дефолт берётся из имени директории проекта, а не из текста brief'а;
# вызывающий (mvp:bootstrap SKILL.md) может переопределить через env, если у
# оператора есть явное имя проекта.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: assemble-agent.sh <role> [stack]"

# emit_result <ok:true|false> <reason> <hint> <data-json> — see lib/gate.sh.
emit_result() {
  AA_OK="$1" AA_REASON="$2" AA_HINT="$3" AA_DATA="$4" python3 -c '
import json, os
ok = os.environ["AA_OK"] == "true"
reason = os.environ.get("AA_REASON") or None
hint = os.environ.get("AA_HINT") or None
data_raw = os.environ.get("AA_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint]
  emit_result false "$1" "${2:-}" ""
  exit 1
}

# --capped <role> — ранняя ветка, до обычного парсинга ROLE/STACK: сама роль
# приходит вторым аргументом, а не первым. Никакого record в plugin-lock —
# это экспериментальный H1-артефакт, не производное плагина (см. коммент в
# начале файла).
if [ "${1:-}" = "--capped" ]; then
  CAP_ROLE="${2:-}"
  if [ -z "$CAP_ROLE" ]; then
    fail "missing role" "usage: assemble-agent.sh --capped <role>"
  fi
  case "$CAP_ROLE" in
    mvp-*)
      # Роли механики пайплайна (reviewer/validator/relay) собираются БЕЗ
      # _common.md (см. case "$ROLE" in mvp-*) ниже) — capped-копии из них
      # были бы копиями без общего контракта, а SKILL (Шаг 4 bootstrap)
      # декларирует capped-копии только для имплементерских ролей. Отказ
      # здесь, а не молчаливая сборка чего-то, что verify-agents-drift.sh
      # потом не сможет проверить как имплементерскую роль.
      fail "role=$CAP_ROLE is a pipeline-mechanic role (mvp-*) — --capped is for implementer roles only" \
        "mvp-* roles are assembled without the _common.md contract by design; a capped copy of one is not the H1 experiment this flag is for"
      ;;
  esac
  CAP_OUT_DIR="${OUT_DIR:-.claude/agents}"
  CAP_SRC="$CAP_OUT_DIR/$CAP_ROLE.md"
  CAP_DST="$CAP_OUT_DIR/$CAP_ROLE-capped.md"
  if [ ! -f "$CAP_SRC" ]; then
    fail "no assembled agent for role=$CAP_ROLE: $CAP_SRC" \
      "run assemble-agent.sh $CAP_ROLE [stack] first — --capped copies an already-assembled file, it does not assemble from a template"
  fi
  # Python-ошибка (raise SystemExit("...")) обязана доехать до hint'а по имени
  # причины, как и остальные отказы в этом файле (ниже: LOCK_OUT, "no template
  # for role"), а не общей «смотри вывод python выше». Ловим stdout+stderr:
  # на успехе скрипт ничего не печатает, на отказе — ровно текст SystemExit.
  CAP_ERR="$(CA_SRC="$CAP_SRC" CA_DST="$CAP_DST" CA_ROLE="$CAP_ROLE" python3 -c '
import os, tempfile

src, dst, role = os.environ["CA_SRC"], os.environ["CA_DST"], os.environ["CA_ROLE"]
text = open(src, encoding="utf-8").read()
lines = text.split("\n")

# Фронтматтер — от первой строки "---" до следующей строки "---".
if not lines or lines[0] != "---":
    raise SystemExit("assembled agent has no frontmatter: %s" % src)
end = next((i for i in range(1, len(lines)) if lines[i] == "---"), None)
if end is None:
    raise SystemExit("assembled agent frontmatter has no closing ---: %s" % src)

found_max_turns = False
for i in range(1, end):
    if lines[i].startswith("name:"):
        lines[i] = "name: %s-capped" % role
    elif lines[i].startswith("maxTurns:"):
        lines[i] = "maxTurns: 30"
        found_max_turns = True
if not found_max_turns:
    lines.insert(end, "maxTurns: 30")

out_dir = os.path.dirname(dst) or "."
with tempfile.NamedTemporaryFile("w", dir=out_dir, delete=False, encoding="utf-8") as tmp:
    tmp.write("\n".join(lines))
    tmp_path = tmp.name
os.replace(tmp_path, dst)
' 2>&1)"
  if [ $? -ne 0 ]; then
    fail "--capped: failed to build capped copy for role=$CAP_ROLE" "${CAP_ERR:-python3 exited non-zero with no message — check disk space/permissions for $CAP_DST}"
  fi
  CAP_DATA="$(python3 -c 'import json,sys; print(json.dumps({"out": sys.argv[1], "role": sys.argv[2]}))' "$CAP_DST" "$CAP_ROLE-capped")"
  emit_result true "" "" "$CAP_DATA"
  exit 0
fi

ROLE="${1:-}"
if [ -z "$ROLE" ]; then
  fail "missing role" "$USAGE"
fi
STACK="${2:-}"

TEMPLATES_DIR="${TEMPLATES_DIR:-$here/../templates}"
OUT_DIR="${OUT_DIR:-.claude/agents}"

# slugify: lowercase, non [a-z0-9-] -> '-', collapse/trim '-'
_slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}
DEFAULT_PROJECT="$(_slugify "$(basename "$(pwd)")")"
PROJECT="${PROJECT:-$DEFAULT_PROJECT}"
SERVICE_API="${SERVICE_API:-${PROJECT}-api}"
SERVICE_WORKER="${SERVICE_WORKER:-${PROJECT}-worker}"

COMMON="$TEMPLATES_DIR/_common.md"
if [ ! -f "$COMMON" ]; then
  fail "_common.md missing: $COMMON" "check TEMPLATES_DIR / plugin install"
fi

if [ -n "$STACK" ] && [ -f "$TEMPLATES_DIR/$ROLE.$STACK.template.md" ]; then
  TEMPLATE="$TEMPLATES_DIR/$ROLE.$STACK.template.md"
elif [ -f "$TEMPLATES_DIR/$ROLE.template.md" ]; then
  TEMPLATE="$TEMPLATES_DIR/$ROLE.template.md"
else
  fail "no template for role=$ROLE stack=$STACK in $TEMPLATES_DIR" \
    "check role/stack spelling, or that TEMPLATES_DIR points at skills/bootstrap/templates"
fi

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$ROLE.md"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

case "$ROLE" in
  mvp-*)
    # mvp-роли — механика пайплайна, а не инженеры проекта: контракт границы
    # задачи им не нужен, его отсутствие — и есть диета префикса (спека
    # 2026-09-22 §4). Шаблон цельный (frontmatter + тело уже собраны автором
    # шаблона) — копируем как есть, без _common.md и без placeholder-подстановки.
    cp "$TEMPLATE" "$TMP"
    ;;
  *)
    # 1. Frontmatter (от первого --- до второго ---, включительно)
    awk '
      /^---$/ {
        print
        c++
        if (c == 2) exit
        next
      }
      c == 1 { print }
    ' "$TEMPLATE" > "$TMP"

    # 2. Пустая строка + _common.md целиком
    printf "\n" >> "$TMP"
    cat "$COMMON" >> "$TMP"

    # 3. Разделитель
    printf "\n---\n\n" >> "$TMP"

    # 4. Тело шаблона роли (всё после второго ---, ведущие пустые строки срезаются)
    awk '
      /^---$/ { c++; next }
      c >= 2 {
        if (!started) {
          if (NF == 0) next
          started = 1
        }
        print
      }
    ' "$TEMPLATE" >> "$TMP"

    # 5. Placeholder-подстановка: только три известных литерала, никакого generic
    #    "{{...}}" — не трогаем "${{ matrix.service }}" (GitHub Actions YAML) в
    #    devops-engineer.docker-dokploy.fastapi.template.md.
    AA_TMP="$TMP" PROJECT="$PROJECT" SERVICE_API="$SERVICE_API" SERVICE_WORKER="$SERVICE_WORKER" python3 -c '
import os
path = os.environ["AA_TMP"]
text = open(path, encoding="utf-8").read()
text = text.replace("{{PROJECT}}", os.environ["PROJECT"])
text = text.replace("{{SERVICE_API}}", os.environ["SERVICE_API"])
text = text.replace("{{SERVICE_WORKER}}", os.environ["SERVICE_WORKER"])
open(path, "w", encoding="utf-8").write(text)
'
    if [ $? -ne 0 ]; then
      fail "placeholder substitution failed" "python3 error while writing $TMP — see stderr above"
    fi
    ;;
esac

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
