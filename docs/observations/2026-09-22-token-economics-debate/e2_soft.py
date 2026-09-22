import pickle, random, statistics as st
exec(open('e_cap.py').read().split("ALL=[r for r in rows]")[0])
WF=[r for r in rows if r['wf']=='wf_4d14cdc2-05c']
B0w=sum(agent_cost(r) for r in WF); B0c=sum(agent_cost(r) for r in rows)
NTURN_w=sum(len(r['ctx']) for r in WF); NTURN_c=sum(len(r['ctx']) for r in rows)
INSTR=300   # tokens of the self-cap instruction, carried on every turn of every agent

def soft(r, cap, E, H, p, rnd, recheck=True):
    """agent is TOLD to stop at `cap`; complies with prob p at each check."""
    C=r['ctx']; O=r['out']; n=len(C)
    base=C[0]+H; omed=st.median(O) if O else 300
    total=0.0; shift=0.0; k=0; since=0; nseg=0; complied_once=False
    while k<n:
        total += C[k]+shift + O[k]
        k+=1; since+=1
        if since>=cap and k<n:
            stop = (rnd.random()<p) if (recheck or not complied_once) else False
            if not recheck and complied_once is False and stop: pass
            if stop:
                nseg+=1
                for j in range(E): total += base + j*D_WARM + omed
                shift = base + E*D_WARM - C[k-1]
                since=0; complied_once=True
            else:
                since=0 if recheck else -10**9   # recheck every `cap` turns, or never again
    return total, nseg

def curve(sel, B0, NT, cap, E, H, ps, M=200, recheck=True):
    out=[]
    for p in ps:
        rnd=random.Random(12345)
        acc=0.0
        for _ in range(M):
            acc+=sum(soft(r,cap,E,H,p,rnd,recheck)[0] for r in sel)
        exp=acc/M + INSTR*NT
        out.append((p,(B0-exp)/B0))
    return out

print("Модель: агент ИНСТРУКТИРОВАН остановиться на CAP и записать handoff (E=7, H=6k);")
print("подчиняется с вероятностью p на каждой проверке. Плюс налог самой инструкции: 300 ток/ход.\n")
for cap,E in ((30,7),(25,7),(40,7),(30,9)):
    for mode,rc in (('перепроверка каждые CAP ходов',True),('один шанс на агента',False)):
        w=curve(WF,B0w,NTURN_w,cap,E,6000,[0.1,0.25,0.5,0.75,0.9,1.0],M=120,recheck=rc)
        c=curve(rows,B0c,NTURN_c,cap,E,6000,[0.1,0.25,0.5,0.75,0.9,1.0],M=40,recheck=rc)
        print(f"CAP={cap} E={E}  [{mode}]")
        print("   p     " + ''.join(f"{p:>8.0%}" for p,_ in w))
        print("   run   " + ''.join(f"{v:>8.1%}" for _,v in w))
        print("   corpus" + ''.join(f"{v:>8.1%}" for _,v in c))
    print()
# p needed for >=10%
print("Минимальное p для экономии >=10 %:")
for cap,E in ((25,7),(30,7),(40,7)):
    for nm,sel,B0,NT,M in (('прогон',WF,B0w,NTURN_w,120),('корпус',rows,B0c,NTURN_c,40)):
        lo=None
        for p in [i/100 for i in range(5,101,5)]:
            v=curve(sel,B0,NT,cap,E,6000,[p],M=M)[0][1]
            if v>=0.10: lo=p; break
        print(f"   CAP={cap} {nm}: p* = {lo:.0%}" if lo else f"   CAP={cap} {nm}: недостижимо")
