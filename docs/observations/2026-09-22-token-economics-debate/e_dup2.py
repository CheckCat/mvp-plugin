import pickle, json, re, collections, statistics as st
rows=pickle.load(open('e_wf.pkl','rb'))
fu=json.load(open('e_fu.json'))
SUBST=('Edit','Write','NotebookEdit','MultiEdit')
PLUG=re.compile(r'(plugins/cache/mvp|mvp-plugin/|skills/build/agents/)')
STATE=re.compile(r'(/\.mvp/|\.claude/state/)')
GITQ=re.compile(r'\bgit\s+(status|diff|log|show|stash list)')
def firstsub(r):
    for i,tl in enumerate(r['tools'],1):
        if any(n in SUBST for n,_ in tl): return i
    return None
def tfiles(tl):
    s=set()
    for n,i in tl:
        if not isinstance(i,dict): continue
        if n in ('Read','Edit','Write','NotebookEdit','NotebookRead'):
            p=i.get('file_path')
            if p: s.add(str(p))
        elif n=='Bash':
            for m in re.findall(r'[\w./~-]*/[\w./-]+\.\w+', str(i.get('command') or '')): s.add(m)
        elif n in ('Grep','Glob'):
            p=i.get('path')
            if p: s.add(str(p))
    return s
def allfiles(tools):
    s=set()
    for tl in tools: s|=tfiles(tl)
    return s
def cmds(tl): return ' ; '.join(str(i.get('command') or '') for n,i in tl if n=='Bash' and isinstance(i,dict))

def classify(tl, predfiles):
    fs=tfiles(tl); c=cmds(tl)
    if any(PLUG.search(x) for x in fs) or PLUG.search(c): return 'A_handoff_role'
    if any(STATE.search(x) for x in fs) or STATE.search(c): return 'A_handoff_state'
    if GITQ.search(c): return 'B_git_whatwasdone'
    if fs and (fs & predfiles): return 'B_reread_predecessor_file'
    if re.search(r'(pytest|npm |uv run|ci-mirror|ruff|vitest|jest|tsc|make |cargo)', c): return 'B_rerun_build'
    if fs: return 'C_new_ground'
    if re.search(r'\b(ls|find|tree|wc|which|pwd)\b', c): return 'B_relocate_tree'
    if not c and not fs: return 'D_text_only'
    return 'C_new_ground'

byt=collections.defaultdict(list)
for r in rows: byt[(r['proj'],r['wf'],r['task'],r['role'])].append(r)
def run(label, pairs, cap=None):
    per=[]; pool=collections.Counter()
    for r,pred in pairs:
        f=firstsub(r)
        if f is None: continue
        pt = (pred['tools'][:cap] if cap else pred['tools']) if pred else []
        pf = allfiles(pt)
        cc=collections.Counter(classify(tl,pf) for tl in r['tools'][:f-1])
        pool+=cc
        A=cc['A_handoff_role']+cc['A_handoff_state']
        B=cc['B_git_whatwasdone']+cc['B_reread_predecessor_file']+cc['B_rerun_build']+cc['B_relocate_tree']
        per.append(dict(pre=f-1,A=A,B=B,C=cc['C_new_ground'],D=cc['D_text_only'],
                        perturn=sum(r['tot'][:f-1])/max(1,f-1), toks=sum(r['tot'][:f-1])))
    tot=sum(pool.values())
    print(f"## {label}  n={len(per)}  turns pooled={tot}")
    for k,v in pool.most_common(): print(f"     {k:28s} {v:4d}  {100*v/tot:5.1f}%")
    for k in ('pre','A','B','C','D'):
        v=sorted(x[k] for x in per)
        print(f"   {k}: med={st.median(v):.1f} mean={st.mean(v):.2f} IQR={v[len(v)//4]}..{v[3*len(v)//4]}")
    e=[x['A']+x['B'] for x in per]
    pt=[x['perturn'] for x in per]
    print(f"   >>> E (A+B turns): med={st.median(e):.1f} mean={st.mean(e):.2f} IQR={sorted(e)[len(e)//4]}..{sorted(e)[3*len(e)//4]}  p90={sorted(e)[int(.9*len(e))]}")
    print(f"   >>> cost/turn during warmup: med={st.median(pt):,.0f}  => E_tokens med ~ {st.median(e)*st.median(pt):,.0f}")
    return per
retry=[]
for r in rows:
    if r['role']=='implementer' and 'This is a RETRY' in fu[r['agent']]:
        peers=[x for x in byt[(r['proj'],r['wf'],r['task'],'implementer')] if x is not r]
        retry.append((r, max(peers,key=lambda p:p['n']) if peers else None))
fixp=[(r, max(byt[(r['proj'],r['wf'],r['task'],'implementer')],key=lambda p:p['n']) if byt[(r['proj'],r['wf'],r['task'],'implementer')] else None) for r in rows if r['role']=='fix']
cold=[(r,None) for r in rows if r['role']=='implementer' and 'This is a RETRY' not in fu[r['agent']]]
run('RETRY implementer  (closest analogue of planned handoff)', retry)
run('RETRY implementer, predecessor truncated @30 turns', retry, cap=30)
run('FIX agent (continuation by findings)', fixp)
run('COLD implementer (control: fresh agent, no predecessor)', cold)
