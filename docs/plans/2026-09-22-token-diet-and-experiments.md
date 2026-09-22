# Токенная диета пайплайна + реестр самопроверяемых гипотез — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Срезать −13…−18% токенов прогона mvp:build узкими ролями механики пайплайна и потолками ходов, и дать плагину реестр гипотез, который сам добирает недостающие доказательства (CAP=30) на живых прогонах.

**Architecture:** Три новых шаблона ролей механики (`mvp-reviewer`/`mvp-validator`/`mvp-relay`, без `_common.md`) диспатчатся из `workflow.mjs` с `maxTurns` во фронтматтере; ветки «обрыв ≠ отказ» отличают потолок от провала по состоянию дерева/наличию текста. Реестр `docs/experiments/registry.json` (правится только руками) + `lib/experiments.sh` + append-only `.mvp/experiments/results.jsonl` в проекте; `mvp:retro` сверяет гипотезы с журналами; greedy-рукав CAP=30 работает на чётном срезе задач внутри обычного прогона.

**Tech Stack:** bash + python3 (через env, никогда интерполяцией), Node (workflow.mjs, plan-io.mjs), bash-тесты `tests/lib/*.test.sh`.

**Spec:** `docs/specs/2026-09-22-token-diet-and-experiments-design.md`. Числа и вердикты — `docs/observations/2026-09-22-token-economics.md`.

## Global Constraints

- Последняя строка stdout каждого скрипта — `{"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}`; `ok:false` всегда exit 1.
- Значения в python — ТОЛЬКО через env-переменные, никогда интерполяцией в текст программы.
- Атомарная запись JSON: `tempfile.NamedTemporaryFile(dir=<та же директория>)` + `os.replace`.
- `git add` — только явные пути, никогда `-A`/`.`.
- Бюджеты SKILL.md не поднимаются: retro ≤ 4096, bootstrap/build ≤ 13312 (`tests/lib/skill-size.test.sh`).
- `events.jsonl` и `results.jsonl` — append-only; поля только добавляются, никогда не переименовываются.
- **Закон недублирования:** ни один режим `experiments` не порождает дополнительный прогон, диспатч или задачу — greedy только меняет параметры уже исполняемых диспатчей.
- `REVIEW_SAMPLES=3` не трогается.
- Проверка workflow.mjs после каждой правки (из корня репо плагина, чистый выход = ок):
  `node -e "const src=require('fs').readFileSync('skills/build/workflow.mjs','utf8').replace(/^export const meta[\s\S]*?^}/m,''); new (Object.getPrototypeOf(async function(){}).constructor)('agent','parallel','pipeline','log','phase','args','budget','workflow', src)"`
- Тесты: `bash tests/run.sh` — зелёный до и после каждой задачи.
- Repo: `/Users/vadim/Documents/tools/claude/mvp-plugin`. Ветка: `token-diet-and-experiments`.

---

### Task 1: `scripts/experiments/tokcost.py` — учёт токенов с дедупом

**Files:**
- Create: `scripts/experiments/tokcost.py`
- Test: `tests/lib/tokcost.test.sh`

**Interfaces:**
- Produces: модуль с функциями `scan(path) -> (dict[model, [in,cw5,cw1,cr,out]], n_requests)` (дедуп по `(файл, requestId)`, максимум по полю) и `merge(dst, src)`. Импортируется h-скриптами Task 10 через `sys.path`.

- [ ] **Step 1: Написать failing test**

`tests/lib/tokcost.test.sh` (конвенции — как `tests/lib/state.test.sh`: `set -u`, `mktemp -d` + `trap`, `assert_eq`, exit 0 = pass):

```bash
#!/usr/bin/env bash
# Tests for scripts/experiments/tokcost.py — дедуп по requestId обязателен:
# наивная сумма завышает output в ~2.2x (см. observation 2026-09-22).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    fail=1
  fi
}

# Фикстура: один requestId написан трижды (стрим), второй — один раз.
cat > "$tmpdir/agent-a1.jsonl" <<'EOF'
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","requestId":"req_2","message":{"model":"claude-sonnet-5","usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":2000,"output_tokens":10}}}
{"type":"user","noise":true}
EOF

out="$(TOKCOST_DIR="$repo_root/scripts/experiments" TOKCOST_PATH="$tmpdir/agent-a1.jsonl" python3 -c '
import os, sys, json
sys.path.insert(0, os.environ["TOKCOST_DIR"])
from tokcost import scan
agg, n = scan(os.environ["TOKCOST_PATH"])
v = agg["claude-sonnet-5"]
print(json.dumps({"n": n, "out": v[4], "cr": v[3], "cw": v[1] + v[2], "base": v[0]}))
')"
# (1) два уникальных запроса, не четыре
assert_eq "уникальных запросов" "2" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n"])')"
# (2) output = max(1,50,200) + 10 = 210 — НЕ сумма 251+10
assert_eq "output с дедупом" "210" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["out"])')"
# (3) cache_read = 1000 + 2000, не 3000+2000
assert_eq "cache_read с дедупом" "3000" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cr"])')"
# (4) запись без cache_creation-объекта: cw = плоское поле, в 5m-колонку
assert_eq "cw" "100" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cw"])')"

exit $fail
```

- [ ] **Step 2: Прогнать — RED** (`bash tests/lib/tokcost.test.sh`; ждём FAIL: модуля нет)

- [ ] **Step 3: Написать модуль**

`scripts/experiments/tokcost.py`:

```python
"""Учёт токенов по журналам Claude Code с обязательным дедупом.

Журнал пишет одну строку запроса многократно (частичные ответы стрима) с тем
же requestId; наивная сумма завышает output в ~2.2x, cache_read в ~1.9x
(замерено 2026-09-22, см. docs/observations/2026-09-22-token-economics.md).
Правило: максимум каждого поля на пару (файл, requestId).

Поля счётчика: [base_input, cache_write_5m, cache_write_1h, cache_read, output].
"""
import json


def scan(path):
    """-> ({model: [in, cw5m, cw1h, cr, out]}, n_unique_requests)."""
    per = {}  # requestId -> [model, [5 counters]]
    with open(path, errors="replace") as fh:
        for line in fh:
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            m = d.get("message") or {}
            u = m.get("usage")
            if not isinstance(u, dict):
                continue
            rid = d.get("requestId") or d.get("uuid")
            cc = u.get("cache_creation") or {}
            cw5 = cc.get("ephemeral_5m_input_tokens")
            cw1 = cc.get("ephemeral_1h_input_tokens")
            if cw5 is None and cw1 is None:
                cw5, cw1 = u.get("cache_creation_input_tokens", 0) or 0, 0
            vals = [
                u.get("input_tokens", 0) or 0,
                cw5 or 0,
                cw1 or 0,
                u.get("cache_read_input_tokens", 0) or 0,
                u.get("output_tokens", 0) or 0,
            ]
            cur = per.get(rid)
            if cur is None:
                per[rid] = [m.get("model"), vals]
            else:
                cur[1] = [max(a, b) for a, b in zip(cur[1], vals)]
    agg = {}
    for model, vals in per.values():
        acc = agg.setdefault(model, [0] * 5)
        for i, v in enumerate(vals):
            acc[i] += v
    return agg, len(per)


def merge(dst, src):
    for model, vals in src.items():
        acc = dst.setdefault(model, [0] * 5)
        for i, v in enumerate(vals):
            acc[i] += v
```

- [ ] **Step 4: GREEN** (`bash tests/lib/tokcost.test.sh`, затем `bash tests/run.sh`)

- [ ] **Step 5: Commit**

```bash
git add scripts/experiments/tokcost.py tests/lib/tokcost.test.sh
git commit -m "feat: tokcost.py — учёт токенов по журналам с дедупом по requestId"
```

---

### Task 2: реестр гипотез — `registry.json` + `lib/experiments.sh`

**Files:**
- Create: `docs/experiments/registry.json`, `lib/experiments.sh`
- Test: `tests/lib/experiments.test.sh`

**Interfaces:**
- Consumes: `lib/state.sh get experiments` (ключа может не быть → режим greedy).
- Produces: verbs `list`, `check <run_label>`, `add --json '<hypothesis>'`. Контракт check-скрипта: bash, получает env `HYP_ID`, `RUN_LABEL`, `RESULTS_PATH`, `PLUGIN_ROOT`, `PROJECT_ROOT`; последняя строка stdout — `{"ok":bool,"reason":...,"hint":...,"data":{"value":<любой JSON>,"verdict":"confirmed"|"refuted"|null}}`. Результат пишет САМ experiments.sh (не check-скрипт) в `.mvp/experiments/results.jsonl`: `{"hypothesis","run_label","value","verdict","ts"}`.
- `runs_seen` гипотезы = число УНИКАЛЬНЫХ `run_label` в results.jsonl для её id — registry.json этим полем не обладает.

- [ ] **Step 1: Написать failing test**

