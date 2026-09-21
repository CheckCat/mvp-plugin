#!/usr/bin/env bash
# Tests for lib/gate.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
gate="$repo_root/lib/gate.sh"
state="$repo_root/lib/state.sh"

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

json_field() { # <json> <python-expr-on-d>
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null
}

new_project_dir() {
  mktemp -d -p "$tmproot"
}

# valid docs/product/ fixture (presence + non-empty content for all required headers)
write_valid_brief() {
  local dir="$1"
  mkdir -p "$dir/docs/product"
  cat >"$dir/docs/product/technical-solutions.md" <<'EOF'
# Technical solutions

## Stack
Backend: fastapi

## Services
api, worker

## Auth
argon2id + JWT RTR

## Deploy
Docker Compose via Dokploy
EOF
  cat >"$dir/docs/product/business-logic.md" <<'EOF'
# Business logic

## Goal
Ship the thing.

## Roles
Operator.

## Core scenarios
Do the thing.

## MVP scope
Just the thing.

## Success criteria
It works.
EOF
}

# docs/product/ fixture with headers present but empty sections (presence-only valid,
# content-invalid — used to differentiate clarify (presence) from bootstrap (content)).
write_headers_only_brief() {
  local dir="$1"
  mkdir -p "$dir/docs/product"
  cat >"$dir/docs/product/technical-solutions.md" <<'EOF'
## Stack

## Services

## Auth

## Deploy
EOF
  cat >"$dir/docs/product/business-logic.md" <<'EOF'
## Goal

## Roles

## Core scenarios

## MVP scope

## Success criteria
EOF
}

run_gate() { # <projectdir> <stage> -> sets G_OUT G_EXIT
  G_OUT="$(cd "$1" && "$gate" "$2" 2>/tmp/mvp-gate-test-err)"
  G_EXIT=$?
}

# --- (1) brief: empty dir -> ok:true, exit 0 --------------------------------

d1="$(new_project_dir)"
run_gate "$d1" brief
assert_eq "(1) brief empty dir exit code" "0" "$G_EXIT"
assert_eq "(1) brief empty dir ok:true" "True" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (2) brief: dir with CLAUDE.md -> ok:false, exit 1 ----------------------

d2="$(new_project_dir)"
: >"$d2/CLAUDE.md"
run_gate "$d2" brief
assert_eq "(2) brief with CLAUDE.md exit code" "1" "$G_EXIT"
assert_eq "(2) brief with CLAUDE.md ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (3) brief: valid docs/product/ + raw leftover file -> recovery archive-only

d3="$(new_project_dir)"
write_valid_brief "$d3"
: >"$d3/original-notes.md"
run_gate "$d3" brief
assert_eq "(3) brief archive-only exit code" "1" "$G_EXIT"
assert_eq "(3) brief archive-only ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"
assert_eq "(3) brief archive-only recovery" "archive-only" "$(json_field "$G_OUT" 'd["data"]["recovery"]')"

# --- (4) clarify: no docs/product/ -> ok:false, exit 1 ---------------------

d4="$(new_project_dir)"
run_gate "$d4" clarify
assert_eq "(4) clarify no brief exit code" "1" "$G_EXIT"
assert_eq "(4) clarify no brief ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (5) clarify: headers present but empty sections -> ok:true (presence-only)

d5="$(new_project_dir)"
write_headers_only_brief "$d5"
run_gate "$d5" clarify
assert_eq "(5) clarify presence-only exit code" "0" "$G_EXIT"
assert_eq "(5) clarify presence-only ok:true" "True" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (6) clarify: missing a header -> ok:false ------------------------------

d6="$(new_project_dir)"
write_headers_only_brief "$d6"
# drop the "## Deploy" header entirely
printf '## Stack\n\n## Services\n\n## Auth\n' >"$d6/docs/product/technical-solutions.md"
run_gate "$d6" clarify
assert_eq "(6) clarify missing header exit code" "1" "$G_EXIT"
assert_eq "(6) clarify missing header ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (7) bootstrap: headers present but empty -> ok:false (content required) -

d7="$(new_project_dir)"
write_headers_only_brief "$d7"
run_gate "$d7" bootstrap
assert_eq "(7) bootstrap empty sections exit code" "1" "$G_EXIT"
assert_eq "(7) bootstrap empty sections ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (8) bootstrap: valid brief + pending_critical unset -> ok:true ---------

