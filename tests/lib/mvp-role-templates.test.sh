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

# (4) verify-agents-drift.sh: смешанный каталог (1 обычная роль + 1 mvp-роль)
# проходит, mvp-relay.md учтён как skipped=1, не как violation.
# Exit code снимается ОТДЕЛЬНО от вызова, что печатает stdout ($? после пайпа
# в tail дал бы код tail, не скрипта — см. предупреждение в plugin-lock.test.sh).
DRIFT_SH="$repo_root/skills/bootstrap/scripts/verify-agents-drift.sh"
vfull="$(bash "$DRIFT_SH" 2>/dev/null)"
vrc=$?
vout="$(printf '%s\n' "$vfull" | tail -n 1)"
[ "$vrc" -eq 0 ] || { echo "FAIL: verify-agents-drift на чистом смешанном каталоге: exit $vrc: $vout" >&2; fail=1; }
echo "$vout" | grep -q '"ok": true' || { echo "FAIL: verify-agents-drift ok на чистом смешанном каталоге: $vout" >&2; fail=1; }
VD_OUT="$vout" python3 -c '
import json, os
d = json.loads(os.environ["VD_OUT"])
assert d["data"]["skipped"] == 1, "skipped != 1: %r" % d
assert d["data"]["total"] == 1, "total != 1 (mvp-relay не должен попадать в checked): %r" % d
assert d["data"]["drift"] == 0, "drift != 0: %r" % d
' || { echo "FAIL: verify-agents-drift data.skipped/total на чистом каталоге" >&2; fail=1; }

# (5) негативный контроль: испорченная ОБЫЧНАЯ роль (не mvp-) всё ещё ловится,
# даже когда в каталоге есть легитимно-пропускаемая mvp-роль рядом. Это тот
# ассерт, что обязан покраснеть, если исключение mvp-* написать слишком широко
# (например, пропускать всё подряд, а не только mvp-*-файлы) — проверено
# вручную во время реализации (см. отчёт), в автотесте не воспроизводится,
# чтобы не оставлять в репозитории намеренно сломанный скрипт.
size="$(wc -c < .claude/agents/integration-specialist.md | tr -d ' ')"
half=$((size / 2))
TAMPER_PATH=".claude/agents/integration-specialist.md" TAMPER_HALF="$half" python3 -c "
import os
p = os.environ['TAMPER_PATH']
half = int(os.environ['TAMPER_HALF'])
data = open(p, 'rb').read()
open(p, 'wb').write(data[:half])
"
vfull2="$(bash "$DRIFT_SH" 2>/dev/null)"
vrc2=$?
vout2="$(printf '%s\n' "$vfull2" | tail -n 1)"
[ "$vrc2" -eq 1 ] || { echo "FAIL: verify-agents-drift на испорченной роли: exit ожидался 1, получен $vrc2" >&2; fail=1; }
echo "$vout2" | grep -q '"ok": false' || { echo "FAIL: verify-agents-drift ok:false на испорченной роли: $vout2" >&2; fail=1; }
VD_OUT2="$vout2" python3 -c '
import json, os
d = json.loads(os.environ["VD_OUT2"])
assert d["data"]["drift"] == 1, "drift != 1 после порчи обычной роли: %r" % d
assert d["data"]["skipped"] == 1, "skipped изменился при порче обычной роли: %r" % d
assert any(v["file"].endswith("integration-specialist.md") for v in d["data"]["violations"]), "violations не называют испорченный файл: %r" % d
' || { echo "FAIL: verify-agents-drift data на испорченной роли" >&2; fail=1; }

# (6) краевой случай: каталог, где ВСЕ файлы — mvp-роли, это законное
# состояние («нет ролей-имплементеров пока, но и проверять нечего»), не
# «каталог пуст». Отдельная свежая фикстура — предыдущие шаги уже насытили
# $tmpdir/.claude/agents обычной ролью, которая испортила бы этот кейс.
tmpdir_onlymvp="$(mktemp -d)"
( cd "$tmpdir_onlymvp" && git init -q . && mkdir -p .mvp && \
  bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" mvp-relay >/dev/null && \
  bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" mvp-reviewer >/dev/null )
vfull6="$(cd "$tmpdir_onlymvp" && bash "$DRIFT_SH" 2>/dev/null)"
vrc6=$?
vout6="$(printf '%s\n' "$vfull6" | tail -n 1)"
rm -rf "$tmpdir_onlymvp"
[ "$vrc6" -eq 0 ] || { echo "FAIL: verify-agents-drift на каталоге из одних mvp-ролей: exit ожидался 0, получен $vrc6: $vout6" >&2; fail=1; }
echo "$vout6" | grep -q '"ok": true' || { echo "FAIL: verify-agents-drift ok на каталоге из одних mvp-ролей: $vout6" >&2; fail=1; }
VD_OUT6="$vout6" python3 -c '
import json, os
d = json.loads(os.environ["VD_OUT6"])
assert d["data"]["total"] == 0, "total != 0: %r" % d
assert d["data"]["skipped"] == 2, "skipped != 2: %r" % d
' || { echo "FAIL: verify-agents-drift data на каталоге из одних mvp-ролей" >&2; fail=1; }