`tests/lib/experiments.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for lib/experiments.sh — гигиена реестра enforced скриптом.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    fail=1
  fi
}
last_line() { tail -n 1; }
jget() { # <json> <py-expr over d>
  J="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["J"]); print(eval(os.environ["E"]))'
}

# Песочница-плагин: experiments.sh читает registry относительно себя,
# поэтому копируем lib + свой registry в фикстуру.
mkdir -p "$tmpdir/plug/lib" "$tmpdir/plug/docs/experiments" "$tmpdir/plug/scripts/experiments"
cp "$repo_root/lib/experiments.sh" "$tmpdir/plug/lib/"
cp "$repo_root/lib/state.sh" "$tmpdir/plug/lib/"
cat > "$tmpdir/plug/docs/experiments/registry.json" <<'EOF'
{ "version": 1, "max_open": 5, "hypotheses": [
  { "id": "T-pass", "title": "t", "status": "open", "mode_required": "passive",
    "check_script": "scripts/experiments/t-pass.sh",
    "threshold": "value >= 1", "ttl_runs": 2, "opened": "2026-09-22" },
  { "id": "T-greedy", "title": "t", "status": "needs-optin", "mode_required": "greedy",
    "check_script": "scripts/experiments/t-greedy.sh",
    "threshold": "value >= 1", "ttl_runs": 9, "opened": "2026-09-22" },
  { "id": "T-missing", "title": "t", "status": "open", "mode_required": "passive",
    "check_script": "scripts/experiments/no-such.sh",
    "threshold": "value >= 1", "ttl_runs": 9, "opened": "2026-09-22" }
] }
EOF
cat > "$tmpdir/plug/scripts/experiments/t-pass.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"reason":null,"hint":null,"data":{"value":42,"verdict":null}}'
EOF
cat > "$tmpdir/plug/scripts/experiments/t-greedy.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"reason":null,"hint":null,"data":{"value":1,"verdict":"confirmed"}}'
EOF
chmod +x "$tmpdir/plug/scripts/experiments/"*.sh

# Проект-фикстура
mkdir -p "$tmpdir/proj/.mvp"
cd "$tmpdir/proj"

# (1) off: check ничего не пишет и ok:true
echo '{"phase":"done","experiments":"off"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-1 | last_line)"
assert_eq "off: ok" "True" "$(jget "$out" 'd["ok"]')"
[ -f .mvp/experiments/results.jsonl ] && { echo "FAIL: off-режим записал results" >&2; fail=1; }

# (2) passive: passive-гипотеза прогнана, greedy — пропущена, missing — залогирована, не упала
echo '{"phase":"done","experiments":"passive"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-1 | last_line)"
assert_eq "passive: ok" "True" "$(jget "$out" 'd["ok"]')"
assert_eq "passive: T-pass записан" "1" "$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"
assert_eq "passive: T-greedy пропущен" "0" "$(grep -c '"T-greedy"' .mvp/experiments/results.jsonl)"
assert_eq "passive: missing-скрипт как skipped, не crash" "True" "$(jget "$out" '"script missing" in json.dumps(d["data"])')"

# (3) greedy: обе прогнаны; вердикт confirmed доехал до results
echo '{"phase":"done","experiments":"greedy"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-2 | last_line)"
assert_eq "greedy: T-greedy записан" "1" "$(grep -c '"T-greedy"' .mvp/experiments/results.jsonl)"
assert_eq "greedy: verdict" "1" "$(grep -c '"verdict": "confirmed"' .mvp/experiments/results.jsonl)"

# (4) отсутствующий ключ experiments = greedy (альфа-дефолт)
echo '{"phase":"done"}' > .mvp/state.json
out="$(bash "$tmpdir/plug/lib/experiments.sh" check run-3 | last_line)"
assert_eq "дефолт greedy" "2" "$(grep -c '"T-greedy"' .mvp/experiments/results.jsonl)"

# (5) list: runs_seen из results (T-pass видел run-1,2,3), ttl_runs=2 → expired-candidate
out="$(bash "$tmpdir/plug/lib/experiments.sh" list | last_line)"
assert_eq "list ok" "True" "$(jget "$out" 'd["ok"]')"
assert_eq "runs_seen из results" "3" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-pass"][0]["runs_seen"]')"
assert_eq "ttl исчерпан → expired-candidate" "True" "$(jget "$out" '[h for h in d["data"]["hypotheses"] if h["id"]=="T-pass"][0]["expired_candidate"]')"

# (6) expired-candidate больше не прогоняется
n_before="$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"
bash "$tmpdir/plug/lib/experiments.sh" check run-4 >/dev/null
assert_eq "expired не прогоняется" "$n_before" "$(grep -c '"T-pass"' .mvp/experiments/results.jsonl)"

# (7) add: без числа в threshold — отказ; с числом — входит; шестая открытая — отказ
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t","status":"open","mode_required":"passive","check_script":"scripts/experiments/x.sh","threshold":"без числа","ttl_runs":5,"opened":"2026-09-22"}' | last_line)" || true
assert_eq "add без числа в threshold" "False" "$(jget "$out" 'd["ok"]')"
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t","status":"open","mode_required":"passive","check_script":"scripts/experiments/x.sh","threshold":"value >= 3","ttl_runs":5,"opened":"2026-09-22"}' | last_line)"
assert_eq "add ok" "True" "$(jget "$out" 'd["ok"]')"
for i in 5 6 7; do
  bash "$tmpdir/plug/lib/experiments.sh" add --json "{\"id\":\"T-fill$i\",\"title\":\"t\",\"status\":\"open\",\"mode_required\":\"passive\",\"check_script\":\"scripts/experiments/x.sh\",\"threshold\":\"value >= $i\",\"ttl_runs\":5,\"opened\":\"2026-09-22\"}" >/dev/null 2>&1 || true
done
out="$(bash "$tmpdir/plug/lib/experiments.sh" list | last_line)"
n_open="$(jget "$out" 'len([h for h in d["data"]["hypotheses"] if h["status"] in ("open","needs-optin")])')"
[ "$n_open" -le 5 ] || { echo "FAIL: max_open=5 нарушен, открытых $n_open" >&2; fail=1; }
# (8) дубликат id — отказ
out="$(bash "$tmpdir/plug/lib/experiments.sh" add --json '{"id":"T-new","title":"t2","status":"open","mode_required":"passive","check_script":"s.sh","threshold":"value >= 1","ttl_runs":5,"opened":"2026-09-22"}' | last_line)" || true
assert_eq "дубликат id" "False" "$(jget "$out" 'd["ok"]')"

exit $fail
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Написать `lib/experiments.sh`**

```bash
#!/usr/bin/env bash
# lib/experiments.sh — реестр самопроверяемых гипотез (спека 2026-09-22 §7).
#
# Verbs:
#   list               — реестр + вычисленные runs_seen / expired_candidate
#   check <run_label>  — прогнать check-скрипты открытых гипотез, дописать
#                        .mvp/experiments/results.jsonl (append-only)
#   add --json '{...}' — валидация и вставка новой гипотезы в registry.json
#
# Registry: <plugin>/docs/experiments/registry.json — источник истины,
# правится ТОЛЬКО этим verbs'ом add либо руками-коммитом; check его не пишет.
# runs_seen НЕ хранится: выводится из results.jsonl (уникальные run_label).
# Режим: .mvp/state.json ключ "experiments" (off|passive|greedy),
# отсутствует → greedy (альфа). off → check не читает и не пишет ничего.
# Cwd — корень целевого проекта (как у всех lib-скриптов).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$here/.." && pwd)"
REGISTRY="$PLUGIN_ROOT/docs/experiments/registry.json"
RESULTS=".mvp/experiments/results.jsonl"
STATE=".mvp/state.json"

cmd="${1:-}"; shift || true

mode() {
  M_STATE="$STATE" python3 -c '
import json, os
try:
    s = json.load(open(os.environ["M_STATE"]))
except Exception:
    s = {}
m = s.get("experiments")
print(m if m in ("off", "passive", "greedy") else "greedy")
'
}

case "$cmd" in
  list)
    E_REG="$REGISTRY" E_RES="$RESULTS" python3 <<'PY'
import json, os
reg = json.load(open(os.environ["E_REG"]))
seen = {}
try:
    for line in open(os.environ["E_RES"]):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        seen.setdefault(r.get("hypothesis"), set()).add(r.get("run_label"))
except FileNotFoundError:
    pass
out = []
for h in reg.get("hypotheses", []):
    n = len(seen.get(h["id"], set()))
    out.append({**h, "runs_seen": n,
                "expired_candidate": h.get("status") in ("open", "needs-optin") and n >= h.get("ttl_runs", 10)})
print(json.dumps({"ok": True, "reason": None, "hint": None,
                  "data": {"max_open": reg.get("max_open", 5), "hypotheses": out}}))
