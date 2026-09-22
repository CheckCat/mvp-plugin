import sys,pickle
sys.path.insert(0,'.')
rows=pickle.load(open('v3_rows.pkl','rb'))

def run2(ctx,T=None,keep=0.3):
    """corrected: simulated ctx = real ctx minus what OUR clears removed, never below the
    stable prefix c0. A real drop in the trace (the harness already compacted) reduces the
    removable pool instead of driving the simulated context negative."""
    c0=ctx[0]; removed=0.0
    tok=0.0; cw=0.0; cr=0.0; clears=0; prev=None
    for k,base in enumerate(ctx):
        pool=max(0.0, base-c0)
        if removed>pool: removed=pool          # harness already removed it; don't double-count
        c=base-removed
        if T is not None and c>T:
            newc=c0+keep*(c-c0)
            removed+=c-newc
            c=newc; clears+=1
            prev=c0                             # stable prefix stays cached
        if prev is None: w=c; r=0.0
        else:
            r=min(prev,c); w=c-r
        tok+=c; cw+=w; cr+=r; prev=c
    return dict(tokens=tok,cw=cw,cr=cr,units=1.25*cw+0.1*cr,clears=clears)

def agg(R,T):
    A=dict(tokens=0.0,cw=0.0,cr=0.0,units=0.0,clears=0)
    for r in R:
        x=run2(r['ctx'],T=T)
        for k in A: A[k]+=x[k]
    return A

print('CORRECTED simulator (no negative context, no double-count of the harness auto-compact)')
print('%-6s %-8s %10s %10s %10s %8s %8s %7s'%('pop','T','tokens','cw','units','dtok','dprice','clears'))
for pop in ('main','sub','wf','ALL'):
    R=[r for r in rows if pop=='ALL' or r['pop']==pop]
    base=agg(R,None)
    for T in (None,250000,200000,150000,100000):
        a=agg(R,T)
        dt=100*(a['tokens']-base['tokens'])/base['tokens']
        dp=100*(a['units']-base['units'])/base['units']
        print('%-6s %-8s %9.1fM %9.1fM %9.1fM %7.1f%% %7.1f%% %7d'%(pop,T or 'base',a['tokens']/1e6,a['cw']/1e6,a['units']/1e6,dt,dp,a['clears']))
    print()
