import json,statistics,math,collections
rows=[x for x in json.load(open("d_rows.json")) if x["delta"]]
def pearson(a,b):
    n=len(a)
    if n<3: return float('nan')
    ma,mb=statistics.mean(a),statistics.mean(b)
    sa=math.sqrt(sum((x-ma)**2 for x in a)); sb=math.sqrt(sum((x-mb)**2 for x in b))
    if sa==0 or sb==0: return float('nan')
    return sum((x-ma)*(y-mb) for x,y in zip(a,b))/(sa*sb)
def rank(v):
    o=sorted(range(len(v)),key=lambda i:v[i]); r=[0.0]*len(v); i=0
    while i<len(o):
        j=i
        while j+1<len(o) and v[o[j+1]]==v[o[i]]: j+=1
        avg=(i+j)/2+1
        for k in range(i,j+1): r[o[k]]=avg
        i=j+1
    return r
def spear(a,b): return pearson(rank(a),rank(b))

print("### Корреляции со стоимостью (delta_tokens = output субагентов)")
print("| подвыборка | n | r(deps) | ρ(deps) | r(files) | ρ(files) | r(disp) | ρ(disp) | r(est) | r(desc_len) |")
print("|---|---|---|---|---|---|---|---|---|---|")
def line(name, rs):
    y=[x["delta"] for x in rs]; ly=[math.log(v) for v in y]
    d=[x["deps"] for x in rs]; f=[x["files"] for x in rs]; dl=[x["desc_len"] for x in rs]
    e=[x["est"] or 0 for x in rs]
    dd=[x for x in rs if x["disp"] is not None]
    if len(dd)>=3:
        rd=pearson([x["disp"] for x in dd],[x["delta"] for x in dd]); sd=spear([x["disp"] for x in dd],[x["delta"] for x in dd])
    else: rd=sd=float('nan')
    print(f"| {name} | {len(rs)} | {pearson(d,y):+.2f} | {spear(d,y):+.2f} | {pearson(f,y):+.2f} | {spear(f,y):+.2f} | {rd:+.2f} (n={len(dd)}) | {sd:+.2f} | {pearson(e,y):+.2f} | {pearson(dl,y):+.2f} |")
line("все 3 проекта", rows)
for p in ("vireo","glotok","trellis"):
    line(p, [x for x in rows if x["proj"]==p])
# within-project z-normalized pooled
zr=[]
for p in ("vireo","glotok","trellis"):
    rs=[x for x in rows if x["proj"]==p]
    ly=[math.log(x["delta"]) for x in rs]
    m,s=statistics.mean(ly),statistics.pstdev(ly)
    for x,v in zip(rs,ly):
        y=dict(x); y["z"]=(v-m)/s; zr.append(y)
print()
print("### Пул с внутрипроектной нормировкой (z от log delta) — убирает эффект «проект»")
zz=[x["z"] for x in zr]
for k in ("deps","files","desc_len","level"):
    v=[x[k] or 0 for x in zr]
    print(f"  {k:10s}: r={pearson(v,zz):+.3f}  ρ={spear(v,zz):+.3f}")
dd=[x for x in zr if x["disp"] is not None]
print(f"  dispatches: r={pearson([x['disp'] for x in dd],[x['z'] for x in dd]):+.3f} ρ={spear([x['disp'] for x in dd],[x['z'] for x in dd]):+.3f}  (n={len(dd)})")
# complexity_class
print()
print("### По complexity_class (медиана delta, внутри проекта нормированная z)")
for c in ("boilerplate","follow-pattern","novel-design"):
    s=[x for x in zr if x["cclass"]==c]
    print(f"  {c:16s} n={len(s):3d}  med delta={statistics.median([x['delta'] for x in s]):9.0f}  mean z={statistics.mean([x['z'] for x in s]):+.3f}")
# deps buckets
print()
print("### По deps (z-нормированные, и сырые медианы внутри trellis/vireo)")
for k in sorted(set(x["deps"] for x in zr)):
    s=[x for x in zr if x["deps"]==k]
    print(f"  deps={k} n={len(s):3d} mean z={statistics.mean([x['z'] for x in s]):+.3f} med delta={statistics.median([x['delta'] for x in s]):9.0f}")
print()
for k in sorted(set(x["files"] for x in zr)):
    s=[x for x in zr if x["files"]==k]
    print(f"  files={k} n={len(s):3d} mean z={statistics.mean([x['z'] for x in s]):+.3f} med delta={statistics.median([x['delta'] for x in s]):9.0f}")
json.dump(zr,open("d_zrows.json","w"),ensure_ascii=False)
