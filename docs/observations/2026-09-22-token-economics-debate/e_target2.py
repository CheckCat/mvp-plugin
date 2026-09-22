import pickle, json, math, statistics as st, collections
exec(open('e_cap.py').read().split("ALL=[r for r in rows]")[0])
P=pickle.load(open('e_pred.pkl','rb')); keys=P['keys']; pred=P['best']['pred']; actual=P['best']['actual']
TC={(t['proj'],t['id']):t for t in json.load(open('d_taskcost.json'))}
byt=collections.defaultdict(list)
for r in rows:
    if r['task']: byt[(r['proj'],r['task'].zfill(3))].append(r)
ROLES=('implementer','fix')
def task_base(k): return sum(agent_cost(r) for r in byt[k])
def task_capped(k,cap,E,H=6000):
    t=0
    for r in byt[k]:
        if r['role'] in ROLES:
            c,_=replay(r,cap,E,H,True); t+=c
        else: t+=agent_cost(r)
    return t
BASE={k:task_base(k) for k in keys}
TOTB=sum(BASE.values())
print(f"joined corpus (123 tasks) baseline = {TOTB:,}")
for cap,E in ((40,5),(30,5),(30,8),(40,8),(30,2)):
    CAPD={k:task_capped(k,cap,E) for k in keys}
    full=sum(BASE[k]-CAPD[k] for k in keys)
    print(f"\n--- CAP={cap} E={E}: flat on ALL tasks = {full:,.0f} = {full/TOTB:+.1%}")
    for name, score in (('plan prediction (LOO)', pred), ('ORACLE actual cost', actual)):
        order=sorted(range(len(keys)), key=lambda i:-score[i])
        for frac in (0.25,0.33,0.5):
            m=int(round(frac*len(keys))); sel={keys[i] for i in order[:m]}
            s=sum(BASE[k]-CAPD[k] for k in sel)
            print(f"    top {frac:.0%} by {name:22s}: {s:,.0f} = {s/TOTB:+.1%} corpus = {100*s/full:.0f}% of flat effect  (tasks={m})")
