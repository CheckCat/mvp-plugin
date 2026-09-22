#!/usr/bin/env python3
"""Attacks on the canonical decomposition."""
import json, os, glob, collections, statistics
from v1_decomp import turns, wf_files, corpus_files


def attack(files, label):
    # A1: how much of category 3 ("grown, first time") is actually a RE-WRITE of
    #     content already seen (cache eviction), i.e. ctx_{i-1} - cr_i > 0 ?
    cat3 = 0
    rewrite = 0          # ctx_{i-1} - cr_i, clipped at >=0, for i>=1
    shrink = 0           # turns where ctx went DOWN (context editing / clearing already happening)
    cat2 = cat4 = 0
    n_evict_turns = 0
    for f in files:
        s = turns(f)
        if not s:
            continue
        ctx = [t["bi"] + t["cw5"] + t["cw1"] + t["cr"] for t in s]
        P = ctx[0]
        for i in range(1, len(s)):
            t = s[i]
            cw = t["cw5"] + t["cw1"] + t["bi"]
            cat3 += cw
            tick = min(t["cr"], P)
            cat2 += tick
            cat4 += t["cr"] - tick
            gap = ctx[i - 1] - t["cr"]
            if gap > 100:
                rewrite += min(gap, cw)
                n_evict_turns += 1
            if ctx[i] < ctx[i - 1] - 100:
                shrink += 1
    print("--- %s" % label)
    print("  cat3 (grown,first) = %.2fM ; of it re-write after eviction <= %.2fM (%.0f%% of cat3)"
          % (cat3 / 1e6, rewrite / 1e6, 100.0 * rewrite / max(cat3, 1)))
    print("  eviction turns: %d ; context-shrink turns: %d" % (n_evict_turns, shrink))
    print("  cat2 %.2fM cat4 %.2fM" % (cat2 / 1e6, cat4 / 1e6))
    return rewrite


def turn1_structure(files, label):
    """What IS the 'ticket'? split turn-1 context into cached-prefix vs fresh."""
    rows = []
    for f in files:
        s = turns(f)
        if not s:
            continue
        t = s[0]
        P = t["bi"] + t["cw5"] + t["cw1"] + t["cr"]
        rows.append((os.path.basename(f), P, t["cr"], t["cw5"] + t["cw1"], t["bi"], len(s)))
    rows.sort(key=lambda r: r[1])
    Ps = [r[1] for r in rows]
    crs = [r[2] for r in rows]
    print("--- turn-1 structure: %s  (n=%d)" % (label, len(rows)))
    print("  P (ticket) median %d  min %d  max %d  sum %.2fM" % (statistics.median(Ps), min(Ps), max(Ps), sum(Ps) / 1e6))
    print("  cr@turn1 >0 in %d/%d agents; sum %.2fM; median-of-nonzero %d"
          % (sum(1 for c in crs if c > 0), len(crs), sum(crs) / 1e6,
             statistics.median([c for c in crs if c > 0]) if any(crs) else 0))
    # cluster cr@turn1 values
    cnt = collections.Counter()
    for c in crs:
        cnt[round(c, -3)] += 1
    print("  cr@turn1 clusters (rounded to 1k, top 12):", cnt.most_common(12))
    return rows


if __name__ == "__main__":
    wf = wf_files()
    attack(wf, "wf_4d14cdc2")
    turn1_structure(wf, "wf_4d14cdc2")
    print()
    cf = corpus_files()
    attack(cf, "corpus")