PY
    ;;
  check)
    run_label="${1:-}"
    [ -n "$run_label" ] || { printf '%s\n' '{"ok":false,"reason":"missing run_label","hint":"usage: experiments.sh check <run_label>","data":null}'; exit 1; }
    m="$(mode)"
    if [ "$m" = "off" ]; then
      printf '%s\n' '{"ok":true,"reason":null,"hint":null,"data":{"mode":"off","checked":[]}}'
      exit 0
    fi
    # Список гипотез к прогону — через list (там же вычислен expired_candidate).
    listing="$(bash "$here/experiments.sh" list | tail -n 1)"
    summary="[]"
    mkdir -p .mvp/experiments
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      id="$(R="$row" python3 -c 'import json,os; print(json.loads(os.environ["R"])["id"])')"
      script_rel="$(R="$row" python3 -c 'import json,os; print(json.loads(os.environ["R"])["check_script"])')"
      script="$PLUGIN_ROOT/$script_rel"
      if [ ! -f "$script" ]; then
        summary="$(S="$summary" I="$id" python3 -c 'import json,os; s=json.loads(os.environ["S"]); s.append({"id":os.environ["I"],"note":"script missing"}); print(json.dumps(s))')"
        continue
      fi
      out_line="$(HYP_ID="$id" RUN_LABEL="$run_label" RESULTS_PATH="$RESULTS" PLUGIN_ROOT="$PLUGIN_ROOT" PROJECT_ROOT="$(pwd)" bash "$script" 2>/dev/null | tail -n 1)" || out_line=""
      appended="$(O="$out_line" I="$id" L="$run_label" RES="$RESULTS" python3 <<'PY'
import json, os, datetime
try:
    r = json.loads(os.environ["O"])
    ok = bool(r.get("ok")); data = r.get("data") or {}
except Exception:
    ok = False; data = {}
if not ok:
    print("skip"); raise SystemExit
rec = {"hypothesis": os.environ["I"], "run_label": os.environ["L"],
       "value": data.get("value"), "verdict": data.get("verdict"),
       "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")}
with open(os.environ["RES"], "a") as fh:
    fh.write(json.dumps(rec) + "\n")
print("ok")
PY
)"
      summary="$(S="$summary" I="$id" A="$appended" python3 -c 'import json,os; s=json.loads(os.environ["S"]); s.append({"id":os.environ["I"],"note":"recorded" if os.environ["A"]=="ok" else "check script returned not-ok, skipped"}); print(json.dumps(s))')"
    done <<EOF2
$(L="$listing" M="$m" python3 -c '
import json, os
d = json.loads(os.environ["L"])["data"]
for h in d["hypotheses"]:
    if h["status"] not in ("open", "needs-optin"): continue
    if h["expired_candidate"]: continue
    if h["mode_required"] == "greedy" and os.environ["M"] != "greedy": continue
    print(json.dumps(h))
')
EOF2
    S="$summary" M="$m" python3 -c 'import json,os; print(json.dumps({"ok":True,"reason":None,"hint":None,"data":{"mode":os.environ["M"],"checked":json.loads(os.environ["S"])}}))'
    ;;
  add)
    [ "${1:-}" = "--json" ] || { printf '%s\n' '{"ok":false,"reason":"usage: experiments.sh add --json <hypothesis-json>","hint":null,"data":null}'; exit 1; }
    H_JSON="${2:-}" E_REG="$REGISTRY" python3 <<'PY'
import json, os, re, sys, tempfile
try:
    h = json.loads(os.environ["H_JSON"])
except Exception as e:
    print(json.dumps({"ok": False, "reason": "hypothesis is not valid JSON: %s" % e, "hint": None, "data": None})); sys.exit(1)
required = ["id", "title", "status", "mode_required", "check_script", "threshold", "ttl_runs", "opened"]
missing = [k for k in required if k not in h]
if missing:
    print(json.dumps({"ok": False, "reason": "missing field(s): %s" % ",".join(missing), "hint": None, "data": None})); sys.exit(1)
if not re.search(r"\d", str(h["threshold"])):
    print(json.dumps({"ok": False, "reason": "threshold has no number — a hypothesis without a decidable threshold is a metrics dump, not an experiment", "hint": "state the exact numeric rule that confirms/refutes", "data": None})); sys.exit(1)
if h["status"] not in ("open", "needs-optin"):
    print(json.dumps({"ok": False, "reason": "new hypothesis must start open or needs-optin", "hint": None, "data": None})); sys.exit(1)
reg = json.load(open(os.environ["E_REG"]))
if any(x["id"] == h["id"] for x in reg["hypotheses"]):
    print(json.dumps({"ok": False, "reason": "duplicate id: %s" % h["id"], "hint": None, "data": None})); sys.exit(1)
n_open = sum(1 for x in reg["hypotheses"] if x["status"] in ("open", "needs-optin"))
if n_open >= reg.get("max_open", 5):
    print(json.dumps({"ok": False, "reason": "max_open reached (%d open)" % n_open, "hint": "close one hypothesis (move its verdict to an observation and delete the row) before adding another", "data": None})); sys.exit(1)
reg["hypotheses"].append(h)
d = os.path.dirname(os.environ["E_REG"])
with tempfile.NamedTemporaryFile(mode="w", dir=d, delete=False) as tmp:
    json.dump(reg, tmp, indent=1, ensure_ascii=False)
    tmp_path = tmp.name
os.replace(tmp_path, os.environ["E_REG"])
print(json.dumps({"ok": True, "reason": None, "hint": None, "data": {"id": h["id"], "open_now": n_open + 1}}))
PY
    ;;
  *)
    printf '%s\n' '{"ok":false,"reason":"unknown cmd","hint":"list|check <run_label>|add --json","data":null}'
    exit 1
    ;;
esac
```

- [ ] **Step 4: Написать стартовый `docs/experiments/registry.json`**

```json
{ "version": 1, "max_open": 5,
  "hypotheses": [
    { "id": "H1-cap-work-preservation",
      "title": "CAP=30 не теряет работу за швом",
      "status": "needs-optin", "mode_required": "greedy",
      "check_script": "scripts/experiments/h1-cap.sh",
      "threshold": "при >=8 задачах рукава суммарно: доля дошедших до finalize >= контроля, средние dispatches рукава <= контроль*1.53; оба условия -> confirmed, провал первого -> refuted",
      "ttl_runs": 10, "opened": "2026-09-22",
      "notes": "capped-копии ролей НЕ штампуются в plugin-lock: check показывает их в derived_unstamped (foreign) — это ожидаемо, гейт не блокирует" },
    { "id": "H2-tier12-savings-match",
      "title": "Экономия Tier 1+2 на живом прогоне сходится с реплеем",
      "status": "open", "mode_required": "passive",
      "check_script": "scripts/experiments/h2-tier12.sh",
      "threshold": "медианный первый префикс mvp-reviewer <= 16000 токенов И ни один ladder-диспатч не ушёл на generic workflow-subagent; оба -> confirmed",
      "ttl_runs": 6, "opened": "2026-09-22" },
    { "id": "H3-prefix-gap-alive",
      "title": "Разрыв префикса generic vs ролевой ещё жив (B-M1 не съеден харнессом)",
      "status": "open", "mode_required": "passive",
      "check_script": "scripts/experiments/h3-prefix-gap.sh",
      "threshold": "gap = медиана(generic ctx0) - медиана(ролевой ctx0); gap < 2000 два прогона подряд -> refuted (харнесс догнал, B-M1 избыточен)",
      "ttl_runs": 12, "opened": "2026-09-22" }
  ] }
```

- [ ] **Step 5: GREEN** (`bash tests/lib/experiments.test.sh`, затем `bash tests/run.sh`)

- [ ] **Step 6: Commit**

```bash
git add lib/experiments.sh docs/experiments/registry.json tests/lib/experiments.test.sh
git commit -m "feat: lib/experiments.sh + registry.json — реестр самопроверяемых гипотез с порогами, TTL и cap открытых"
```

---

### Task 3: шаг реестра в `mvp:retro` + handbook

**Files:**
- Modify: `skills/retro/SKILL.md` (сейчас 4032 байта, бюджет 4096 — НЕ поднимать)
- Create: `skills/retro/references/experiments-handbook.md`

**Interfaces:**
- Consumes: `lib/experiments.sh check <run_label>` из Task 2.

- [ ] **Step 1: Вставить новый шаг в SKILL.md**

После секции «## Шаг 4 — observation-файл» и ПЕРЕД «## Шаг 5 — что дальше руками» вставить (и переименовать старый Шаг 5 в Шаг 6):

```markdown
## Шаг 5 — реестр гипотез

```
${CLAUDE_PLUGIN_ROOT}/lib/experiments.sh check <stamp>
```

