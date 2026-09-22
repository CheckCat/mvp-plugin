import pickle,math
GROW=2200   # measured context growth per warm-up turn (verdict-2)
def replay(ctx,K,E=7,H=0,count_warmup=True):
    """segment an agent's real context trajectory at cap K.
       each continuation: starts at C1+H, spends E warm-up turns growing GROW/turn,
       then replays the agent's own remaining deltas.
       count_warmup=True -> warm-up turns count against the cap (strict)."""
    n=len(ctx)
    if n<=K: return sum(ctx),0
    c0=ctx[0]; d=[ctx[i]-ctx[i-1] for i in range(1,n)]
    tot=0.0; idx=0; done=0; seg=0
    while done<n:
        work=min(K-(E if (seg>0 and count_warmup) else 0), n-done)
        if work<1: work=1
        c=c0+(H if seg>0 else 0)
        if seg>0:
            for _ in range(E):
                tot+=c; c+=GROW
        for j in range(work):
            tot+=c
            if j<work-1 or True:
                if idx<len(d): c+=d[idx]; idx+=1
        done+=work; seg+=1
    return tot,seg-1
def agg(ctxs,K,**kw):
    t=0; seams=0
    for c in ctxs:
        a,b=replay(c,K,**kw); t+=a; seams+=b
    return t,seams
