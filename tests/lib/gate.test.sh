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

# Вернуть плагин к исходным байтам _common.md (derived снова чист — восстановление
# байтов, не пересборка/re-record), испортить только нормативку
printf 'COMMON v1\n' > "$gl_plugin/skills/bootstrap/templates/_common.md"
printf 'SKILL build v2 — новое требование\n' > "$gl_plugin/skills/build/SKILL.md"
g_norm="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: нормативка НЕ валит" "True" "$(json_field "$g_norm" 'd["ok"]')"
assert_eq "gate-lock: нормативка попала в data" "skills/build/SKILL.md" \
  "$(json_field "$g_norm" 'd["data"]["normative_changed"][0]')"

# --- plugin-lock: halt срабатывает на КАЖДЫЙ hard-класс, не только stale ---
# Правка 6а: мутация "оставить в halt-кортеже только stale" не красит эти
# три случая — tampered/missing/unstamped независимые ветки policy в
# gate_build (lib/gate.sh), и каждая нуждается в своём негативном контроле.

# tampered: агент руками поправлен, sources в lock не менялись.
printf 'ASSEMBLED devops — HAND EDITED\n' > "$gl_proj/.claude/agents/devops-engineer.md"
g_tampered="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: tampered валит" "False" "$(json_field "$g_tampered" 'd["ok"]')"
if ! echo "$g_tampered" | grep -q "hand-edited"; then
  echo "FAIL: gate-lock: tampered reason не про hand-edited: $g_tampered" >&2
  fail=1
fi
# восстановить байты — содержимое совпадает с тем, что было в момент record
# (строка 311 ниже по файлу), новый output_sha256 не нужен.
printf 'ASSEMBLED devops\n' > "$gl_proj/.claude/agents/devops-engineer.md"

# missing: роль ЕСТЬ в lock, но НЕ входит в plan.json tasks — иначе более
# ранняя проверка gate_build ("no agent file for role(s)") перехватила бы
# её первой, так и не добравшись до плагин-лока (plan.json здесь ссылается
# только на devops-engineer).
printf -- '---\nname: integration-specialist\ndescription: d\ntools: Read\n---\n\nBODY integ v1\n' \
  > "$gl_plugin/skills/bootstrap/templates/integration-specialist.template.md"