Сводку `checked` — в observation-файл. `list` покажет `expired_candidate` и терминальные статусы: их вердикты перенеси в observation ПЛАГИНА и удали строку из registry.json руками — порядок в [справочнике](references/experiments-handbook.md).
```

- [ ] **Step 2: Выкроить байты**

Бюджет: 4032 + ~370 нового текста > 4096, нужно срезать ~350. Резать в этом порядке, пока `bash tests/lib/skill-size.test.sh` не позеленеет; контент переезжает в experiments-handbook.md (Шаг 3-вырезки — в существующий retro-handbook.md):
1. Шаг 3: «дефекты вне границы агента, которых не ловит ни один гейт (цикл импорта ронял два деплой-юнита при зелёном CI); каждый незакрытый» → «дефекты, которых не ловит ни один гейт (почему — в справочнике); каждый незакрытый» (пример уходит в retro-handbook.md, если его там ещё нет).
2. Шаг 4: «Форма файла и что класть в каждую секцию — [references/retro-handbook.md](references/retro-handbook.md) (**Load when:** пишешь отчёт). Пиши через `Write`.» → «Форма файла — [справочник](references/retro-handbook.md) (**Load when:** пишешь отчёт). Пиши через `Write`.»
3. HARD-GATE: «Покажи: путь отчёта, сводку телеметрии, число кандидатов.» → «Покажи: путь отчёта, сводку телеметрии, число кандидатов, строку на каждую открытую гипотезу.» (это ДОБАВКА — обязательная, входит в бюджет).

- [ ] **Step 3: Написать `skills/retro/references/experiments-handbook.md`**

```markdown
# Реестр гипотез — порядок работы retro

**Load when:** Шаг 5 mvp:retro, либо оператор спросил про гипотезы/эксперименты.

## Что происходит на Шаге 5

`lib/experiments.sh check <stamp>` прогоняет check-скрипт каждой открытой
гипотезы (registry.json в репо плагина) и дописывает результат в
`.mvp/experiments/results.jsonl` проекта (append-only). Режим — ключ
`experiments` в `.mvp/state.json`: `off` (реестр игнорируется), `passive`
(только замеры), `greedy` (дефолт альфы: замеры + экспериментальные рукава
в mvp:build). **Закон: ни один режим не дублирует прогон/диспатч/задачу.**

## HARD-GATE строка на гипотезу

`<id>: <status>, runs_seen=<n>/<ttl>, последний value=<...>, verdict=<...>`
— бери из `experiments.sh list` + хвоста results.jsonl. Гипотеза с
`expired_candidate: true` — кандидат на закрытие «недоказуемо этим способом».

## Закрытие гипотезы (руками, в РЕПО плагина — не в кэше)

1. Вердикт + путь results.jsonl → в `docs/observations/` плагина (кладбище
   или «подтверждено»); для confirmed — какая правка плагина из этого следует.
2. Удали строку из `docs/experiments/registry.json` (коммит с обоснованием).
3. Пока строка не удалена, retro повторяет это напоминание каждый прогон —
   это не баг, это анти-мусорка.

## Новая гипотеза

`lib/experiments.sh add --json '{...}'` — обязателен threshold с числом
(решающее правило), иначе отказ; максимум 5 открытых; ttl_runs обязателен.
Каждой гипотезе — check-скрипт в `scripts/experiments/` (контракт env:
HYP_ID, RUN_LABEL, RESULTS_PATH, PLUGIN_ROOT, PROJECT_ROOT; последняя строка
stdout — {"ok","reason","hint","data":{"value","verdict"}}).
```

- [ ] **Step 4: Проверить** `bash tests/lib/skill-size.test.sh` и `bash tests/run.sh` — GREEN; `wc -c skills/retro/SKILL.md` ≤ 4096.

- [ ] **Step 5: Commit**

```bash
git add skills/retro/SKILL.md skills/retro/references/experiments-handbook.md
git commit -m "feat: mvp:retro Шаг 5 — сверка реестра гипотез с журналами прогона"
```

---

### Task 4: шаблоны mvp-ролей + `assemble-agent.sh` mvp-префикс

**Files:**
- Create: `skills/bootstrap/templates/mvp-reviewer.template.md`, `skills/bootstrap/templates/mvp-validator.template.md`, `skills/bootstrap/templates/mvp-relay.template.md`
- Modify: `skills/bootstrap/scripts/assemble-agent.sh`, `skills/bootstrap/SKILL.md` (13292/13312!)
- Test: `tests/lib/mvp-role-templates.test.sh`

**Interfaces:**
- Produces: собранные `.claude/agents/mvp-reviewer.md|mvp-validator.md|mvp-relay.md` — имена, которые Task 5 подставит в agentType. Правило assemble: роль с префиксом `mvp-` собирается БЕЗ `_common.md` и БЕЗ placeholder-подстановки (шаблон копируется как есть), штампуется в plugin-lock как обычная derived-роль.

- [ ] **Step 1: Failing test**

`tests/lib/mvp-role-templates.test.sh`:

```bash
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
assert any(e.get('role') == 'mvp-relay' for e in lock['derived']), 'mvp-relay не в lock'
" || { echo "FAIL: lock" >&2; fail=1; }

# (3) обычная роль по-прежнему С _common (регресс-контроль)
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" integration-specialist | tail -n 1)"
echo "$out" | grep -q '"ok": true' || { echo "FAIL: assemble integration-specialist: $out" >&2; fail=1; }
grep -q "Common Agent Principles" .claude/agents/integration-specialist.md || { echo "FAIL: обычная роль потеряла _common" >&2; fail=1; }

exit $fail
```

Примечание: если `assemble-agent.sh`/`plugin-lock.sh` требуют git-репо или других предусловий фикстуры — смотри как это делает `tests/lib/plugin-lock.test.sh` (`make_fake_project`) и повтори.

- [ ] **Step 2: RED**

- [ ] **Step 3: Шаблоны**

`mvp-reviewer.template.md`:

```markdown
---
name: mvp-reviewer
description: Review-poll agent of the mvp:build ladder — reads the review package and emits the reviewer contract. Assembled by mvp:bootstrap; dispatched by workflow.mjs.
tools: Read, Bash
maxTurns: 15
---

Ты — агент опроса ревью лестницы mvp:build. Твой полный контракт — в файле, который назовёт диспатч-промпт (`skills/build/agents/reviewer.md` или `re-review.md`): прочитай его ПЕРВЫМ и следуй дословно. Здесь только границы роли:

- Ревью-пакет уже содержит commit list, stat и полный diff — НЕ добывай их повторно через git; Bash — только для точечных чтений, которых нет в пакете.
- Ты не редактируешь файлы и не запускаешь пишущие команды; тестовые сюиты не перегоняешь — validate уже прогнал CI.
- Весь результат — финальное сообщение по контракту (≤15 строк). У тебя потолок ходов: если чувствуешь, что расследование затягивается, — выноси вердикт по тому, что проверил, и честно заполни CANNOT_VERIFY.
```

`mvp-validator.template.md`:

```markdown
---
name: mvp-validator
description: Validate-verdict agent of the mvp:build ladder — judges boundary/CI violations and answers by the validator contract. Assembled by mvp:bootstrap; dispatched by workflow.mjs.
tools: Read, Bash
maxTurns: 15
---

Ты — агент вердикта валидации лестницы mvp:build. Твой полный контракт — в файле, который назовёт диспатч-промпт (`skills/build/agents/validator.md`): прочитай его ПЕРВЫМ и следуй дословно. Границы роли:

- VIOLATIONS уже в промпте — не перезапускай validate-task.sh ради их повторного получения.
- Ты не редактируешь файлы проекта; PATCHES выражай строго по контракту.
- Весь результат — финальное сообщение по контракту. Потолок ходов есть: не тяни расследование — выноси вердикт по увиденному.
```

`mvp-relay.template.md`:

```markdown
---
name: mvp-relay
description: Command relay of the mvp pipeline — runs exactly one given command and returns its last stdout line via structured output. Assembled by mvp:bootstrap; dispatched by workflow.mjs.
tools: Bash
maxTurns: 3
---