d8="$(new_project_dir)"
write_valid_brief "$d8"
run_gate "$d8" bootstrap
assert_eq "(8) bootstrap valid brief exit code" "0" "$G_EXIT"
assert_eq "(8) bootstrap valid brief ok:true" "True" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (9) bootstrap: pending_critical > 0 -> ok:false with hint --------------

d9="$(new_project_dir)"
write_valid_brief "$d9"
(cd "$d9" && "$state" init >/dev/null && "$state" set pending_critical 2 >/dev/null)
run_gate "$d9" bootstrap
assert_eq "(9) bootstrap pending_critical exit code" "1" "$G_EXIT"
assert_eq "(9) bootstrap pending_critical ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"
if ! echo "$G_OUT" | grep -q "resolve criticals"; then
  echo "FAIL: (9) bootstrap pending_critical hint missing 'resolve criticals': $G_OUT" >&2
  fail=1
fi

# --- (10) plan: phase=bootstrap-done, no plan.json -> ok:true ---------------

d10="$(new_project_dir)"
(cd "$d10" && "$state" init >/dev/null && "$state" set phase bootstrap-done >/dev/null)
(cd "$d10" && git init -q)
run_gate "$d10" plan
assert_eq "(10) plan bootstrap-done exit code" "0" "$G_EXIT"
assert_eq "(10) plan bootstrap-done ok:true" "True" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (11) plan: phase=brief-done (not bootstrap-done) -> ok:false ----------

d11="$(new_project_dir)"
(cd "$d11" && "$state" init >/dev/null && "$state" set phase brief-done >/dev/null)
(cd "$d11" && git init -q)
run_gate "$d11" plan
assert_eq "(11) plan wrong phase exit code" "1" "$G_EXIT"
assert_eq "(11) plan wrong phase ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (12) plan: plan.json exists uncommitted in tmp-git -> recovery finalize-plan

d12="$(new_project_dir)"
(cd "$d12" && "$state" init >/dev/null && "$state" set phase bootstrap-done >/dev/null)
(cd "$d12" && git init -q && mkdir -p .mvp && echo '{}' >.mvp/plan.json)
run_gate "$d12" plan
assert_eq "(12) plan finalize-plan exit code" "1" "$G_EXIT"
assert_eq "(12) plan finalize-plan ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"
assert_eq "(12) plan finalize-plan recovery" "finalize-plan" "$(json_field "$G_OUT" 'd["data"]["recovery"]')"

# --- (13) build: plan.json missing -> ok:false ------------------------------

d13="$(new_project_dir)"
(cd "$d13" && "$state" init >/dev/null && "$state" set phase plan-done >/dev/null)
(cd "$d13" && git init -q)
run_gate "$d13" build
assert_eq "(13) build no plan.json exit code" "1" "$G_EXIT"
assert_eq "(13) build no plan.json ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (14) build: plan.json present + committed + phase=plan-done -> ok:true -

d14="$(new_project_dir)"
(cd "$d14" && "$state" init >/dev/null && "$state" set phase plan-done >/dev/null)
(
  cd "$d14" &&
  git init -q &&
  git config user.email test@test.local &&
  git config user.name test &&
  mkdir -p .mvp &&
  echo '{}' >.mvp/plan.json &&
  git add .mvp/plan.json .mvp/state.json &&
  git commit -q -m "chore: test fixture"
)
run_gate "$d14" build
assert_eq "(14) build ready exit code" "0" "$G_EXIT"
assert_eq "(14) build ready ok:true" "True" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (15) argv guard: unknown stage -> ok:false, hint lists valid stages ----

d15="$(new_project_dir)"
run_gate "$d15" bogus-stage
assert_eq "(15) argv guard unknown stage exit code" "1" "$G_EXIT"
assert_eq "(15) argv guard unknown stage ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"
if ! echo "$G_OUT" | grep -q "brief"; then
  echo "FAIL: (15) argv guard hint doesn't list valid stages: $G_OUT" >&2
  fail=1
fi

# --- (16) argv guard: missing stage -> ok:false, exit 1 ---------------------

