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

# Состав нормативки — глобами, не списком: новый файл плагина попадает под
# наблюдение сам. Список был бы третьим источником правды рядом с кодом и
# шаблонами и начал бы врать с первого забытого обновления (спека §4.4).
# Намеренно снаружи: skills/*/agents/*, skills/*/references/* (меняют
# поведение плагина, но не требуют изменений в проекте), docs/, tests/.
NORMATIVE_GLOBS='skills/*/SKILL.md skills/*/scripts/* lib/*'

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
  check)
    PL_PLUGIN_ROOT="$PLUGIN_ROOT" PL_LOCK="$LOCK" PL_GLOBS="$NORMATIVE_GLOBS" PL_OUT_DIR="$OUT_DIR" python3 -c '
import hashlib, json, os, pathlib, sys

plugin_root = pathlib.Path(os.environ["PL_PLUGIN_ROOT"])
lock_path   = pathlib.Path(os.environ["PL_LOCK"])
out_dir     = pathlib.Path(os.environ["PL_OUT_DIR"])

def sha(path):
    return "sha256:" + hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

empty = {
    "lock_present": False, "lock_broken": False,
    "derived_stale": [], "derived_tampered": [], "derived_missing": [],
    "derived_unstamped": [],
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
    print(json.dumps({"ok": False, "reason": "plugin-lock.json exists but is not valid JSON",
                      "hint": "delete it and run mvp:sync — it is regenerable",
                      "data": dict(empty, lock_broken=True)}))
    sys.exit(1)

data = dict(empty, lock_present=True)

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

# Обратное отношение: файл лежит в OUT_DIR, но ключа для него в derived нет.
# Ни одна из проверок выше его не видит — цикл выше идёт по lock["derived"],
# а не по файловой системе. Без этого агент без записи в lock невидим всему
# механизму (спека §5.2).
derived_keys = set(lock.get("derived", {}).keys())
if out_dir.is_dir():
    for f in sorted(out_dir.glob("*.md")):
        p = str(out_dir / f.name)
        if p not in derived_keys:
            data["derived_unstamped"].append({"path": p})

problems = []
if data["derived_stale"]:
    problems.append("%d agent(s) stale vs plugin" % len(data["derived_stale"]))
if data["derived_tampered"]:
    problems.append("%d agent(s) hand-edited" % len(data["derived_tampered"]))
if data["derived_missing"]:
    problems.append("%d agent file(s) missing" % len(data["derived_missing"]))
if data["derived_unstamped"]:
    problems.append("%d agent file(s) unstamped" % len(data["derived_unstamped"]))

n_drift = len(data["normative_changed"]) + len(data["normative_added"]) + len(data["normative_removed"])
if n_drift:
    problems.append("%d normative file(s) changed in plugin" % n_drift)

if problems:
    print(json.dumps({"ok": False, "reason": "; ".join(problems),
                      "hint": "run mvp:sync", "data": data}))
    sys.exit(1)

print(json.dumps({"ok": True, "reason": None, "hint": None, "data": data}))
'
    exit $?
    ;;
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
  *)
    emit_result false "unknown cmd: ${cmd:-<missing>}" "record|check|seal" ""
    exit 1
    ;;
esac
