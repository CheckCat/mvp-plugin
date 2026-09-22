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
import json, os, sys
E_REG = os.environ["E_REG"]
try:
    reg = json.load(open(E_REG))
except FileNotFoundError:
    print(json.dumps({"ok": False, "reason": "registry not found: %s" % E_REG,
                      "hint": "create docs/experiments/registry.json (see plan \u00a77) or fix PLUGIN_ROOT", "data": None}))
    sys.exit(1)
except json.JSONDecodeError as e:
    print(json.dumps({"ok": False, "reason": "registry is not valid JSON: %s" % e,
                      "hint": "fix docs/experiments/registry.json by hand \u2014 the reader does not auto-repair it", "data": None}))
    sys.exit(1)
seen = {}
verdicts = {}
try:
    for line in open(os.environ["E_RES"]):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        hid = r.get("hypothesis")
        seen.setdefault(hid, set()).add(r.get("run_label"))
        v = r.get("verdict")
        if v:
            verdicts[hid] = v
except FileNotFoundError:
    pass
out = []
for h in reg.get("hypotheses", []):
    n = len(seen.get(h["id"], set()))
    verdict_seen = verdicts.get(h["id"])
    expired = (h.get("status") in ("open", "needs-optin")
               and n >= h.get("ttl_runs", 10)
               and verdict_seen is None)
    out.append({**h, "runs_seen": n, "verdict_seen": verdict_seen, "expired_candidate": expired})
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
    if ! L="$listing" python3 -c 'import json,os,sys; sys.exit(0 if json.loads(os.environ["L"]).get("ok") else 1)' 2>/dev/null; then
      printf '%s\n' "$listing"
      exit 1
    fi
    summary="[]"
    mkdir -p .mvp/experiments
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      # id + check_script — одним вызовом python на строку $row (было два
      # отдельных вызова на один и тот же JSON; финальное ревью). Разделитель
      # — таб: оба поля реестра простые строки-идентификаторы/пути, табов не
      # несут.
      IFS=$'\t' read -r id script_rel <<<"$(R="$row" python3 -c 'import json,os; h=json.loads(os.environ["R"]); print(h["id"] + "\t" + h["check_script"])')"
      script="$PLUGIN_ROOT/$script_rel"
      if [ ! -f "$script" ]; then
        summary="$(S="$summary" I="$id" python3 -c 'import json,os; s=json.loads(os.environ["S"]); s.append({"id":os.environ["I"],"note":"script missing"}); print(json.dumps(s))')"
        continue
      fi
      # Без pipe: раньше было `bash "$script" | tail -n1` внутри `out_line="$(...)"`
      # — и без pipefail код возврата брался от tail (правая команда пайпа,
      # почти никогда не падает), так что прежняя `|| out_line=""` была
      # мертва (финальное ревью). ${PIPESTATUS[0]} эту проблему НЕ чинит:
      # весь пайп исполняется внутри субшелла command substitution, а
      # PIPESTATUS субшелла в родительский не просачивается (было
      # перепроверено эмпирически — так и оставался 0 на упавшем скрипте).
      # Лекарство — убрать сам pipe: захватываем ПОЛНЫЙ stdout одной простой
      # командой (не пайпом), `$?` после неё — реальный exit code скрипта;
      # tail-n1 делаем ОТДЕЛЬНЫМ шагом над уже захваченной строкой.
      full_out="$(HYP_ID="$id" RUN_LABEL="$run_label" RESULTS_PATH="$RESULTS" PLUGIN_ROOT="$PLUGIN_ROOT" PROJECT_ROOT="$(pwd)" bash "$script" 2>/dev/null)"
      script_rc=$?
      out_line="$(printf '%s\n' "$full_out" | tail -n 1)"
      # Если скрипт упал, не доверяем его stdout, даже если тот выглядит как
      # валидный JSON (мог напечатать контрактную строку и упасть уже после)
      # — обнуляем, дальше пустая строка уже трактуется как ok:false.
      [ "$script_rc" -eq 0 ] || out_line=""
      appended="$(O="$out_line" I="$id" L="$run_label" RES="$RESULTS" python3 <<'PY'