Ты — релей команд пайплайна. Выполни РОВНО ту команду, что дана в промпте, один раз, и верни последнюю строку stdout по заданной схеме структурированного вывода. Ничего не исследуй, не читай файлы, не интерпретируй результат, не запускай другие команды.
```

- [ ] **Step 4: `assemble-agent.sh` — ветка mvp-префикса**

В месте, где скрипт склеивает `frontmatter + _common + --- + body` и делает placeholder-подстановку, добавить ветку: `case "$ROLE" in mvp-*)` — шаблон `mvp-<x>.template.md` копируется в `$OUT_DIR/<role>.md` БЕЗ вставки `_common.md` и БЕЗ подстановки placeholder'ов (склейка не нужна — файл цельный); всё остальное (JSON-контракт, вызов `plugin-lock.sh record "$ROLE" ""` после `mv`) — как у обычных ролей. Комментарий в коде: «mvp-роли — механика пайплайна, а не инженеры проекта: контракт границы задачи им не нужен, его отсутствие — и есть диета префикса (спека 2026-09-22 §4)».

- [ ] **Step 5: `skills/bootstrap/SKILL.md`** — в шаге сборки агентов (Шаг 4) добавить одно предложение: «Затем собери безусловные роли механики: `assemble-agent.sh mvp-reviewer`, `mvp-validator`, `mvp-relay` (без стека).» Бюджет 13312 при текущих 13292: компенсируй, сократив в том же шаге эквивалентный объём прозы (например, свёрнутый пример вывода). Проверка — `bash tests/lib/skill-size.test.sh`.

- [ ] **Step 6: GREEN** (`bash tests/lib/mvp-role-templates.test.sh`, `bash tests/run.sh` — существующие plugin-lock/gate тесты обязаны остаться зелёными: mvp-роли для них — обычные derived)

- [ ] **Step 7: Commit**

```bash
git add skills/bootstrap/templates/mvp-reviewer.template.md skills/bootstrap/templates/mvp-validator.template.md skills/bootstrap/templates/mvp-relay.template.md skills/bootstrap/scripts/assemble-agent.sh skills/bootstrap/SKILL.md tests/lib/mvp-role-templates.test.sh
git commit -m "feat: mvp-роли механики пайплайна — узкие tools + maxTurns, сборка без _common (Tier 1: B-M1)"
```

---

### Task 5: `workflow.mjs` — agentType в лестнице + «обрыв ≠ отказ» для ревью

**Files:**
- Modify: `skills/build/workflow.mjs`
- Test: `tests/lib/workflow-wiring.test.sh` (create)

**Interfaces:**
- Consumes: имена ролей из Task 4.
- Produces: все ladder-диспатчи несут agentType; опрос ревью с null-текстом = «воздержался», не BLOCKED.

- [ ] **Step 1: Failing test**

`tests/lib/workflow-wiring.test.sh` — grep-смоук по исходнику + sanity-parse (лестница не исполняется в тестах, но проводка и синтаксис проверяемы):

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
wf="$repo_root/skills/build/workflow.mjs"

need() { grep -qE "$1" "$wf" || { echo "FAIL: workflow.mjs: не найдено /$1/ — $2" >&2; fail=1; }; }

need "agentType: 'mvp-relay'" "релеи без узкой роли"
need "agentType: 'mvp-reviewer'" "опросы ревью без узкой роли"
need "agentType: 'mvp-validator'" "валидатор без узкой роли"
need "abstain" "нет ветки «обрыв ≠ отказ» (воздержавшийся опрос)"
# Закон: no-fallback релея не молчит — при падении узкой роли идёт retry без agentType
need "mvp-relay.*fallback|fallback.*mvp-relay" "нет generic-fallback у релея"
# Sanity-parse (та же команда, что в Global Constraints)
node -e "const src=require('fs').readFileSync('$wf','utf8').replace(/^export const meta[\s\S]*?^}/m,''); new (Object.getPrototypeOf(async function(){}).constructor)('agent','parallel','pipeline','log','phase','args','budget','workflow', src)" || { echo "FAIL: sanity-parse" >&2; fail=1; }

exit $fail
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Правки workflow.mjs** (якоря — точные строки текущего файла)

**(а) Релеи.** В `relayLine` и в `relay` объект `callOpts` получает `agentType: 'mvp-relay'`. Fallback обязателен (старый проект без sync не должен умереть): в `relayLine` — если `out` null/невалиден с agentType, ОДИН повтор без agentType перед throw, с `log('mvp-relay did not dispatch; relay fell back to generic — run mvp:sync and restart the session')`; в `relay` — внутри `attempt()` первый вызов с agentType, а существующий retryable-повтор — без agentType (тот же log).

**(б) Валидатор.** Строка 1116: `agentText(validatorPrompt(...), {model:'sonnet',...})` → `dispatchAgentText(validatorPrompt(...), {model:'sonnet', phase:'Validate', label:..., agentType:'mvp-validator'})` — dispatchAgentText уже даёт fallback + учёт в agentTypeFallbacks.

**(в) Опросы ревью.** В цикле polls (строка ~1248) вызов `agentText(reviewerPrompt(...), {model:'sonnet', phase:'Review', label})` получает `agentType: 'mvp-reviewer'` (БЕЗ dispatchAgentText — генерик-повтор опроса стёр бы экономию потолка ровно на длинных опросах). После получения `text`:

```js
    if (text == null) {
      // «Обрыв ≠ отказ» (спека §6): потолок ходов или мёртвая роль дают null
      // без финального сообщения. Такой опрос — ВОЗДЕРЖАВШИЙСЯ, не BLOCKED:
      // save-review уже сохранил пустую реплику как evidence, в агрегацию
      // вердиктов он не входит.
      polls.push({ label, text: null, abstain: true, cannotVerify: null, verdict: { kind: 'none' } });
      continue;
    }
```

(сохранение через save-review оставить ДО этой ветки — пустая реплика тоже evidence, как сейчас).

**(г) Агрегация по действительным опросам.** Сразу после цикла:

```js
  const abstained = polls.filter((p) => p.abstain);
  const live = polls.filter((p) => !p.abstain);
  if (live.length === 0) {
    return { parked: true, why: `all ${REVIEW_SAMPLES} review polls returned no text — either agentType "mvp-reviewer" is not registered `
      + '(run mvp:sync, restart the session) or every poll hit its turn cap. No review happened, so no verdict is possible.' };
  }
  if (abstained.length) {
    ctx.concerns.push(`${abstained.length} of ${REVIEW_SAMPLES} review polls returned no text (turn cap or dead agentType) and were counted as abstain`);
  }
```

Дальше по функции ЗАМЕНИТЬ основания на живые опросы: `blind`-фильтр и его порог — по `live` (`blind.length * 2 > live.length`), `unionFindings(live)`, `patchPolls`/`blockedPolls` — из `live`; строки сообщений с `of ${REVIEW_SAMPLES}` в этих ветках — на `of ${live.length}` там, где речь о доле опросов (тексты concern'ов с «N of 3» про исторические сравнения не трогать — только те, что вычисляются из текущего массива).

**(д) Re-review.** Строка ~1420: `agentText(reReviewPrompt(...))` → `dispatchAgentText(..., {model:'sonnet', phase:'Review', label:'re-review-...', agentType:'mvp-reviewer'})` — адъюдикатору fallback нужен (его null сейчас паркует готовую задачу).

**(е) Reviewer-retry** (строка ~1323) — как (в): `agentType: 'mvp-reviewer'`, null → оставить текущее поведение (retry-ветка и так терминальна).

- [ ] **Step 4: GREEN** (`bash tests/lib/workflow-wiring.test.sh`, `bash tests/run.sh`)

- [ ] **Step 5: Commit**

```bash
git add skills/build/workflow.mjs tests/lib/workflow-wiring.test.sh
git commit -m "feat: лестница диспатчит узкие mvp-роли; оборванный опрос ревью — воздержался, не BLOCKED (Tier 1+2)"
```

---

### Task 6: диета `_common.md`

**Files:**
- Modify: `skills/bootstrap/templates/_common.md` (11.2K)
- Test: `tests/lib/common-diet.test.sh` (create)

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
# Диета _common.md: прозу режем, контракт — нет (спека §5).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
f="$repo_root/skills/bootstrap/templates/_common.md"

size="$(wc -c <"$f" | tr -d ' ')"
[ "$size" -le 8192 ] || { echo "FAIL: _common.md = $size байт, диета требует <= 8192" >&2; fail=1; }

for heading in "## Что ты НЕ делаешь (общие границы)" "## Когда поднимать Stop&Ask" "## Что не исполнялось — обязательная секция отчёта" "## Формат отчёта об окончании (status-contract)"; do
  grep -qF "$heading" "$f" || { echo "FAIL: контрактная секция исчезла: $heading" >&2; fail=1; }
done
grep -qF "STATUS:" "$f" || { echo "FAIL: STATUS-контракт исчез" >&2; fail=1; }

exit $fail
```

- [ ] **Step 2: RED** (файл сейчас 11.2K)

- [ ] **Step 3: Резать.** Только секцию `## Принципы (применяются в строгом порядке)` (строки ~32–77): каждый принцип сжимается до правила в 1–2 строки, вся поясняющая проза («почему», исторические примеры) удаляется — порядок и номера принципов сохраняются. Секции `## Self-positioning` и `## Откуда берётся задача` — сжать до 2–3 строк каждая. Секции с 78-й строки до конца (границы, Готов когда, Stop&Ask, Defer&Continue, Что не исполнялось, Формат отчёта) — НЕ трогать ни байтом: это контракт, на котором держится ревью (риск ¹ из финального вердикта).

- [ ] **Step 4: GREEN**, затем пересобрать эталон: в песочнице `assemble-agent.sh integration-specialist` должен остаться `ok:true` (склейка не сломана).

- [ ] **Step 5: Commit**

```bash
git add skills/bootstrap/templates/_common.md tests/lib/common-diet.test.sh
git commit -m "feat: диета _common.md — правила остаются, проза уходит (Tier 1: B-M3, −3.5k префикса ролевых)"
```

---

### Task 7: `lib/handoff.sh` — реконструктор указателя

**Files:**
- Create: `lib/handoff.sh`
- Test: `tests/lib/handoff.test.sh`

**Interfaces:**
- Produces: `handoff.sh <task_id> <segment>` — из ГРЯЗНОГО дерева пишет `.mvp/handoff-<task_id>.md` и отвечает `{"ok":true,...,"data":{"path":"...","segment":N}}`; на чистом дереве — `ok:false, reason:"clean tree — not a cap break"` (это сигнал диспетчеру: обычный отказ, паркуй как раньше). Task 8 зовёт его релеем.

