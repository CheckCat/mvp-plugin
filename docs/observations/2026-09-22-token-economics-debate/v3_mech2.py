import pickle,collections,statistics
rows=pickle.load(open('v3_rows.pkl','rb'))
W=[r for r in rows if r['pop']=='wf']
def at(r): return (r.get('meta') or {}).get('agentType')
def md(r): return (r.get('meta') or {}).get('model') or 'sonnet'
def generic(r): return at(r) in ('workflow-subagent','general-purpose')
def role(r): return at(r) and not generic(r)
def prompt_generic(r): return generic(r) and md(r) in ('sonnet','opus')
def relay(r): return generic(r) and md(r)=='haiku'
# $/MTok (opus-5 / sonnet-5 / haiku-4.5) from tokcost.PRICE
PR={'opus':(5.0,6.25,0.50),'sonnet':(2.0,2.50,0.20),'haiku':(1.0,1.25,0.10)}
def money(ctx,model):
    bi,cw,cr=PR.get(model,PR['sonnet'])
    c0=ctx[0]; m=cw*c0/1e6; prev=c0
    for c in ctx[1:]:
        r=min(prev,c); w=max(0,c-r); m+=(cr*r+cw*w)/1e6; prev=c
    return m
def toks(ctx): return sum(ctx)
def shrink(ctx,P): 
    d=max(0.0,ctx[0]-P); return [c-d for c in ctx]
def cap(ctx,K): return ctx[:K]
def segment(ctx,CAP,H,E):
    n=len(ctx); c0=ctx[0]
    if n<=CAP: return ctx[:]
    d=[ctx[i]-ctx[i-1] for i in range(1,n)]
    out=[];cur=c0;t=0;st=0
    while t<n:
        if st>=CAP:
            cur=c0+H;st=0
            for _ in range(E):
                out.append(cur);st+=1
                if st>=CAP:break
            continue
        out.append(cur);st+=1
        if t<n-1: cur+=d[t]
        t+=1
    return out
def run(name,pop,tf,sel):
    bt=sum(toks(r['ctx']) for r in pop); bm=sum(money(r['ctx'],md(r)) for r in pop)
    nt=0.0;nm=0.0
    for r in pop:
        c=tf(r) if sel(r) else r['ctx']
        nt+=toks(c); nm+=money(c,md(r))
    print('%-44s tok %+7.2fM %+5.1f%%   $ %+6.2f %+5.1f%%'%(name,(nt-bt)/1e6,100*(nt-bt)/bt,nm-bm,100*(nm-bm)/bm))
for lbl,pop in (('REF RUN wf_4d14cdc2',[r for r in W if 'wf_4d14cdc2' in r['path']]),('ALL wf RUNS',W)):
    bt=sum(toks(r['ctx']) for r in pop); bm=sum(money(r['ctx'],md(r)) for r in pop)
    print('=== %s: %.1fM tokens, $%.2f (input side only, model-aware) ==='%(lbl,bt/1e6,bm))
    run("B-M1 narrow agentType prompt-agents P'=16k",pop,lambda r:shrink(r['ctx'],16000),prompt_generic)
    run("B-M2 narrow agentType relays P'=16k",pop,lambda r:shrink(r['ctx'],16000),relay)
    run("B-M1+M2 P'=16k",pop,lambda r:shrink(r['ctx'],16000),generic)
    run("B-M1+M2 conservative P'=20k",pop,lambda r:shrink(r['ctx'],20000),generic)
    run("B-M3 -3.5k prefix on role agents",pop,lambda r:shrink(r['ctx'],r['ctx'][0]-3500),role)
    run("A-M1 cap K=15 prompt-agents",pop,lambda r:cap(r['ctx'],15),prompt_generic)
    run("C CAP=40 role, measured warmup E=13/H=60k",pop,lambda r:segment(r['ctx'],40,60000,13),role)
    run("C CAP=40 role, optimistic E=2/H=6k",pop,lambda r:segment(r['ctx'],40,6000,2),role)
    # combined realistic
    nt=0.0;nm=0.0
    for r in pop:
        c=r['ctx']
        if generic(r): c=shrink(c,16000)
        if role(r): c=shrink(c,3500+ (c[0]-3500) - 3500) if False else [x-3500 for x in c]
        if prompt_generic(r): c=cap(c,15)
        nt+=toks(c);nm+=money(c,md(r))
    print('%-44s tok %+7.2fM %+5.1f%%   $ %+6.2f %+5.1f%%'%('COMBINED B-M1+M2+M3+A-M1(15)',(nt-bt)/1e6,100*(nt-bt)/bt,nm-bm,100*(nm-bm)/bm))
    nt=0.0;nm=0.0
    for r in pop:
        c=r['ctx']
        if generic(r): c=shrink(c,16000)
        if role(r): c=[x-3500 for x in c]
        nt+=toks(c);nm+=money(c,md(r))
    print('%-44s tok %+7.2fM %+5.1f%%   $ %+6.2f %+5.1f%%'%('CONSERVATIVE B-M1+M2+M3 only (no cap)',(nt-bt)/1e6,100*(nt-bt)/bt,nm-bm,100*(nm-bm)/bm))
    print()