printf 'ASSEMBLED integ\n' > "$gl_proj/.claude/agents/integration-specialist.md"
(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" \
   record integration-specialist >/dev/null 2>&1)
rm "$gl_proj/.claude/agents/integration-specialist.md"
g_missing="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: missing валит" "False" "$(json_field "$g_missing" 'd["ok"]')"
if ! echo "$g_missing" | grep -q "missing"; then
  echo "FAIL: gate-lock: missing reason не про missing: $g_missing" >&2
  fail=1
fi
# Закрыть missing ДО следующего случая: байты совпадают с тем, что было в
# момент record строкой выше, новый output_sha256 не нужен. Остаток 3а:
# предыдущая версия этого файла не восстанавливала файл здесь, и следующий
# ("unstamped") ассерт ok:false проходил по чужой причине — missing,
# оставшийся открытым от этого случая, а не по своей.
printf 'ASSEMBLED integ\n' > "$gl_proj/.claude/agents/integration-specialist.md"

# --- plugin-lock: derived_unstamped халтит ТОЛЬКО если роль реально
# диспатчится планом (Остаток 1, спека §7/§5.2) -------------------------
# check не умеет отличить подменённого плагинного агента от рукописного
# файла оператора — у unstamped-находки нет поля role. Различает гейт, по
# planned_roles (то же извлечение ролей из plan.json, что и у missing_roles
# чуть выше в lib/gate.sh). Опасен только тот случай, когда план вот-вот
# выдаст задачу под эту роль; посторонний файл — не наша забота, но и не
# тишина: путь обязан быть виден оператору в data (симметрично normative).
#
# Две ИЗОЛИРОВАННЫЕ фикстуры, не мутации gl_proj: сценарии взаимоисключающие
# (один обязан валить, другой обязан проходить), и после известной находки
# в Остатке 3а история мутаций gl_proj и так длинная — плодить в ней ещё
# одну пару "добавили/убрали" означало бы новый шанс на тот же дефект.

# (a) роль unstamped-файла ЕСТЬ в plan.json -> halt.
gl_unstamp_inplan="$tmproot/gate-unstamped-inplan"
mkdir -p "$gl_unstamp_inplan/.claude/agents" "$gl_unstamp_inplan/.mvp"
(cd "$gl_unstamp_inplan" && git init -q . && git config user.email t@t && git config user.name t)
printf '%s\n' '{"tasks":[{"id":"001","role":"test-writer"}]}' > "$gl_unstamp_inplan/.mvp/plan.json"
printf '%s\n' '{"phase":"plan-done"}' > "$gl_unstamp_inplan/.mvp/state.json"
# Файл существует (не запись через record) — ровно то, что делает находку
# unstamped, а не missing/stale/tampered.
printf 'HAND-PLACED test-writer\n' > "$gl_unstamp_inplan/.claude/agents/test-writer.md"
(cd "$gl_unstamp_inplan" && git add .mvp .claude && git commit -qm init)
# lock должен существовать (иначе halt приходит по "no .mvp/plugin-lock.json",
# а не по unstamped) — seal его создаёт с derived:{} и нормативкой текущего
# плагина; derived-запись для test-writer в нём нет ни одной.
(cd "$gl_unstamp_inplan" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" seal >/dev/null 2>&1)
g_unstamp_inplan="$(cd "$gl_unstamp_inplan" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: unstamped, роль в плане — валит" "False" "$(json_field "$g_unstamp_inplan" 'd["ok"]')"
if ! echo "$g_unstamp_inplan" | grep -q "unstamped"; then
  echo "FAIL: gate-lock: unstamped(в плане) reason не про unstamped: $g_unstamp_inplan" >&2
  fail=1
fi

# (b) роль unstamped-файла НЕ входит в plan.json -> проходит, путь виден в data.
# ("my-custom-helper" — тот самый рукописный агент оператора из Остатка 1:
# ни одна роль плана не называется так же.)
gl_unstamp_foreign="$tmproot/gate-unstamped-foreign"
mkdir -p "$gl_unstamp_foreign/.claude/agents" "$gl_unstamp_foreign/.mvp"
(cd "$gl_unstamp_foreign" && git init -q . && git config user.email t@t && git config user.name t)
printf '%s\n' '{"tasks":[{"id":"001","role":"devops-engineer"}]}' > "$gl_unstamp_foreign/.mvp/plan.json"
printf '%s\n' '{"phase":"plan-done"}' > "$gl_unstamp_foreign/.mvp/state.json"
printf 'ASSEMBLED devops\n' > "$gl_unstamp_foreign/.claude/agents/devops-engineer.md"
(cd "$gl_unstamp_foreign" && git add .mvp .claude && git commit -qm init)
# devops-engineer — единственная роль плана — ЗАПИСАНА и запечатана, иначе
# она сама оказалась бы unstamped(в плане) и замаскировала бы то, что
# проверяет этот случай.
(cd "$gl_unstamp_foreign" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" \
   record devops-engineer docker-compose.fastify >/dev/null 2>&1)
(cd "$gl_unstamp_foreign" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/plugin-lock.sh" seal >/dev/null 2>&1)
printf 'MY CUSTOM HELPER\n' > "$gl_unstamp_foreign/.claude/agents/my-custom-helper.md"
g_unstamp_foreign="$(cd "$gl_unstamp_foreign" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: unstamped, роли нет в плане — не валит" "True" "$(json_field "$g_unstamp_foreign" 'd["ok"]')"
assert_eq "gate-lock: посторонний путь виден в data" ".claude/agents/my-custom-helper.md" \
  "$(json_field "$g_unstamp_foreign" 'd["data"]["derived_unstamped_foreign"][0]')"

# Отсутствие lock при наличии агентов — валит
rm "$gl_proj/.mvp/plugin-lock.json"
g_nolock="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: нет lock при наличии агентов — валит" "False" "$(json_field "$g_nolock" 'd["ok"]')"
if ! echo "$g_nolock" | grep -q "no .mvp/plugin-lock.json"; then
  echo "FAIL: gate-lock: нет-lock reason не про отсутствие lock-файла: $g_nolock" >&2
  fail=1
fi

# Битый lock (Остаток 2): файл ЕСТЬ, но не парсится как JSON — reason гейта
# обязан называть именно это, а не переиспользовать текст "файла нет вовсе".
# lib/gate.sh уже различает lock_present:false/lock_broken:true (полученные
# от plugin-lock.sh check) — здесь фиксируем это поведение тестом: раньше
# откат к безусловному "no .mvp/plugin-lock.json" не красил ни один тест.
printf '{not valid json' > "$gl_proj/.mvp/plugin-lock.json"
g_brokenlock="$(cd "$gl_proj" && PLUGIN_ROOT="$gl_plugin" bash "$repo_root/lib/gate.sh" build 2>/dev/null | tail -n1)"
assert_eq "gate-lock: битый lock — валит" "False" "$(json_field "$g_brokenlock" 'd["ok"]')"
assert_eq "gate-lock: битый lock reason называет битый файл" \
  "plugin-lock.json exists but is not valid JSON — cannot tell if agents match the plugin" \
  "$(json_field "$g_brokenlock" 'd["reason"]')"
if echo "$g_brokenlock" | grep -q "no .mvp/plugin-lock.json"; then
  echo "FAIL: gate-lock: битый lock reason говорит про отсутствующий файл (тот же текст, что и для нет-lock): $g_brokenlock" >&2
  fail=1
fi
rm "$gl_proj/.mvp/plugin-lock.json"

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

# --- plugin-lock: skip-ветка на валидном JSON, который НЕ объект -----------
# Правка 5а: `d.get(...)` в вердикт-блоке раньше не проверял тип r/d перед
# .get() — валидный JSON вида "[1,2,3]" или "null" не кидает json.loads,
# кидает AttributeError на r.get(...) ПОСЛЕ него. Без type-guard вердикт-
# скрипт падает молча, $lv остаётся пустым, ни одна ветка (halt/warn/skip)
# не срабатывает, и до правки build печатал ok:true с data:null БЕЗ
# диагностики на stderr — молча промахиваясь в небезопасную сторону.
# Проверяем обеими сторонами, как и в тесте выше: ok:true И непустой stderr.
for payload in '[1,2,3]' 'null'; do
  gl_lib_nonobj="$tmproot/gate-lock-nonobj-$(printf '%s' "$payload" | tr -dc 'a-z0-9')"
  cp -r "$repo_root/lib" "$gl_lib_nonobj"
  printf '#!/usr/bin/env bash\necho '"'"'%s'"'"'\n' "$payload" > "$gl_lib_nonobj/plugin-lock.sh"
  chmod +x "$gl_lib_nonobj/plugin-lock.sh"

  gl_nonobj_err="$tmproot/gate-lock-nonobj-stderr-$(printf '%s' "$payload" | tr -dc 'a-z0-9').txt"
  g_nonobj="$(cd "$gl_proj" && "$gl_lib_nonobj/gate.sh" build 2>"$gl_nonobj_err" | tail -n1)"
  assert_eq "gate-lock: non-object payload ($payload) не валит build" "True" \
    "$(json_field "$g_nonobj" 'd["ok"]')"
  if ! grep -q "plugin-lock" "$gl_nonobj_err"; then
    echo "FAIL: gate-lock: non-object payload ($payload) молчит на stderr: $(cat "$gl_nonobj_err")" >&2
    fail=1
  fi
done

exit $fail