- [ ] **Step 1: Failing test**

`tests/lib/handoff.test.sh`:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
ok_of() { O="$1" python3 -c 'import json,os; print(json.loads(os.environ["O"])["ok"])'; }

cd "$tmpdir"; git init -q .; git commit -q --allow-empty -m init; mkdir -p .mvp

# (1) чистое дерево → ok:false «не обрыв»
out="$(bash "$repo_root/lib/handoff.sh" 007 2 | tail -n 1)" || true
assert_eq "clean tree" "False" "$(ok_of "$out")"
echo "$out" | grep -q "clean tree" || { echo "FAIL: причина не названа" >&2; fail=1; }

# (2) грязное дерево → файл-указатель со status, diff, сегментом
mkdir -p src && printf 'line1\nline2\n' > src/a.txt && git add src/a.txt && git commit -qm one
printf 'line1\nCHANGED\n' > src/a.txt && echo new > src/new.txt
out="$(bash "$repo_root/lib/handoff.sh" 007 2 | tail -n 1)"
assert_eq "dirty tree ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
assert_eq "путь" ".mvp/handoff-007.md" "$p"
grep -q "segment: 2" "$p" || { echo "FAIL: нет номера сегмента" >&2; fail=1; }
grep -q "src/a.txt" "$p" || { echo "FAIL: нет git status" >&2; fail=1; }
grep -q "CHANGED" "$p" || { echo "FAIL: нет диффа" >&2; fail=1; }
grep -q "new.txt" "$p" || { echo "FAIL: untracked не виден" >&2; fail=1; }

# (3) огромный дифф режется с маркером
python3 -c "print('x\n' * 20000, end='')" > src/big.txt
out="$(bash "$repo_root/lib/handoff.sh" 007 3 | tail -n 1)"
assert_eq "big ok" "True" "$(ok_of "$out")"
lines="$(wc -l < .mvp/handoff-007.md | tr -d ' ')"
[ "$lines" -le 4200 ] || { echo "FAIL: указатель $lines строк, cap 4000+обвязка" >&2; fail=1; }
grep -q "TRUNCATED" .mvp/handoff-007.md || { echo "FAIL: нет маркера обрезки" >&2; fail=1; }

exit $fail
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Написать `lib/handoff.sh`**

```bash
#!/usr/bin/env bash
# lib/handoff.sh <task_id> <segment> — реконструктор указателя для CAP-рукава
# (спека 2026-09-22 §9). Вызывается релеем из workflow.mjs, когда имплементер
# оборван потолком ходов: собирает из git-состояния структурированное
# изложение «что уже сделано», которое читает агент-продолжение. Финальный
# вердикт дискуссии: указатель этого класса — УСЛОВИЕ применимости E=7;
# без него продолжение перепроходит разведку (E≈11.5).
# Чистое дерево — это НЕ обрыв по потолку (обрыв всегда оставляет правки):
# ok:false, диспетчер паркует задачу обычным путём.
set -u
TASK="${1:-}"; SEG="${2:-}"
[ -n "$TASK" ] && [ -n "$SEG" ] || { printf '%s\n' '{"ok":false,"reason":"usage: handoff.sh <task_id> <segment>","hint":null,"data":null}'; exit 1; }
DIFF_CAP=4000

status="$(git status --porcelain 2>/dev/null)" || { printf '%s\n' '{"ok":false,"reason":"not a git repo","hint":null,"data":null}'; exit 1; }
if [ -z "$status" ]; then
  H_T="$TASK" python3 -c 'import json,os; print(json.dumps({"ok":False,"reason":"clean tree — not a cap break","hint":"a turn-capped implementer always leaves edits; treat this as an ordinary failure and park","data":{"task":os.environ["H_T"]}}))'
  exit 1
fi

mkdir -p .mvp
out=".mvp/handoff-$TASK.md"
{
  echo "# Handoff pointer — task $TASK, segment: $SEG"
  echo
  echo "Предыдущий агент этой задачи оборван потолком ходов. Ниже — что уже"
  echo "сделано в рабочем дереве (НЕ переделывай это заново):"
  echo
  echo '## git status --short'
  echo '```'
  git status --short
  echo '```'
  echo
  echo "## git diff (первые $DIFF_CAP строк)"
  echo '```diff'
  git diff | head -n "$DIFF_CAP"
  if [ "$(git diff | wc -l)" -gt "$DIFF_CAP" ]; then echo "[TRUNCATED at $DIFF_CAP lines — смотри полный diff командой git diff]"; fi
  echo '```'
  echo
  echo '## Untracked-файлы (созданы предыдущим сегментом, содержимое смотри сам)'
  echo '```'
  git ls-files --others --exclude-standard
  echo '```'
  echo
  echo "Отчёт предыдущего сегмента, если он успел его писать: .mvp/reports/task-$TASK.md"
} > "$out"

H_OUT="$out" H_SEG="$SEG" python3 -c 'import json,os; print(json.dumps({"ok":True,"reason":None,"hint":None,"data":{"path":os.environ["H_OUT"],"segment":int(os.environ["H_SEG"])}}))'
```

- [ ] **Step 4: GREEN** (`bash tests/lib/handoff.test.sh`, `bash tests/run.sh`)

- [ ] **Step 5: Commit**

```bash
git add lib/handoff.sh tests/lib/handoff.test.sh
git commit -m "feat: lib/handoff.sh — указатель из git-состояния для CAP-продолжений"
```

---

### Task 8: CAP-рукав в `workflow.mjs` + поля телеметрии

**Files:**
- Modify: `skills/build/workflow.mjs`, `lib/plan-io.mjs`
- Test: `tests/lib/plan-io-experiments.test.sh` (create), дополнение `tests/lib/workflow-wiring.test.sh`

**Interfaces:**
- Consumes: `lib/handoff.sh` (Task 7); capped-роли появятся в Task 9 — до этого `capped_role` всегда null и рукав мёртв (безопасный порядок).
- Produces: `plan-io.mjs next` payload + `experiments` (`"off"|"passive"|"greedy"`) и `capped_role` (`"<role>-capped"` если `.claude/agents/<role>-capped.md` существует, иначе null); `plan-io.mjs complete` флаги `--arm <cap30|control>` и `--segments <n>` → additive-поля события `task_complete`.

- [ ] **Step 1: Failing test для plan-io**

`tests/lib/plan-io-experiments.test.sh` — фикстуру плана строй так же, как ближайший существующий тест `next` в `tests/lib/plan-io.test.sh` (скопируй его сетап: git-репо, `.mvp/plan.json` с одной pending-задачей, state.json):

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
jfield() { O="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(eval(os.environ["E"]))'; }

# <сетап фикстуры: git init, commit, .mvp/plan.json с задачей id=001 role=backend-implementer
#  status=pending, .mvp/state.json {"phase":"build"} — скопировать из plan-io.test.sh>

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

# (3) capped-файл существует → имя роли в payload
mkdir -p .claude/agents && echo x > .claude/agents/backend-implementer-capped.md
out="$(node "$repo_root/lib/plan-io.mjs" next | tail -n 1)"
assert_eq "capped_role" "backend-implementer-capped" "$(jfield "$out" 'd["data"]["capped_role"]')"

# (4) complete с --arm/--segments → additive-поля события
node "$repo_root/lib/plan-io.mjs" complete 001 --tokens 5 --dispatches 7 --arm cap30 --segments 2 >/dev/null
ev="$(tail -n 1 .mvp/telemetry/events.jsonl)"
assert_eq "arm в событии" "cap30" "$(jfield "$ev" 'd["arm"]')"
assert_eq "segments в событии" "2" "$(jfield "$ev" 'd["segments"]')"
# (5) additive: complete БЕЗ --arm/--segments не пишет эти поля вовсе
#     (фикстура: вторая pending-задача id=002 в том же plan.json)
node "$repo_root/lib/plan-io.mjs" complete 002 --tokens 1 --dispatches 1 >/dev/null
ev="$(tail -n 1 .mvp/telemetry/events.jsonl)"
assert_eq "без флагов arm отсутствует" "False" "$(jfield "$ev" '"'"'"arm" in d'"'"')"
assert_eq "без флагов segments отсутствует" "False" "$(jfield "$ev" '"'"'"segments" in d'"'"')"

exit $fail
```

- [ ] **Step 2: RED**

- [ ] **Step 3: `lib/plan-io.mjs`**

В `cmdNext` (payload задачи): прочитать `.mvp/state.json` (уже читается для phase — если нет, добавить локальное чтение с try/catch), `experiments = s.experiments ∈ {off,passive,greedy} ? s.experiments : 'greedy'`; `cappedPath = '.claude/agents/' + role + '-capped.md'`; `capped_role = fs.existsSync(cappedPath) ? role + '-capped' : null`. Оба — в `data` рядом с `head_sha`.

В `cmdComplete`: `parseFlags` добавить `arm`, `segments`; событие:

