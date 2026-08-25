#!/usr/bin/env bash
# make-dryrun.sh — builds a throwaway git repo seeded with a 2-task dry-run
# fixture for skills/build/workflow.mjs.
#
# Run from anywhere (no cwd assumptions). Output: a single line of JSON,
# contract R10 (same shape as every lib/*.sh script):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":{"path":str}|null}
# ok:false always exits 1. Success: data = {"path": "<abs path to the repo>"}.
#
# The repo it builds:
#   .mvp/plan.json      — 2 tasks, role general-purpose,
#                                   complexity_class boilerplate, service_path
#                                   "app", depends_on chained (002 -> 001) so
#                                   the dry-run also exercises plan-io's
#                                   dependency-report injection. Each task's
#                                   title tells the implementer to create one
#                                   file with fixed content — the simplest
#                                   molecule an implementer agent can finish
#                                   without judgment calls.
#   .mvp/ci-mirror.sh   — `true`: a CI mirror that always exits 0,
#                                   so validate-task.sh's ci-check never
#                                   blocks the dry-run on a real toolchain.
#   .mvp/invariants.md  — minimal, non-empty (writeBrief() in
#                                   plan-io.mjs embeds it verbatim into every
#                                   task brief).
# One initial commit, clean tree — the same baseline every plan-io.mjs test
# fixture uses (see tests/lib/plan-io.test.sh's new_repo()), since
# plan-io.mjs `next` halts with dirty-tree on anything else.
#
# Caller owns cleanup (mktemp -d under the system tmp dir, not auto-removed
# here) — the dry-run needs the repo to survive after this script exits.

set -u

USAGE="usage: make-dryrun.sh"

emit_result() { # <ok:true|false> <reason> <hint> <data-json>
  MD_OK="$1" MD_REASON="$2" MD_HINT="$3" MD_DATA="$4" python3 -c '
import json, os
ok = os.environ["MD_OK"] == "true"
reason = os.environ.get("MD_REASON") or None
hint = os.environ.get("MD_HINT") or None
data_raw = os.environ.get("MD_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint]
  emit_result false "$1" "${2:-}" ""
  exit 1
}

if [ $# -ne 0 ]; then
  fail "unexpected argument: $1" "$USAGE"
fi

DIR="$(mktemp -d -t mvp-dryrun.XXXXXX)" || fail "mktemp -d failed"

if ! (cd "$DIR" && git init -q); then
  fail "git init failed in $DIR"
fi
if ! (cd "$DIR" && git config user.email dryrun@test.local && git config user.name "mvp dryrun"); then
  fail "git config failed in $DIR"
fi

mkdir -p "$DIR/.mvp" || fail "mkdir .mvp failed"

cat >"$DIR/.mvp/plan.json" <<'EOF'
{
  "tasks": [
    {
      "id": "001",
      "title": "создай файл app/a.txt с содержимым HELLO-A",
      "level": 1,
      "service": "app",
      "service_path": "app",
      "role": "general-purpose",
      "files": ["app/a.txt"],
      "depends_on": [],
      "estimate_tokens": 500,
      "status": "pending",
      "complexity_class": "boilerplate"
    },
    {
      "id": "002",
      "title": "создай файл app/b.txt с содержимым HELLO-B",
      "level": 2,
      "service": "app",
      "service_path": "app",
      "role": "general-purpose",
      "files": ["app/b.txt"],
      "depends_on": ["001"],
      "estimate_tokens": 500,
      "status": "pending",
      "complexity_class": "boilerplate"
    }
  ]
}
EOF
[ -f "$DIR/.mvp/plan.json" ] || fail "failed to write plan.json"

cat >"$DIR/.mvp/ci-mirror.sh" <<'EOF'
#!/usr/bin/env bash
true
EOF
chmod +x "$DIR/.mvp/ci-mirror.sh"

cat >"$DIR/.mvp/invariants.md" <<'EOF'
# Project invariants (dry-run fixture)

- Stack: none — synthetic smoke fixture for skills/build/workflow.mjs.
- CI mirror: `bash .mvp/ci-mirror.sh` (always exits 0).
- Boundary: every task's files live under `app/`.
EOF

if ! (cd "$DIR" && git add .mvp/plan.json .mvp/ci-mirror.sh .mvp/invariants.md); then
  fail "git add failed in $DIR"
fi
if ! (cd "$DIR" && git commit -q -m "chore: seed dryrun fixture"); then
  fail "git commit failed in $DIR"
fi

DATA="$(python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1]}))' "$DIR")"
emit_result true "" "" "$DATA"
exit 0
