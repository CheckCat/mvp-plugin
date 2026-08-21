#!/usr/bin/env bash
# review-package.sh <task-id> --base <sha>
#
# Writes a self-contained review bundle for one build task to
# .claude/state/review/task-<task-id>.md: commit subjects (base..HEAD),
# diffstat, then the full unified diff. Run from the TARGET PROJECT root
# (not this plugin repo). Single-line JSON contract on every exit path (same
# shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1. Success: data = {"path": "<relative path>"}.
#
# task-id is used verbatim in the output filename (bare ids, e.g. "001" —
# controller ruling R11); no extra path-sanitization is applied since task
# ids are pipeline-generated, not untrusted external input (same trust model
# lib/finalize.sh applies to its scope/msg-file args).

set -u

USAGE="usage: review-package.sh <task-id> --base <sha>"

# emit_result <ok:true|false> <reason> <hint> <data-json> — see lib/gate.sh.
emit_result() {
  RP_OK="$1" RP_REASON="$2" RP_HINT="$3" RP_DATA="$4" python3 -c '
import json, os
ok = os.environ["RP_OK"] == "true"
reason = os.environ.get("RP_REASON") or None
hint = os.environ.get("RP_HINT") or None
data_raw = os.environ.get("RP_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint]
  emit_result false "$1" "${2:-}" ""
  exit 1
}

# --- parse argv --------------------------------------------------------------

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  fail "missing task-id" "$USAGE"
fi
shift

BASE=""
HAVE_BASE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      if [ $# -lt 2 ]; then fail "--base requires a value" "$USAGE"; fi
      BASE="$2"
      HAVE_BASE=1
      shift 2
      ;;
    *)
      fail "unexpected argument: $1" "$USAGE"
      ;;
  esac
done

if [ "$HAVE_BASE" -ne 1 ]; then
  fail "missing --base" "$USAGE"
fi

# --- preconditions -------------------------------------------------------------

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  fail "not a git repository"
fi

if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
  fail "invalid base sha: $BASE"
fi

# --- write the review bundle ---------------------------------------------------

OUT_DIR=".claude/state/review"
OUT_PATH="$OUT_DIR/task-${TASK_ID}.md"

mkdir -p "$OUT_DIR"

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

{
  echo "# Review: task ${TASK_ID}"
  echo
  echo "## Commits (${BASE}..HEAD)"
  echo
  git log --oneline "${BASE}..HEAD"
  echo
  echo "## Diffstat"
  echo
  git diff --stat "${BASE}..HEAD"
  echo
  echo "## Diff"
  echo
  echo '```diff'
  git diff "${BASE}..HEAD"
  echo '```'
} >"$TMP_OUT"

mv "$TMP_OUT" "$OUT_PATH"
trap - EXIT

DATA="$(python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1]}))' "$OUT_PATH")"
emit_result true "" "" "$DATA"
exit 0
