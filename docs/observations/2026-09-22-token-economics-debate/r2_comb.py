import json,math,collections,statistics
A=json.load(open("d_wfagents.json")); Z=json.load(open("d_z.json"))
C=lambda x:x["i"]+x["cw"]+x["cr"]+x["o"]
K,B,W=6950,1.67,13; TOOL=288_075; AREV=0.69
T=sum(C(x) for x in A)
zk={(z["proj"],z["id"]):z for z in Z}
per=collections.defaultdict(lambda:dict(rev=0,fix=0))
for x in A:
    if not x["task"]: continue
    k=(x["proj"],x["task"])
    if x["role"] in ("prompt:reviewer","prompt:re-review","prompt:validator"): per[k]["rev"]+=C(x)
    elif x["role"]=="prompt:fix": per[k]["fix"]+=C(x)
impl={}
for x in A:
    if x["role"]=="prompt:implementer" and x["task"]: impl.setdefault((x["proj"],x["task"]),x)
def cap_cost(r,cap):
    if r<=cap: return K*r**B
    S=max(1,math.ceil(max(r-W,0)/max(cap-W,1)))
    return S*K*(W+max(r-W,0)/S)**B
def sim(th,cap):
    new=0
    for k,x in impl.items():
        z=zk.get(k)
        if not z: new+=C(x); continue
        r=x["n"]; rv=per[k]["rev"]
        if th and r>=th:
            half=W+max(r-W,0)/2
            new+= 2*cap_cost(half,cap or 10**9) + rv*(2*0.5**AREV) + TOOL
        else:
            new+= cap_cost(r,cap or 10**9) + rv
    base=sum(C(x) for x in impl.values())+sum(per[k]["rev"] for k in impl)
    return base-new
print("## Механизмы на едином допущении W=13 (измеренный разогрев). Экономия в % корпуса workflow (867.1M)")
print(f"  {'':>28s} {'токенов':>15s} {'% корпуса':>10s}")
for nm,th,cap in [("только D: порог 50",50,None),("только D: порог 60",60,None),
                  ("только C: CAP=40",None,40),("только C: CAP=30",None,30),("только C: CAP=25",None,25),
                  ("D(50) + C(40)",50,40),("D(50) + C(30)",50,30),("D(60) + C(40)",60,40)]:
    d=sim(th,cap); print(f"  {nm:>28s} {d:>+15,.0f} {d/T:>+9.1%}")
print("\n## Тот же расчёт при допущении C (W=2) — для наглядности цены допущения")
W=2
for nm,th,cap in [("только C: CAP=30",None,30),("только D: порог 50",50,None)]:
    d=sim(th,cap); print(f"  {nm:>28s} {d:>+15,.0f} {d/T:>+9.1%}")
