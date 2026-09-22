import pickle, json, statistics as st, collections, math, sys
rows=pickle.load(open('e_wf.pkl','rb'))
fu=json.load(open('e_fu.json'))
D_WARM = 2200      # measured: mean ctx delta per warmup turn of a continuation agent
ROLES_SEG = ('implementer','fix')   # roles a TURN_CAP would segment (reviewers max 27 turns)

def agent_cost(r): return sum(r['ctx'])+sum(r['out'])

def replay(r, cap, E, H, strict=True, charge_ticket_write=False):
    """strict: CAP counts ALL turns of a segment (warmup included)."""
    C=r['ctx']; O=r['out']; n=len(C)
    if n<=cap: return agent_cost(r), 0
    base=C[0]+H
    omed=st.median(O) if O else 300
    total=sum(C[:cap])+sum(O[:cap])
    k=cap; nseg=0
    prod = cap-E if strict else cap
    if prod<1: return float('inf'), 0
    while k<n:
        nseg+=1
        # warmup turns
        for j in range(E): total += base + j*D_WARM + omed
        shift = base + E*D_WARM - C[k-1]
        end=min(n, k+prod)
        for i in range(k,end): total += C[i]+shift + O[i]
        if charge_ticket_write: total += C[0]
        k=end
    return total, nseg

def ticket_mass(r, cap, E, H, strict=True):
    """tokens in NEW segments attributable to carrying base=C1+H (B's tax)"""
    C=r['ctx']; n=len(C)
    if n<=cap: return 0
    base=C[0]+H; prod=cap-E if strict else cap
    if prod<1: return 0
    k=cap; m=0
    while k<n:
        m += E*base
        end=min(n,k+prod); m += (end-k)*base
        k=end
    return m

def curve(sel, label, caps=(15,20,30,40,50), Es=(2,5,8,13), H=6000, strict=True, roles=None):
    if roles: sel=[r for r in sel if r['role'] in roles]
    B0=sum(agent_cost(r) for r in sel)
    print(f"\n### {label}   baseline={B0:,} tokens, {len(sel)} agents")
    hdr='CAP  ' + ''.join(f"  E={e:<2d}          " for e in Es) + '  new segs'
    print(hdr)
    for cap in caps:
        line=f"{cap:3d} "
        segs=None
        for e in Es:
            if cap-e<1: line+='       n/a     '; continue
            tot=0; ns=0
            for r in sel:
                t,s=replay(r,cap,e,H,strict); tot+=t; ns+=s
            d=B0-tot
            line+=f"  {d/B0:+6.1%} ({d/1e6:5.1f}M)"
            if e==Es[1]: segs=ns
        print(line + f"   {segs}")
    return B0

ALL=[r for r in rows]
WF=[r for r in rows if r['wf']=='wf_4d14cdc2-05c']
B0=curve(WF,'wf_4d14cdc2 (C\'s run) — CAP on ALL agents, %-of-run')
curve(WF,'wf_4d14cdc2 — CAP on implementer+fix only', roles=ROLES_SEG)
curve(ALL,'FULL workflow corpus (1339 agents, 3 projects) — CAP on ALL')
curve(ALL,'FULL corpus — CAP on implementer+fix only', roles=ROLES_SEG)
print("\n--- lenient variant (CAP counts only productive turns; warmup is extra) ---")
curve(WF,'wf_4d14cdc2 — lenient', strict=False)
curve(ALL,'FULL corpus — lenient', strict=False)
