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
# Использование:
#   assemble-agent.sh backend-implementer nestjs
#   assemble-agent.sh code-reviewer            # роли без стек-вариантов
#
# Переменные окружения:
#   TEMPLATES_DIR  — путь к шаблонам (default: <plugin>/skills/bootstrap/templates)
#   OUT_DIR        — куда писать (default: .claude/agents — относительно cwd)
#   PROJECT        — значение для {{PROJECT}} (default: basename cwd, slug'ифицированный)
#   SERVICE_API    — значение для {{SERVICE_API}} (default: "${PROJECT}-api")
#   SERVICE_WORKER — значение для {{SERVICE_WORKER}} (default: "${PROJECT}-worker")
#
# Источник значений (документировано в task-11 report): {{PROJECT}} в brief
# не хранится отдельным полем (project_brief-контракт его не требует) —
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

mv "$TMP" "$OUT"
trap - EXIT

DATA="$(python3 -c 'import json,sys; print(json.dumps({"out": sys.argv[1], "template": sys.argv[2]}))' "$OUT" "$(basename "$TEMPLATE")")"
emit_result true "" "" "$DATA"
exit 0
