import json, os, glob, sys, collections, statistics
sys.path.insert(0,'/private/tmp/claude-501/-Users-vadim-Documents-Pet-trellis/ffbe66c3-5d41-424f-b4eb-27417e32a7fc/scratchpad')
import tokcost

def per_request(path):
    """ordered list of (rid, model, vals) dedup by rid, max per field, in first-seen order"""
    order=[]; per={}
    for line in open(path, errors="replace"):
        if '"usage"' not in line: continue
        try: d=json.loads(line)
        except: continue
        m=d.get("message") or {}
        u=m.get("usage")
        if not isinstance(u,dict): continue
        rid=d.get("requestId") or d.get("uuid")
        cc=u.get("cache_creation") or {}
        cw5=cc.get("ephemeral_5m_input_tokens"); cw1=cc.get("ephemeral_1h_input_tokens")
        if cw5 is None and cw1 is None:
            cw5,cw1=u.get("cache_creation_input_tokens",0) or 0,0
        vals=[u.get("input_tokens",0) or 0, cw5 or 0, cw1 or 0,
              u.get("cache_read_input_tokens",0) or 0, u.get("output_tokens",0) or 0]
        if rid not in per:
            per[rid]=[m.get("model"),vals]; order.append(rid)
        else:
            per[rid][1]=[max(a,b) for a,b in zip(per[rid][1],vals)]
    return [(r,per[r][0],per[r][1]) for r in order]

D=sys.argv[1]
rows=[]
for f in sorted(glob.glob(os.path.join(D,'agent-*.jsonl'))):
    meta={}
    mp=f[:-6]+'.meta.json'
    if os.path.exists(mp):
        try: meta=json.load(open(mp))
        except: pass
    reqs=per_request(f)
    if not reqs: continue
    first=reqs[0][2]
    tot=[sum(r[2][i] for r in reqs) for i in range(5)]
    rows.append(dict(f=os.path.basename(f), model=reqs[0][1],
        desc=(meta.get("description") or meta.get("agentType") or "?"),
        atype=meta.get("agentType") or "?",
        n=len(reqs),
        t_in=first[0], t_cw=first[1]+first[2], t_cr=first[3], t_out=first[4],
        tot_in=tot[0], tot_cw=tot[1]+tot[2], tot_cr=tot[3], tot_out=tot[4]))
json.dump(rows, open(sys.argv[2],'w'), ensure_ascii=False, indent=0)
print("agents",len(rows),"requests",sum(r['n'] for r in rows))
G=lambda k: sum(r[k] for r in rows)
print("TOTAL  in %d cw %d cr %d out %d  ALL %d"%(G('tot_in'),G('tot_cw'),G('tot_cr'),G('tot_out'),G('tot_in')+G('tot_cw')+G('tot_cr')+G('tot_out')))
print("FIRST  in %d cw %d cr %d out %d  ALL %d"%(G('t_in'),G('t_cw'),G('t_cr'),G('t_out'),G('t_in')+G('t_cw')+G('t_cr')+G('t_out')))
