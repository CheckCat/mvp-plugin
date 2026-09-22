"""Учёт токенов по журналам Claude Code с обязательным дедупом.

Журнал пишет одну строку запроса многократно (частичные ответы стрима) с тем
же requestId; наивная сумма завышает output в ~2.2x, cache_read в ~1.9x
(замерено 2026-09-22, см. docs/observations/2026-09-22-token-economics.md).
Правило: максимум каждого поля на пару (файл, requestId). Запись без ни
requestId, ни uuid (находка 4, финальное ревью) НЕ схлопывается с другими
такими же безымянными записями — синтетический уникальный ключ на каждую,
иначе max() по несвязанным записям занижает n_unique_requests и подменяет
сумму значением одной случайной строки.

Поля счётчика: [base_input, cache_write_5m, cache_write_1h, cache_read, output].
"""
import json


def scan(path):
    """-> ({model: [in, cw5m, cw1h, cr, out]}, n_unique_requests)."""
    per = {}  # requestId -> [model, [5 counters]]
    no_id_seq = 0  # находка 4 (финальное ревью), см. коммент у rid ниже
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
            if rid is None:
                # Ни requestId, ни uuid — без ключа дедупа нельзя понять, что
                # это один и тот же (стримящийся) запрос. Раньше все такие
                # строки схлопывались под ключ None в одну корзину: занижало
                # n_unique_requests и подменяло сумму max()'ом по НЕСВЯЗАННЫМ
                # записям. Синтетический уникальный ключ на каждую такую
                # строку — гарантированно НЕ группируется ни с одной другой
                # (даже с другой такой же безымянной строкой): без общего
                # requestId у нас нет оснований считать две строки одним
                # запросом, так что max() тут был бы такой же выдумкой, как
                # схлопывание всех в одну корзину.
                no_id_seq += 1
                rid = ("__no_id__", no_id_seq)
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


def first_prefix(path):
    """Первый usage-объект файла: input + cache_creation(total) + cache_read.

    Та же экстракция cache_creation, что и в scan() (ephemeral-поля
    приоритетны, плоское cache_creation_input_tokens — fallback), но БЕЗ
    дедупа по requestId: нужен именно ПЕРВЫЙ запрос файла (нулевой контекст
    ролевого/generic старта), не сумма/максимум по сессии.

    Общая реализация для scripts/experiments/h2-tier12.sh и
    scripts/experiments/h3-prefix-gap.sh (финальное ревью, отложенная
    находка: копии этой функции разошлись дословно, докстринги уже не
    совпадали) — оба импортируют её отсюда через sys.path, тем же приёмом,
    что tests/lib/tokcost.test.sh использует для scan/merge.
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
