import json, os, glob, statistics, math
P="/Users/vadim/Documents/Pet"
rows=[]
for proj in ("vireo","glotok","trellis"):
    plan=json.load(open(f"{P}/{proj}/.mvp/plan.json"))["tasks"]
    tel={}
    for l in open(f"{P}/{proj}/.mvp/telemetry/events.jsonl"):
        try: d=json.loads(l)
        except: continue
        if d.get("event")!="task_complete": continue
        tel[d["task"]]=d
    for t in plan:
        e=tel.get(t["id"],{})
        rows.append(dict(proj=proj, id=t["id"],
            deps=len(t.get("depends_on") or []),
            files=len(t.get("files") or []),
            desc_len=len(t.get("title","")),
            level=t.get("level"), role=t.get("role"), service=t.get("service"),
            cclass=t.get("complexity_class"),
            est=t.get("estimate_tokens"),
            actual=t.get("actual_tokens"),
            status=t.get("status"),
            delta=e.get("delta_tokens"),
            disp=e.get("dispatches"),
            ctrl=e.get("controller_only"),
            ts=e.get("ts")))
json.dump(rows, open("d_rows.json","w"), ensure_ascii=False, indent=0)
print("tasks total", len(rows))
for proj in ("vireo","glotok","trellis"):
    r=[x for x in rows if x["proj"]==proj]
    withtel=[x for x in r if x["delta"]]
    print(proj, "plan tasks",len(r), "with telemetry",len(withtel),
          "done",sum(1 for x in r if x["status"]=="done"))