d16="$(new_project_dir)"
G_OUT="$(cd "$d16" && "$gate" 2>/tmp/mvp-gate-test-err)"
G_EXIT=$?
assert_eq "(16) argv guard missing stage exit code" "1" "$G_EXIT"
assert_eq "(16) argv guard missing stage ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"

# --- (17) every output line is valid single-line JSON -----------------------

for out in "$(cd "$d1" && "$gate" brief)"; do
  lines="$(printf '%s' "$out" | wc -l | tr -d ' ')"
  assert_eq "(17) output is single line (no trailing newline mid-output)" "0" "$lines"
done

# --- (18) plan: no .git at all, valid plan.json, phase=bootstrap-done -> ok:false, reason mentions git

d18="$(new_project_dir)"
(cd "$d18" && "$state" init >/dev/null && "$state" set phase bootstrap-done >/dev/null)
mkdir -p "$d18/.mvp"
echo '{}' >"$d18/.mvp/plan.json"
run_gate "$d18" plan
assert_eq "(18) plan no-git exit code" "1" "$G_EXIT"
assert_eq "(18) plan no-git ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"
if ! echo "$G_OUT" | grep -qi "git"; then
  echo "FAIL: (18) plan no-git reason doesn't mention git: $G_OUT" >&2
  fail=1
fi

# --- (19) build: no .git at all, valid plan.json, phase=plan-done -> ok:false, reason mentions git

d19="$(new_project_dir)"
(cd "$d19" && "$state" init >/dev/null && "$state" set phase plan-done >/dev/null)
mkdir -p "$d19/.mvp"
echo '{}' >"$d19/.mvp/plan.json"
run_gate "$d19" build
assert_eq "(19) build no-git exit code" "1" "$G_EXIT"
assert_eq "(19) build no-git ok:false" "False" "$(json_field "$G_OUT" 'd["ok"]')"
if ! echo "$G_OUT" | grep -qi "git"; then
  echo "FAIL: (19) build no-git reason doesn't mention git: $G_OUT" >&2
  fail=1
fi

# --- plugin-lock: derived-дрейф валит gate build ------------------------
# Асимметрия намеренная (спека §7): устаревшие агенты не регистрируются,
# задачи уходят на general-purpose без контракта, и ревью это пропускает —
# оно судит дифф, а не автора. Нормативка так не вредит и не блокирует.

gl_proj="$tmproot/gate-lock-proj"
gl_plugin="$tmproot/gate-lock-plugin"
mkdir -p "$gl_plugin/skills/bootstrap/templates" "$gl_plugin/skills/build" \
         "$gl_plugin/lib" "$gl_plugin/.claude-plugin"
printf '%s\n' '{"name":"mvp","version":"9.9.9"}' > "$gl_plugin/.claude-plugin/plugin.json"
printf 'COMMON v1\n' > "$gl_plugin/skills/bootstrap/templates/_common.md"
printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nB\n' \
  > "$gl_plugin/skills/bootstrap/templates/devops-engineer.docker-compose.fastify.template.md"
printf 'SKILL build v1\n' > "$gl_plugin/skills/build/SKILL.md"
printf 'echo hi\n' > "$gl_plugin/lib/validate-task.sh"

