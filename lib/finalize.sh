#!/usr/bin/env bash
# finalize.sh <scope> <msg-file> [--files f1 f2 ...]
#
# Stage-agnostic commit finalizer for the mvp pipeline. Run from the TARGET
# PROJECT root (not this plugin repo). Single-line JSON contract on every
# exit path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1. Success: data = {"sha": "<full sha>"}.
#
# Scope presets (paths staged + committed):
#   brief      = project_brief project_brief.raw
#   clarify    = project_brief .claude/state/state.json
#   bootstrap  = CLAUDE.md ARCHITECTURE.md .claude/agents .claude/state
#   plan       = .claude/state PROJECT_PLAN.md
#   build-task = --files (REQUIRED) + .claude/state (always appended)
#
# --files may be passed for ANY scope to EXTEND its preset (harmless,
# deterministic — the extra paths are simply appended to the staged list).
# build-task is the only scope where --files is mandatory; every other scope
# works with zero extra args. This lets a caller attach one-off extra paths
# (e.g. a stray file the agent also touched) without inventing a new scope.
#
# Subject-prefix is validated from the FIRST LINE of msg-file BEFORE any
# staging/commit happens: ^(feat|fix|ci|chore|test|docs|refactor)(\(.+\))?:
#
# Staging never uses `git add -A`: only the resolved, existing paths are
# added by name. Commit is path-restricted (`git commit -F msg -- <paths>`)
# so any files the operator pre-staged outside our scope are never swept
# into this commit and remain staged in the index afterwards (ported idea
# from ~/.claude/playbooks/scripts/finalize.sh; graphify invalidation and
# temp-artifact cleanup from that base script are dropped — out of scope
# for v2 / YAGNI).

set -u

USAGE="usage: finalize.sh <scope> <msg-file> [--files f1 f2 ...]"
VALID_SCOPES="brief clarify bootstrap plan build-task"

# emit_result <ok:true|false> <reason> <hint> <data-json>
#   Same contract/pattern as lib/gate.sh: values are passed via env vars
#   (never shell-interpolated into the python source), reason/hint empty
#   string -> null, data empty string -> null else parsed as JSON.
emit_result() {
  F_OK="$1" F_REASON="$2" F_HINT="$3" F_DATA="$4" python3 -c '
import json, os
ok = os.environ["F_OK"] == "true"
reason = os.environ.get("F_REASON") or None
hint = os.environ.get("F_HINT") or None
data_raw = os.environ.get("F_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint]
  emit_result false "$1" "${2:-}" ""
  exit 1
}

# --- parse argv ----------------------------------------------------------

SCOPE="${1:-}"
MSG_FILE="${2:-}"

case "$SCOPE" in
  brief|clarify|bootstrap|plan|build-task) ;;
  *) fail "unknown scope: ${SCOPE:-<missing>}" "$USAGE (scopes: $VALID_SCOPES)" ;;
esac

if [[ -z "$MSG_FILE" ]]; then
  fail "missing msg-file" "$USAGE"
fi
if [[ ! -f "$MSG_FILE" ]]; then
  fail "msg-file not found: $MSG_FILE" "$USAGE"
fi

shift 2 2>/dev/null || true
FILES_ARG=()
if [[ $# -gt 0 ]]; then
  if [[ "$1" != "--files" ]]; then
    fail "unexpected argument: $1" "$USAGE"
  fi
  shift
  FILES_ARG=("$@")
fi

if [[ "$SCOPE" == "build-task" && ${#FILES_ARG[@]} -eq 0 ]]; then
  fail "--files is required for scope build-task" "$USAGE"
fi

# --- resolve scope preset -------------------------------------------------

PATHS=()
case "$SCOPE" in
  brief) PATHS=(project_brief project_brief.raw) ;;
  clarify) PATHS=(project_brief .claude/state/state.json) ;;
  bootstrap) PATHS=(CLAUDE.md ARCHITECTURE.md .claude/agents .claude/state) ;;
  plan) PATHS=(.claude/state PROJECT_PLAN.md) ;;
  build-task) PATHS=("${FILES_ARG[@]}" .claude/state) ;;
esac

# non-build-task scopes: --files EXTENDS the preset (see header comment).
if [[ "$SCOPE" != "build-task" && ${#FILES_ARG[@]} -gt 0 ]]; then
  PATHS+=("${FILES_ARG[@]}")
fi

# --- subject-prefix check, BEFORE any staging/commit ----------------------

SUBJECT="$(head -n1 -- "$MSG_FILE")"
PREFIX_RE='^(feat|fix|ci|chore|test|docs|refactor)(\(.+\))?: '
if ! [[ "$SUBJECT" =~ $PREFIX_RE ]]; then
  fail "invalid subject prefix: $SUBJECT" \
    "first line of msg-file must match ^(feat|fix|ci|chore|test|docs|refactor)(\\(.+\\))?: "
fi

# --- stage paths that exist on disk OR are tracked in git -----------------
#
# "Exists on disk" alone is not the right test: a task whose whole job is to
# DELETE a file leaves that path absent from the working tree while git still
# tracks it, and skipping it here silently dropped the deletion from the
# commit (the file stayed in HEAD, and the next `plan-io next` saw a dirty
# tree forever). `git ls-files --error-unmatch` answers "does git know this
# path", which is exactly the second half of the condition; a path that is
# neither on disk nor tracked is still skipped silently, as before.

EXISTING=()
for p in "${PATHS[@]}"; do
  if [[ -e "$p" ]] || git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    EXISTING+=("$p")
  fi
done

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  fail "nothing to commit" "none of the scope paths exist on disk"
fi

# mktemp + trap-cleanup for all captured command output below (git add stderr,
# git commit output) — never a fixed /tmp path, to avoid races/clobbering
# under concurrent finalize.sh invocations.
GIT_ADD_ERR="$(mktemp)"
COMMIT_OUT="$(mktemp)"
trap 'rm -f "$GIT_ADD_ERR" "$COMMIT_OUT"' EXIT

for p in "${EXISTING[@]}"; do
  if ! git add -- "$p" 2>"$GIT_ADD_ERR"; then
    fail "git add failed for: $p ($(head -c 200 "$GIT_ADD_ERR"))"
  fi
done

# guard: at least one of OUR paths actually has a staged diff.
if [[ -z "$(git diff --cached --name-only -- "${EXISTING[@]}")" ]]; then
  fail "nothing to commit"
fi

# --- path-restricted commit: operator's unrelated staged files never leak -

if ! git commit -F "$MSG_FILE" -- "${EXISTING[@]}" >"$COMMIT_OUT" 2>&1; then
  fail "commit failed: $(head -c 200 "$COMMIT_OUT")"
fi

SHA="$(git log -1 --pretty=format:'%H')"
emit_result true "" "" "$(python3 -c 'import json,sys; print(json.dumps({"sha": sys.argv[1]}))' "$SHA")"
exit 0
