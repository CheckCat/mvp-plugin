#!/usr/bin/env bash
# gate.sh <brief|clarify|bootstrap|plan|build>
#
# Deterministic stage preconditions for the mvp pipeline. Run from the
# TARGET PROJECT root (not this plugin repo). Single-line JSON contract on
# every exit path: {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/brief-contract.sh"

STAGES="brief clarify bootstrap plan build"

# emit_result <ok:true|false> <reason> <hint> <data-json>
#   reason/hint: empty string -> null. data: empty string -> null, else must be
#   valid JSON text (e.g. '{"recovery":"archive-only"}'). Values are passed via
#   env vars (never shell-interpolated into the python source) so no argument
#   can break out of the JSON contract.
emit_result() {
  GATE_OK="$1" GATE_REASON="$2" GATE_HINT="$3" GATE_DATA="$4" python3 -c '
import json, os
ok = os.environ["GATE_OK"] == "true"
reason = os.environ.get("GATE_REASON") or None
hint = os.environ.get("GATE_HINT") or None
data_raw = os.environ.get("GATE_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

# get_phase -> current state.json "phase" value, or "" if unset/missing.
get_phase() {
  "$here/state.sh" get phase 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
else:
    v = (d.get("data") or {}).get("value") if d.get("ok") else None
    print(v if isinstance(v, str) else "")
'
}

# get_pending_critical -> integer, 0 if unset/missing/non-numeric.
get_pending_critical() {
  "$here/state.sh" get pending_critical 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = (d.get("data") or {}).get("value") if d.get("ok") else None
    print(int(v))
except Exception:
    print(0)
'
}

# --- shared header-set helpers ----------------------------------------------
# Headers are multi-word ("## Success criteria"): always collected into an
# array via a read loop, never via unquoted $(...) word-splitting.

_headers_of() { # <kind: tech|biz> -> header lines on stdout
  case "$1" in
    tech) required_headers_tech ;;
    biz) required_headers_biz ;;
  esac
}

headers_present_all() { # <file> <kind> — presence only (clarify)
  local h
  while IFS= read -r h; do header_present "$1" "$h" || return 1; done < <(_headers_of "$2")
  return 0
}

headers_valid_all() { # <file> <kind> — presence + non-empty content (bootstrap/brief)
  local -a arr=()
  local h
  while IFS= read -r h; do arr+=("$h"); done < <(_headers_of "$2")
  validate_headers "$1" "${arr[@]}" 2>/dev/null
}

docs/product_files_exist() {
  [ -f docs/product/technical-solutions.md ] && [ -f docs/product/business-logic.md ]
}

git_repo_present() {
  git rev-parse --git-dir >/dev/null 2>&1
}

# --- brief -------------------------------------------------------------------

is_root_manifest_present() {
  [ -f package.json ] || [ -f pyproject.toml ] || [ -f Cargo.toml ] || [ -f go.mod ]
}

