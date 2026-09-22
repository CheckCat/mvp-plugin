#!/usr/bin/env bash
# h2-tier12.sh — check-скрипт гипотезы H2-tier12-savings-match
# (docs/experiments/registry.json): экономия Tier 1+2 на живом прогоне
# сходится с реплеем.
#
# Контракт check-скрипта (lib/experiments.sh, спека §7): env HYP_ID,
# RUN_LABEL, RESULTS_PATH, PLUGIN_ROOT, PROJECT_ROOT, JOURNALS_DIR;
# последняя строка stdout — контрактный JSON. Запись в results.jsonl делает
# вызывающий lib/experiments.sh, не этот скрипт.
#
# JOURNALS_DIR — каталог subagents/ сессии прогона (retro узнаёт его из
# транскрипта). Его отсутствие — не ошибка: passive-прогон без журналов
# легален, отвечаем ok:true с value:null/verdict:null и note.
set -u
if [ -z "${JOURNALS_DIR:-}" ] || [ ! -d "${JOURNALS_DIR:-}" ]; then
  printf '%s\n' '{"ok":true,"reason":"журналы недоступны: JOURNALS_DIR не задан или каталог не существует — легально для passive-прогона без журналов","hint":"передайте JOURNALS_DIR=<каталог subagents/ сессии>, чтобы гипотеза получила данные","data":{"value":null,"verdict":null}}'
  exit 0
fi

python3 <<'PY'
import glob, json, os, statistics

journals_dir = os.environ["JOURNALS_DIR"]


def first_prefix(path):
    """Первый usage-объект файла: input + cache_creation(total) + cache_read.

    Та же экстракция cache_creation, что и в tokcost.scan (ephemeral-поля
    приоритетны, плоское cache_creation_input_tokens — fallback), но без
    дедупа по requestId: нужен именно ПЕРВЫЙ запрос файла, не сумма.
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


reviewer_prefixes = []
generic_count = 0
for jsonl_path in sorted(glob.glob(os.path.join(journals_dir, "agent-*.jsonl"))):
    meta_path = jsonl_path[: -len(".jsonl")] + ".meta.json"
    try:
        meta = json.load(open(meta_path))
    except (FileNotFoundError, ValueError):
        meta = {}
    agent_type = meta.get("agentType")
    # generic_ladder_agents: журналы не несут отдельной метки "это ревью-
    # диспатч", поэтому вместо задуманного label-фильтра считаем просто
    # все agentType=="workflow-subagent" файлы сессии (см. task-10-report.md).
    if agent_type == "workflow-subagent":
        generic_count += 1
    if agent_type == "mvp-reviewer":
        p = first_prefix(jsonl_path)
        if p is not None:
            reviewer_prefixes.append(p)

median_reviewer_prefix = statistics.median(reviewer_prefixes) if reviewer_prefixes else None
n_reviewer = len(reviewer_prefixes)

# Fix round 1, Finding 3: без минимума одного журнала достаточно для
# уверенного вердикта — медиана тогда просто пересказывает единственный
# файл. MIN_OBS=3 — минимум, при котором медиана перестаёт быть средним
# пары или значением одного файла и становится настоящим средним по рангу
# элементом, испытывающим влияние обоих соседей.
MIN_OBS = 3

verdict = None
reason = None
if median_reviewer_prefix is None:
    reason = "нет журналов agentType=mvp-reviewer в JOURNALS_DIR — медиану посчитать не из чего"
elif n_reviewer < MIN_OBS:
    reason = (
        "недостаточно наблюдений: agentType=mvp-reviewer журналов %d < %d — "
        "медиана по такой выборке пересказывает один-два файла, а не "
        "распределение, вердикт откладывается" % (n_reviewer, MIN_OBS)
    )
elif median_reviewer_prefix <= 16000 and generic_count == 0:
    verdict = "confirmed"
    reason = (
        "median_reviewer_prefix=%.0f <= 16000 и generic_ladder_agents=0 "
        "по %d mvp-reviewer журналам — диета Tier1+2 подтверждается"
        % (median_reviewer_prefix, n_reviewer)
    )
elif median_reviewer_prefix > 24000:
    verdict = "refuted"
    reason = (
        "median_reviewer_prefix=%.0f > 24000 по %d mvp-reviewer журналам — "
        "диета не сработала" % (median_reviewer_prefix, n_reviewer)
    )
else:
    reason = (
        "median_reviewer_prefix=%.0f, generic_ladder_agents=%d по %d "
        "mvp-reviewer журналам — не укладываются ни в confirmed (<=16000 и "
        "0 generic), ни в refuted (>24000)"
        % (median_reviewer_prefix, generic_count, n_reviewer)
    )

value = {"median_reviewer_prefix": median_reviewer_prefix, "generic_ladder_agents": generic_count}
print(json.dumps({"ok": True, "reason": reason, "hint": None,
                  "data": {"value": value, "verdict": verdict}}))
PY
