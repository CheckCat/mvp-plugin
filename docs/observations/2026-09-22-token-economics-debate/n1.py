import sys,glob,os,pickle; sys.path.insert(0,'.')
from agents_c import *
# price units in "base-input-token equivalents": base 1.0, cw5m 1.25, cw1h 2.0, cr 0.1
def run(ctx,T=None,keep=0.3,rewrite_every_turn=False):
    """returns dict(tokens, cw, cr, units, clears)"""
    n=len(ctx); c0=ctx[0]
    d=[ctx[i]-ctx[i-1] for i in range(1,n)]
    c=c0; tok=0; cw=0; cr=0; clears=0
    prev=None            # cached prefix size entering this turn
    for k in range(n):
        if T is not None and c>T:
            kept=c0+keep*(c-c0)
            # after clear: stable prefix c0 stays cached, rest must be re-written
            c=kept; prev=c0; clears+=1
        if prev is None:              # turn 1: whole prompt is a write
            w=c; r=0
        elif rewrite_every_turn:
            w=c; r=0
        else:
            r=min(prev,c); w=c-r
        tok+=c; cw+=w; cr+=r
        prev=c
        if k<n-1: c+=d[k]
    return dict(tokens=tok,cw=cw,cr=cr,units=1.25*cw+0.1*cr,clears=clears)
def agg(ctxs,**kw):
    A=dict(tokens=0,cw=0,cr=0,units=0,clears=0)
    for c in ctxs:
        r=run(c,**kw)
        for k in A: A[k]+=r[k]
    return A
