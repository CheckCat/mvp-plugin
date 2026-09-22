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
import glob, json, os, statistics, sys

journals_dir = os.environ["JOURNALS_DIR"]
project_root = os.environ.get("PROJECT_ROOT", ".")
results_path_env = os.environ.get("RESULTS_PATH", ".mvp/experiments/results.jsonl")
results_path = (
    results_path_env
    if os.path.isabs(results_path_env)
    else os.path.join(project_root, results_path_env)
)
hyp_id = os.environ.get("HYP_ID", "")

# first_prefix — общая реализация с h2-tier12.sh, вынесена в tokcost.py
# (финальное ревью, отложенная находка: две дословные копии уже разошлись
# докстрингами). Импорт через sys.path — тот же приём, что и в
# tests/lib/tokcost.test.sh для scan/merge.
sys.path.insert(0, os.path.join(os.environ["PLUGIN_ROOT"], "scripts", "experiments"))
from tokcost import first_prefix

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

# Fix round 1, Finding 3: MIN_OBS — та же логика, что и в h2-tier12.sh:
# 1-2 наблюдения делают медиану пересказом одного-двух файлов, не
# распределения. Ниже порога gap продолжает считаться и репортится (число
# как факт есть), но verdict не выносится.
MIN_OBS = 3
n_generic = len(generic_prefixes)
n_role = len(role_prefixes)

gap = None
reason = None
if not generic_prefixes:
    reason = (
        "generic'ов (agentType=workflow-subagent) в JOURNALS_DIR нет — после "
        "Tier 1 они исчезают из лестницы, гипотеза кормится только "
        "SDD/Task-агентами сессий, где generic ещё жив"
    )
elif not role_prefixes:
    reason = "нет журналов agentType, начинающегося с mvp- — сравнивать generic не с чем"
else:
    gap = statistics.median(generic_prefixes) - statistics.median(role_prefixes)

verdict = None
reliable = gap is not None and n_generic >= MIN_OBS and n_role >= MIN_OBS
if gap is None:
    pass  # reason уже объясняет отсутствующую группу
elif not reliable:
    reason = (
        "недостаточно наблюдений: generic=%d, mvp-=%d журналов, порог %d по "
        "каждой группе — медиана ненадёжна, вердикт откладывается (gap=%.0f "
        "посчитан как факт, но не решает)" % (n_generic, n_role, MIN_OBS, gap)
    )
elif gap < 2000:
    # Находка I4 (финальное ревью): «два прогона подряд» обязано означать
    # два СОСТОЯТЕЛЬНЫХ прогона — иначе шумовой замер (n_generic/n_role
    # ниже MIN_OBS в ту сессию) молча превращается во второй голос за
    # refuted. n_generic/n_role пишутся в value только начиная с этого
    # фикса; запись без них — старый формат, состоятельность неизвестна,
    # такая запись НЕ засчитывается как надёжный первый прогон (поля
    # журнала только добавляются, старые записи не переименовываются, но
    # и не домысливаются в свою пользу).
    prev_gap = None
    prev_reliable = False
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
                    # последняя строка своей гипотезы — предыдущий прогон
                    prev_gap = val.get("gap")
                    p_ng, p_nr = val.get("n_generic"), val.get("n_role")
                    prev_reliable = (
                        isinstance(p_ng, (int, float)) and isinstance(p_nr, (int, float))
                        and p_ng >= MIN_OBS and p_nr >= MIN_OBS
                    )
    except FileNotFoundError:
        pass
    if prev_gap is not None and prev_gap < 2000 and prev_reliable:
        verdict = "refuted"
        reason = (
            "gap=%.0f < 2000 и предыдущий СОСТОЯТЕЛЬНЫЙ прогон тоже gap=%.0f "
            "< 2000 — два надёжных подряд, харнесс догнал разрыв, B-M1 "
            "избыточен" % (gap, prev_gap)
        )
    elif prev_gap is not None and prev_gap < 2000 and not prev_reliable:
        reason = (
            "gap=%.0f < 2000, предыдущая запись тоже gap=%.0f < 2000, но её "
            "состоятельность неизвестна или недостаточна (нет n_generic/"
            "n_role >= %d в той записи) — не считается первым из двух "
            "надёжных прогонов подряд, нужен ещё один достоверный замер"
            % (gap, prev_gap, MIN_OBS)
        )
    else:
        reason = (
            "gap=%.0f < 2000 (текущий прогон состоятелен), но предыдущего "
            "состоятельного прогона этой гипотезы с gap<2000 нет (prev_gap=%s) "
            "— нужен ещё один такой прогон подряд" % (gap, prev_gap)
        )
else:
    reason = "gap=%.0f >= 2000 — разрыв ещё жив, харнесс его не съел" % gap

value = {"gap": gap}
if gap is not None:
    # n_generic/n_role — аддитивные поля (находка I4): состоятельность ЭТОЙ
    # записи для будущего «два прогона подряд». Пишутся всегда, когда gap
    # вообще посчитан (в т.ч. когда наблюдений мало и вердикта нет) — иначе
    # будущий прогон не отличит надёжный gap от шумового.
    value["n_generic"] = n_generic
    value["n_role"] = n_role

print(json.dumps({"ok": True, "reason": reason, "hint": None,
                  "data": {"value": value, "verdict": verdict}}))
PY
