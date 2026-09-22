import json,math,statistics,collections
A=json.load(open("d_wfagents.json")); Z={(z["proj"],z["id"]):z for z in json.load(open("d_z.json"))}
C=lambda x:x["i"]+x["cw"]+x["cr"]+x["o"]
K,B=6950,1.67                  # implementer: tot = K·r^B  (R2=.933)
T_ALL=sum(C(x) for x in A)
impl=[x for x in A if x["role"]=="prompt:implementer"]
S_IMPL=sum(C(x) for x in impl)
print(f"корпус workflow {T_ALL:,};  имплементеры {S_IMPL:,} ({S_IMPL/T_ALL:.1%}), {len(impl)} агентов")
print(f"эмпирический разогрев имплементера до 1-й правки: медиана 14 ходов; у fix (продолжение по handoff) 13 ходов\n")

def seg_cost(r,S,W):
    """S сегментов, каждый платит W ходов разогрева + (r-W)/S продуктивных"""
    if S<=1: return K*r**B
    prod=max(r-W,0)/S
    return S*K*(W+prod)**B

def run(nm,cap_or_parts,W,extra_per_split=0.0,mode="cap"):
    new=0; nsplit=0; parts_tot=0
    for x in impl:
        r=x["n"]; c=C(x)
        if mode=="cap":
            if r<=cap_or_parts: new+=c; continue
            prod=max(r-W,0); per=max(cap_or_parts-W,1)
            S=1+math.ceil(max(prod-(cap_or_parts-W),0)/per) if prod>cap_or_parts-W else 1
            S=max(1,math.ceil(prod/per))
        else:
            S=cap_or_parts if r>=40 else 1
        if S<=1: new+=c; continue
        nsplit+=1; parts_tot+=S-1
        new+=seg_cost(r,S,W)+extra_per_split*(S-1)
    d=S_IMPL-new
    print(f"  {nm:52s} разбито {nsplit:3d} имплементеров (+{parts_tot:3d} сегм.)  {S_IMPL:,} -> {new:,.0f}  Δ={d:+,.0f} = {d/T_ALL:+.1%} корпуса")
    return d

print("## C: TURN_CAP на имплементере. Его допущение E≈2 хода против измеренного W=13-14")
for cap in (60,40,30,25,20):
    run(f"CAP={cap}, разогрев W=2 (допущение C)", cap, 2)
print()
for cap in (60,40,30,25,20):
    run(f"CAP={cap}, разогрев W=13 (ИЗМЕРЕНО на fix-агентах)", cap, 13)
print()
print("## То же, но каждый рестарт ещё платит билет диспатча (по B: role-агент ~14k × длина сегмента)")
for cap in (40,30,25):
    run(f"CAP={cap}, W=13 + билет 14k×{cap} ходов", cap, 13, extra_per_split=14000*cap)
print()
print("## D: разбиение задачи пополам (мой механизм) с ТОЙ ЖЕ поправкой на разогрев")
TOOL=288_075; REV_MED=624_162
for th in (80,60,50,40):
    # split into 2 parts, each a full task: +1 ladder (tool + review)
    new=0; nsplit=0
    for x in impl:
        r=x["n"]; c=C(x)
        if r<th: new+=c; continue
        nsplit+=1
        new+=seg_cost(r,2,13)
    dimpl=S_IMPL-new
    ladder=nsplit*(TOOL+REV_MED*0.6)   # консервативно: ревью половинки = 0.6 от целого, платим 2×0.6=1.2
    net=dimpl-ladder
    print(f"  порог {th:3d}: разбито {nsplit:3d} задач; имплементер {dimpl:+,.0f}; доплата за лестницы -{ladder:,.0f}; ИТОГО {net:+,.0f} = {net/T_ALL:+.1%} корпуса")
print()
print("## Честное сравнение при ОДИНАКОВОМ допущении о разогреве (W=13):")
c30=run("  C: CAP=30", 30, 13)
d50_new=0; n50=0
for x in impl:
    if x["n"]<50: d50_new+=C(x); continue
    n50+=1; d50_new+=seg_cost(x["n"],2,13)
d50=(S_IMPL-d50_new)-n50*(TOOL+REV_MED*0.6)
print(f"  D: порог 50 (с доплатой за лестницу)                 {d50:+,.0f} = {d50/T_ALL:+.1%} корпуса")
print(f"  разница в пользу C: {c30-d50:+,.0f} = {(c30-d50)/T_ALL:+.1%} корпуса")
