import pickle, json, re, collections, statistics as st
rows=pickle.load(open('e_wf.pkl','rb'))
fu=json.load(open('e_fu.json'))
SUBST=('Edit','Write','NotebookEdit','MultiEdit')
PLUG=re.compile(r'(plugins/cache/mvp|mvp-plugin/|skills/build/agents/)')
def firstsub(r):
    for i,tl in enumerate(r['tools'],1):
        if any(n in SUBST for n,_ in tl): return i
    return None
def tfiles(tl):
    s=set()
    for n,i in tl:
        if not isinstance(i,dict): continue
        if n in ('Read','Edit','Write','NotebookEdit','NotebookRead'):
            p=i.get('file_path');  s.add(str(p)) if p else None
        elif n=='Bash':
            for m in re.findall(r'[\w./~-]*/[\w./-]+\.\w+', str(i.get('command') or '')): s.add(m)
        elif n in ('Grep','Glob'):
            p=i.get('path');  s.add(str(p)) if p else None
    return s
def allfiles(tools):
    s=set()
    for tl in tools: s|=tfiles(tl)
    return s
byt=collections.defaultdict(list)
for r in rows: byt[(r['proj'],r['wf'],r['task'],r['role'])].append(r)

def run(label, pairs, cap=None):
    recs=[]
    for r,pred in pairs:
        f=firstsub(r)
        if f is None: continue
        predtools = pred['tools'][:cap] if (pred and cap) else (pred['tools'] if pred else [])
        pf=allfiles(predtools)
        dupT=newT=plugT=noneT=0
        for tl in r['tools'][:f-1]:
            fs=tfiles(tl)
            if any(PLUG.search(x) for x in fs): plugT+=1; continue
            if not fs: noneT+=1; continue
            if fs & pf: dupT+=1
            else: newT+=1
        recs.append(dict(pre=f-1,dupT=dupT,newT=newT,plugT=plugT,noneT=noneT,
                         toks_pre=sum(r['tot'][:f-1]), perturn=sum(r['tot'][:f-1])/max(1,f-1),
                         plen=len(fu[r['agent']])))
    if not recs: return
    print(f"## {label}  n={len(recs)}")
    for k in ('pre','plugT','dupT','newT','noneT','toks_pre','perturn','plen'):
        v=sorted(x[k] for x in recs)
        print(f"   {k:9s} med={st.median(v):>9.1f} mean={st.mean(v):>9.1f}  p25={v[len(v)//4]:>9.1f} p75={v[3*len(v)//4]:>9.1f}")
    tot=sum(x['pre'] for x in recs)
    print(f"   pooled: plugin/handoff-read {sum(x['plugT'] for x in recs)/tot:.0%} | duplicate-of-predecessor {sum(x['dupT'] for x in recs)/tot:.0%} | new-ground {sum(x['newT'] for x in recs)/tot:.0%} | no-file {sum(x['noneT'] for x in recs)/tot:.0%}")
    # E estimate = plug + dup turns
    e=[x['plugT']+x['dupT'] for x in recs]
    print(f"   E_reorient (plug+dup turns): med={st.median(e):.1f} mean={st.mean(e):.2f} p25={sorted(e)[len(e)//4]} p75={sorted(e)[3*len(e)//4]}")
    return recs

retry=[]
for r in rows:
    if r['role']=='implementer' and 'This is a RETRY' in fu[r['agent']]:
        peers=[x for x in byt[(r['proj'],r['wf'],r['task'],'implementer')] if x is not r]
        retry.append((r, max(peers,key=lambda p:p['n']) if peers else None))
fixp=[(r, max(byt[(r['proj'],r['wf'],r['task'],'implementer')],key=lambda p:p['n']) if byt[(r['proj'],r['wf'],r['task'],'implementer')] else None) for r in rows if r['role']=='fix']
cold=[(r,None) for r in rows if r['role']=='implementer' and 'This is a RETRY' not in fu[r['agent']]]
a=run('RETRY implementer (predecessor = full first attempt)', retry)
b=run('RETRY implementer (predecessor truncated to first 30 turns)', retry, cap=30)
c=run('FIX agent (predecessor = task implementer)', fixp)
d=run('COLD implementer (control, no predecessor)', cold)