```js
  if (flags.arm === 'cap30' || flags.arm === 'control') event.arm = flags.arm;
  const segs = flags.segments === undefined ? null : Number(flags.segments);
  if (Number.isFinite(segs)) event.segments = segs;
```

(комментарий: additive-поля, консумер — scripts/experiments/h1-cap.sh; события без них законны — прогоны passive/off).

- [ ] **Step 4: workflow.mjs — рукав**

**(а) Решение о рукаве** в `runOneTask`, сразу после чтения `adv.data`:

```js
  // CAP-рукав (спека §9): жив только в greedy, только при существующей
  // capped-роли, и только на чётном срезе исполнения — нечётные задачи
  // прогона остаются контролем. ЗАКОН: рукав меняет параметры УЖЕ
  // исполняемых диспатчей, никогда не добавляя ни прогона, ни задачи.
  const armEligible = adv.data.experiments === 'greedy' && !!adv.data.capped_role;
  const armActive = armEligible && (tasksDone % 2 === 0);
  const arm = armEligible ? (armActive ? 'cap30' : 'control') : null;
```

(`tasksDone` — счётчик главного цикла; передать его в `runOneTask` аргументом либо вычислить armActive в цикле и передать готовым — выбери меньший дифф.)

**(б) Диспатч имплементера.** При `armActive` — НЕ через dispatchAgentText (его generic-fallback перезапустил бы задачу целиком без контракта):

```js
  let implText;
  let segments = 1;
  if (armActive) {
    implText = await agentText(implPrompt, {
      model: initialModel, phase: 'Implement', label: `implementer-${id}`, agentType: adv.data.capped_role,
    });
    // Дискриминатор «обрыв ≠ отказ»: null без финального сообщения + грязное
    // дерево = потолок ходов; handoff.sh сам отличает (чистое дерево → ok:false
    // → обычный park). Цена промаха — выброс сегмента; допуск до 52% промахов
    // (final-verdict), ветке достаточно быть правой в двух случаях из трёх.
    const CAP_SEGMENTS = 4;
    while (implText == null && segments < CAP_SEGMENTS) {
      const ho = await relay(`bash "${lib}/handoff.sh" "${id}" ${segments + 1}`, {
        phase: 'Implement', label: `handoff-${id}-${segments + 1}`, retryable: false,
      });
      if (!ho.ok) break; // чистое дерево — не обрыв: вниз, к обычному park по null
      segments += 1;
      implText = await agentText(
        `${implPrompt}\n\nПеред началом прочитай ${ho.data.path} — предыдущий агент этой задачи оборван потолком ходов, там что уже сделано. Продолжай с этого места, не переделывай сделанное.`,
        { model: initialModel, phase: 'Implement', label: `implementer-${id}-seg${segments}`, agentType: adv.data.capped_role },
      );
    }
    if (implText == null) {
      return park(id, boundary, `implementer (cap arm) returned no text after ${segments} segment(s) — either the cap discriminator saw a clean tree (ordinary failure) or ${CAP_SEGMENTS} segments were exhausted`);
    }
  } else {
    implText = await dispatchAgentText(implPrompt, { model: initialModel, phase: 'Implement', label: `implementer-${id}`, agentType: role });
    if (implText == null) {
      return park(id, boundary, 'implementer dispatch failed: both agentType and general-purpose fallback returned no result');
    }
  }
```

Существующий халт `agentTypeFallbacks.has(role)` остаётся только в else-ветке (capped-путь fallback не использует).

**(в) Телеметрия.** `finalize(...)` получает два новых аргумента `arm, segments`; в команду `plan-io.mjs complete` добавляется ` --arm ${arm} --segments ${segments}` только когда `arm != null`. Вызов `finalize(id, boundary, tokensDelta, dispatches, ctx.concerns, 'Finalize')` → передать `arm, armActive ? segments : 1`.

**(г) workflow-wiring.test.sh** дополнить:

```bash
need "capped_role" "рукав не читает payload plan-io"
need "CAP_SEGMENTS" "нет лимита сегментов"
need "tasksDone % 2" "нет чётного среза (внутрипрогонный контроль)"
grep -c "dispatchCount" "$wf" >/dev/null # рукав не должен добавлять новых точек инкремента сверх agentText/relay
```

- [ ] **Step 5: GREEN** (`plan-io-experiments`, `workflow-wiring`, весь `tests/run.sh`, sanity-parse)

- [ ] **Step 6: Commit**

```bash
git add skills/build/workflow.mjs lib/plan-io.mjs tests/lib/plan-io-experiments.test.sh tests/lib/workflow-wiring.test.sh
git commit -m "feat: greedy-рукав CAP=30 — чётный срез, дискриминатор обрыва, handoff-продолжения, arm/segments в телеметрии"
```

---

### Task 9: capped-копии ролей в `assemble-agent.sh` + bootstrap

**Files:**
- Modify: `skills/bootstrap/scripts/assemble-agent.sh`, `skills/bootstrap/SKILL.md`
- Test: дополнение `tests/lib/mvp-role-templates.test.sh`

**Interfaces:**
- Produces: `assemble-agent.sh --capped <role>` — читает СОБРАННЫЙ `.claude/agents/<role>.md`, вставляет/заменяет `maxTurns: 30` во фронтматтере, пишет `.claude/agents/<role>-capped.md`. В plugin-lock НЕ штампуется (экспериментальный артефакт; `plugin-lock.sh check` покажет его в `derived_unstamped` как foreign — гейт не блокирует, это записано в notes гипотезы H1).

- [ ] **Step 1: Failing test** — дополнить `tests/lib/mvp-role-templates.test.sh`:

