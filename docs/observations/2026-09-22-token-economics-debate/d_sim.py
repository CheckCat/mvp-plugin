import json,math,statistics,collections
A=json.load(open("d_wfagents.json"))
Z={(x["proj"],x["id"]):x for x in json.load(open("d_z.json"))}
per=collections.defaultdict(lambda: collections.defaultdict(list))
for x in A:
    if not x["task"]: continue
    per[(x["proj"],x["task"])][x["role"]].append(x)
IMPL_A,IMPL_B=6950,1.67
REV_A,REV_B=31632,1.34
TOOLTAX=58_854   # медиана tool-агента
def C(x): return x["i"]+x["cw"]+x["cr"]+x["o"]
print("## Симуляция «разбить задачу пополам» на реальных 124 задачах")
print("   модель: implementer 6950·req^1.67 (R2=.93), reviewer 31632·req^1.34 (R2=.92),")
print("   tool-налог 58 854 ток/диспатч (медиана), лестница добавляет 7 tool-диспатчей + 3 ревьюера на половинку.")
def sim(thresh, rev_mode):
    base=0; new=0; nsplit=0
    for k,roles in per.items():
        if k not in Z: continue
        impl=roles.get("prompt:implementer",[])
        tot=sum(C(x) for r in roles.values() for x in r)
        base+=tot
        if not impl or impl[0]["n"]<thresh: new+=tot; continue
        nsplit+=1
        r=impl[0]["n"]
        ci=C(impl[0])
        ci_new=2*IMPL_A*(r/2)**IMPL_B
        revs=[x for x in roles.get("prompt:reviewer",[])+roles.get("prompt:re-review",[])]
        cr_old=sum(C(x) for x in revs)
        if rev_mode=="half": cr_new=2*sum(REV_A*(x["n"]/2)**REV_B for x in revs)
        elif rev_mode=="same": cr_new=2*cr_old
        fixes=[x for x in roles.get("prompt:fix",[])]
        cf_old=sum(C(x) for x in fixes)
        cf_new=cf_old*(2*(0.5)**1.60)   # fix тоже пополам
        tools=sum(C(x) for rr,v in roles.items() if rr.startswith("tool:") for x in v)
        t_new=tools+7*TOOLTAX
        rest=tot-ci-cr_old-cf_old-tools
        new+=ci_new+cr_new+cf_new+t_new+rest
    return base,new,nsplit
for rev_mode,nm in (("half","ревьюер дешевеет пропорционально пакету"),("same","ПЕССИМИСТ: ревьюер не дешевеет, платим его дважды")):
    print(f"\n  режим: {nm}")
    print(f"  {'порог req импл.':>16s} {'разбито задач':>13s} {'было':>14s} {'стало':>14s} {'экономия':>12s}")
    for th in (100,80,60,50,40,30,0):
        b,n,ns=sim(th,rev_mode)
        print(f"  {th:>16d} {ns:>13d} {b:>14,.0f} {n:>14,.0f} {(b-n)/b:>11.1%}")
print("\n## Сколько «крупных» имплементеров и какова их доля расхода")
impl=[x for x in A if x["role"]=="prompt:implementer"]
impl.sort(key=lambda x:-C(x))
T=sum(C(x) for x in A)
for q in (0.1,0.2,0.3,0.5):
    k=int(len(impl)*q)
    print(f"  топ {q:.0%} имплементеров ({k} из {len(impl)}): {sum(C(x) for x in impl[:k])/T:.1%} ВСЕХ токенов пайплайна; медиана req у них {statistics.median([x['n'] for x in impl[:k]]):.0f}")
print(f"  все имплементеры: медиана req {statistics.median([x['n'] for x in impl]):.0f}, p90 {sorted(x['n'] for x in impl)[int(.9*len(impl))]}, max {max(x['n'] for x in impl)}")
