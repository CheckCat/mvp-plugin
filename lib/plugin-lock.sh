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
