import json,math,collections,statistics
A=json.load(open("d_wfagents.json")); Z=json.load(open("d_z.json"))
C=lambda x:x["i"]+x["cw"]+x["cr"]+x["o"]
K,B,W=6950,1.67,13
T=sum(C(x) for x in A)
zk={(z["proj"],z["id"]):z for z in Z}
impl={}
for x in A:
    if x["role"]=="prompt:implementer" and x["task"]: impl.setdefault((x["proj"],x["task"]),x)
rows=[(zk[k],x) for k,x in impl.items() if k in zk]
print("## 1. Может ли ПЛАН заранее указать, на какие задачи ставить CAP? (адресность)")
# предиктор из плана: log req ~ deps+files+log est+class  (R2=0.405, посчитано в раунде 1)
def ols(X,y):
    n=len(y);k=len(X[0]);M=[[1.0]+list(r) for r in X];p=k+1
    XtX=[[sum(M[t][a]*M[t][b] for t in range(n)) for b in range(p)] for a in range(p)]
    Xty=[sum(M[t][a]*y[t] for t in range(n)) for a in range(p)]
    G=[XtX[a][:]+[Xty[a]] for a in range(p)]
    for c in range(p):
        pv=max(range(c,p),key=lambda r:abs(G[r][c])); G[c],G[pv]=G[pv],G[c]
        if abs(G[c][c])<1e-12: continue
        d=G[c][c]; G[c]=[v/d for v in G[c]]
        for r in range(p):
            if r!=c and G[r][c]: f=G[r][c]; G[r]=[a-f*b for a,b in zip(G[r],G[c])]
    return [G[a][p] for a in range(p)]
cc=sorted(set(z["cclass"] for z,_ in rows))
feat=lambda z:[z["deps"],z["files"],math.log(max(z["est"] or 1,1)),1 if z["cclass"]==cc[1] else 0,1 if z["cclass"]==cc[2] else 0]
beta=ols([feat(z) for z,_ in rows],[math.log(x["n"]) for _,x in rows])
pred=[(math.exp(beta[0]+sum(b*f for b,f in zip(beta[1:],feat(z)))),z,x) for z,x in rows]
pred.sort(key=lambda t:-t[0])
S_IMPL=sum(C(x) for _,_,x in pred)
def cap_cost(r,cap):
    if r<=cap: return K*r**B
    S=max(1,math.ceil(max(r-W,0)/max(cap-W,1)))
    return S*K*(W+max(r-W,0)/S)**B
full=S_IMPL-sum(cap_cost(x["n"],40) for _,_,x in pred)
print(f"   CAP=40 на ВСЕ задачи: экономия {full:,.0f} = {full/T:.1%} корпуса")
for q in (0.25,0.33,0.5):
    k=int(len(pred)*q)
    sav=sum(C(x)-cap_cost(x["n"],40) for _,_,x in pred[:k])
    print(f"   CAP=40 только на верхнюю {q:.0%} задач по предсказанию ПЛАНА (n={k}): {sav:,.0f} = {sav/T:.1%} корпуса = {sav/full:.0%} полного эффекта")
print("\n## 2. Насколько план ошибается в оценке (estimate_tokens против факта output)")
r=[(z,x) for z,x in rows if z["est"] and z["delta"]]
rat=sorted(z["delta"]/z["est"] for z,_ in r)
print(f"   n={len(r)}: медиана факт/оценка = {statistics.median(rat):.2f}, p10 {rat[len(rat)//10]:.2f}, p90 {rat[9*len(rat)//10]:.2f}, max {rat[-1]:.1f}")
print(f"   доля задач, где факт превысил оценку более чем втрое: {sum(1 for v in rat if v>3)/len(rat):.0%}")
print("\n## 3. ПРОТИВ B: сравнение SDD (15.6M/задача) и пайплайна (9.1M/задача) при нормировке")
print("   B сравнивает 9 задач SDD с 8 задачами wf_4d14cdc2. Нормируем на то, что умеем мерить.")
wf=[(z,x) for z,x in rows if z["proj"]=="trellis" and x["wf"].startswith("wf_4d14cdc2")]
print(f"   wf_4d14cdc2: {len(wf)} задач, медиана ходов имплементера {statistics.median([x['n'] for _,x in wf]):.0f}, медиана files {statistics.median([z['files'] for z,_ in wf]):.0f}")
print("   SDD-агенты (subagents/agent-*.jsonl сессии ffbe66c3) по данным B: 31 агент, медиана 22 хода, топ-агент 189 ходов / 36.8M")
print("   Единая метрика, не зависящая от нарезки задач — цена ОДНОГО хода агента:")
print(f"   wf_4d14cdc2: 72.81M / 1073 хода = {72_812_227/1073:,.0f} ток/ход")
print(f"   SDD ffbe66c3: 140.84M / 1270 ходов = {140_841_249/1270:,.0f} ток/ход")
print(f"   отношение {140_841_249/1270/(72_812_227/1073):.2f}× — SDD дороже НА ХОД, при том что задач у него 'меньше на агента'")
print(f"   Тот же корпус по моим данным: медиана ток/ход у имплементера {statistics.median([C(x)/x['n'] for _,_,x in pred]):,.0f}")
print("\n## 4. ПРОТИВ B: фактическая ошибка в его таблице")
P=json.load(open("/Users/vadim/Documents/Pet/trellis/.mvp/plan.json"))["tasks"]
d={t["id"]:t for t in P}
print("   B пишет 'deps у всех восьми — ноль'. В plan.json нет ключа 'deps'; есть 'depends_on':")
print("   " + ", ".join(f"{i}:{len(d[i]['depends_on'])}" for i in ("011","012","013","014","015","016","017","018")))
print(f"   реальные deps: {[len(d[i]['depends_on']) for i in ('011','012','013','014','015','016','017','018')]} — не константа")
import math as _m
def pear(a,b):
    ma,mb=statistics.mean(a),statistics.mean(b)
    sa=_m.sqrt(sum((v-ma)**2 for v in a));sb=_m.sqrt(sum((v-mb)**2 for v in b))
    return sum((v-ma)*(w-mb) for v,w in zip(a,b))/(sa*sb)
ids=("011","012","013","014","015","016","017","018")
tok=[6561430,8319858,8303540,4735111,14838816,12294882,5725639,11628313]
fl=[len(d[i]["files"]) for i in ids]; dp=[len(d[i]["depends_on"]) for i in ids]
print(f"   пересчёт корреляции B на тех же 8 задачах: r(files,tok)={pear(fl,tok):+.2f}, r(deps,tok)={pear(dp,tok):+.2f}, r(files+deps,tok)={pear([a+b for a,b in zip(fl,dp)],tok):+.2f}")
print(f"   (мой честный комментарий: n=8, все связи незначимы; сам по себе этот срез не доказывает НИЧЬЮ гипотезу)")
