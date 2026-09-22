import json,statistics,math,collections
rows=json.load(open("d_taskcost.json"))
def pearson(a,b):
    n=len(a); ma,mb=statistics.mean(a),statistics.mean(b)
    sa=math.sqrt(sum((x-ma)**2 for x in a)); sb=math.sqrt(sum((x-mb)**2 for x in b))
    if sa==0 or sb==0: return float('nan')
    return sum((x-ma)*(y-mb) for x,y in zip(a,b))/(sa*sb)
def rank(v):
    o=sorted(range(len(v)),key=lambda i:v[i]); r=[0.0]*len(v); i=0
    while i<len(o):
        j=i
        while j+1<len(o) and v[o[j+1]]==v[o[i]]: j+=1
        for k in range(i,j+1): r[o[k]]=(i+j)/2+1
        i=j+1
    return r
def spear(a,b): return pearson(rank(a),rank(b))
def ols(X,y):
    # X: list of rows (without intercept). returns beta, R2
    n=len(y); k=len(X[0])
    A=[[1.0]+list(r) for r in X]; p=k+1
    XtX=[[sum(A[t][a]*A[t][b] for t in range(n)) for b in range(p)] for a in range(p)]
    Xty=[sum(A[t][a]*y[t] for t in range(n)) for a in range(p)]
    M=[XtX[a][:]+[Xty[a]] for a in range(p)]
    for c in range(p):
        piv=max(range(c,p),key=lambda r:abs(M[r][c])); M[c],M[piv]=M[piv],M[c]
        if abs(M[c][c])<1e-12: continue
        d=M[c][c]
        M[c]=[v/d for v in M[c]]
        for r in range(p):
            if r!=c and M[r][c]:
                f=M[r][c]; M[r]=[a-f*b for a,b in zip(M[r],M[c])]
    beta=[M[a][p] for a in range(p)]
    yh=[sum(beta[a]*A[t][a] for a in range(p)) for t in range(n)]
    my=statistics.mean(y); sst=sum((v-my)**2 for v in y); sse=sum((v-h)**2 for v,h in zip(y,yh))
    return beta, 1-sse/sst

print("## ПОЛНАЯ СТОИМОСТЬ (in+cw+cr+out всех workflow-субагентов задачи)")
print("| выборка | n | медиана tot | r(deps) | ρ(deps) | r(files) | ρ(files) | r(n_req) | r(n_ag) | r(out) |")
print("|---|---|---|---|---|---|---|---|---|---|")
def line(nm,rs):
    y=[x["tot"] for x in rs]
    g=lambda k:[x[k] for x in rs]
    print(f"| {nm} | {len(rs)} | {statistics.median(y):,.0f} | {pearson(g('deps'),y):+.2f} | {spear(g('deps'),y):+.2f} | {pearson(g('files'),y):+.2f} | {spear(g('files'),y):+.2f} | {pearson(g('n_req'),y):+.2f} | {pearson(g('n_ag'),y):+.2f} | {pearson(g('o'),y):+.2f} |")
line("всё",rows)
for p in ("vireo","glotok","trellis"): line(p,[x for x in rows if x["proj"]==p])

# z-normalized within project on log(tot)
zr=[]
for p in ("vireo","glotok","trellis"):
    rs=[x for x in rows if x["proj"]==p]
    ly=[math.log(x["tot"]) for x in rs]; m,s=statistics.mean(ly),statistics.pstdev(ly)
    for x,v in zip(rs,ly):
        y=dict(x); y["z"]=(v-m)/s; y["ltot"]=v; zr.append(y)
zz=[x["z"] for x in zr]
print("\n## Пул, z(log полной стоимости), внутрипроектная нормировка, n=%d"%len(zr))
for k in ("deps","files","level","n_req","n_ag","n_impl","n_rev","n_fix","est"):
    v=[x[k] or 0 for x in zr]
    print(f"  {k:8s}: r={pearson(v,zz):+.3f}  ρ={spear(v,zz):+.3f}")
dd=[x for x in zr if x["disp"] is not None]
print(f"  dispatch: r={pearson([x['disp'] for x in dd],[x['z'] for x in dd]):+.3f} ρ={spear([x['disp'] for x in dd],[x['z'] for x in dd]):+.3f} (n={len(dd)})")

print("\n## R2 регрессий на z(log tot), пул 124 задачи")
def show(nm,keys):
    X=[[x[k] or 0 for k in keys] for x in zr]
    b,r2=ols(X,zz); print(f"  {nm:38s} R2={r2:.3f}  beta={[round(v,3) for v in b]}")
show("deps",["deps"]); show("files",["files"]); show("deps+files",["deps","files"])
show("deps+files+level",["deps","files","level"])
# dummies for cclass
cc=sorted(set(x["cclass"] for x in zr))
for x in zr:
    for c in cc: x["cc_"+c]=1 if x["cclass"]==c else 0
show("cclass(3 dummy)",["cc_follow-pattern","cc_novel-design"])
show("deps+files+cclass",["deps","files","cc_follow-pattern","cc_novel-design"])
show("n_req (механика)",["n_req"])
show("n_ag (механика)",["n_ag"])
show("deps+files+n_req",["deps","files","n_req"])
print("\n## Структура расхода в среднем по задаче (полная)")
for nm,rs in [("все",rows)]+[(p,[x for x in rows if x["proj"]==p]) for p in ("vireo","glotok","trellis")]:
    T=sum(x["tot"] for x in rs)
    print(f"  {nm:8s} cr={sum(x['cr'] for x in rs)/T:.1%} cw={sum(x['cw'] for x in rs)/T:.1%} out={sum(x['o'] for x in rs)/T:.1%} in={sum(x['i'] for x in rs)/T:.2%}")
json.dump(zr,open("d_z.json","w"),ensure_ascii=False)
