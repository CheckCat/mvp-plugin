#!/usr/bin/env bash
# Tests for lib/plan-io.mjs
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
plan_io="$repo_root/lib/plan-io.mjs"
fixture="$repo_root/tests/fixtures/plan-3tasks.json"

fail=0
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    fail=1
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" != "true" ] && [ "$cond" != "1" ]; then
    echo "FAIL: $desc — expected truthy, got [$cond]" >&2
    fail=1
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) echo "FAIL: $desc — expected to contain [$needle]" >&2; fail=1 ;;
  esac
}

json_field() { # <json> <python-expr-on-d>
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null
}

# new_repo -> path to a fresh tmp-git project with the 3-task fixture seeded
# and committed at .claude/state/plan.json (clean tree baseline).
new_repo() {
  local dir
  dir="$(mktemp -d -p "$tmproot")"
  ( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
  mkdir -p "$dir/.claude/state"
  cp "$fixture" "$dir/.claude/state/plan.json"
  ( cd "$dir" && git add .claude/state/plan.json && git commit -q -m "chore: seed plan" )
  echo "$dir"
}

# run_plan_io <dir> <args...> — runs plan-io.mjs with cwd=<dir>
run_plan_io() {
  local dir="$1"; shift
  ( cd "$dir" && node "$plan_io" "$@" )
}

# mutate_plan <dir> <python-stmt-on-plan> — loads/rewrites .claude/state/plan.json
mutate_plan() {
  local dir="$1" stmt="$2"
  python3 - "$dir/.claude/state/plan.json" "$stmt" <<'PY'
import json, sys
path, stmt = sys.argv[1], sys.argv[2]
with open(path) as f:
    plan = json.load(f)
exec(stmt)
with open(path, "w") as f:
    json.dump(plan, f)
PY
}

# new_repo_with_plan <raw-json-content> -> path to a fresh tmp-git project
# with plan.json set to the given raw content (committed, clean baseline).
new_repo_with_plan() {
  local content="$1"
  local dir
  dir="$(mktemp -d -p "$tmproot")"
  ( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
  mkdir -p "$dir/.claude/state"
  printf '%s' "$content" > "$dir/.claude/state/plan.json"
  ( cd "$dir" && git add .claude/state/plan.json && git commit -q -m "chore: seed plan" )
  echo "$dir"
}

# ---------------------------------------------------------------------------
# (a) validate
# ---------------------------------------------------------------------------

dir="$(new_repo)"
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "validate valid fixture: exit code" "0" "$rc"
assert_eq "validate valid fixture: ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "validate valid fixture: errors empty" "0" "$(json_field "$out" 'len(d["data"]["errors"])')"

dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"][0]["depends_on"] = ["003"]'
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "validate cycle: exit code" "1" "$rc"
assert_eq "validate cycle: ok" "False" "$(json_field "$out" 'd["ok"]')"
errs="$(json_field "$out" '" ".join(d["data"]["errors"])')"
assert_contains "validate cycle: mentions cycle" "$errs" "cycle"

dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"][0]["files"] = ["other/outside.py"]'
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "validate files-outside-boundary: exit code" "1" "$rc"
assert_eq "validate files-outside-boundary: ok" "False" "$(json_field "$out" 'd["ok"]')"
errs="$(json_field "$out" '" ".join(d["data"]["errors"])')"
assert_contains "validate files-outside-boundary: mentions file" "$errs" "other/outside.py"

# bonus: --schema <path> reads the same info from a schema JSON file
dir="$(new_repo)"
schema_file="$dir/schema.json"
cat >"$schema_file" <<'EOF'
{
  "required_fields": ["id","title","level","service","service_path","role","files","depends_on","estimate_tokens","status","complexity_class"],
  "enums": {
    "complexity_class": ["boilerplate","follow-pattern","novel-design"],
    "status": ["pending","in_progress","done","failed"]
  },
  "max_estimate_tokens": 25000
}
EOF
out="$(run_plan_io "$dir" validate --schema "$schema_file")"; rc=$?
assert_eq "validate with --schema file: exit code" "0" "$rc"
assert_eq "validate with --schema file: ok" "True" "$(json_field "$out" 'd["ok"]')"

# bonus: no plan.json at all -> real error, not a halt
dir="$(mktemp -d -p "$tmproot")"
( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "validate no plan.json: exit code" "1" "$rc"
assert_eq "validate no plan.json: ok" "False" "$(json_field "$out" 'd["ok"]')"

# ---------------------------------------------------------------------------
# (b) next on fresh fixture -> task-001
# ---------------------------------------------------------------------------

dir="$(new_repo)"
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "next fresh: exit code" "0" "$rc"
assert_eq "next fresh: ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "next fresh: task_id" "001" "$(json_field "$out" 'd["data"]["task_id"]')"
assert_eq "next fresh: boundary" "app" "$(json_field "$out" 'd["data"]["boundary"]')"
assert_eq "next fresh: role" "backend-implementer" "$(json_field "$out" 'd["data"]["role"]')"
assert_eq "next fresh: model_class == task complexity_class" "boilerplate" "$(json_field "$out" 'd["data"]["model_class"]')"
assert_eq "next fresh: files == task declared files" "app/main.py" "$(json_field "$out" '",".join(d["data"]["files"])')"
assert_eq "next fresh: title == task title" "Set up API skeleton" "$(json_field "$out" 'd["data"]["title"]')"
brief_path="$(json_field "$out" 'd["data"]["brief_path"]')"
assert_true "next fresh: brief file exists" "$([ -f "$dir/$brief_path" ] && echo true || echo false)"
brief_content="$(cat "$dir/$brief_path")"
assert_contains "next fresh: brief has Boundary section" "$brief_content" "## Boundary"
assert_contains "next fresh: brief boundary is service_path verbatim" "$brief_content" "app"

# ---------------------------------------------------------------------------
# (c) after set-status + report -> next gives task-002, brief has task-001's report
# ---------------------------------------------------------------------------

mkdir -p "$dir/.claude/state/reports"
echo "Interface: GET /health returns 200" > "$dir/.claude/state/reports/task-001.md"
out="$(run_plan_io "$dir" set-status 001 done)"; rc=$?
assert_eq "set-status 001 done: exit code" "0" "$rc"
assert_eq "set-status 001 done: ok" "True" "$(json_field "$out" 'd["ok"]')"

out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "next after 001 done: exit code" "0" "$rc"
assert_eq "next after 001 done: task_id" "002" "$(json_field "$out" 'd["data"]["task_id"]')"
brief_path="$(json_field "$out" 'd["data"]["brief_path"]')"
brief_content="$(cat "$dir/$brief_path")"
assert_contains "next after 001 done: brief contains dep report text" "$brief_content" "GET /health returns 200"

# ---------------------------------------------------------------------------
# (d) interrupt file -> halt interrupt
# ---------------------------------------------------------------------------

dir="$(new_repo)"
echo "operator paused the run" > "$dir/.claude/state/user-interrupt.md"
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "next interrupt: exit code" "0" "$rc"
assert_eq "next interrupt: ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "next interrupt: halt" "interrupt" "$(json_field "$out" 'd["data"]["halt"]')"

# ---------------------------------------------------------------------------
# (e) dirty file outside .claude/state -> halt dirty-tree
# ---------------------------------------------------------------------------

dir="$(new_repo)"
echo "stray edit" > "$dir/README.md"
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "next dirty-tree: exit code" "0" "$rc"
assert_eq "next dirty-tree: ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "next dirty-tree: halt" "dirty-tree" "$(json_field "$out" 'd["data"]["halt"]')"
files_str="$(json_field "$out" '" ".join(d["data"]["files"])')"
assert_contains "next dirty-tree: lists README.md" "$files_str" "README.md"

# bonus: explicit --task with unmet deps -> halt dag-stuck with detail
dir="$(new_repo)"
out="$(run_plan_io "$dir" next --task 002)"; rc=$?
assert_eq "next explicit --task unmet deps: exit code" "0" "$rc"
assert_eq "next explicit --task unmet deps: halt" "dag-stuck" "$(json_field "$out" 'd["data"]["halt"]')"
detail="$(json_field "$out" 'd["data"].get("detail","")')"
assert_true "next explicit --task unmet deps: has detail" "$([ -n "$detail" ] && echo true || echo false)"

# bonus: all tasks done -> halt all-done
dir="$(new_repo)"
run_plan_io "$dir" set-status 001 done >/dev/null
run_plan_io "$dir" set-status 002 done >/dev/null
run_plan_io "$dir" set-status 003 done >/dev/null
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "next all-done: halt" "all-done" "$(json_field "$out" 'd["data"]["halt"]')"

# ---------------------------------------------------------------------------
# (f) complete -> status done, per-task delta tokens, ISO ts telemetry event
# ---------------------------------------------------------------------------

dir="$(new_repo)"
out="$(run_plan_io "$dir" complete 001 --tokens 4200)"; rc=$?
assert_eq "complete: exit code" "0" "$rc"
assert_eq "complete: ok" "True" "$(json_field "$out" 'd["ok"]')"

plan_status="$(python3 -c 'import json; d=json.load(open("'"$dir"'/.claude/state/plan.json")); print([t for t in d["tasks"] if t["id"]=="001"][0]["status"])')"
assert_eq "complete: task status done in plan.json" "done" "$plan_status"
plan_tokens="$(python3 -c 'import json; d=json.load(open("'"$dir"'/.claude/state/plan.json")); print([t for t in d["tasks"] if t["id"]=="001"][0]["actual_tokens"])')"
assert_eq "complete: actual_tokens stored" "4200" "$plan_tokens"

events_file="$dir/.claude/state/telemetry/events.jsonl"
assert_true "complete: events.jsonl exists" "$([ -f "$events_file" ] && echo true || echo false)"
last_event="$(tail -n1 "$events_file")"
assert_eq "complete: event type" "task_complete" "$(json_field "$last_event" 'd["event"]')"
assert_eq "complete: event task" "001" "$(json_field "$last_event" 'd["task"]')"
assert_eq "complete: event delta_tokens" "4200" "$(json_field "$last_event" 'd["delta_tokens"]')"
ts="$(json_field "$last_event" 'd["ts"]')"
if [[ ! "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]; then
  echo "FAIL: complete: ts is not ISO 8601 — got [$ts]" >&2
  fail=1
fi

# delta-not-cumulative: a second complete call with a different delta must
# OVERWRITE actual_tokens, not add to it, and telemetry keeps two per-call
# entries (not a running total).
run_plan_io "$dir" complete 001 --tokens 500 >/dev/null
plan_tokens2="$(python3 -c 'import json; d=json.load(open("'"$dir"'/.claude/state/plan.json")); print([t for t in d["tasks"] if t["id"]=="001"][0]["actual_tokens"])')"
assert_eq "complete: second call stores delta, not cumulative sum" "500" "$plan_tokens2"
event_count="$(python3 -c 'print(sum(1 for _ in open("'"$events_file"'")))')"
assert_eq "complete: telemetry has one event per call" "2" "$event_count"
second_event_delta="$(json_field "$(tail -n1 "$events_file")" 'd["delta_tokens"]')"
assert_eq "complete: second event delta_tokens is per-call, not cumulative" "500" "$second_event_delta"

# ---------------------------------------------------------------------------
# (g) ledger — idempotent header, appended lines
# ---------------------------------------------------------------------------

dir="$(new_repo)"
run_plan_io "$dir" ledger --task 001 --sha abc1234 >/dev/null
run_plan_io "$dir" ledger --task 002 --sha def5678 >/dev/null
ledger_file="$dir/.claude/state/ledger.md"
assert_true "ledger: file exists" "$([ -f "$ledger_file" ] && echo true || echo false)"
header_count="$(grep -c '^# Ledger ' "$ledger_file")"
assert_eq "ledger: exactly one header line" "1" "$header_count"
task_line_count="$(grep -c '^Task ' "$ledger_file")"
assert_eq "ledger: two task lines" "2" "$task_line_count"
assert_true "ledger: header mentions plan.json abs path" "$(grep -q "plan.json sha256:" "$ledger_file" && echo true || echo false)"
assert_true "ledger: line 1 for task 001" "$(grep -q '^Task 001: complete (abc1234)$' "$ledger_file" && echo true || echo false)"
assert_true "ledger: line 2 for task 002" "$(grep -q '^Task 002: complete (def5678)$' "$ledger_file" && echo true || echo false)"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

dir="$(new_repo)"
run_plan_io "$dir" set-status 001 done >/dev/null
out="$(run_plan_io "$dir" summary)"; rc=$?
assert_eq "summary: exit code" "0" "$rc"
assert_eq "summary: total" "3" "$(json_field "$out" 'd["data"]["total"]')"
assert_eq "summary: done" "1" "$(json_field "$out" 'd["data"]["done"]')"
assert_eq "summary: pending" "2" "$(json_field "$out" 'd["data"]["pending"]')"
assert_eq "summary: failed" "0" "$(json_field "$out" 'd["data"]["failed"]')"
phase1_done="$(json_field "$out" 'd["data"]["phases"]["1"]["done"]')"
assert_eq "summary: phases grouped by level" "1" "$phase1_done"

# ---------------------------------------------------------------------------
# argv guard — unknown/missing subcommand and args never crash with a stack trace
# ---------------------------------------------------------------------------

dir="$(new_repo)"
out="$(run_plan_io "$dir" bogus-command)"; rc=$?
assert_eq "argv guard: unknown subcommand exit code" "1" "$rc"
assert_eq "argv guard: unknown subcommand ok" "False" "$(json_field "$out" 'd["ok"]')"
assert_true "argv guard: unknown subcommand has hint" "$([ -n "$(json_field "$out" 'd["hint"] or ""')" ] && echo true || echo false)"

out="$(run_plan_io "$dir")"; rc=$?
assert_eq "argv guard: missing subcommand exit code" "1" "$rc"
assert_eq "argv guard: missing subcommand ok" "False" "$(json_field "$out" 'd["ok"]')"

out="$(run_plan_io "$dir" complete 001)"; rc=$?
assert_eq "argv guard: complete missing --tokens exit code" "1" "$rc"
assert_eq "argv guard: complete missing --tokens ok" "False" "$(json_field "$out" 'd["ok"]')"

out="$(run_plan_io "$dir" set-status 001 not-a-status)"; rc=$?
assert_eq "argv guard: set-status invalid status exit code" "1" "$rc"
assert_eq "argv guard: set-status invalid status ok" "False" "$(json_field "$out" 'd["ok"]')"

# ---------------------------------------------------------------------------
# regression: C-1 — all-done is terminal ONLY when every task is done.
# failed/in_progress tasks (with no eligible pending task) must halt
# dag-stuck with a detail naming the blocking id(s) and their status.
# ---------------------------------------------------------------------------

# (i) 001 done + 002 failed -> dag-stuck, detail names 002(failed)
dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"] = plan["tasks"][:2]'
run_plan_io "$dir" set-status 001 done >/dev/null
run_plan_io "$dir" set-status 002 failed >/dev/null
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "C-1(i) 001 done + 002 failed: exit code" "0" "$rc"
assert_eq "C-1(i) 001 done + 002 failed: halt" "dag-stuck" "$(json_field "$out" 'd["data"]["halt"]')"
detail="$(json_field "$out" 'd["data"]["detail"]')"
assert_contains "C-1(i) 001 done + 002 failed: detail names 002(failed)" "$detail" "002(failed)"

# (ii) same, but 002 in_progress -> dag-stuck, detail names 002(in_progress)
dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"] = plan["tasks"][:2]'
run_plan_io "$dir" set-status 001 done >/dev/null
run_plan_io "$dir" set-status 002 in_progress >/dev/null
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "C-1(ii) 001 done + 002 in_progress: exit code" "0" "$rc"
assert_eq "C-1(ii) 001 done + 002 in_progress: halt" "dag-stuck" "$(json_field "$out" 'd["data"]["halt"]')"
detail="$(json_field "$out" 'd["data"]["detail"]')"
assert_contains "C-1(ii) 001 done + 002 in_progress: detail names 002(in_progress)" "$detail" "002(in_progress)"

# (iii) truly all done -> all-done (still holds after the C-1 fix)
dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"] = plan["tasks"][:2]'
run_plan_io "$dir" set-status 001 done >/dev/null
run_plan_io "$dir" set-status 002 done >/dev/null
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "C-1(iii) all done: halt" "all-done" "$(json_field "$out" 'd["data"]["halt"]')"

# (iv) zero tasks in plan -> dag-stuck (never all-done), detail says so
dir="$(new_repo_with_plan '{"tasks": []}')"
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "C-1(iv) zero tasks: exit code" "0" "$rc"
assert_eq "C-1(iv) zero tasks: halt" "dag-stuck" "$(json_field "$out" 'd["data"]["halt"]')"
assert_eq "C-1(iv) zero tasks: detail" "no tasks in plan" "$(json_field "$out" 'd["data"]["detail"]')"

# ---------------------------------------------------------------------------
# regression: I-1 — validate rejects a missing/empty plan.tasks structurally
# (ok:false), instead of silently treating "no tasks" as valid.
# ---------------------------------------------------------------------------

dir="$(new_repo_with_plan '{}')"
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "I-1 missing tasks field ({}): exit code" "1" "$rc"
assert_eq "I-1 missing tasks field ({}): ok" "False" "$(json_field "$out" 'd["ok"]')"

dir="$(new_repo_with_plan '{"tasks": []}')"
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "I-1 empty tasks array: exit code" "1" "$rc"
assert_eq "I-1 empty tasks array: ok" "False" "$(json_field "$out" 'd["ok"]')"

# ---------------------------------------------------------------------------
# regression: I-2 — --schema file that parses but has none of the recognized
# keys must error clearly, not silently fall back to defaults.
# ---------------------------------------------------------------------------

dir="$(new_repo)"
unrecognized_schema="$dir/unrecognized-schema.json"
echo '{"totally_unrelated_key": true}' > "$unrecognized_schema"
out="$(run_plan_io "$dir" validate --schema "$unrecognized_schema")"; rc=$?
assert_eq "I-2 unrecognized schema file: exit code" "1" "$rc"
assert_eq "I-2 unrecognized schema file: ok" "False" "$(json_field "$out" 'd["ok"]')"
reason="$(json_field "$out" 'd["reason"]')"
assert_contains "I-2 unrecognized schema file: reason mentions recognized keys" "$reason" "recognized keys"

# ---------------------------------------------------------------------------
# regression: I-3 — isUnderBoundary normalizes via path.relative.
# ---------------------------------------------------------------------------

# app/../secret/x.py resolves OUTSIDE app/ -> must now be rejected
dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"][0]["files"] = ["app/../secret/x.py"]'
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "I-3 traversal escapes boundary: exit code" "1" "$rc"
assert_eq "I-3 traversal escapes boundary: ok" "False" "$(json_field "$out" 'd["ok"]')"
errs="$(json_field "$out" '" ".join(d["data"]["errors"])')"
assert_contains "I-3 traversal escapes boundary: mentions file" "$errs" "app/../secret/x.py"

# ./app/main.py resolves INSIDE app/ -> must now be accepted
dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"][0]["files"] = ["./app/main.py"]'
out="$(run_plan_io "$dir" validate)"; rc=$?
assert_eq "I-3 leading-./ form is accepted: exit code" "0" "$rc"
assert_eq "I-3 leading-./ form is accepted: ok" "True" "$(json_field "$out" 'd["ok"]')"

# ---------------------------------------------------------------------------
# regression: M-1 — interrupt check happens BEFORE plan.json is read.
# interrupt file present + plan.json missing -> halt interrupt (ok:true),
# never a plan.json read error.
# ---------------------------------------------------------------------------

dir="$(mktemp -d -p "$tmproot")"
( cd "$dir" && git init -q && git config user.email test@test.local && git config user.name test )
mkdir -p "$dir/.claude/state"
echo "operator paused the run" > "$dir/.claude/state/user-interrupt.md"
out="$(run_plan_io "$dir" next)"; rc=$?
assert_eq "M-1 interrupt before missing plan.json: exit code" "0" "$rc"
assert_eq "M-1 interrupt before missing plan.json: ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "M-1 interrupt before missing plan.json: halt" "interrupt" "$(json_field "$out" 'd["data"]["halt"]')"

# ---------------------------------------------------------------------------
# (N) relay diet + script-owned concerns: head_sha on `next`, --write-msg /
#     --dispatches on `complete`, `ledger --sha HEAD` and --concern. Each of
#     these removed either a whole subagent dispatch (~30 200 tokens of boot
#     apiece) or a state write the calling SKILL was told to make and never did.
# ---------------------------------------------------------------------------

dir="$(new_repo)"
out="$(run_plan_io "$dir" next)"
expected_head="$( cd "$dir" && git rev-parse HEAD )"
assert_eq "N-1 next returns head_sha" "$expected_head" "$(json_field "$out" 'd["data"]["head_sha"]')"

# complete --write-msg builds a finalize.sh-compatible subject from plan.json,
# so the free-text task title never passes through a shell or a prompt.
dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"][0]["title"] = "Title with \"quotes\" and $VAR and `backtick`"'
out="$(run_plan_io "$dir" complete 001 --tokens 5 --dispatches 9 --write-msg .claude/state/msg.txt)"
assert_eq "N-2 complete ok" "True" "$(json_field "$out" 'd["ok"]')"
subject="$(head -n1 "$dir/.claude/state/msg.txt")"
assert_eq "N-3 subject keeps the title verbatim" \
  'feat: task 001: Title with "quotes" and $VAR and `backtick`' "$subject"
assert_eq "N-4 msg file is exactly one line" "1" "$(wc -l < "$dir/.claude/state/msg.txt" | tr -d ' ')"
if ! printf '%s' "$subject" | grep -qE '^(feat|fix|ci|chore|test|docs|refactor)(\(.+\))?: '; then
  echo "FAIL: N-5 subject fails finalize.sh prefix check: $subject" >&2
  fail=1
fi

# telemetry is additive: delta_tokens survives, the honesty fields join it
ev="$(tail -n1 "$dir/.claude/state/telemetry/events.jsonl")"
assert_eq "N-6 telemetry keeps delta_tokens" "5" "$(json_field "$ev" 'd["delta_tokens"]')"
assert_eq "N-7 telemetry records dispatches" "9" "$(json_field "$ev" 'd["dispatches"]')"
assert_eq "N-8 telemetry marks the figure controller-only" "True" "$(json_field "$ev" 'd["controller_only"]')"

# a newline in the title must not push the real subject into the commit body
dir="$(new_repo)"
mutate_plan "$dir" 'plan["tasks"][0]["title"] = "first\nsecond"'
run_plan_io "$dir" complete 001 --tokens 1 --write-msg .claude/state/msg.txt >/dev/null
assert_eq "N-9 newline in title collapses to one line" "1" \
  "$(wc -l < "$dir/.claude/state/msg.txt" | tr -d ' ')"

# ledger --sha HEAD resolves the commit itself, so the call can be chained
# after finalize.sh in one shell command instead of costing its own relay.
dir="$(new_repo)"
head_sha="$( cd "$dir" && git rev-parse HEAD )"
out="$(run_plan_io "$dir" ledger --task 001 --sha HEAD)"
assert_eq "N-10 ledger --sha HEAD ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "N-11 ledger echoes the resolved sha" "$head_sha" "$(json_field "$out" 'd["data"]["sha"]')"
assert_eq "N-12 ledger line carries the real sha" "1" \
  "$(grep -c "Task 001: complete ($head_sha)" "$dir/.claude/state/ledger.md")"

# concerns are written BY THE SCRIPT — this is the write the SKILL was told to
# make and skipped on 36 of 36 vireo tasks.
dir="$(new_repo)"
run_plan_io "$dir" ledger --task 002 --sha HEAD \
  --concern "declared-files hint mismatch: a.py, b.py
review finding refuted, not fixed: no caller reaches that path" >/dev/null
assert_eq "N-13 first concern line persisted" "1" \
  "$(grep -c 'concern (task 002): declared-files hint mismatch: a.py, b.py' "$dir/.claude/state/ledger.md")"
assert_eq "N-14 second concern line persisted" "1" \
  "$(grep -c 'concern (task 002): review finding refuted' "$dir/.claude/state/ledger.md")"
# a concern must never look like it belongs to the following task
assert_eq "N-15 concerns precede their Task line" "1" \
  "$(python3 -c "
import sys
lines = open(sys.argv[1]).read().splitlines()
ci = max(i for i, l in enumerate(lines) if l.startswith('  concern (task 002)'))
ti = max(i for i, l in enumerate(lines) if l.startswith('Task 002: complete'))
print(1 if ci < ti else 0)
" "$dir/.claude/state/ledger.md")"

# ---------------------------------------------------------------------------
# (O) add-task — a plan discovered mid-run must be able to grow.
#     Until this verb existed the DAG froze the moment mvp:plan committed it.
#     Hit twice on vireo; the second time a circular import that broke two
#     deploy units sat in blockers.md with nowhere to go and was fixed by hand
#     after the plan had already reported all-done.
# ---------------------------------------------------------------------------

VALID_TASK='{"title":"Smoke-test entrypoint imports","level":11,"service":"api","service_path":"services/api","role":"test-writer","files":["services/api/tests/test_entrypoint_imports.py"],"depends_on":[],"estimate_tokens":8000,"complexity_class":"follow-pattern"}'

# id is assigned by continuing the sequence when the caller omits it
dir="$(new_repo)"
out="$(run_plan_io "$dir" add-task --json "$VALID_TASK")"
assert_eq "O-1 add-task ok" "True" "$(json_field "$out" 'd["ok"]')"
assert_eq "O-2 id continues the sequence" "004" "$(json_field "$out" 'd["data"]["task_id"]')"
assert_eq "O-3 plan grew by one" "4" "$(json_field "$out" 'd["data"]["total"]')"
assert_eq "O-4 the new task is pending" "pending" \
  "$(python3 -c "
import json,sys
p=json.load(open(sys.argv[1]))
print([t for t in p['tasks'] if t['id']=='004'][0]['status'])
" "$dir/.claude/state/plan.json")"

# a caller cannot smuggle in an already-complete task
dir="$(new_repo)"
run_plan_io "$dir" add-task --json "$(printf '%s' "$VALID_TASK" | python3 -c "
import json,sys
t=json.load(sys.stdin); t['status']='done'; print(json.dumps(t))
")" >/dev/null
assert_eq "O-5 status is forced to pending" "pending" \
  "$(python3 -c "
import json,sys
p=json.load(open(sys.argv[1]))
print([t for t in p['tasks'] if t['id']=='004'][0]['status'])
" "$dir/.claude/state/plan.json")"

# duplicate id is refused
dir="$(new_repo)"
out="$(run_plan_io "$dir" add-task --json "$(printf '%s' "$VALID_TASK" | python3 -c "
import json,sys
t=json.load(sys.stdin); t['id']='001'; print(json.dumps(t))
")")"; rc=$?
assert_eq "O-6 duplicate id exit code" "1" "$rc"
assert_eq "O-7 duplicate id ok:false" "False" "$(json_field "$out" 'd["ok"]')"

# an invalid task must leave plan.json byte-identical — validation runs on the
# RESULT, and a rejected write is a no-op, not a partial one
dir="$(new_repo)"
before="$(shasum "$dir/.claude/state/plan.json" | cut -d' ' -f1)"
out="$(run_plan_io "$dir" add-task --json '{"title":"no fields at all"}')"; rc=$?
after="$(shasum "$dir/.claude/state/plan.json" | cut -d' ' -f1)"
assert_eq "O-8 invalid task exit code" "1" "$rc"
assert_eq "O-9 invalid task reports errors" "True" \
  "$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d['data']['errors'])>0)" "$out")"
assert_eq "O-10 plan.json untouched after a rejected add" "$before" "$after"

# an unknown dependency is rejected by the same shared validation
dir="$(new_repo)"
out="$(run_plan_io "$dir" add-task --json "$(printf '%s' "$VALID_TASK" | python3 -c "
import json,sys
t=json.load(sys.stdin); t['depends_on']=['999']; print(json.dumps(t))
")")"
assert_eq "O-11 unknown depends_on is refused" "False" "$(json_field "$out" 'd["ok"]')"

# a file outside service_path is rejected (same boundary rule as validate)
dir="$(new_repo)"
out="$(run_plan_io "$dir" add-task --json "$(printf '%s' "$VALID_TASK" | python3 -c "
import json,sys
t=json.load(sys.stdin); t['files']=['services/other/x.py']; print(json.dumps(t))
")")"
assert_eq "O-12 file outside service_path is refused" "False" "$(json_field "$out" 'd["ok"]')"

# malformed --json is a usage error, not a crash
dir="$(new_repo)"
out="$(run_plan_io "$dir" add-task --json '{not json')"; rc=$?
assert_eq "O-13 malformed json exit code" "1" "$rc"
assert_eq "O-14 malformed json ok:false" "False" "$(json_field "$out" 'd["ok"]')"

# the added task is immediately dispatchable
dir="$(new_repo)"
run_plan_io "$dir" add-task --json "$VALID_TASK" >/dev/null
mutate_plan "$dir" 'for t in plan["tasks"]:
    if t["id"] != "004":
        t["status"] = "done"'
out="$(run_plan_io "$dir" next)"
assert_eq "O-15 next picks the newly added task" "004" "$(json_field "$out" 'd["data"]["task_id"]')"

exit $fail
