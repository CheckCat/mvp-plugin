import json,collections,statistics,math
A=json.load(open("d_wfagents.json"))
R=json.load(open("d_rows.json"))
plan={(x["proj"],x["id"]):x for x in R}
agg=collections.defaultdict(lambda: dict(n_ag=0,n_req=0,i=0,cw=0,cr=0,o=0,roles=collections.Counter()))
unatt=collections.Counter()
for x in A:
    if not x["task"]: unatt[x["proj"]]+= x["i"]+x["cw"]+x["cr"]+x["o"]; continue
    k=(x["proj"],x["task"])
    if k not in plan: unatt[x["proj"]+"/nokey"]+=x["i"]+x["cw"]+x["cr"]+x["o"]; continue
    a=agg[k]; a["n_ag"]+=1; a["n_req"]+=x["n"]
    for f in ("i","cw","cr","o"): a[f]+=x[f]
    a["roles"][x["role"]]+=1
print("unattributed totals:",dict(unatt))
rows=[]
for k,a in agg.items():
    p=plan[k]
    tot=a["i"]+a["cw"]+a["cr"]+a["o"]
    rows.append(dict(proj=k[0],id=k[1],deps=p["deps"],files=p["files"],cclass=p["cclass"],
        level=p["level"],role_plan=p["role"],est=p["est"],delta=p["delta"],disp=p["disp"],
        n_ag=a["n_ag"],n_req=a["n_req"],i=a["i"],cw=a["cw"],cr=a["cr"],o=a["o"],tot=tot,
        n_impl=a["roles"]["prompt:implementer"],n_rev=a["roles"]["prompt:reviewer"]+a["roles"]["prompt:re-review"],
        n_fix=a["roles"]["prompt:fix"],n_revpkg=a["roles"]["tool:reviewpkg"],n_val=a["roles"]["tool:validate"]))
rows.sort(key=lambda x:(x["proj"],x["id"]))
json.dump(rows,open("d_taskcost.json","w"),ensure_ascii=False)
print("tasks with wf cost:",len(rows))
for p in ("vireo","glotok","trellis"):
    s=[x for x in rows if x["proj"]==p]
    print(f"  {p}: {len(s)} tasks, total {sum(x['tot'] for x in s)/1e6:.1f}M tok, out {sum(x['o'] for x in s)/1e3:.0f}k")
# sanity: does workflow output ~ delta?
s=[x for x in rows if x["delta"] and x["o"]>0]
rr=[(x["o"],x["delta"]) for x in s]
print("sanity o vs delta: n=%d  median ratio %.2f"%(len(rr),statistics.median(a/b for a,b in rr)))
