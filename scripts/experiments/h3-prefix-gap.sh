#!/usr/bin/env bash
# h3-prefix-gap.sh — check-скрипт гипотезы H3-prefix-gap-alive
# (docs/experiments/registry.json): разрыв префикса generic vs ролевой
# ещё жив (B-M1 не съеден харнессом).
#
# Контракт check-скрипта (lib/experiments.sh, спека §7): env HYP_ID,
# RUN_LABEL, RESULTS_PATH, PLUGIN_ROOT, PROJECT_ROOT, JOURNALS_DIR;
# последняя строка stdout — контрактный JSON. Запись в results.jsonl делает
# вызывающий lib/experiments.sh, не этот скрипт — но RESULTS_PATH этот
# скрипт ЧИТАЕТ (свою же предыдущую запись, для двухпрогонного refuted).
#
# JOURNALS_DIR отсутствует → passive-прогон без журналов, это легально:
# ok:true, value:{"gap":null}, verdict:null, note.
set -u
if [ -z "${JOURNALS_DIR:-}" ] || [ ! -d "${JOURNALS_DIR:-}" ]; then
  printf '%s\n' '{"ok":true,"reason":"журналы недоступны: JOURNALS_DIR не задан или каталог не существует — легально для passive-прогона без журналов","hint":"передайте JOURNALS_DIR=<каталог subagents/ сессии>, чтобы гипотеза получила данные","data":{"value":{"gap":null},"verdict":null}}'
  exit 0
fi

python3 <<'PY'
import glob, json, os, statistics

journals_dir = os.environ["JOURNALS_DIR"]
project_root = os.environ.get("PROJECT_ROOT", ".")
results_path_env = os.environ.get("RESULTS_PATH", ".mvp/experiments/results.jsonl")
results_path = (
    results_path_env
    if os.path.isabs(results_path_env)
    else os.path.join(project_root, results_path_env)
)
hyp_id = os.environ.get("HYP_ID", "")


def first_prefix(path):
    """Первый usage-объект файла: input + cache_creation(total) + cache_read.

    Та же экстракция cache_creation, что и в tokcost.scan, но без дедупа по
    requestId — нужен именно ПЕРВЫЙ запрос файла (нулевой контекст ролевого
    старта), не сумма по сессии.
    """
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
            cc = u.get("cache_creation") or {}
            cw5 = cc.get("ephemeral_5m_input_tokens")
            cw1 = cc.get("ephemeral_1h_input_tokens")
            if cw5 is None and cw1 is None:
                cw5, cw1 = u.get("cache_creation_input_tokens", 0) or 0, 0
            return (
                (u.get("input_tokens", 0) or 0)
                + (cw5 or 0)
                + (cw1 or 0)
                + (u.get("cache_read_input_tokens", 0) or 0)
            )
    return None


generic_prefixes, role_prefixes = [], []
for jsonl_path in sorted(glob.glob(os.path.join(journals_dir, "agent-*.jsonl"))):
    meta_path = jsonl_path[: -len(".jsonl")] + ".meta.json"
    try:
        meta = json.load(open(meta_path))
    except (FileNotFoundError, ValueError):
        meta = {}
    agent_type = meta.get("agentType") or ""
    p = first_prefix(jsonl_path)
    if p is None:
        continue
    if agent_type == "workflow-subagent":
        generic_prefixes.append(p)
    elif agent_type.startswith("mvp-"):
        role_prefixes.append(p)

reason = None
if not generic_prefixes:
    gap = None
    reason = (
        "generic'ов (agentType=workflow-subagent) в JOURNALS_DIR нет — после "
        "Tier 1 они исчезают из лестницы, гипотеза кормится только "
        "SDD/Task-агентами сессий, где generic ещё жив"
    )
elif not role_prefixes:
    gap = None
    reason = "нет журналов agentType, начинающегося с mvp- — сравнивать generic не с чем"
else:
    gap = statistics.median(generic_prefixes) - statistics.median(role_prefixes)

verdict = None
if gap is not None and gap < 2000:
    prev_gap = None
    try:
        with open(results_path, errors="replace") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("hypothesis") != hyp_id:
                    continue
                val = rec.get("value") or {}
                if isinstance(val, dict) and "gap" in val:
                    prev_gap = val.get("gap")  # последняя строка своей гипотезы — предыдущий прогон
    except FileNotFoundError:
        pass
    if prev_gap is not None and prev_gap < 2000:
        verdict = "refuted"

print(json.dumps({"ok": True, "reason": reason, "hint": None,
                  "data": {"value": {"gap": gap}, "verdict": verdict}}))
PY
