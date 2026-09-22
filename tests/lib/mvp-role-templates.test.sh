#!/usr/bin/env bash
# mvp-роли: узкие tools, maxTurns во фронтматтере, сборка без _common.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fm_field() { # <file> <key> — значение из frontmatter
  awk -v k="$2" 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside && index($0, k":")==1 {sub(k": *", ""); print; exit}' "$1"
}

# (1) шаблоны существуют, tools узкие, maxTurns задан
t="$repo_root/skills/bootstrap/templates"
[ "$(fm_field "$t/mvp-reviewer.template.md" tools)" = "Read, Bash" ] || { echo "FAIL: mvp-reviewer tools" >&2; fail=1; }
[ "$(fm_field "$t/mvp-reviewer.template.md" maxTurns)" = "15" ] || { echo "FAIL: mvp-reviewer maxTurns" >&2; fail=1; }
[ "$(fm_field "$t/mvp-validator.template.md" maxTurns)" = "15" ] || { echo "FAIL: mvp-validator maxTurns" >&2; fail=1; }
[ "$(fm_field "$t/mvp-relay.template.md" tools)" = "Bash" ] || { echo "FAIL: mvp-relay tools" >&2; fail=1; }
[ "$(fm_field "$t/mvp-relay.template.md" maxTurns)" = "3" ] || { echo "FAIL: mvp-relay maxTurns" >&2; fail=1; }

# (2) сборка mvp-роли: без _common, без подстановки, зато штамп в lock
cd "$tmpdir"; git init -q .; mkdir -p .mvp
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" mvp-relay | tail -n 1)"
echo "$out" | grep -q '"ok": true' || { echo "FAIL: assemble mvp-relay: $out" >&2; fail=1; }
grep -q "Common Agent Principles" .claude/agents/mvp-relay.md && { echo "FAIL: mvp-роль получила _common" >&2; fail=1; }
grep -q "{{PROJECT}}" "$t/../templates/mvp-relay.template.md" && { echo "FAIL: в mvp-шаблоне не должно быть placeholder'ов" >&2; fail=1; }
python3 -c "
import json
lock = json.load(open('.mvp/plugin-lock.json'))
# derived — словарь по пути собранного файла (lib/plugin-lock.sh: lock['derived'][out] = {...}),
# не список: перебираем значения, не ключи (в брифе — перебор ключей, всегда AttributeError).
assert any(e.get('role') == 'mvp-relay' for e in lock['derived'].values()), 'mvp-relay не в lock'
" || { echo "FAIL: lock" >&2; fail=1; }

# (3) обычная роль по-прежнему С _common (регресс-контроль)
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" integration-specialist | tail -n 1)"
echo "$out" | grep -q '"ok": true' || { echo "FAIL: assemble integration-specialist: $out" >&2; fail=1; }
grep -q "Common Agent Principles" .claude/agents/integration-specialist.md || { echo "FAIL: обычная роль потеряла _common" >&2; fail=1; }

exit $fail
