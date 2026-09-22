import pickle,statistics,math
rows=pickle.load(open('v3_rows.pkl','rb'))
W=[r for r in rows if r['pop']=='wf']
def at(r): return (r.get('meta') or {}).get('agentType')
def generic(r): return at(r) in ('workflow-subagent','general-purpose')
def role(r): return at(r) and not generic(r)
R=[r for r in W if role(r)]
REF=[r for r in W if 'wf_4d14cdc2' in r['path']]
REFR=[r for r in REF if role(r)]

# --- OLD model (verdict-3): seam resets to c0+H, then E FLAT turns at that level -----
def seg_old(ctx,CAP,H,E):
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

# --- NEW model: seam resets to c0+H, E warm-up turns during which context GROWS at the
#     agent's own per-turn rate; the accumulated mass is the seam cost (no separate H).
def seg_new(ctx,CAP,E,H=0.0,g=None,Rsur=0.0):
    n=len(ctx); c0=ctx[0]
    if n<=CAP: return ctx[:],0,0.0
    d=[ctx[i]-ctx[i-1] for i in range(1,n)]
    gg = g if g is not None else max(0.0,(ctx[-1]-ctx[0])/max(1,n-1))
    out=[];cur=c0;t=0;st=0;seams=0;sur=0.0
    Ei=int(E); Efrac=E-Ei
    while t<n:
        if st>=CAP:
            seams+=1; sur+=Rsur
            cur=c0+H; st=0
            k=Ei+(1 if Efrac>0 else 0)
            for j in range(k):
                w = 1.0 if j<Ei else Efrac
                out.append(cur*w); st+=1
                cur+=gg
                if st>=CAP: break
            continue
        out.append(cur);st+=1
        if t<n-1: cur+=d[t]
        t+=1
    return out,seams,sur

def tok(c): return sum(c)
def report(pop,label):
    base=sum(tok(r['ctx']) for r in pop)
    print('%s  base(role agents)=%.2fM  of which agents>CAP30: %d/%d'%(label,base/1e6,
        sum(1 for r in pop if r['n']>30),len(pop)))
    return base
