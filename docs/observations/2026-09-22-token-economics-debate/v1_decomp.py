#!/usr/bin/env python3
"""Independent re-derivation of the canonical decomposition (auditor).
No import of C's code. Dedup by (file, requestId), max per field.
"""
import json, os, glob, sys, collections

HOME = os.path.expanduser("~")
PROJ = os.path.join(HOME, ".claude", "projects")
SLUGS = ["-Users-vadim-Documents-Pet-vireo",
         "-Users-vadim-Documents-Pet-glotok",
         "-Users-vadim-Documents-Pet-trellis"]


def turns(path):
    """Ordered per-request usage rows. Returns list of dicts."""
    order = []
    per = {}
    with open(path, errors="replace") as fh:
        for line in fh:
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            m = d.get("message") or {}
            u = m.get("usage")
            if not isinstance(u, dict):
                continue
            rid = d.get("requestId") or d.get("uuid")
            cc = u.get("cache_creation") or {}
            c5 = cc.get("ephemeral_5m_input_tokens")
            c1 = cc.get("ephemeral_1h_input_tokens")
            if c5 is None and c1 is None:
                c5, c1 = (u.get("cache_creation_input_tokens", 0) or 0), 0
            v = dict(bi=u.get("input_tokens", 0) or 0,
                     cw5=c5 or 0, cw1=c1 or 0,
                     cr=u.get("cache_read_input_tokens", 0) or 0,
                     out=u.get("output_tokens", 0) or 0,
                     model=m.get("model"), ts=d.get("timestamp"))
            if rid in per:
                p = per[rid]
                for k in ("bi", "cw5", "cw1", "cr", "out"):
                    p[k] = max(p[k], v[k])
            else:
                per[rid] = v
                order.append(rid)
    return [per[r] for r in order]


CATS = ["1_ticket_first_write", "1b_ticket_from_neighbor_cache",
        "2_ticket_reread_self", "3_grown_first_time",
        "4_grown_reread", "5_output"]


def decompose(files, variant="canon"):
    A = collections.Counter()
    nag = nturn = 0
    diag = collections.Counter()
    for f in files:
        s = turns(f)
        if not s:
            continue
        nag += 1
        nturn += len(s)
        ctx = [t["bi"] + t["cw5"] + t["cw1"] + t["cr"] for t in s]
        P = ctx[0]
        for i, t in enumerate(s):
            cw = t["cw5"] + t["cw1"]
            A["5_output"] += t["out"]
            if i == 0:
                A["1_ticket_first_write"] += cw + t["bi"]
                A["1b_ticket_from_neighbor_cache"] += t["cr"]
            else:
                tick = min(t["cr"], P)
                A["2_ticket_reread_self"] += tick
                A["4_grown_reread"] += t["cr"] - tick
                A["3_grown_first_time"] += cw + t["bi"]
                # diagnostics: is cache_read == previous context?
                prev = ctx[i - 1]
                d = t["cr"] - prev
                if abs(d) > 100:
                    diag["turns_cr_ne_prevctx"] += 1
                    diag["excess_write"] += max(0, (cw + t["bi"]) - (ctx[i] - prev))
                if t["cr"] < P:
                    diag["turns_cr_lt_P"] += 1
                    diag["tok_cr_lt_P"] += t["cr"]
    return A, nag, nturn, diag


def report(label, A, nag, nturn, diag):
    T = sum(A.values())
    print("=== %s: %d agents, %d turns, %.2fM tokens" % (label, nag, nturn, T / 1e6))
    for k in CATS:
        print("   %-34s %9.3fM  %6.2f%%" % (k, A[k] / 1e6, 100.0 * A[k] / T))
    print("   check 1+3 = %d (cache_write+base) ; 1b+2+4 = %d (cache_read) ; 5 = %d"
          % (A["1_ticket_first_write"] + A["3_grown_first_time"],
             A["1b_ticket_from_neighbor_cache"] + A["2_ticket_reread_self"] + A["4_grown_reread"],
             A["5_output"]))
    print("   diag:", dict(diag))
    print()
    return T


def wf_files():
    d = os.path.join(PROJ, "-Users-vadim-Documents-Pet-trellis",
                     "ffbe66c3-5d41-424f-b4eb-27417e32a7fc",
                     "subagents", "workflows", "wf_4d14cdc2-05c")
    return sorted(glob.glob(os.path.join(d, "agent-*.jsonl")))


def corpus_files():
    out = []
    for s in SLUGS:
        base = os.path.join(PROJ, s)
        out += sorted(glob.glob(os.path.join(base, "*.jsonl")))
        out += sorted(glob.glob(os.path.join(base, "*", "subagents", "agent-*.jsonl")))
        out += sorted(glob.glob(os.path.join(base, "*", "subagents", "workflows", "*", "agent-*.jsonl")))
    return out


if __name__ == "__main__":
    wf = wf_files()
    A, n, t, dg = decompose(wf)
    report("wf_4d14cdc2 (110 agents)", A, n, t, dg)
    cf = corpus_files()
    print("corpus entities:", len(cf))
    A2, n2, t2, dg2 = decompose(cf)
    report("corpus 3 projects", A2, n2, t2, dg2)
