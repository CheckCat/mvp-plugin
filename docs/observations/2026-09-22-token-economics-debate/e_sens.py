import pickle, statistics as st, collections
exec(open('e_cap.py').read().split("ALL=[r for r in rows]")[0])
WF=[r for r in rows if r['wf']=='wf_4d14cdc2-05c']
def sweep(sel,label):
    B0=sum(agent_cost(r) for r in sel)
    print(f"\n### {label} baseline {B0:,}")
    print("CAP " + ''.join(f"E={e:<3d}" for e in range(1,20)))
    for cap in (15,20,25,30,40,50,60):
        line=f"{cap:3d} "
        for e in range(1,20):
            if cap-e<2: line+=' --- '; continue
            tot=sum(replay(r,cap,e,6000,True)[0] for r in sel)
            line+=f"{100*(B0-tot)/B0:4.0f} "
        print(line)
    # break-even E
    print(" break-even E (saving crosses 0):")
    for cap in (15,20,25,30,40,50,60):
        be=None
        for e in range(1,cap-1):
            tot=sum(replay(r,cap,e,6000,True)[0] for r in sel)
            if B0-tot<0: be=e; break
        print(f"   CAP={cap}: E*={be}")
sweep(WF,'wf_4d14cdc2 (all 110 agents)')
sweep(rows,'full workflow corpus (1339 agents)')
# how many agents/tasks does a flat cap actually touch
for cap in (20,30,40,50):
    touched=[r for r in rows if len(r['ctx'])>cap]
    tasks={(r['proj'],r['task']) for r in touched if r['task']}
    print(f"flat CAP={cap}: touches {len(touched)} of 1339 agents ({len(touched)/1339:.0%}), {len(tasks)} tasks; "
          f"they hold {sum(agent_cost(r) for r in touched)/sum(agent_cost(r) for r in rows):.0%} of corpus tokens; "
          f"roles={collections.Counter(r['role'] for r in touched).most_common(4)}")
