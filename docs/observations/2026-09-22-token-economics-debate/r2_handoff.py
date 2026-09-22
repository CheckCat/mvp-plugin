import json,os,glob,re,statistics,collections
ROOT=os.path.expanduser("~/.claude/projects")
SL={"vireo":"-Users-vadim-Documents-Pet-vireo","glotok":"-Users-vadim-Documents-Pet-glotok","trellis":"-Users-vadim-Documents-Pet-trellis"}
A=json.load(open("d_wfagents.json"))
idx={}
for proj,slug in SL.items():
    for f in glob.glob(os.path.join(ROOT,slug,"*","subagents","workflows","wf_*","agent-*.jsonl")):
        idx[(proj,os.path.basename(os.path.dirname(f)),os.path.basename(f))]=f
def turns(path):
    """список ходов ассистента: (requestId, [tool names], ctx, out)"""
    per={}; order=[]
    for line in open(path,errors="replace"):
        if '"usage"' not in line and '"tool_use"' not in line: continue
        try: d=json.loads(line)
        except: continue
        m=d.get("message") or {}
        if m.get("role")!="assistant": continue
        rid=d.get("requestId") or d.get("uuid")
        u=m.get("usage") or {}
        cc=u.get("cache_creation") or {}
        cw=(cc.get("ephemeral_5m_input_tokens") or 0)+(cc.get("ephemeral_1h_input_tokens") or 0) or (u.get("cache_creation_input_tokens") or 0)
        ctx=(u.get("input_tokens") or 0)+cw+(u.get("cache_read_input_tokens") or 0)
        tools=[c.get("name") for c in (m.get("content") or []) if isinstance(c,dict) and c.get("type")=="tool_use"]
        if rid not in per: per[rid]=[set(),ctx,u.get("output_tokens") or 0]; order.append(rid)
        per[rid][0].update(t for t in tools if t)
        per[rid][1]=max(per[rid][1],ctx); per[rid][2]=max(per[rid][2],u.get("output_tokens") or 0)
    return [(r,per[r][0],per[r][1],per[r][2]) for r in order]
WRITE={"Edit","Write","NotebookEdit","MultiEdit","apply_patch"}
res=collections.defaultdict(list)
for x in A:
    if x["role"] not in ("prompt:implementer","prompt:fix","prompt:reviewer","prompt:re-review"): continue
    p=idx.get((x["proj"],x["wf"],x["agent"]))
    if not p: continue
    ts=turns(p)
    if not ts: continue
    k=next((i for i,t in enumerate(ts) if t[1]&WRITE), None)
    pre=sum(t[2] for t in ts[:k]) if k is not None else sum(t[2] for t in ts)
    res[x["role"]].append(dict(n=len(ts),first_write=k,pre=pre,tot=sum(t[2] for t in ts)))
print("## Реальная цена «переориентации»: сколько ходов и токенов агент тратит ДО первой правки файла")
print(f"{'роль':22s} {'n':>4s} {'медиана ходов':>13s} {'мед. ход 1-й правки':>20s} {'мед. токенов до неё':>20s} {'доля от агента':>15s}")
for r,v in res.items():
    w=[a for a in v if a["first_write"] is not None]
    if not w: 
        print(f"{r:22s} {len(v):4d}  (правок нет: чисто читающая роль, медиана ходов {statistics.median([a['n'] for a in v]):.0f})")
        continue
    print(f"{r:22s} {len(w):4d} {statistics.median([a['n'] for a in w]):13.0f} {statistics.median([a['first_write'] for a in w])+1:20.0f} {statistics.median([a['pre'] for a in w]):20,.0f} {statistics.median([a['pre']/a['tot'] for a in w]):14.1%}")
print()
# fix = естественный эксперимент «продолжение по handoff-файлу»
fx=[a for a in res["prompt:fix"] if a["first_write"] is not None]
im=[a for a in res["prompt:implementer"] if a["first_write"] is not None]
print("## fix-агент = продолжение той же задачи по внешнему handoff (findings ревью). Его разогрев:")
print(f"  fix:         медиана {statistics.median([a['first_write'] for a in fx])+1:.0f} ходов и {statistics.median([a['pre'] for a in fx]):,.0f} токенов до первой правки (n={len(fx)})")
print(f"  implementer: медиана {statistics.median([a['first_write'] for a in im])+1:.0f} ходов и {statistics.median([a['pre'] for a in im]):,.0f} токенов до первой правки (n={len(im)})")
print(f"  => эмпирическая цена одной передачи состояния внутри задачи: E ≈ {statistics.median([a['first_write'] for a in fx])+1:.0f} ходов, ≈ {statistics.median([a['pre'] for a in fx]):,.0f} токенов")
json.dump({k:v for k,v in res.items()},open("r2_warmup.json","w"))