import json, os, datetime
try:
    r = json.loads(os.environ["O"])
    ok = bool(r.get("ok")); data = r.get("data") or {}
except Exception:
    ok = False; data = {}
if not ok:
    print("skip"); raise SystemExit
# reason — аддитивное поле (финальное ревью, находка I1): без него запись
# «value:null, verdict:null» неотличима от данных; подряд идущие «журналы
# недоступны» — признак того, что retro не передаёт JOURNALS_DIR, и гипотеза
# голодает, а не проверяется. Старые записи без поля остаются читаемыми.
rec = {"hypothesis": os.environ["I"], "run_label": os.environ["L"],
       "value": data.get("value"), "verdict": data.get("verdict"),
       "reason": r.get("reason"),
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
try:
    reg_text = open(os.environ["E_REG"], encoding="utf-8").read()
except FileNotFoundError:
    print(json.dumps({"ok": False, "reason": "registry not found: %s" % os.environ["E_REG"],
                      "hint": "create docs/experiments/registry.json (see plan \u00a77) or fix PLUGIN_ROOT", "data": None})); sys.exit(1)
try:
    reg = json.loads(reg_text)
except json.JSONDecodeError as e:
    print(json.dumps({"ok": False, "reason": "registry is not valid JSON: %s" % e,
                      "hint": "fix docs/experiments/registry.json by hand \u2014 the reader does not auto-repair it", "data": None})); sys.exit(1)
if any(x["id"] == h["id"] for x in reg["hypotheses"]):
    print(json.dumps({"ok": False, "reason": "duplicate id: %s" % h["id"], "hint": None, "data": None})); sys.exit(1)
n_open = sum(1 for x in reg["hypotheses"] if x["status"] in ("open", "needs-optin"))
if n_open >= reg.get("max_open", 5):
    print(json.dumps({"ok": False, "reason": "max_open reached (%d open)" % n_open, "hint": "close one hypothesis (move its verdict to an observation and delete the row) before adding another", "data": None})); sys.exit(1)

# \u0422\u043e\u0447\u0435\u0447\u043d\u0430\u044f \u0432\u0441\u0442\u0430\u0432\u043a\u0430 \u0432 \u0421\u042b\u0420\u041e\u0419 \u0422\u0415\u041a\u0421\u0422 \u0444\u0430\u0439\u043b\u0430, \u0430 \u043d\u0435 json.dump(reg, ...) \u043f\u043e\u0432\u0435\u0440\u0445
# \u0440\u0430\u0441\u043f\u0430\u0440\u0441\u0435\u043d\u043d\u043e\u0433\u043e \u043e\u0431\u044a\u0435\u043a\u0442\u0430 (\u0444\u0438\u043d\u0430\u043b\u044c\u043d\u043e\u0435 \u0440\u0435\u0432\u044c\u044e, \u043d\u0430\u0445\u043e\u0434\u043a\u0430 5d): \u0440\u0435\u0435\u0441\u0442\u0440 \u044d\u0442\u043e\u0433\u043e \u0440\u0435\u043f\u043e
# \u0432\u0440\u0443\u0447\u043d\u0443\u044e \u043e\u0442\u0444\u043e\u0440\u043c\u0430\u0442\u0438\u0440\u043e\u0432\u0430\u043d \u043a\u043e\u043c\u043f\u0430\u043a\u0442\u043d\u043e (\u043d\u0435\u0441\u043a\u043e\u043b\u044c\u043a\u043e \u043f\u043e\u043b\u0435\u0439 \u043d\u0430 \u0441\u0442\u0440\u043e\u043a\u0443, \u0431\u0435\u0437 \u0435\u0434\u0438\u043d\u043e\u0433\u043e
# \u0443\u0440\u043e\u0432\u043d\u044f \u043e\u0442\u0441\u0442\u0443\u043f\u0430) \u2014 json.dump(indent=1) \u043f\u0435\u0440\u0435\u043f\u0438\u0441\u0430\u043b \u0431\u044b \u041a\u0410\u0416\u0414\u0423\u042e \u0431\u0443\u0434\u0443\u0449\u0443\u044e
# \u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u044e \u043a\u0430\u043a \u043f\u043e\u043b\u043d\u044b\u0439 \u0440\u0435\u0444\u043b\u043e\u0443 \u0432\u0441\u0435\u0433\u043e \u0444\u0430\u0439\u043b\u0430 (\u0448\u0443\u043c\u043d\u044b\u0439 \u0434\u0438\u0444\u0444 \u0432\u043c\u0435\u0441\u0442\u043e \u0442\u043e\u0447\u0435\u0447\u043d\u043e\u0433\u043e).
# \u041d\u0430\u0445\u043e\u0434\u0438\u043c \u043c\u0430\u0441\u0441\u0438\u0432 "hypotheses": [...] \u0432 \u0438\u0441\u0445\u043e\u0434\u043d\u043e\u043c \u0442\u0435\u043a\u0441\u0442\u0435 \u0447\u0435\u0440\u0435\u0437 raw_decode
# (\u0443\u0441\u0442\u043e\u0439\u0447\u0438\u0432\u043e \u043a \u043b\u044e\u0431\u043e\u043c\u0443 \u0441\u043e\u0434\u0435\u0440\u0436\u0438\u043c\u043e\u043c\u0443 \u0441\u0442\u0440\u043e\u043a \u0432\u043d\u0443\u0442\u0440\u0438, \u0432\u043a\u043b\u044e\u0447\u0430\u044f \u043a\u0430\u0432\u044b\u0447\u043a\u0438/\u0441\u043a\u043e\u0431\u043a\u0438) \u0438
# \u0432\u0441\u0442\u0430\u0432\u043b\u044f\u0435\u043c \u043d\u043e\u0432\u0443\u044e \u0437\u0430\u043f\u0438\u0441\u044c \u043f\u0435\u0440\u0435\u0434 \u0437\u0430\u043a\u0440\u044b\u0432\u0430\u044e\u0449\u0435\u0439 "]", \u043d\u0435 \u0442\u0440\u043e\u0433\u0430\u044f \u043d\u0438 \u0431\u0430\u0439\u0442\u0430 \u043f\u0440\u0435\u0436\u043d\u0435\u0433\u043e
# \u0441\u043e\u0434\u0435\u0440\u0436\u0438\u043c\u043e\u0433\u043e.
key_idx = reg_text.index('"hypotheses"')
colon_idx = reg_text.index(":", key_idx)
i = colon_idx + 1
while reg_text[i] in " \t\r\n":
    i += 1
start = i  # \u0438\u043d\u0434\u0435\u043a\u0441 "["
_, end = json.JSONDecoder().raw_decode(reg_text, start)
close_idx = end - 1  # \u0438\u043d\u0434\u0435\u043a\u0441 \u043f\u0430\u0440\u043d\u043e\u0439 "]"
inner = reg_text[start + 1:close_idx]
kept_len = len(inner.rstrip())
new_entry_text = json.dumps(h, ensure_ascii=False)
if inner[:kept_len].strip():
    insertion = ",\n    " + new_entry_text
else:
    insertion = "\n    " + new_entry_text + "\n  "
new_text = reg_text[:start + 1] + inner[:kept_len] + insertion + inner[kept_len:] + reg_text[close_idx:]

d = os.path.dirname(os.environ["E_REG"])
with tempfile.NamedTemporaryFile(mode="w", dir=d, delete=False, encoding="utf-8") as tmp:
    tmp.write(new_text)
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