has_nonempty_apps_or_services() {
  local d sub
  for d in apps services; do
    if [ -d "$d" ]; then
      for sub in "$d"/*/; do
        [ -d "$sub" ] || continue
        if [ -n "$(find "$sub" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
          return 0
        fi
      done
    fi
  done
  return 1
}

# any *.md|*.txt|*.json at root that isn't a standard project file.
root_raw_files_present() {
  local f base allowed=(CLAUDE.md ARCHITECTURE.md PROJECT_PLAN.md README.md) a skip
  for f in *.md *.txt *.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    skip=0
    for a in "${allowed[@]}"; do
      [ "$base" = "$a" ] && skip=1 && break
    done
    [ "$skip" -eq 0 ] && return 0
  done
  return 1
}

valid_docs/product() {
  docs/product_files_exist || return 1
  headers_valid_all docs/product/technical-solutions.md tech || return 1
  headers_valid_all docs/product/business-logic.md biz || return 1
  return 0
}

gate_brief() {
  if valid_docs/product && root_raw_files_present; then
    emit_result false "docs/product/ packaged but raw source files not archived" \
      "crash between swap and archive — run the archive step (mvp:brief resume)" \
      '{"recovery":"archive-only"}'
    exit 1
  fi

  local reason=""
  if [ -z "$reason" ] && [ -d .mvp ]; then reason=".mvp/ already exists"; fi
  if [ -z "$reason" ] && [ -f CLAUDE.md ]; then reason="CLAUDE.md already exists"; fi
  if [ -z "$reason" ] && [ -f ARCHITECTURE.md ]; then reason="ARCHITECTURE.md already exists"; fi
  if [ -z "$reason" ] && is_root_manifest_present; then
    reason="root manifest (package.json|pyproject.toml|Cargo.toml|go.mod) already exists"
  fi
  if [ -z "$reason" ] && has_nonempty_apps_or_services; then
    reason="non-empty apps/*/ or services/*/ found"
  fi

  if [ -n "$reason" ]; then
    emit_result false "$reason" "mvp:brief only runs on an empty/fresh project" ""
    exit 1
  fi
  emit_result true "" "" ""
  exit 0
}

# --- clarify -------------------------------------------------------------------

gate_clarify() {
  if ! docs/product_files_exist; then
    emit_result false "docs/product/ missing" "run gate brief / mvp:brief first" ""
    exit 1
  fi
  if ! headers_present_all docs/product/technical-solutions.md tech; then
    emit_result false "technical-solutions.md missing required headers" \
      "add the missing ## headers to docs/product/technical-solutions.md" ""
    exit 1
  fi
  if ! headers_present_all docs/product/business-logic.md biz; then
    emit_result false "business-logic.md missing required headers" \
      "add the missing ## headers to docs/product/business-logic.md" ""
    exit 1
  fi
  emit_result true "" "" ""
  exit 0
}

# --- bootstrap -------------------------------------------------------------------

gate_bootstrap() {
  if ! docs/product_files_exist; then
    emit_result false "docs/product/ missing" "run gate brief / mvp:brief first" ""
    exit 1
  fi
  if ! headers_valid_all docs/product/technical-solutions.md tech; then
    emit_result false "technical-solutions.md incomplete" \
      "fill in missing/empty ## sections (run mvp:clarify)" ""
    exit 1
  fi
  if ! headers_valid_all docs/product/business-logic.md biz; then
    emit_result false "business-logic.md incomplete" \
      "fill in missing/empty ## sections (run mvp:clarify)" ""
    exit 1
  fi
  local pc
  pc="$(get_pending_critical)"
  if [ "$pc" -gt 0 ]; then
    emit_result false "pending_critical=$pc" \
      "resolve criticals via mvp:clarify or confirm override" ""
    exit 1
  fi
  emit_result true "" "" ""
  exit 0
}

# --- plan -------------------------------------------------------------------

gate_plan() {
  # invariant: build commits every completed task via finalize.sh, so a
  # project without a git repo can never reach build — require git from
  # plan onward, checked before the uncommitted-plan.json probe below.
  if ! git_repo_present; then
    emit_result false "no git repository" \
      "run git init (or rerun mvp:brief git step) — plan/build phases require git" ""
    exit 1
  fi
  local planfile=".mvp/plan.json"
  if [ -f "$planfile" ]; then
    local status
    status="$(git status --porcelain -- "$planfile" 2>/dev/null)"
    if [ -n "$status" ]; then
      emit_result false "plan.json exists but is not committed" \
        "crash between validate and finalize — run the finalize step (mvp:plan resume)" \
        '{"recovery":"finalize-plan"}'
      exit 1
    fi
  fi
  local phase
  phase="$(get_phase)"
  if [ "$phase" != "bootstrap-done" ]; then
    emit_result false "phase != bootstrap-done (got: ${phase:-null})" \
      "run gate bootstrap / mvp:bootstrap first" ""
    exit 1
  fi
  emit_result true "" "" ""
  exit 0
}

# --- build -------------------------------------------------------------------

gate_build() {
  # invariant: build commits every completed task via finalize.sh — require
  # git before anything else (same rule as gate_plan; see comment there).
  if ! git_repo_present; then
    emit_result false "no git repository" \
      "run git init (or rerun mvp:brief git step) — plan/build phases require git" ""
    exit 1
  fi
  local planfile=".mvp/plan.json"
  local reason=""
  if [ ! -f "$planfile" ]; then
    reason="plan.json missing"
  else
    local status
    status="$(git status --porcelain -- "$planfile" 2>/dev/null)"
    [ -n "$status" ] && reason="plan.json not committed"
  fi
  local phase
  phase="$(get_phase)"
  if [ "$phase" != "plan-done" ]; then
    if [ -n "$reason" ]; then reason="$reason; phase != plan-done"; else reason="phase != plan-done"; fi
  fi
  if [ -n "$reason" ]; then
    emit_result false "$reason" "run gate plan / mvp:plan first" ""
    exit 1
  fi

  # Roles the plan actually dispatches — extracted once, here, and reused by
  # both the missing-agent-file check right below and the unstamped-role
  # filter further down (§7 of the design doc). "Dispatched by the plan" has
  # exactly one definition in this script; a second, slightly different way
  # to re-derive it from plan.json would drift from this one silently.
  local planned_roles
  planned_roles="$(python3 - "$planfile" <<'PY' 2>/dev/null
import json, sys
try:
    tasks = json.load(open(sys.argv[1], encoding="utf-8")).get("tasks", [])
except Exception:
    sys.exit(0)
roles = sorted({t.get("role") for t in tasks if t.get("role")})
print(",".join(roles))
PY
)"

  # Every role the plan dispatches must have an assembled agent file. This
  # catches a skipped/partial mvp:bootstrap; it CANNOT catch the other half of
  # the problem — agent types register when a Claude Code session starts, so
  # files written by a bootstrap in the current session exist here and still do
  # not dispatch. workflow.mjs raises that one as a per-task concern.
  local missing_roles
  missing_roles="$(GB_ROLES="$planned_roles" python3 -c '
import os
roles = [r for r in os.environ.get("GB_ROLES", "").split(",") if r]
print(",".join(r for r in roles if not os.path.isfile(f".claude/agents/{r}.md")))
')"
  if [ -n "$missing_roles" ]; then
    emit_result false "no agent file for role(s): $missing_roles" \
      "rerun mvp:bootstrap step 4 (assemble-agent.sh) for each missing role" ""
    exit 1
  fi

  # --- plugin-lock: производное блокирует, нормативка только докладывается --
  #
  # Асимметрия намеренная (docs/specs/2026-09-21-plugin-lock-and-sync-design.md
  # §7). derived блокирует, потому что цена известна: устаревшие агенты не
  # регистрируются, задачи уходят на general-purpose без контракта _common.md,
  # и ревью их одобряет — оно судит дифф, а не автора. Нормативка не
  # блокирует, потому что иначе любой коммит в плагин останавливает все
  # проекты сразу, и первое, чему научится оператор — обходить гейт.
  #
  # derived_unstamped — частный случай той же асимметрии, не расширение
  # списка «жёстких» причин. check (§5.2) не может отличить подменённого
  # плагинного агента от рукописного файла оператора — у находки нет поля
  # role. Гейт может: он уже знает, какие роли диспатчит план (planned_roles
  # выше). Подменённый плагинный агент опасен только если план вот-вот
  # выдаст ему задачу — тогда роль есть в planned_roles, и это тот же риск,
  # что derived_stale/tampered/missing. Файл, чью роль план не диспатчит, —
  # не наша забота: запрещать оператору собственных агентов в .claude/agents/
  # мы не вправе (см. §7 в спеке — halt только на роли, которые план реально
  # диспатчит).
  #
  # `check` возвращает ok:false на ЛЮБОЕ расхождение — он диагност, а не
  # политика. Политика здесь.
  # Спека §7: "lock_present: false" валит build, только если в проекте уже
  # есть хоть один собранный агент (.claude/agents/*.md) — иначе сравнивать
  # не с чем (§5.2), и это не отличается от "плагин ещё не использовался".
  local agents_present="false"
  compgen -G ".claude/agents/*.md" >/dev/null 2>&1 && agents_present="true"

  local lock_json
  lock_json="$("$here/plugin-lock.sh" check 2>/dev/null | tail -n1)"
  local lock_verdict
  lock_verdict="$(GB_J="$lock_json" GB_AGENTS_PRESENT="$agents_present" GB_PLANNED_ROLES="$planned_roles" python3 -c '
import json, os, sys
raw = os.environ.get("GB_J") or ""
try:
    r = json.loads(raw)
    if not isinstance(r, dict):
        raise ValueError("plugin-lock.sh check payload is not a JSON object")
except ValueError:
    # Скрипт не отдал контракт (нет python3? снесли файл? отдал валидный
    # JSON, но не объект — например [1,2,3] или null). Молча пропускать
    # нельзя, но и валить build из-за сломанного диагноста — хуже: сам гейт
    # тогда становится точкой отказа. Пропускаем, назвав причину.
    print(json.dumps({"verdict": "skip", "reason": "plugin-lock.sh gave no JSON contract"}))
    sys.exit(0)

d = r.get("data") or {}
if not isinstance(d, dict):
    d = {}
if d.get("lock_present") is False:
    if os.environ.get("GB_AGENTS_PRESENT") == "true":
        reason = ("plugin-lock.json exists but is not valid JSON — cannot tell if agents match the plugin"
                   if d.get("lock_broken") is True else
                   "no .mvp/plugin-lock.json — cannot tell if agents match the plugin")
        print(json.dumps({"verdict": "halt", "reason": reason}))
    else:
        print(json.dumps({"verdict": "clean"}))
    sys.exit(0)

hard = []
for key, label in (("derived_stale", "stale"), ("derived_tampered", "hand-edited"),
                   ("derived_missing", "missing")):
    for item in d.get(key) or []:
        hard.append("%s(%s)" % (item.get("role"), label))

# derived_unstamped items carry only "path" (check has no way to know a
# role for them — §5.2). Derive the role from the filename and halt ONLY
# for roles the plan dispatches; everything else is reported, not blocked
# (see the policy comment above, in the shell code that calls this script).
planned_roles = set(r for r in (os.environ.get("GB_PLANNED_ROLES") or "").split(",") if r)
unstamped_foreign = []
for item in d.get("derived_unstamped") or []:
    path = item.get("path") or ""
    role = os.path.splitext(os.path.basename(path))[0]
    if role in planned_roles:
        hard.append("%s(unstamped)" % role)
    else:
        unstamped_foreign.append(path)

if hard:
    print(json.dumps({"verdict": "halt",
                      "reason": "agent file(s) out of sync with plugin: " + ", ".join(sorted(hard))}))
    sys.exit(0)

soft = {k: d.get(k) or [] for k in ("normative_changed", "normative_added", "normative_removed")}
data_out = dict(soft)
if unstamped_foreign:
    data_out["derived_unstamped_foreign"] = sorted(unstamped_foreign)
if any(soft.values()) or unstamped_foreign:
    print(json.dumps({"verdict": "warn", "data": data_out}))
    sys.exit(0)

print(json.dumps({"verdict": "clean"}))
')"

  local lv
  lv="$(GB_V="$lock_verdict" python3 -c '
import json, os
try:
    d = json.loads(os.environ.get("GB_V") or "")
except Exception:
    d = None
print(d["verdict"] if isinstance(d, dict) and "verdict" in d else "skip")
')"
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
  if [ "$lv" = "skip" ]; then
    # Не блокируем build за сломанный диагност, но и не пропускаем молча:
    # причина обязана быть видна оператору хоть где-то (stderr — единственное
    # доступное место, stdout зарезервирован под JSON-контракт).
    local skip_reason
    skip_reason="$(GB_V="$lock_verdict" python3 -c '
import json, os
try:
    d = json.loads(os.environ.get("GB_V") or "")
except Exception:
    d = None
print(d.get("reason") if isinstance(d, dict) and d.get("reason") else "plugin-lock verdict unavailable")
')"
    echo "gate build: plugin-lock check skipped — $skip_reason" >&2
  fi

  emit_result true "" "" ""
  exit 0
}

# --- main -------------------------------------------------------------------

main() {
  local stage="${1:-}"
  case "$stage" in
    brief) gate_brief ;;
    clarify) gate_clarify ;;
    bootstrap) gate_bootstrap ;;
    plan) gate_plan ;;
    build) gate_build ;;
    *)
      emit_result false "unknown stage: ${stage:-<missing>}" "usage: gate.sh <$( echo "$STAGES" | tr ' ' '|' )>" ""
      exit 1
      ;;
  esac
}

main "$@"
