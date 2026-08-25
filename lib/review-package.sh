#!/usr/bin/env bash
# review-package.sh <task-id> --base <sha>
#
# Writes a self-contained review bundle for one build task to
# .mvp/review/task-<task-id>.md: commits since base (if any),
# diffstat + diff of BASE -> the CURRENT WORKING TREE (not HEAD — see
# ruling below), and the full content of any new untracked files. Run from
# the TARGET PROJECT root (not this plugin repo). Single-line JSON contract
# on every exit path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1. Success: data = {"path": "<relative path>"}.
#
# task-id is used verbatim in the output filename (bare ids, e.g. "001" —
# controller ruling R11); no extra path-sanitization is applied since task
# ids are pipeline-generated, not untrusted external input (same trust model
# lib/finalize.sh applies to its scope/msg-file args).
#
# CONTROLLER RULING (Task 14 fix round, post-review): the original version
# diffed `BASE..HEAD` (committed refs only). But skills/build/workflow.mjs's
# implementer/fix agents never `git commit` their own work — finalize.sh
# does that exactly once, at the very end of a task — so HEAD never moves
# between the workflow's baseSha capture and this script's invocation. A
# `BASE..HEAD` diff was therefore ALWAYS empty for an in-progress task,
# leaving the reviewer nothing to review. Fixed by diffing BASE against the
# WORKING TREE instead:
#   - `git log --oneline BASE..HEAD` is kept (usually empty mid-task,
#     harmless, cheap extra context on the rare path where HEAD did move).
#   - `git diff --stat BASE` / `git diff BASE` (one positional ref, no
#     `--cached`) compare BASE to the on-disk working tree, which already
#     includes BOTH staged and unstaged tracked changes — verified
#     empirically: `git diff <commit>` reads current file content, not the
#     index, so its output is already a strict superset of
#     `git diff --cached BASE`. That third invocation is therefore omitted
#     as redundant, not forgotten.
#   - untracked files (`git ls-files --others --exclude-standard`) are not
#     covered by ANY `git diff` invocation, staged or not — they are the
#     implementer's brand-new files, exactly what a reviewer most needs to
#     see for a task like "create app/a.txt". Each is inlined under its own
#     heading, content capped at UNTRACKED_FILE_LINE_CAP lines with an
#     explicit truncation note so a large generated file can't blow up the
#     review package.
#
# NOISE FIX (post-smoke analysis, real task-002 artifact: 1442 lines, ~60%
# noise): `git ls-files --others` runs BEFORE this script `mv`s its own
# output into place, so a prior run's task-<id>.md under
# .mvp/review/ was untracked at listing time and got inlined into
# ITS OWN package — briefs/reports/review are already handed to the
# reviewer via explicit paths, so self-inclusion here is pure noise, not a
# feature. Fixed by excluding .mvp/** from the untracked listing
# entirely. Separately, lock/generated files (package-lock.json and
# friends) were being inlined whole — one such file alone was 400+113
# lines in the smoke artifact. These are never hand-reviewed diffs a human
# needs to read; only their NAME + size matters (did a lockfile change at
# all). Fixed by listing those by name+size only, never inlining content.

set -u

USAGE="usage: review-package.sh <task-id> --base <sha>"

# UNTRACKED_FILE_LINE_CAP — per-file inline cap for NEW (untracked) files.
#
# Raised 400 -> 2000 on 2026-08-24, and truncation is no longer silent: any
# hit is reported in data.truncated so the caller can fail closed. Measured
# over the vireo run: the untracked section is a MEDIAN 90% of a review
# package — on greenfield work virtually all of a task's output is new files,
# so this cap governs almost the entire diff the reviewer judges, not some
# edge case. 16 of 36 packages were truncated, hiding 8 166 lines; in one
# task (OAuth account connect) the state validation, one-shot consent
# consumption and redirect-URI allowlist never reached the reviewer, which
# returned `approve` regardless. The cap still exists so one generated
# 100k-line file cannot blow up a package, but a hit is now a reported fact.
UNTRACKED_FILE_LINE_CAP="${UNTRACKED_FILE_LINE_CAP:-2000}"

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

OUT_DIR=".mvp/review"
OUT_PATH="$OUT_DIR/task-${TASK_ID}.md"

mkdir -p "$OUT_DIR"

TMP_OUT="$(mktemp)"
TRUNC_FILE="$(mktemp)"
trap 'rm -f "$TMP_OUT" "$TRUNC_FILE"' EXIT

{
  echo "# Review: task ${TASK_ID}"
  echo
  echo "## Commits (${BASE}..HEAD)"
  echo
  git log --oneline "${BASE}..HEAD"
  echo
  echo "## Diffstat (${BASE} -> working tree)"
  echo
  git diff --stat "${BASE}"
  echo
  echo "## Diff (${BASE} -> working tree, tracked files, staged + unstaged)"
  echo
  echo '```diff'
  git diff "${BASE}"
  echo '```'
  echo
  echo "## Untracked files (new, not yet added)"
  echo
} >"$TMP_OUT"

