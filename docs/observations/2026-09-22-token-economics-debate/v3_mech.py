import pickle,collections,statistics,math
rows=pickle.load(open('v3_rows.pkl','rb'))
W=[r for r in rows if r['pop']=='wf']
def at(r): return (r.get('meta') or {}).get('agentType')
def md(r): return (r.get('meta') or {}).get('model')
def generic(r): return at(r) in ('workflow-subagent','general-purpose')
def role(r): return at(r) and not generic(r)
# prompt-agents (reviewer/validator/fix/re-review/reviewer-retry) = generic+sonnet/opus
def prompt_generic(r): return generic(r) and md(r) in ('sonnet','opus')
def relay(r): return generic(r) and md(r)=='haiku'

def cost_tokens(ctx): return sum(ctx)
def units(ctx):
    # turn1 = cache write (1.25), rest = cache read (0.1) on the shared prefix + write on the delta.
    # conservative: prefix read 0.1, growth written 1.25
    c0=ctx[0]; u=1.25*c0
    prev=c0
    for c in ctx[1:]:
        r=min(prev,c); w=max(0,c-r)
        u+=0.1*r+1.25*w; prev=c
    return u

def shrink_prefix(ctx,Pnew):
    dP=max(0.0, ctx[0]-Pnew)
    return [c-dP for c in ctx]

def cap(ctx,K):
    return ctx[:K] if len(ctx)>K else ctx[:]

def segment(ctx,CAP,H,E):
    """split into segments of <=CAP turns; each new segment restarts at c0+H and pays E re-warm
    turns at that level before resuming the original per-turn increments."""
    n=len(ctx); c0=ctx[0]
    if n<=CAP: return ctx[:]
    d=[ctx[i]-ctx[i-1] for i in range(1,n)]
    out=[]; cur=c0; t=0; seg_turns=0; first=True
    while t<n:
        if seg_turns>=CAP:
            cur=c0+H; seg_turns=0; first=False
            for _ in range(E):
                out.append(cur); seg_turns+=1
                if seg_turns>=CAP: break
            continue
        out.append(cur); seg_turns+=1
        if t<n-1: cur+=d[t]
        t+=1
    return out

def report(name,pop,transform,sel):
    base_t=sum(cost_tokens(r['ctx']) for r in pop)
    base_u=sum(units(r['ctx']) for r in pop)
    nt=0.0; nu=0.0
    for r in pop:
        c=transform(r) if sel(r) else r['ctx']
        nt+=cost_tokens(c); nu+=units(c)
    print('%-46s tok %+7.2fM = %+5.1f%%   price %+6.1f%%'%(name,(nt-base_t)/1e6,100*(nt-base_t)/base_t,100*(nu-base_u)/base_u))
    return base_t-nt, base_u-nu

for label,pop in (('=== REFERENCE RUN wf_4d14cdc2 ===',[r for r in W if 'wf_4d14cdc2' in r['path']]),
                  ('=== ALL wf RUNS (3 projects) ===',W)):
    print(label,' base %.2fM tokens, %d agents, %d turns'%(sum(r['alltok'] for r in pop)/1e6,len(pop),sum(r['n'] for r in pop)))
    report('B-M1 narrow agentType, P\'=16k (prompt-agents)',pop,lambda r:shrink_prefix(r['ctx'],16000),prompt_generic)
    report('B-M2 narrow agentType on relays, P\'=16k',pop,lambda r:shrink_prefix(r['ctx'],16000),relay)
    report('B-M1+M2 together',pop,lambda r:shrink_prefix(r['ctx'],16000),generic)
    report('B-M1+M2 conservative P\'=20k',pop,lambda r:shrink_prefix(r['ctx'],20000),generic)
    for K in (12,15,18):
        report('A-M1 reviewer/prompt turn cap K=%d (no resume)'%K,pop,lambda r,K=K:cap(r['ctx'],K),prompt_generic)
    for CAP,H,E in ((40,6000,2),(40,60000,13),(30,60000,13),(30,6000,2)):
        report('C TURN_CAP=%d on role agents (H=%dk,E=%d)'%(CAP,H//1000,E),pop,lambda r,CAP=CAP,H=H,E=E:segment(r['ctx'],CAP,H,E),role)
    # combined B-M1/M2 + A-M1(15)
    base_t=sum(cost_tokens(r['ctx']) for r in pop); base_u=sum(units(r['ctx']) for r in pop)
    nt=0.0;nu=0.0
    for r in pop:
        c=r['ctx']
        if generic(r): c=shrink_prefix(c,16000)
        if prompt_generic(r): c=cap(c,15)
        nt+=cost_tokens(c); nu+=units(c)
    print('%-46s tok %+7.2fM = %+5.1f%%   price %+6.1f%%'%('COMBINED B-M1+B-M2+A-M1(K=15)',(nt-base_t)/1e6,100*(nt-base_t)/base_t,100*(nu-base_u)/base_u))
    print()
