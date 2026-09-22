import e_scan as E, os, json, statistics as st, collections, re
SUBST=('Edit','Write','NotebookEdit','MultiEdit')
ev=json.load(open('e_compacts.json'))
ev=[e for e in ev if e[4]>1000]          # drop ctx==0 artifacts
print('genuine compaction events:', len(ev))
def brief(n,i):
    if not isinstance(i,dict): return n
    if n=='Bash': return 'Bash| '+str(i.get('command'))[:90]
    if n in ('Read','Edit','Write'): return n+'| '+str(i.get('file_path')).split('/')[-1]
    if n in ('Grep','Glob'): return n+'| '+str(i.get('pattern'))[:40]
    return n
cache={}
out=[]
for f,i,ntot,prev,cur in ev:
    if f not in cache: cache[f]=E.turns(f)
    T=cache[f]
    # baseline: median gap between consecutive substantive turns in this session
    subs=[k for k,t in enumerate(T) if any(n in SUBST for n,_,_ in t['tools'])]
    gaps=[b-a for a,b in zip(subs,subs[1:])] if len(subs)>1 else []
    nxt=None
    for k in range(i,len(T)):
        if any(n in SUBST for n,_,_ in T[k]['tools']): nxt=k; break
    if nxt is None: continue
    warm=nxt-i
    toks=sum(t['tot'] for t in T[i:nxt])
    cats=collections.Counter()
    lines=[]
    for k in range(i,min(nxt,i+14)):
        lines.append('; '.join(brief(n,x) for n,x,_ in T[k]['tools'])[:110] or '(text)')
    out.append(dict(f=os.path.basename(f)[:8],turn=i+1,warm=warm,toks=toks,
                    base_gap=st.median(gaps) if gaps else None, ctx=cur, lines=lines))
for o in out:
    print(f"--- {o['f']} @turn {o['turn']}  ctx_after={o['ctx']:,}  warm={o['warm']} turns  toks={o['toks']:,}  (session median inter-edit gap={o['base_gap']})")
    for j,l in enumerate(o['lines'],1): print(f"      {j:2d} {l}")
w=[o['warm'] for o in out]; t=[o['toks'] for o in out]
print('WARM turns: ', sorted(w), 'median', st.median(w))
print('WARM tokens:', [f'{x:,}' for x in sorted(t)], 'median', f'{st.median(t):,.0f}')
print('session median inter-edit gaps:', [o['base_gap'] for o in out])
