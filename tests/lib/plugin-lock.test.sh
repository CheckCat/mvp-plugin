#!/usr/bin/env bash
# Tests for lib/plugin-lock.sh
# Convention (tests/run.sh): exit 0 = pass. Fixtures under mktemp -d, cleaned via trap.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
LOCK_SH="$repo_root/lib/plugin-lock.sh"

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() { # <desc> <expected> <actual>
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1 — expected [$2], got [$3]" >&2
    fail=1
  fi
}

# Последняя строка stdout — JSON-контракт. Всё, что скрипт напечатал раньше,
# к контракту не относится и в тестах не участвует.
last_line() { printf '%s\n' "$1" | tail -n1; }

jq_py() { # <json> <python-выражение над d>
  PL_J="$1" PL_E="$2" python3 -c '
import json, os
d = json.loads(os.environ["PL_J"])
print(eval(os.environ["PL_E"]))
'
}

# Минимальный поддельный плагин: ровно те файлы, которые скрипт читает.
# Настоящий плагин не трогаем — тесты мутируют шаблоны.
make_fake_plugin() { # <dir>
  local p="$1"
  mkdir -p "$p/skills/bootstrap/templates" "$p/skills/bootstrap/scripts" \
           "$p/skills/build" "$p/lib" "$p/.claude-plugin"
  printf '%s\n' '{"name":"mvp","version":"9.9.9"}' > "$p/.claude-plugin/plugin.json"
  printf 'COMMON v1\n' > "$p/skills/bootstrap/templates/_common.md"
  printf -- '---\nname: devops-engineer\ndescription: d\ntools: Read\n---\n\nBODY devops v1\n' \
    > "$p/skills/bootstrap/templates/devops-engineer.docker-compose.fastify.template.md"
  printf -- '---\nname: integration-specialist\ndescription: d\ntools: Read\n---\n\nBODY integ v1\n' \
    > "$p/skills/bootstrap/templates/integration-specialist.template.md"
  printf -- '---\nname: test-writer\ndescription: d\ntools: Read\n---\n\nBODY test-writer v1\n' \
    > "$p/skills/bootstrap/templates/test-writer.fastify.template.md"
  printf 'SKILL bootstrap v1\n' > "$p/skills/bootstrap/SKILL.md"
  printf 'SKILL build v1\n'     > "$p/skills/build/SKILL.md"
  printf 'echo hi\n'            > "$p/lib/validate-task.sh"
  printf 'echo meta\n'          > "$p/skills/bootstrap/scripts/check-meta.sh"
}

make_fake_project() { # <dir>
  mkdir -p "$1/.claude/agents" "$1/.mvp"
}

# --- Test 1: record создаёт lock с одной записью derived ------------------

t1_plugin="$tmpdir/t1-plugin"; t1_proj="$tmpdir/t1-proj"
make_fake_plugin "$t1_plugin"; make_fake_project "$t1_proj"
printf 'ASSEMBLED devops\n' > "$t1_proj/.claude/agents/devops-engineer.md"

out1="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" PROJECT=trellis \
  SERVICE_API=trellis-api SERVICE_WORKER=trellis-worker \
  bash "$LOCK_SH" record devops-engineer docker-compose.fastify 2>/dev/null)"
rc1=$?
assert_eq "test 1: record exit" "0" "$rc1"
assert_eq "test 1: ok" "True" "$(jq_py "$(last_line "$out1")" 'd["ok"]')"

lock1="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 1: lock_version" "1" "$(jq_py "$lock1" 'd["lock_version"]')"
assert_eq "test 1: ключ derived" ".claude/agents/devops-engineer.md" \
  "$(jq_py "$lock1" 'list(d["derived"])[0]')"
assert_eq "test 1: stack" "docker-compose.fastify" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
assert_eq "test 1: template" "devops-engineer.docker-compose.fastify.template.md" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["template"]')"
assert_eq "test 1: PROJECT" "trellis" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["placeholders"]["PROJECT"]')"
assert_eq "test 1: два источника" "2" \
  "$(jq_py "$lock1" 'len(d["derived"][".claude/agents/devops-engineer.md"]["sources"])')"
assert_eq "test 1: output_sha256 есть" "True" \
  "$(jq_py "$lock1" 'd["derived"][".claude/agents/devops-engineer.md"]["output_sha256"].startswith("sha256:")')"
assert_eq "test 1: plugin.version" "9.9.9" "$(jq_py "$lock1" 'd["plugin"]["version"]')"
assert_eq "test 1: normative пуста" "0" "$(jq_py "$lock1" 'len(d["normative"])')"

# --- Test 8: record одной роли не ломает записи остальных ------------------

printf 'ASSEMBLED integ\n' > "$t1_proj/.claude/agents/integration-specialist.md"
(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" bash "$LOCK_SH" record integration-specialist >/dev/null 2>&1)

lock8="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 8: две записи" "2" "$(jq_py "$lock8" 'len(d["derived"])')"
assert_eq "test 8: devops уцелел" "docker-compose.fastify" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/devops-engineer.md"]["stack"]')"
assert_eq "test 8: роль без стека" "" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/integration-specialist.md"]["stack"]')"
assert_eq "test 8: шаблон без стека" "integration-specialist.template.md" \
  "$(jq_py "$lock8" 'd["derived"][".claude/agents/integration-specialist.md"]["template"]')"

# --- Test 8b: record при отсутствующем собранном агенте — ok:false ---------
# Шаблон test-writer.fastify.template.md существует (см. make_fake_plugin),
# поэтому падение должно случиться именно на отсутствии .claude/agents/test-writer.md,
# а не раньше — на отсутствии шаблона. Иначе тест проверяет не ту ветку.

out8b="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" \
  bash "$LOCK_SH" record test-writer fastify 2>/dev/null)"
rc8b=$?
assert_eq "test 8b: exit" "1" "$rc8b"
assert_eq "test 8b: ok" "False" "$(jq_py "$(last_line "$out8b")" 'd["ok"]')"
assert_eq "test 8b: reason про отсутствующий собранный агент" "True" \
  "$(jq_py "$(last_line "$out8b")" '"assembled agent missing" in d["reason"]')"

# --- Test 9: record с несуществующим стеком сбрасывает stack в "" ----------
# integration-specialist уже собран (.claude/agents/integration-specialist.md
# создан для Test 8). Запрашиваем заведомо отсутствующий стек: стекового
# шаблона <role>.<stack>.template.md нет, есть только общий <role>.template.md —
# запись обязана указывать на общий шаблон с обнулённым stack, а не хранить
# запрошенный "nosuchstack".

out9="$(cd "$t1_proj" && PLUGIN_ROOT="$t1_plugin" \
  bash "$LOCK_SH" record integration-specialist nosuchstack 2>/dev/null)"
rc9=$?
assert_eq "test 9: exit" "0" "$rc9"
assert_eq "test 9: ok" "True" "$(jq_py "$(last_line "$out9")" 'd["ok"]')"

lock9="$(cat "$t1_proj/.mvp/plugin-lock.json")"
assert_eq "test 9: stack сброшен" "" \
  "$(jq_py "$lock9" 'd["derived"][".claude/agents/integration-specialist.md"]["stack"]')"
assert_eq "test 9: template общий" "integration-specialist.template.md" \
  "$(jq_py "$lock9" 'd["derived"][".claude/agents/integration-specialist.md"]["template"]')"

exit $fail