```bash
# (4) capped-копия: тот же файл + maxTurns: 30 во фронтматтере
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped integration-specialist | tail -n 1)"
echo "$out" | grep -q '"ok": true' || { echo "FAIL: --capped: $out" >&2; fail=1; }
[ -f .claude/agents/integration-specialist-capped.md ] || { echo "FAIL: capped-файл не создан" >&2; fail=1; }
[ "$(awk 'NR==1&&$0=="---"{i=1;next} i&&$0=="---"{exit} i&&index($0,"maxTurns:")==1{sub("maxTurns: *",""); print; exit}' .claude/agents/integration-specialist-capped.md)" = "30" ] || { echo "FAIL: maxTurns" >&2; fail=1; }
# name во фронтматтере должен стать <role>-capped — иначе харнесс зарегистрирует дубль имени
grep -q "name: integration-specialist-capped" .claude/agents/integration-specialist-capped.md || { echo "FAIL: name не переименован" >&2; fail=1; }
# тело — идентично исходному (diff только во фронтматтере)
# (5) --capped без собранного исходника → ok:false с hint про порядок сборки
rm -f .claude/agents/nope.md
out="$(bash "$repo_root/skills/bootstrap/scripts/assemble-agent.sh" --capped nope | tail -n 1)" || true
echo "$out" | grep -q '"ok": false' || { echo "FAIL: --capped без исходника должен падать" >&2; fail=1; }
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Реализация** в `assemble-agent.sh`: ранняя ветка `if [ "${1:-}" = "--capped" ]`, python через env (`CA_SRC`, `CA_DST`, `CA_ROLE`): прочитать исходник, в блоке фронтматтера заменить `name: <role>` → `name: <role>-capped`, заменить существующий `maxTurns: N` или вставить `maxTurns: 30` перед закрывающим `---`, атомарно записать. Никакого record. Комментарий: «эксперимент H1-cap-work-preservation; файл живёт, пока гипотеза открыта — закрытие гипотезы удаляет его руками (см. experiments-handbook)».

- [ ] **Step 4: `skills/bootstrap/SKILL.md`** — в том же шаге сборки одна фраза: «В режиме experiments=greedy (дефолт при отсутствии ключа) после сборки ролей плана сделай capped-копии имплементерских ролей: `assemble-agent.sh --capped <role>`.» Бюджет — компенсировать на месте, `skill-size.test.sh` зелёный.

- [ ] **Step 5: GREEN** (`bash tests/run.sh` — plugin-lock-тесты обязаны пережить незаштампованный capped-файл: он foreign, `check` его лишь перечисляет)

- [ ] **Step 6: Commit**

```bash
git add skills/bootstrap/scripts/assemble-agent.sh skills/bootstrap/SKILL.md tests/lib/mvp-role-templates.test.sh
git commit -m "feat: assemble-agent --capped — экспериментальные копии ролей с maxTurns:30 для H1"
```

---

### Task 10: check-скрипты гипотез H1/H2/H3

**Files:**
- Create: `scripts/experiments/h1-cap.sh`, `scripts/experiments/h2-tier12.sh`, `scripts/experiments/h3-prefix-gap.sh`
- Test: `tests/lib/h-scripts.test.sh`

**Interfaces:**
- Consumes: контракт check-скрипта из Task 2 (env `HYP_ID`, `RUN_LABEL`, `RESULTS_PATH`, `PLUGIN_ROOT`, `PROJECT_ROOT`); телеметрия с `arm`/`segments` из Task 8; `tokcost.py` из Task 1. Для H2/H3 дополнительно env `JOURNALS_DIR` (каталог `subagents/` сессии прогона; retro узнаёт его из транскрипта — Шаг 3) — отсутствует → `ok:true, value:null, verdict:null` с note «журналы недоступны» (не ошибка: passive-запуск без журналов легален).

- [ ] **Step 1: Failing test**

`tests/lib/h-scripts.test.sh` — фикстуры: `.mvp/telemetry/events.jsonl` с задачами `arm:cap30|control` и `.mvp/plan.json` со статусами; синтетический журнал для h3 (та же форма строк, что в tokcost-тесте, плюс `agent-*.meta.json` с `agentType`). Проверить:

```bash
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
jd() { O="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(eval(os.environ["E"]))'; }
run_h() { # <script> — общий запуск с контрактным env
  HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/$1" | tail -n 1
}

cd "$tmpdir"; mkdir -p .mvp/telemetry .mvp/experiments

# --- H1: мало данных → verdict null; рукав не хуже контроля при n>=8 → confirmed
for i in 1 2 3; do echo "{\"event\":\"task_complete\",\"task\":\"00$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":1,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 мало данных: ok" "True" "$(jd "$out" 'd["ok"]')"
assert_eq "h1 мало данных: verdict null" "None" "$(jd "$out" 'd["data"]["verdict"]')"
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"a$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":1,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"c$i\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 confirmed" "confirmed" "$(jd "$out" 'd["data"]["verdict"]')"
# рукав с dispatches хуже порога → refuted не выносится (условие 2 — refuted только по потере задач),
# но confirmed невозможен:
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"a$i\",\"delta_tokens\":10,\"dispatches\":20,\"arm\":\"cap30\",\"segments\":3,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"c$i\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 дорогой рукав: не confirmed" "None" "$(jd "$out" 'd["data"]["verdict"]')"

# --- H2/H3: без JOURNALS_DIR — ok:true, verdict null, note
out="$(run_h h2-tier12.sh)"
assert_eq "h2 без журналов ok" "True" "$(jd "$out" 'd["ok"]')"
assert_eq "h2 без журналов verdict" "None" "$(jd "$out" 'd["data"]["verdict"]')"

# --- H3 с синтетическим журналом: gap считается
mkdir -p j
cat > j/agent-a1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j/agent-a1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":24000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j/agent-a2.meta.json <<'EOF'
{"agentType":"mvp-relay"}
EOF
cat > j/agent-a2.jsonl <<'EOF'
{"type":"assistant","requestId":"r2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":9000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 gap" "15000" "$(jd "$out" 'd["data"]["value"]["gap"]')"

exit $fail
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Скрипты.** Общая форма: bash-обёртка, вся логика в `python3 <<'PY'` с env; последняя строка — JSON-контракт.

`h1-cap.sh` — из `.mvp/telemetry/events.jsonl`: события `task_complete` с полем `arm`; `n_arm`, `n_control`; `mean_disp_arm`, `mean_disp_control`; done-доля обеих групп из `.mvp/plan.json` (задача есть в events = дошла до finalize; parked-задачи в events не попадают — done-доля рукава = n событий рукава / n задач рукава в плане… плану поле arm неизвестно, поэтому оперируй консервативно: доля рукава со `segments >= 2` и сам факт наличия событий; решающее правило по threshold реестра: `verdict = confirmed` если `n_arm >= 8` и `mean_disp_arm <= 1.53 * mean_disp_control` и `n_control >= 1`; `refuted` если `n_arm >= 8` и `mean_disp_arm > 2.5 * mean_disp_control` (рукав явно разрушителен); иначе `null`. `value` = `{"n_arm","n_control","mean_disp_arm","mean_disp_control","mean_segments"}`.

`h2-tier12.sh` — без `JOURNALS_DIR` → `{"value":null,"verdict":null}` + note. С ним: `tokcost.scan` по `agent-*.jsonl`, для каждого прочитать соседний `.meta.json` → `agentType`; первый запрос файла = префикс (как в tokcost, но нужен именно ПЕРВЫЙ requestId — добавь в скрипт локальную функцию first_prefix(path): первый usage-объект файла, сумма input+cache_creation+cache_read). `value = {"median_reviewer_prefix": медиана по agentType=="mvp-reviewer", "generic_ladder_agents": счёт файлов с agentType=="workflow-subagent" и меткой label ревью — если label недоступен, просто счёт workflow-subagent}`; `verdict = confirmed` если медиана ≤ 16000 и generic-счёт == 0; `refuted` если медиана > 24000 (диета не сработала); иначе null.

`h3-prefix-gap.sh` — с `JOURNALS_DIR`: `gap = median(first_prefix у agentType=="workflow-subagent") − median(first_prefix у agentType, начинающегося с "mvp-")`; generic'ов нет → `value={"gap":null}`, verdict null (после Tier 1 generic в лестнице исчезает — гипотеза кормится SDD/Task-агентами сессий, где generic жив). `verdict=refuted` только если в `RESULTS_PATH` ПРЕДЫДУЩАЯ запись этой гипотезы имеет `value.gap < 2000` и текущий `gap < 2000` (два прогона подряд — читает свой же results.jsonl). Иначе null.

- [ ] **Step 4: GREEN** (`bash tests/lib/h-scripts.test.sh`, `bash tests/run.sh`)

- [ ] **Step 5: Commit**

```bash
git add scripts/experiments/h1-cap.sh scripts/experiments/h2-tier12.sh scripts/experiments/h3-prefix-gap.sh tests/lib/h-scripts.test.sh
git commit -m "feat: check-скрипты гипотез H1 (CAP), H2 (экономия Tier1+2), H3 (разрыв префикса)"
```

---

### Task 11: документация и сквозная сверка

**Files:**
- Modify: `README.md`, `skills/build/SKILL.md` (13034/13312), `docs/specs/2026-08-21-mvp-pipeline-v2-design.md`

- [ ] **Step 1: `skills/build/SKILL.md`** — в Шаг 2 (аргументы оператора) одно предложение: «Флаг `experiments` живёт в `.mvp/state.json` (`greedy`-дефолт | `passive` | `off`): greedy может вести CAP-рукав на чётном срезе задач — прогон и число диспатчей это не удваивает никогда (закон недублирования, спека 2026-09-22).» Бюджет: 278 байт свободно — влезает без трима; проверь `skill-size.test.sh`.

- [ ] **Step 2: `README.md`** — раздел про скиллы/механику дополнить тремя строками: mvp-роли механики (что это, зачем узкие), реестр гипотез (registry.json, retro Шаг 5), флаг experiments.

- [ ] **Step 3: Главная спека `2026-08-21-mvp-pipeline-v2-design.md`** — в перечень компонентов добавить ссылку на спеку 2026-09-22 (не дублировать содержимое).

- [ ] **Step 4: Сквозная сверка** (руками, из корня плагина):
  - `bash tests/run.sh` — весь набор зелёный;
  - sanity-parse workflow.mjs (команда из Global Constraints);
  - `bash lib/experiments.sh list` — три гипотезы, статусы по registry;
  - в песочнице-проекте: `assemble-agent.sh mvp-relay && assemble-agent.sh --capped mvp-relay` НЕ имеет смысла (relay не имплементер) — проверить, что порядок из SKILL bootstrap называет --capped только для ролей плана;
  - `wc -c` всех трёх правленых SKILL.md — в бюджетах.

- [ ] **Step 5: Commit**

```bash
git add README.md skills/build/SKILL.md docs/specs/2026-08-21-mvp-pipeline-v2-design.md
git commit -m "docs: experiments-флаг, mvp-роли и реестр гипотез в README/SKILL/спеке"
```

---

## Порядок и зависимости

1 (tokcost) → 2 (experiments.sh) → 3 (retro) — реестр раньше диеты (спека §13).
4 (шаблоны) → 5 (проводка) → 6 (диета _common) — Tier 1+2.
7 (handoff) → 8 (рукав) → 9 (capped-копии) — CAP; рукав до Task 9 мёртв по построению (capped_role=null), это безопасно.
10 (h-скрипты) — после 8 (нужны поля arm/segments). 11 — последним.

## Что план сознательно НЕ делает

- Не меряет экономию сам: это работа H2 на первом живом прогоне.
- Не включает CAP по умолчанию: судьба Tier 3 — вердикт H1 (confirmed → отдельный коммит: maxTurns в основные шаблоны, удаление рукава и capped-копий).
- Не трогает REVIEW_SAMPLES, plugin-lock-схему и `enum` плановых ролей.
- Не штампует capped-копии в lock: они foreign по дизайну (notes H1).

## После мержа (операторские шаги, вне плана)

1. В trellis (и других живых проектах): `mvp:sync` → новая сессия (агенты регистрируются на старте).
2. По желанию оператора: `autoCompactWindow: 150000` в settings.json — −29% корпуса, вне плагина.
3. Первый прогон mvp:build на новом проекте: retro Шаг 5 даст первые точки H2/H3; первый прогон с greedy и capped-ролями — первые точки H1.
