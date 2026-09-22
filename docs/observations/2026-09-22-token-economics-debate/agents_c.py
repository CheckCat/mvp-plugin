import json, os, glob, sys, math
sys.path.insert(0,"/private/tmp/claude-501/-Users-vadim-Documents-Pet-trellis/ffbe66c3-5d41-424f-b4eb-27417e32a7fc/scratchpad")
import tokcost as T

def series(path):
    """ordered list of per-requestId merged usage, in file order of first appearance"""
    order=[]; per={}
    for line in open(path, errors="replace"):
        if '"usage"' not in line: continue
        try: d=json.loads(line)
        except: continue
        m=d.get("message") or {}
        u=m.get("usage")
        if not isinstance(u,dict): continue
        rid=d.get("requestId") or d.get("uuid")
        cc=u.get("cache_creation") or {}
        cw5=cc.get("ephemeral_5m_input_tokens"); cw1=cc.get("ephemeral_1h_input_tokens")
        if cw5 is None and cw1 is None:
            cw5,cw1=u.get("cache_creation_input_tokens",0) or 0,0
        vals=[u.get("input_tokens",0) or 0, cw5 or 0, cw1 or 0,
              u.get("cache_read_input_tokens",0) or 0, u.get("output_tokens",0) or 0]
        if rid not in per:
            per[rid]=[m.get("model"),vals]; order.append(rid)
        else:
            per[rid][1]=[max(a,b) for a,b in zip(per[rid][1],vals)]
    return [(rid,per[rid][0],per[rid][1]) for rid in order]

def agent_stats(path):
    s=series(path)
    if not s: return None
    n=len(s)
    tot=[sum(x[2][i] for x in s) for i in range(5)]
    # context of a turn = cache_read + cache_write(5m+1h) + base input
    ctx=[x[2][3]+x[2][1]+x[2][2]+x[2][0] for x in s]
    return dict(path=path,n=n,tot=tot,alltok=sum(tot),cr=tot[3],cw=tot[1]+tot[2],out=tot[4],
                ctx0=ctx[0],ctxlast=ctx[-1],ctxmax=max(ctx),ctx=ctx,model=s[0][1])

def meta(path):
    mp=path[:-6]+".meta.json"
    if os.path.exists(mp):
        try: return json.load(open(mp))
        except: return {}
    return {}
