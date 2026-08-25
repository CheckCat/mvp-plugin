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
  if [ -z "$reason" ] && [ -d .claude/state ]; then reason=".claude/state/ already exists"; fi
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
  local planfile=".claude/state/plan.json"
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
  local planfile=".claude/state/plan.json"
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
