#!/usr/bin/env bash
# Tests for the CAP-experiment additive fields on lib/plan-io.mjs (спека 2026-09-22 §8/§9):
#   `next` payload gains `experiments` (off|passive|greedy, default greedy) and
#   `capped_role` (<role>-capped when that project agent file exists, else null);
#   `complete` gains --arm/--segments -> additive `arm`/`segments` fields on the
#   task_complete telemetry event (absent entirely when the flags are absent —
#   passive/off runs never pass them, and old events.jsonl consumers must keep
#   reading unaffected).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
jfield() { O="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(eval(os.environ["E"]))'; }

# Fixture setup — same shape as tests/lib/plan-io.test.sh's new_repo(): a
# fresh tmp git repo, tests/fixtures/plan-3tasks.json seeded at .mvp/plan.json
# and committed (task 001 role=backend-implementer status=pending, task 002
# depends_on 001 — reused verbatim for step (5)'s "second pending task"), plus
# .mvp/state.json {"phase":"build"} (left uncommitted — under .mvp, so it
# never trips the dirty-tree gate in plan-io.mjs next).
cd "$tmpdir" || { echo "FAIL: cannot cd to tmpdir" >&2; exit 1; }
git init -q
git config user.email test@test.local
git config user.name test
mkdir -p .mvp
cp "$repo_root/tests/fixtures/plan-3tasks.json" .mvp/plan.json
git add .mvp/plan.json
git commit -q -m "chore: seed plan"
printf '%s' '{"phase":"build"}' > .mvp/state.json

# (1) без ключа experiments → greedy; capped-файла нет → capped_role null
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "experiments default" "greedy" "$(jfield "$out" 'd["data"]["experiments"]')"
assert_eq "capped_role null" "None" "$(jfield "$out" 'd["data"]["capped_role"]')"

# (2) passive из state.json доезжает
python3 - <<'EOF'
import json
s = json.load(open(".mvp/state.json")); s["experiments"] = "passive"
json.dump(s, open(".mvp/state.json", "w"))
EOF
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "experiments passive" "passive" "$(jfield "$out" 'd["data"]["experiments"]')"

# (3) capped-файл существует → имя роли в payload. Committed (not left
# untracked): a real capped-role file is authored by mvp:bootstrap and
# already part of the target repo's history by the time `next` runs — an
# untracked .claude/agents/ would trip plan-io's own (unrelated) dirty-tree
# gate before capped_role is even computed, which is not what this case is
# testing.
mkdir -p .claude/agents && echo x > .claude/agents/backend-implementer-capped.md
git add .claude/agents/backend-implementer-capped.md
git commit -q -m "chore: seed capped role"
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "capped_role" "backend-implementer-capped" "$(jfield "$out" 'd["data"]["capped_role"]')"

# (4) complete с --arm/--segments → additive-поля события
node "$repo_root/lib/plan-io.mjs" complete 001 --tokens 5 --dispatches 7 --arm cap30 --segments 2 >/dev/null
ev="$(tail -n 1 .mvp/telemetry/events.jsonl)"
assert_eq "arm в событии" "cap30" "$(jfield "$ev" 'd["arm"]')"
assert_eq "segments в событии" "2" "$(jfield "$ev" 'd["segments"]')"
# (5) additive: complete БЕЗ --arm/--segments не пишет эти поля вовсе
#     (фикстура: вторая pending-задача id=002 в том же plan.json, уже есть в
#     tests/fixtures/plan-3tasks.json)
node "$repo_root/lib/plan-io.mjs" complete 002 --tokens 1 --dispatches 1 >/dev/null
ev="$(tail -n 1 .mvp/telemetry/events.jsonl)"
assert_eq "без флагов arm отсутствует" "False" "$(jfield "$ev" '"arm" in d')"
assert_eq "без флагов segments отсутствует" "False" "$(jfield "$ev" '"segments" in d')"

exit $fail
