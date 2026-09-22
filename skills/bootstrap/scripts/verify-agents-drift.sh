#!/usr/bin/env bash
# verify-agents-drift.sh
#
# Post-bootstrap invariant check, scoped to IMPLEMENTER roles only:
# every .claude/agents/<role>.md, EXCEPT files whose name starts with
# "mvp-" (pipeline-mechanic roles: mvp-reviewer/mvp-validator/mvp-relay —
# assembled deliberately WITHOUT _common.md, see skills/bootstrap/templates/
# mvp-*.template.md and docs/specs/2026-09-22-token-diet-and-experiments-
# design.md §4), must contain the contents of _common.md byte-for-byte.
# assemble-agent.sh inserts _common.md verbatim between the frontmatter and
# the role body for every OTHER role — so the entire common file must appear
# as a contiguous byte substring of each assembled implementer-agent file.
# This is a narrowed scope, not a weakened invariant: mechanic roles were
# never under the _common.md contract (they carry no project task boundary
# to guard) — mvp- files are SKIPPED, not exempted-and-still-counted.
#
# Why substring-match (not awk-parse): _common.md itself uses "---" lines as
# section separators internally, so trying to slice the "common block" out of
# an assembled file by finding "---" boundaries is fragile. Substring presence
# is unambiguous: either the verbatim file is in the assembled output, or it
# isn't.
#
# Drift = bug in assemble-agent.sh or manual tampering. Exits non-zero on any
# drift, with a per-file report on stderr.
#
# Usage: verify-agents-drift.sh [agents_dir] [common_md]
#   agents_dir defaults to .claude/agents (relative to CWD — run from the
#              TARGET PROJECT root, not this plugin repo)
#   common_md  defaults to <plugin>/skills/bootstrap/templates/_common.md
#              (script-relative — no more $HOME/.claude/agents/templates
#              dependency now that templates live inside the plugin)
#
# This script is REQUIRED by mvp:bootstrap Step 4 — the SKILL must not
# paraphrase or weaken it. If a project needs a different invariant, fork the
# script, do not rewrite it inline.
#
# Output contract (R10, added in v2 — v1 only printed human text + exit
# code; "skipped" added when mvp- mechanic roles were excluded from scope):
# last line of stdout is single-line JSON
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":{"total":int,"drift":int,"skipped":int,"violations":[{"file":str}]}}
# "total"/"drift"/"violations" count only checked (non-mvp-) files; "skipped"
# counts mvp- files that were excluded from scope, not violations. ok:false
# always exits 1 (setup errors — missing dir/_common.md/zero CHECKABLE agent
# files with zero skipped too — also exit 1, same as drift, with a specific
# "reason"). A directory holding ONLY mvp- mechanic roles (total=0, skipped>0)
# is a legitimate state, not "no agent files": nothing there is under this
# invariant's scope, so there is nothing to fail on. The human-readable ❌/✓
# diagnostics still go to stderr, unchanged from v1 except for a skip count.

set -u

AGENTS_DIR="${1:-.claude/agents}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_MD="${2:-$here/../templates/_common.md}"

# emit_result <ok:true|false> <reason> <hint> <data-json> — see lib/gate.sh.
emit_result() {
  VD_OK="$1" VD_REASON="$2" VD_HINT="$3" VD_DATA="$4" python3 -c '
import json, os
ok = os.environ["VD_OK"] == "true"
reason = os.environ.get("VD_REASON") or None
hint = os.environ.get("VD_HINT") or None
data_raw = os.environ.get("VD_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

if [ ! -d "$AGENTS_DIR" ]; then
  echo "❌ agents dir not found: $AGENTS_DIR" >&2
  emit_result false "agents dir not found: $AGENTS_DIR" "run assemble-agent.sh first" ""
  exit 1
fi
if [ ! -f "$COMMON_MD" ]; then
  echo "❌ _common.md not found: $COMMON_MD" >&2
  emit_result false "_common.md not found: $COMMON_MD" "check plugin install / COMMON_MD arg" ""
  exit 1
fi

DRIFT=0
TOTAL=0
SKIPPED=0
DRIFTED_FILES=()

for f in "$AGENTS_DIR"/*.md; do
  [ -f "$f" ] || continue

  # mvp- mechanic roles (reviewer/validator/relay) are assembled WITHOUT
  # _common.md on purpose — out of scope for this invariant, not a violation
  # of it. Skip visibly (counted, reported) rather than silently.
  base="$(basename "$f")"
  case "$base" in
    mvp-*)
      SKIPPED=$((SKIPPED + 1))
      continue
      ;;
  esac

  TOTAL=$((TOTAL + 1))

  # python is the simplest portable way to check "is file A a byte-for-byte
  # substring of file B". No shell quoting / locale / newline-translation
  # surprises. Both _common.md and assembled files are UTF-8.
  python3 - "$COMMON_MD" "$f" <<'PY'
import sys, pathlib
common = pathlib.Path(sys.argv[1]).read_bytes()
agent  = pathlib.Path(sys.argv[2]).read_bytes()
sys.exit(0 if common in agent else 1)
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "❌ DRIFT: $f — _common.md not present byte-for-byte" >&2
    DRIFT=$((DRIFT + 1))
    DRIFTED_FILES+=("$f")
  fi
done

if [ "$TOTAL" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
  echo "❌ no agent files in $AGENTS_DIR" >&2
  emit_result false "no agent files in $AGENTS_DIR" "run assemble-agent.sh first" ""
  exit 1
fi

if [ "$DRIFT" -gt 0 ]; then
  echo "" >&2
  echo "FAIL: $DRIFT/$TOTAL checked agent files drifted from _common.md ($SKIPPED mvp- mechanic role(s) skipped)" >&2
  echo "Diagnose: rerun assemble-agent.sh for the drifted role(s), or inspect manual edits." >&2
  VIOLATIONS_JSON="$(python3 -c '
import json, sys
print(json.dumps([{"file": f} for f in sys.argv[1:]]))
' "${DRIFTED_FILES[@]}")"
  DATA="$(python3 -c '
import json, sys
total, drift, skipped, violations = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), json.loads(sys.argv[4])
print(json.dumps({"total": total, "drift": drift, "skipped": skipped, "violations": violations}))
' "$TOTAL" "$DRIFT" "$SKIPPED" "$VIOLATIONS_JSON")"
  emit_result false "$DRIFT/$TOTAL agent files drifted from _common.md" \
    "rerun assemble-agent.sh for the drifted role(s), or inspect manual edits" "$DATA"
  exit 1
fi

echo "✓ DRIFT-check passed: $TOTAL checked agent file(s) embed _common.md byte-for-byte ($SKIPPED mvp- mechanic role(s) skipped)" >&2
DATA="$(python3 -c 'import json,sys; print(json.dumps({"total": int(sys.argv[1]), "drift": 0, "skipped": int(sys.argv[2]), "violations": []}))' "$TOTAL" "$SKIPPED")"
emit_result true "" "" "$DATA"
exit 0
