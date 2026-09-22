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
                "expired_candidate": h.get("status") in ("open", "needs-optin") and n > h.get("ttl_runs", 10)})
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
