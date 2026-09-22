import pickle, statistics as st, collections
exec(open('e_cap.py').read().split("ALL=[r for r in rows]")[0])
WF=[r for r in rows if r['wf']=='wf_4d14cdc2-05c']
def tot(sel,cap,E,H): return sum(replay(r,cap,E,H,True)[0] for r in sel)
def segs(sel,cap,E,H): return sum(replay(r,cap,E,H,True)[1] for r in sel)
B0w=sum(agent_cost(r) for r in WF); B0c=sum(agent_cost(r) for r in rows)
print(f"baseline run {B0w/1e6:.2f}M   corpus {B0c/1e6:.1f}M\n")

print("### A. Проверка: воспроизводится ли '+9.0% убытка' verdict-3 (E=13 И H=60k одновременно)")
for cap,H in ((30,60000),(40,60000),(30,6000),(40,6000),(30,2000),(40,2000)):
    tw=tot(WF,cap,13,H); tc=tot(rows,cap,13,H)
    print(f"  CAP={cap} E=13 H={H//1000:2d}k: run {(B0w-tw)/B0w:+7.1%} ({(B0w-tw)/1e6:+6.2f}M)   corpus {(B0c-tc)/B0c:+7.1%}")
print("\n  контроль двойного счёта: токены, сожжённые разогревом ОДНОГО шва при E=13, H=6k:")
base=14000+6000
print(f"    Σ(base + j*2200), j=0..12 = {sum(base+j*2200 for j in range(13)):,}  <- это и есть измеренные ~397k D")

print("\n### B. Кривая ЖЁСТКОГО BREAK (handoff-файла нет; H=2k — только недописанный отчёт на диске)")
print(f"{'CAP':>4} | " + ' | '.join(f"E={e}".center(17) for e in (9,11,12,13)))
for cap in (20,25,30,40,50):
    cells=[]
    for e in (9,11,12,13):
        if cap-e<2: cells.append('      n/a        '); continue
        tw=tot(WF,cap,e,2000); tc=tot(rows,cap,e,2000)
        cells.append(f"{(B0w-tw)/B0w:+6.1%} / {(B0c-tc)/B0c:+6.1%}")
    print(f"{cap:>4} | " + ' | '.join(cells))
print("   (в каждой ячейке: % прогона wf_4d14cdc2 / % workflow-корпуса)")

print("\n### C. Цена park'а: q — доля швов, оборачивающихся park'ом (371k выброшенной работы)")
for cap in (25,30,40):
    for e in (11,13):
        ns_w=segs(WF,cap,e,2000); ns_c=segs(rows,cap,e,2000)
        sw=B0w-tot(WF,cap,e,2000); sc=B0c-tot(rows,cap,e,2000)
        qw=sw/(ns_w*371000) if ns_w else float('inf')
        qc=sc/(ns_c*371000) if ns_c else float('inf')
        print(f"  CAP={cap} E={e}: швов {ns_w:3d}/{ns_c:4d}; экономия {sw/1e6:5.2f}M/{sc/1e6:6.1f}M; "
              f"break-even q = {min(qw,1):.0%} (run) / {min(qc,1):.0%} (corpus)")
