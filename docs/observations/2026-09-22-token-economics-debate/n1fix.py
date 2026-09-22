import pickle
def run_fixed(real,T=None,keep=0.3):
    """simulated ctx = real ctx minus what WE removed, never below the stable prefix.
       a real harness compaction shrinks the pool of removable content instead of
       driving the counter negative (the bug in n1.py)."""
    c0=real[0]; removed=0.0
    tok=cw=cr=0.0; clears=0; prev=None
    for x in real:
        pool=max(0.0,x-c0)
        if removed>pool: removed=pool           # harness already took some of it
        sim=max(float(c0),x-removed)
        cleared_now=False
        if T is not None and sim>T:
            cut=(sim-c0)*(1.0-keep)
            removed+=cut; sim-=cut; clears+=1; cleared_now=True
        if prev is None:     w,r=sim,0.0
        elif cleared_now:    r=float(c0); w=sim-c0          # only the stable prefix survives
        else:                r=min(prev,sim); w=sim-r
        tok+=sim; cw+=w; cr+=r; prev=sim
    return dict(tokens=tok,cw=cw,cr=cr,units=1.25*cw+0.1*cr,clears=clears)
def agg(ctxs,**kw):
    A=dict(tokens=0,cw=0,cr=0,units=0,clears=0)
    for c in ctxs:
        r=run_fixed(c,**kw)
        for k in A: A[k]+=r[k]
    return A