# (7) регресс-контроль: каталог реально пуст (ни одной роли вообще) — это
# по-прежнему ошибка, не путать с (6). Иначе (6) не отличал бы «легитимно
# нечего проверять» от «assemble-agent.sh вообще не запускали».
tmpdir_empty="$(mktemp -d)"
mkdir -p "$tmpdir_empty/.claude/agents"
vfull7="$(cd "$tmpdir_empty" && bash "$DRIFT_SH" 2>/dev/null)"
vrc7=$?
vout7="$(printf '%s\n' "$vfull7" | tail -n 1)"
rm -rf "$tmpdir_empty"
[ "$vrc7" -eq 1 ] || { echo "FAIL: verify-agents-drift на пустом каталоге: exit ожидался 1, получен $vrc7" >&2; fail=1; }
echo "$vout7" | grep -q '"ok": false' || { echo "FAIL: verify-agents-drift ok:false на пустом каталоге: $vout7" >&2; fail=1; }

# (8) capped-копия: тот же файл + maxTurns: 30 во фронтматтере (Task 9,
# спека H1-cap-work-preservation). Использует уже собранный на шаге (3)
# integration-specialist.md.
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped integration-specialist | tail -n 1)"
echo "$out" | grep -q '"ok": true' || { echo "FAIL: --capped: $out" >&2; fail=1; }
[ -f .claude/agents/integration-specialist-capped.md ] || { echo "FAIL: capped-файл не создан" >&2; fail=1; }
[ "$(fm_field .claude/agents/integration-specialist-capped.md maxTurns)" = "30" ] || { echo "FAIL: maxTurns" >&2; fail=1; }
# name во фронтматтере должен стать <role>-capped — иначе харнесс зарегистрирует дубль имени
grep -q "name: integration-specialist-capped" .claude/agents/integration-specialist-capped.md || { echo "FAIL: name не переименован" >&2; fail=1; }
# тело (после фронтматтера) — идентично исходному, включая _common.md
# (drift-инвариант обязан продолжать держаться и на capped-копии).
diff <(awk 'NR==1&&$0=="---"{i++;next} i==1&&$0=="---"{i++;next} i>=2{print}' .claude/agents/integration-specialist.md) \
     <(awk 'NR==1&&$0=="---"{i++;next} i==1&&$0=="---"{i++;next} i>=2{print}' .claude/agents/integration-specialist-capped.md) \
  >/dev/null || { echo "FAIL: тело capped-копии разошлось с исходником" >&2; fail=1; }
# capped-копия НЕ штампуется в lock — экспериментальный артефакт, не производный
python3 -c "
import json
lock = json.load(open('.mvp/plugin-lock.json'))
assert '.claude/agents/integration-specialist-capped.md' not in lock['derived'], 'capped-файл не должен попадать в lock[\"derived\"]'
" || { echo "FAIL: capped-файл заштампован в lock" >&2; fail=1; }
# (9) --capped без собранного исходника → ok:false с hint про порядок сборки
rm -f .claude/agents/nope.md
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped nope | tail -n 1)" || true
echo "$out" | grep -q '"ok": false' || { echo "FAIL: --capped без исходника должен падать" >&2; fail=1; }

# (10) verify-agents-drift.sh: capped-копия имплементерской роли обязана
# по-прежнему проходить byte-substring-инвариант (она сделана из уже
# собранного файла — общий контракт в ней есть). Свежая фикстура: только
# integration-specialist + его capped-копия, ничего больше не мешает счёту.
tmpdir_capped="$(mktemp -d)"
( cd "$tmpdir_capped" && git init -q . && mkdir -p .mvp && \
  bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" integration-specialist >/dev/null && \
  bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped integration-specialist >/dev/null )
vfull10="$(cd "$tmpdir_capped" && bash "$DRIFT_SH" 2>/dev/null)"
vrc10=$?
vout10="$(printf '%s\n' "$vfull10" | tail -n 1)"
rm -rf "$tmpdir_capped"
[ "$vrc10" -eq 0 ] || { echo "FAIL: verify-agents-drift на capped-копии: exit ожидался 0, получен $vrc10: $vout10" >&2; fail=1; }
VD_OUT10="$vout10" python3 -c '
import json, os
d = json.loads(os.environ["VD_OUT10"])
assert d["data"]["total"] == 2, "total != 2 (обе роли под инвариантом): %r" % d
assert d["data"]["drift"] == 0, "drift != 0 на capped-копии: %r" % d
' || { echo "FAIL: verify-agents-drift data на capped-копии" >&2; fail=1; }

# (11) plugin-lock.sh check: незаштампованная capped-копия видна как
# derived_unstamped (foreign), но НЕ блокирует — гейт (lib/gate.sh) не в
# scope этого теста, здесь проверяем ровно то, что описано в notes H1:
# check её лишь перечисляет, не превращает в missing/stale/tampered.
tmpdir_check="$(mktemp -d)"
( cd "$tmpdir_check" && git init -q . && mkdir -p .mvp && \
  bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" integration-specialist >/dev/null && \
  PLUGIN_ROOT="$repo_root" bash "$repo_root/lib/plugin-lock.sh" seal >/dev/null && \
  bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped integration-specialist >/dev/null )
cfull="$(cd "$tmpdir_check" && PLUGIN_ROOT="$repo_root" bash "$repo_root/lib/plugin-lock.sh" check 2>/dev/null)"
cout="$(printf '%s\n' "$cfull" | tail -n 1)"
rm -rf "$tmpdir_check"
CHECK_OUT="$cout" python3 -c '
import json, os
d = json.loads(os.environ["CHECK_OUT"])
paths = [e["path"] for e in d["data"]["derived_unstamped"]]
assert ".claude/agents/integration-specialist-capped.md" in paths, "capped-файл не виден в derived_unstamped: %r" % d
assert d["data"]["derived_stale"] == [], "capped-файл не должен считаться stale: %r" % d
assert d["data"]["derived_tampered"] == [], "capped-файл не должен считаться tampered: %r" % d
' || { echo "FAIL: plugin-lock check на capped-копии" >&2; fail=1; }

exit $fail
