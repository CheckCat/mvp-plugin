import json,math,statistics,collections
A=json.load(open("d_wfagents.json"))
Z={(x["proj"],x["id"]):x for x in json.load(open("d_z.json"))}
impl={}
for x in A:
    if x["role"]=="prompt:implementer" and x["task"]:
        impl.setdefault((x["proj"],x["task"]),x)
rows=[]
for k,x in impl.items():
    z=Z.get(k)
    if not z: continue
    rows.append(dict(proj=k[0],id=k[1],req=x["n"],cost=x["i"]+x["cw"]+x["cr"]+x["o"],
        deps=z["deps"],files=z["files"],est=z["est"] or 0,cclass=z["cclass"],level=z["level"],
        tot=z["tot"],ltot=z["ltot"]))
print("имплементеров с планом:",len(rows))
def ols(X,y):
    n=len(y);k=len(X[0]);A_=[[1.0]+list(r) for r in X];p=k+1
    XtX=[[sum(A_[t][a]*A_[t][b] for t in range(n)) for b in range(p)] for a in range(p)]
    Xty=[sum(A_[t][a]*y[t] for t in range(n)) for a in range(p)]
    M=[XtX[a][:]+[Xty[a]] for a in range(p)]
    for c in range(p):
        piv=max(range(c,p),key=lambda r:abs(M[r][c])); M[c],M[piv]=M[piv],M[c]
        if abs(M[c][c])<1e-12: continue
        d=M[c][c]; M[c]=[v/d for v in M[c]]
        for r in range(p):
            if r!=c and M[r][c]: f=M[r][c]; M[r]=[a-f*b for a,b in zip(M[r],M[c])]
    beta=[M[a][p] for a in range(p)]
    yh=[sum(beta[a]*A_[t][a] for a in range(p)) for t in range(n)]
    my=statistics.mean(y); sst=sum((v-my)**2 for v in y); sse=sum((v-h)**2 for v,h in zip(y,yh))
    return beta,1-sse/sst
cc=sorted(set(r["cclass"] for r in rows))
for r in rows:
    for c in cc: r["cc_"+c]=1 if r["cclass"]==c else 0
    r["lreq"]=math.log(r["req"]); r["lest"]=math.log(max(r["est"],1))
y=[r["lreq"] for r in rows]
print("\n## Предсказуемость длины имплементера (log req) ТОЛЬКО из плана")
for nm,keys in [("deps",["deps"]),("files",["files"]),("deps+files",["deps","files"]),
                ("est",["lest"]),("deps+files+est",["deps","files","lest"]),
                ("deps+files+cclass",["deps","files"]+["cc_"+c for c in cc[1:]]),
                ("всё из плана",["deps","files","lest","level"]+["cc_"+c for c in cc[1:]])]:
    b,r2=ols([[r[k] for k in keys] for r in rows],y)
    print(f"  {nm:22s} R2={r2:.3f}")
print("\n## Предсказуемость ПОЛНОЙ стоимости задачи (log tot) только из плана")
y2=[r["ltot"] for r in rows]
for nm,keys in [("deps+files",["deps","files"]),("est",["lest"]),
                ("всё из плана",["deps","files","lest","level"]+["cc_"+c for c in cc[1:]])]:
    b,r2=ols([[r[k] for k in keys] for r in rows],y2)
    print(f"  {nm:22s} R2={r2:.3f}")
print("\n## Насколько план УГАДЫВАЕТ: estimate_tokens vs факт")
rs=[r for r in rows if r["est"]]
print(f"  n={len(rs)} корреляция log(est) ~ log(tot): ", end="")
def pear(a,b):
    ma,mb=statistics.mean(a),statistics.mean(b)
    sa=math.sqrt(sum((x-ma)**2 for x in a));sb=math.sqrt(sum((x-mb)**2 for x in b))
    return sum((x-ma)*(y-mb) for x,y in zip(a,b))/(sa*sb)
print(f"{pear([r['lest'] for r in rs],[r['ltot'] for r in rs]):+.3f}")
print("\n## Сколько задач имеют имплементера длиннее порога (кандидаты на дробление)")
for th in (40,50,60,80):
    s=[r for r in rows if r["req"]>=th]
    print(f"  req>={th}: {len(s):3d} задач ({len(s)/len(rows):.0%}), их доля в стоимости имплементеров {sum(r['cost'] for r in s)/sum(r['cost'] for r in rows):.0%}, ср files={statistics.mean([r['files'] for r in s]):.2f} ср deps={statistics.mean([r['deps'] for r in s]):.2f} ср est={statistics.mean([r['est'] for r in s]):,.0f}")
print(f"  ВСЕ: ср files={statistics.mean([r['files'] for r in rows]):.2f} ср deps={statistics.mean([r['deps'] for r in rows]):.2f} ср est={statistics.mean([r['est'] for r in rows]):,.0f}")
json.dump(rows,open("d_impl.json","w"),ensure_ascii=False)
