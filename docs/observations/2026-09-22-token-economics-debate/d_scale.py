import json,math,statistics,collections
A=json.load(open("d_wfagents.json"))
def fit(rs,nm):
    xs=[math.log(x["n"]) for x in rs]; ys=[math.log(x["i"]+x["cw"]+x["cr"]+x["o"]) for x in rs]
    n=len(xs); mx,my=statistics.mean(xs),statistics.mean(ys)
    b=sum((a-mx)*(c-my) for a,c in zip(xs,ys))/sum((a-mx)**2 for a in xs)
    a0=my-b*mx
    yh=[a0+b*v for v in xs]; sst=sum((v-my)**2 for v in ys); sse=sum((v-h)**2 for v,h in zip(ys,yh))
    print(f"  {nm:22s} n={n:4d}  tot ≈ {math.exp(a0):,.0f} · req^{b:.2f}   R2={1-sse/sst:.3f}")
    return a0,b
print("## Скейлинг стоимости агента от числа его запросов (log-log OLS)")
for r in ("prompt:implementer","prompt:reviewer","prompt:fix","prompt:re-review","prompt:validator"):
    s=[x for x in A if x["role"]==r and x["n"]>=2]
    if len(s)>5: fit(s,r)
fit([x for x in A if x["role"].startswith("prompt:") and x["n"]>=2],"ВСЕ prompt-агенты")
tool=[x for x in A if x["role"].startswith("tool:")]
tv=[x["i"]+x["cw"]+x["cr"]+x["o"] for x in tool]
print(f"\n## Налог tool-диспатчей: n={len(tool)} медиана {statistics.median(tv):,.0f} среднее {statistics.mean(tv):,.0f} суммарно {sum(tv):,.0f}")
allp=[x["i"]+x["cw"]+x["cr"]+x["o"] for x in A]
print(f"   доля tool-агентов: {len(tool)/len(A):.0%} по числу, {sum(tv)/sum(allp):.1%} по токенам")
print(f"   медианное число запросов у tool-агента: {statistics.median([x['n'] for x in tool])}")
print("\n## Доля ролей по всем трём проектам (workflow-агенты)")
byr=collections.defaultdict(lambda:[0,0,0])
for x in A:
    t=x["i"]+x["cw"]+x["cr"]+x["o"]; b=byr[x["role"]]; b[0]+=1; b[1]+=x["n"]; b[2]+=t
T=sum(b[2] for b in byr.values())
for r,b in sorted(byr.items(),key=lambda kv:-kv[1][2]):
    print(f"  {r:22s} агентов {b[0]:5d} запросов {b[1]:6d} токенов {b[2]:13,d} ({b[2]/T:5.1%})")
print(f"  ИТОГО {sum(b[0] for b in byr.values())} агентов, {T:,d} токенов")