# Untracked files, NUL-delimited (filenames may contain spaces/special
# chars) so paths cross the bash/python boundary intact — same pattern as
# lib/validate-task.sh's boundary check. Two exceptions to "inline it all":
#   - .mvp/** is excluded entirely — briefs/reports/review are
#     already handed to the reviewer via explicit paths; this is this
#     script's own prior output (untracked until it `mv`s itself into
#     place), so listing it here is self-inclusion, not review material.
#   - lock/generated files (name in LOCK_BASENAMES, or matching a
#     LOCK_GLOBS pattern) are listed by NAME + size only, content never
#     inlined — a human reviews a diff, not a regenerated lockfile.
# Everything else keeps the original behavior: content inlined, capped at
# UNTRACKED_FILE_LINE_CAP lines per file with a truncation note.
git ls-files --others --exclude-standard -z | UT_CAP="$UNTRACKED_FILE_LINE_CAP" RP_TRUNC_FILE="$TRUNC_FILE" python3 -c '
import fnmatch, json, os, sys

cap = int(os.environ["UT_CAP"])
data = sys.stdin.buffer.read()
paths = [p.decode("utf-8", "replace") for p in data.split(b"\x00") if p]

# self-inclusion bug (see header comment): this script'"'"'s own output lives
# under .mvp/review/ and is untracked until the final `mv` — never
# list anything under .mvp/** here.
STATE_PREFIX = ".mvp/"
paths = [p for p in paths if p != ".mvp" and not p.startswith(STATE_PREFIX)]

LOCK_BASENAMES = {
    "package-lock.json", "uv.lock", "yarn.lock", "pnpm-lock.yaml",
    "Cargo.lock", "poetry.lock", "composer.lock",
}
LOCK_GLOBS = ("*.min.js", "*.min.css")

def is_lock_or_generated(p):
    base = os.path.basename(p)
    if base in LOCK_BASENAMES:
        return True
    return any(fnmatch.fnmatch(base, g) for g in LOCK_GLOBS)

out = []
truncated = []
if not paths:
    out.append("(none)")
for p in paths:
    if is_lock_or_generated(p):
        try:
            size = f"{os.path.getsize(p)} bytes"
        except OSError as e:
            size = f"unknown size: {e}"
        out.append(f"## Untracked (content omitted — lockfile/generated): {p} ({size})")
        out.append("")
        continue
    out.append(f"### {p}")
    out.append("")
    out.append("```")
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        out.append(f"(could not read file: {e})")
        out.append("```")
        out.append("")
        continue
    out.extend(lines[:cap])
    if len(lines) > cap:
        out.append(f"... truncated, {len(lines) - cap} more line(s) not shown ...")
        truncated.append({"path": p, "hidden_lines": len(lines) - cap, "total_lines": len(lines)})
    out.append("```")
    out.append("")
print("\n".join(out))

# Machine-readable truncation record for the caller. Written to a side file
# rather than stdout because stdout here IS the package body. An empty list
# is written explicitly so a missing file always means "the inliner never
# ran", never "nothing was truncated".
with open(os.environ["RP_TRUNC_FILE"], "w", encoding="utf-8") as fh:
    json.dump(truncated, fh)
' >>"$TMP_OUT"

mv "$TMP_OUT" "$OUT_PATH"
# TMP_OUT is gone (moved); TRUNC_FILE is still needed one line below, so the
# trap is narrowed rather than cleared.
trap 'rm -f "$TRUNC_FILE"' EXIT

# data.truncated: [] when the reviewer will see every new file in full. A
# non-empty list means the package is NOT a complete view of the change —
# workflow.mjs treats that as blocking (fail closed) instead of letting a
# verdict be issued on partial evidence. See the cap comment above.
# Fail CLOSED: an unreadable/absent truncation record means the inliner did
# not finish, so "nothing was truncated" is not a conclusion we may draw. An
# early version of this block defaulted to [] on error and a crash inside the
# inliner (a missing import) silently reported a truncated package as
# complete — exactly the failure this whole change exists to remove.
if ! DATA="$(RP_OUT_PATH="$OUT_PATH" RP_TRUNC_FILE="$TRUNC_FILE" python3 -c '
import json, os, sys
with open(os.environ["RP_TRUNC_FILE"], encoding="utf-8") as fh:
    truncated = json.load(fh)
if not isinstance(truncated, list):
    sys.exit("truncation record is not a list")
print(json.dumps({"path": os.environ["RP_OUT_PATH"], "truncated": truncated}))
' 2>&1)"; then
  fail "cannot read truncation record: $DATA" \
    "the untracked-file inliner did not complete; the package may be incomplete"
fi
emit_result true "" "" "$DATA"
exit 0
