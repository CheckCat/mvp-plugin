import sys,pickle
sys.path.insert(0,'.')
rows=pickle.load(open('v3_rows.pkl','rb'))
# 1. how often does the real trace DECREASE (already-compacted / cleared by harness)?
for pop in ('main','sub','wf'):
    R=[r for r in rows if r['pop']==pop]
    dec=0; turns=0; bigdrop=0
    for r in R:
        c=r['ctx']
        for i in range(1,len(c)):
            turns+=1
            if c[i]<c[i-1]:
                dec+=1
                if c[i-1]-c[i] > 50000: bigdrop+=1
    print(pop,'turns',turns,'decreasing',dec,'(%.1f%%)'%(100*dec/max(turns,1)),'drops>50k',bigdrop)

# 2. replay n1 at T=150k and count turns where simulated ctx goes negative
def n1trace(ctx,T,keep=0.3):
    n=len(ctx); c0=ctx[0]
    d=[ctx[i]-ctx[i-1] for i in range(1,n)]
    c=c0; neg=0; mn=0
    for k in range(n):
        if T is not None and c>T:
            c=c0+keep*(c-c0)
        if c<0: neg+=1; mn=min(mn,c)
        if k<n-1: c+=d[k]
    return neg,mn
for pop in ('main','sub','wf'):
    R=[r for r in rows if r['pop']==pop]
    tn=0; agents=0; worst=0
    for r in R:
        neg,mn=n1trace(r['ctx'],150000)
        if neg: agents+=1; tn+=neg; worst=min(worst,mn)
    print(pop,'agents with NEGATIVE simulated ctx:',agents,'turns:',tn,'min ctx %.0f'%worst)