# Проект, доведённый до состояния, в котором gate build проходит ВСЕ
# предыдущие проверки: git-репо, закоммиченный plan.json, phase=plan-done,
# агент на каждую роль плана.
mkdir -p "$gl_proj/.claude/agents" "$gl_proj/.mvp"
(cd "$gl_proj" && git init -q . && git config user.email t@t && git config user.name t)
printf 'ASSEMBLED devops\n' > "$gl_proj/.claude/agents/devops-engineer.md"
printf '%s\n' '{"tasks":[{"id":"001","role":"devops-engineer"}]}' > "$gl_proj/.mvp/plan.json"
printf '%s\n' '{"phase":"plan-done"}' > "$gl_proj/.mvp/state.json"
(cd "$gl_proj" && git add .mvp .claude && git commit -qm init)
(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" \
   record devops-engineer docker-compose.fastify >/dev/null 2>&1)
(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" \
   seal >/dev/null 2>&1)
(cd "$gl_proj" && git add .mvp && git commit -qm lock)

g_clean="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: чистый проект проходит" "True" "$(json_field "$g_clean" 'd["ok"]')"

# derived-дрейф: правим _common.md в плагине
printf 'COMMON v2\n' > "$gl_plugin/skills/bootstrap/templates/_common.md"
g_stale="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: derived-дрейф валит" "False" "$(json_field "$g_stale" 'd["ok"]')"
assert_eq "gate-lock: hint зовёт в mvp:sync" "run mvp:sync" "$(json_field "$g_stale" 'd["hint"]')"
# ok:false в gate_build бывает по многим причинам (нет git, план не
# закоммичен, нет агента под роль...) — hint уже различает их (см. выше), но
# reason проверяем отдельной подстрокой, чтобы не спутать именно ЭТОТ halt
# с любым другим источником ok:false.
if ! echo "$g_stale" | grep -q "out of sync with plugin"; then
  echo "FAIL: gate-lock: derived-дрейф reason не про рассинхрон с плагином: $g_stale" >&2
  fail=1
fi

# Вернуть плагин, пересобрать отметку, испортить только нормативку
printf 'COMMON v1\n' > "$gl_plugin/skills/bootstrap/templates/_common.md"
printf 'SKILL build v2 — новое требование\n' > "$gl_plugin/skills/build/SKILL.md"
g_norm="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: нормативка НЕ валит" "True" "$(json_field "$g_norm" 'd["ok"]')"
assert_eq "gate-lock: нормативка попала в data" "skills/build/SKILL.md" \
  "$(json_field "$g_norm" 'd["data"]["normative_changed"][0]')"

# Отсутствие lock при наличии агентов — валит
rm "$gl_proj/.mvp/plugin-lock.json"
g_nolock="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: нет lock при наличии агентов — валит" "False" "$(json_field "$g_nolock" 'd["ok"]')"
if ! echo "$g_nolock" | grep -q "no .mvp/plugin-lock.json"; then
  echo "FAIL: gate-lock: нет-lock reason не про отсутствие lock-файла: $g_nolock" >&2
  fail=1
fi

# Обратный контроль: отсутствие lock БЕЗ единого собранного агента — не
# валит (спека §7: "сравнить не с чем" — это не дрейф). Отдельный свежий
# проект, чтобы не зависеть от мутаций gl_proj выше по файлу.
gl_proj_noagents="$tmproot/gate-lock-proj-noagents"
mkdir -p "$gl_proj_noagents/.mvp"
(cd "$gl_proj_noagents" && git init -q . && git config user.email t@t && git config user.name t)
printf '%s\n' '{"tasks":[]}' > "$gl_proj_noagents/.mvp/plan.json"
printf '%s\n' '{"phase":"plan-done"}' > "$gl_proj_noagents/.mvp/state.json"
(cd "$gl_proj_noagents" && git add .mvp && git commit -qm init)
g_noagents="$(cd "$gl_proj_noagents" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: нет lock и нет агентов — НЕ валит" "True" "$(json_field "$g_noagents" 'd["ok"]')"

# --- plugin-lock: skip-ветка (plugin-lock.sh не отдал разбираемый JSON) --
# Требование: гейт не должен сам стать точкой отказа (build остаётся
# ok:true), но и не имеет права молча проглотить проблему — причина обязана
# уйти хоть куда-то (stderr, раз stdout занят JSON-контрактом). Проверяем
# обеими сторонами: ok:true И непустой релевантный stderr — по отдельности
# каждая половина могла бы пройти при сломанной другой.
gl_lib_broken="$tmproot/gate-lock-broken-lib"
cp -r "$repo_root/lib" "$gl_lib_broken"
printf '#!/usr/bin/env bash\necho "not valid json"\n' > "$gl_lib_broken/plugin-lock.sh"
chmod +x "$gl_lib_broken/plugin-lock.sh"

gl_skip_err="$tmproot/gate-lock-skip-stderr.txt"
g_skip="$(cd "$gl_proj" && "$gl_lib_broken/gate.sh" build 2>"$gl_skip_err" | tail -n1)"
assert_eq "gate-lock: skip-ветка не валит build" "True" "$(json_field "$g_skip" 'd["ok"]')"
if ! grep -q "plugin-lock" "$gl_skip_err"; then
  echo "FAIL: gate-lock: skip-ветка молчит на stderr: $(cat "$gl_skip_err")" >&2
  fail=1
fi

exit $fail
