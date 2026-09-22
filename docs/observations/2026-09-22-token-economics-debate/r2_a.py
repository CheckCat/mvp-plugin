import json,math,statistics,collections
A=json.load(open("d_wfagents.json")); Z=json.load(open("d_z.json"))
C=lambda x:x["i"]+x["cw"]+x["cr"]+x["o"]
def pear(a,b):
    ma,mb=statistics.mean(a),statistics.mean(b)
    sa=math.sqrt(sum((x-ma)**2 for x in a));sb=math.sqrt(sum((y-mb)**2 for y in b))
    return sum((x-ma)*(y-mb) for x,y in zip(a,b))/(sa*sb) if sa and sb else float('nan')
per=collections.defaultdict(lambda:dict(impl=0,rev=0,fix=0,tool=0,n_rev=0))
for x in A:
    k=(x["proj"],x["task"])
    if not x["task"]: continue
    a=per[k]
    if x["role"]=="prompt:implementer": a["impl"]+=C(x)
    elif x["role"] in ("prompt:reviewer","prompt:re-review","prompt:validator"): a["rev"]+=C(x); a["n_rev"]+=1
    elif x["role"]=="prompt:fix": a["fix"]+=C(x)
    elif x["role"].startswith("tool:"): a["tool"]+=C(x)
zk={(z["proj"],z["id"]):z for z in Z}
rows=[dict(k=k,**v,tot=v["impl"]+v["rev"]+v["fix"]+v["tool"]) for k,v in per.items() if k in zk and v["impl"]>0]
print("## ПРОТИВ A: ревью-контур — стабильный ПРОЦЕНТ или стабильная МАССА?   n=%d задач"%len(rows))
im=[r["impl"] for r in rows]; rv=[r["rev"] for r in rows]; fx=[r["fix"] for r in rows]; tl=[r["tool"] for r in rows]
print(f"  r(impl, rev)      = {pear(im,rv):+.3f}   (лог-лог: {pear([math.log(v) for v in im],[math.log(max(v,1)) for v in rv]):+.3f})")
print(f"  r(impl, rev+fix)  = {pear(im,[a+b for a,b in zip(rv,fx)]):+.3f}")
print(f"  r(impl, tool)     = {pear(im,tl):+.3f}")
# лог-лог наклон rev ~ impl^b
xs=[math.log(v) for v in im]; ys=[math.log(max(v,1)) for v in rv]
mx,my=statistics.mean(xs),statistics.mean(ys)
b=sum((a-mx)*(c-my) for a,c in zip(xs,ys))/sum((a-mx)**2 for a in xs)
print(f"  лог-лог наклон: rev ∝ impl^{b:.2f}  — ревью РАСТЁТ вместе с имплементером")
print("\n  Коэффициент вариации долей и масс по задачам:")
for nm,v in (("impl",im),("review-контур",rv),("fix",fx),("tool",tl)):
    sh=[a/r["tot"] for a,r in zip(v,rows)]
    print(f"   {nm:14s} МАССА: медиана {statistics.median(v):11,.0f} CV {statistics.pstdev(v)/statistics.mean(v):5.2f} размах {max(v)/max(min(v),1):7.1f}x | ДОЛЯ: медиана {statistics.median(sh):5.1%} CV {statistics.pstdev(sh)/statistics.mean(sh):.2f}")
print("\n  Квартили задач по стоимости имплементера -> сколько стоит ревью-контур:")
rows.sort(key=lambda r:r["impl"])
q=len(rows)//4
for i,nm in enumerate(("Q1 дешёвые","Q2","Q3","Q4 дорогие")):
    s=rows[i*q:(i+1)*q] if i<3 else rows[3*q:]
    print(f"   {nm:12s} n={len(s):3d} медиана impl {statistics.median([r['impl'] for r in s]):11,.0f}  медиана ревью {statistics.median([r['rev'] for r in s]):10,.0f}  доля ревью {statistics.median([r['rev']/r['tot'] for r in s]):5.1%}")
print("\n  Что даёт A-шная экономия 'потолок 15 ходов ревьюера' НА ВСЕХ ТРЁХ ПРОЕКТАХ:")
revs=[x for x in A if x["role"] in ("prompt:reviewer","prompt:re-review")]
over=[x for x in revs if x["n"]>15]
med15=statistics.median([C(x) for x in revs if 12<=x["n"]<=15])
T=sum(C(x) for x in A)
print(f"   опросов всего {len(revs)}, длиннее 15 ходов {len(over)} ({len(over)/len(revs):.0%}), они стоят {sum(C(x) for x in over):,}")
print(f"   медиана опроса 12-15 ходов = {med15:,.0f}; после потолка {len(over)}×{med15:,.0f} = {len(over)*med15:,.0f}")
print(f"   экономия {sum(C(x) for x in over)-len(over)*med15:,.0f} = {(sum(C(x) for x in over)-len(over)*med15)/T:.1%} корпуса workflow")
