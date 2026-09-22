import pickle, json, re, collections, statistics as st
rows=pickle.load(open('e_wf.pkl','rb'))
fu=json.load(open('e_fu.json'))
SUBST=('Edit','Write','NotebookEdit','MultiEdit')
def firstsub(r):
    for i,tl in enumerate(r['tools'],1):
        if any(n in SUBST for n,_ in tl): return i
    return None
def brief(n,i):
    if not isinstance(i,dict): return n
    if n=='Bash': return 'Bash| '+str(i.get('command'))[:110]
    if n in ('Read','Edit','Write'): return n+'| '+str(i.get('file_path'))
    if n in ('Grep','Glob'): return n+'| '+str(i.get('pattern'))[:50]+' '+str(i.get('path') or '')[:50]
    return n
byt=collections.defaultdict(list)
for r in rows:
    if r['role']=='implementer': byt[(r['proj'],r['wf'],r['task'])].append(r)
res=[]
for r in rows:
    if r['role']!='implementer': continue
    if 'This is a RETRY' not in fu[r['agent']]: continue
    peers=[x for x in byt[(r['proj'],r['wf'],r['task'])] if x is not r]
    f=firstsub(r)
    res.append((r,peers,f))
print('RETRY implementers:',len(res))
for r,peers,f in res:
    pf=[firstsub(p) for p in peers]
    print('='*100)
    print(f"{r['proj']} {r['wf']} task={r['task']} agent={r['agent'][:18]} n={r['n']} first_sub={f} tot={sum(r['tot']):,} prompt_len={len(fu[r['agent']]):,}")
    print(f"   first-attempt peers: n={[p['n'] for p in peers]} first_sub={pf} tot={[sum(p['tot']) for p in peers]}")
    for i,tl in enumerate(r['tools'][:(f or r['n'])],1):
        print(f"     {i:2d} ctx={r['ctx'][i-1]:7d} | " + '; '.join(brief(n,x) for n,x in tl)[:150])
