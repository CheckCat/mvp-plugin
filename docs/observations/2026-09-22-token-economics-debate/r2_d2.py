import json,math,statistics,collections
A=json.load(open("d_wfagents.json")); Z=json.load(open("d_z.json"))
C=lambda x:x["i"]+x["cw"]+x["cr"]+x["o"]
K,B=6950,1.67; W=13
T_ALL=sum(C(x) for x in A)
# 1) масштаб ревью и fix от числа файлов -- по данным
per=collections.defaultdict(lambda:dict(rev=0,fix=0))
for x in A:
    if not x["task"]: continue
    k=(x["proj"],x["task"])
    if x["role"] in ("prompt:reviewer","prompt:re-review","prompt:validator"): per[k]["rev"]+=C(x)
    elif x["role"]=="prompt:fix": per[k]["fix"]+=C(x)
zk={(z["proj"],z["id"]):z for z in Z}
rows=[(zk[k]["files"],v["rev"],v["fix"],zk[k]) for k,v in per.items() if k in zk and v["rev"]>0]
xs=[math.log(f) for f,_,_,_ in rows]; ys=[math.log(r) for _,r,_,_ in rows]
mx,my=statistics.mean(xs),statistics.mean(ys)
a=sum((p-mx)*(q-my) for p,q in zip(xs,ys))/sum((p-mx)**2 for p in xs)
yh=[my+a*(p-mx) for p in xs]; sst=sum((q-my)**2 for q in ys); sse=sum((q-h)**2 for q,h in zip(ys,yh))
print(f"## Масштаб ревью-контура от ширины задачи: rev ∝ files^{a:.2f}  (R2={1-sse/sst:.3f}, n={len(rows)})")
print(f"   => разбить задачу пополам по файлам: ревью 2·(1/2)^{a:.2f} = {2*0.5**a:.2f}× — {'дешевле' if 2*0.5**a<1 else 'дороже'}")
# 2) вероятность fix от files
print("\n## Вероятность fix-раунда от ширины задачи")
for lo,hi,nm in ((1,2,"files 1-2"),(3,3,"files 3"),(4,4,"files 4"),(5,99,"files 5+")):
    s=[r for r in rows if lo<=r[0]<=hi]
    p=sum(1 for r in s if r[2]>0)/len(s)
    print(f"   {nm:10s} n={len(s):3d}  P(fix)={p:.0%}  медиана стоимости fix там, где он был: {statistics.median([r[2] for r in s if r[2]>0]) if any(r[2]>0 for r in s) else 0:,.0f}")
# 3) полная симуляция D с измеренными масштабами
impl={}
for x in A:
    if x["role"]=="prompt:implementer" and x["task"]: impl.setdefault((x["proj"],x["task"]),x)
TOOL=288_075
def seg(r,S):
    if S<=1: return K*r**B
    return S*K*(W+max(r-W,0)/S)**B
print("\n## D пересчитанный: имплементер (W=13) + ревью ∝ files^%.2f + tool-налог + эффект на fix"%a)
print(f"  {'порог req':>10s} {'задач':>6s} {'Δимплементер':>15s} {'Δревью':>13s} {'Δtool':>12s} {'Δfix':>13s} {'ИТОГО':>15s} {'% корпуса':>10s}")
for th in (80,60,50,40,30):
    dI=dR=dT=dF=0; n=0
    for k,x in impl.items():
        z=zk.get(k)
        if not z or x["n"]<th: continue
        n+=1
        dI+=C(x)-seg(x["n"],2)
        rv=per[k]["rev"]; dR+=rv-rv*(2*0.5**a)
        dT-=TOOL
        # fix: ширина падает вдвое -> вероятность fix по таблице падает; консервативно только если files>=4
        if z["files"]>=4 and per[k]["fix"]>0: dF+=per[k]["fix"]*0.30
    tot=dI+dR+dT+dF
    print(f"  {th:>10d} {n:>6d} {dI:>+15,.0f} {dR:>+13,.0f} {dT:>+12,.0f} {dF:>+13,.0f} {tot:>+15,.0f} {tot/T_ALL:>+9.1%}")
print("\n## D + C вместе (разбить задачу пополам И ограничить каждый сегмент CAP=40)")
for th in (60,50,40):
    tot=0;n=0
    for k,x in impl.items():
        z=zk.get(k)
        if not z: continue
        r=x["n"]
        if r<th:
            # только CAP
            if r>40:
                S=max(1,math.ceil(max(r-W,0)/(40-W))); tot+=C(x)-seg(r,S)
            continue
        n+=1
        half=W+max(r-W,0)/2
        S=max(1,math.ceil(max(half-W,0)/(40-W)))
        tot+=C(x)-2*seg(half,S)/1.0*0+ (C(x)-(2*S*K*(W+max(half-W,0)/S)**B))
        rv=per[k]["rev"]; tot+=rv-rv*(2*0.5**a); tot-=TOOL
    print(f"  порог D={th}, CAP=40: ИТОГО {tot:+,.0f} = {tot/T_ALL:+.1%} корпуса (разбито {n} задач)")
