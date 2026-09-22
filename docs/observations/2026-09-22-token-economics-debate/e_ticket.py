import pickle, statistics as st
exec(open('e_cap.py').read().split("ALL=[r for r in rows]")[0])
for label, sel in (('wf_4d14cdc2', [r for r in rows if r['wf']=='wf_4d14cdc2-05c']),
                   ('full corpus', rows)):
    B0=sum(agent_cost(r) for r in sel)
    print(f"\n== {label}  baseline {B0:,}")
    for cap in (20,30,40):
        for E in (2,5,8):
            tot=0; ns=0; tm=0; tot_w=0
            for r in sel:
                t,s=replay(r,cap,E,6000,True); tot+=t; ns+=s
                tm+=ticket_mass(r,cap,E,6000,True)
                t2,_=replay(r,cap,E,6000,True,charge_ticket_write=True); tot_w+=t2
            print(f" CAP={cap} E={E}: save={B0-tot:,.0f} ({(B0-tot)/B0:+.1%})  new segs={ns}  "
                  f"ticket+handoff carried inside new segs={tm:,.0f} ({tm/B0:.1%} of run)  "
                  f"extra if ALSO charging a fresh cache-write per segment: {(tot_w-tot):,.0f} ({(tot_w-tot)/B0:.2%})")
