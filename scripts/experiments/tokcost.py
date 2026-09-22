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
