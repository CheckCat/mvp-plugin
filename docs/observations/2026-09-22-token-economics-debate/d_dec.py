import json,statistics,math,collections
zr=json.load(open("d_z.json"))
def pearson(a,b):
    ma,mb=statistics.mean(a),statistics.mean(b)
    sa=math.sqrt(sum((x-ma)**2 for x in a)); sb=math.sqrt(sum((x-mb)**2 for x in b))
    return sum((x-ma)*(y-mb) for x,y in zip(a,b))/(sa*sb) if sa and sb else float('nan')
def rank(v):
    o=sorted(range(len(v)),key=lambda i:v[i]); r=[0.0]*len(v); i=0
    while i<len(o):
        j=i
        while j+1<len(o) and v[o[j+1]]==v[o[i]]: j+=1
        for k in range(i,j+1): r[o[k]]=(i+j)/2+1
        i=j+1
    return r
def spear(a,b): return pearson(rank(a),rank(b))
for x in zr:
    x["ctx"]=x["tot"]/x["n_req"]          # средний контекст на запрос
    x["lreq"]=math.log(x["n_req"]); x["lctx"]=math.log(x["ctx"])
print("## Разложение log(tot) = log(n_req) + log(средний контекст/запрос)")
lt=[x["ltot"] for x in zr]; lr=[x["lreq"] for x in zr]; lc=[x["lctx"] for x in zr]
vt=statistics.pvariance(lt); vr=statistics.pvariance(lr); vc=statistics.pvariance(lc)
cov=statistics.mean([(a-statistics.mean(lr))*(b-statistics.mean(lc)) for a,b in zip(lr,lc)])
print(f"  Var(log tot)={vt:.4f}  Var(log n_req)={vr:.4f} ({vr/vt:.0%})  Var(log ctx)={vc:.4f} ({vc/vt:.0%})  2Cov={2*cov/vt:+.0%}")
print(f"  средний контекст/запрос: медиана {statistics.median([x['ctx'] for x in zr]):,.0f}  p10 {sorted(x['ctx'] for x in zr)[len(zr)//10]:,.0f}  p90 {sorted(x['ctx'] for x in zr)[9*len(zr)//10]:,.0f}")
print("\n## Канал: предсказывают ли deps/files ЧИСЛО ЗАПРОСОВ и ЧИСЛО FIX-раундов?")
for tgt in ("n_req","n_ag","n_fix","n_impl","n_rev","lctx"):
    y=[x[tgt] for x in zr]
    print(f"  {tgt:6s} ~ deps r={pearson([x['deps'] for x in zr],y):+.3f} ρ={spear([x['deps'] for x in zr],y):+.3f} | files r={pearson([x['files'] for x in zr],y):+.3f} ρ={spear([x['files'] for x in zr],y):+.3f}")
print("\n## Есть ли fix-раунды и как они связаны со сложностью")
print("  n_fix dist:",collections.Counter(x["n_fix"] for x in zr))
for k in sorted(set(x["n_fix"] for x in zr)):
    s=[x for x in zr if x["n_fix"]==k]
    print(f"   n_fix={k} n={len(s):3d} медиана tot={statistics.median([x['tot'] for x in s]):12,.0f} ср deps={statistics.mean([x['deps'] for x in s]):.2f} ср files={statistics.mean([x['files'] for x in s]):.2f}")
print("\n## Бакеты deps (полная стоимость)")
for k in sorted(set(x["deps"] for x in zr)):
    s=[x for x in zr if x["deps"]==k]
    print(f"  deps={k} n={len(s):3d} медиана tot={statistics.median([x['tot'] for x in s]):12,.0f} ср z={statistics.mean([x['z'] for x in s]):+.2f} ср n_req={statistics.mean([x['n_req'] for x in s]):5.1f} ср n_ag={statistics.mean([x['n_ag'] for x in s]):4.1f} ср n_fix={statistics.mean([x['n_fix'] for x in s]):.2f}")
print("\n## Бакеты files")
for k in sorted(set(x["files"] for x in zr)):
    s=[x for x in zr if x["files"]==k]
    print(f"  files={k:2d} n={len(s):3d} медиана tot={statistics.median([x['tot'] for x in s]):12,.0f} ср z={statistics.mean([x['z'] for x in s]):+.2f} ср n_req={statistics.mean([x['n_req'] for x in s]):5.1f} ср n_fix={statistics.mean([x['n_fix'] for x in s]):.2f}")
print("\n## Бакеты cclass")
for c in ("boilerplate","follow-pattern","novel-design"):
    s=[x for x in zr if x["cclass"]==c]
    if not s: continue
    print(f"  {c:15s} n={len(s):3d} медиана tot={statistics.median([x['tot'] for x in s]):12,.0f} ср z={statistics.mean([x['z'] for x in s]):+.2f} ср n_req={statistics.mean([x['n_req'] for x in s]):5.1f} ср n_ag={statistics.mean([x['n_ag'] for x in s]):4.1f} ср n_fix={statistics.mean([x['n_fix'] for x in s]):.2f} ср deps={statistics.mean([x['deps'] for x in s]):.2f} ср files={statistics.mean([x['files'] for x in s]):.2f}")
json.dump(zr,open("d_z.json","w"),ensure_ascii=False)
