import pickle, json, re, collections, statistics as st
rows=pickle.load(open('e_wf.pkl','rb'))
fu=json.load(open('e_fu.json'))
SUBST=('Edit','Write','NotebookEdit','MultiEdit')
PLUG=re.compile(r'(plugins/cache/mvp|mvp-plugin/|skills/build/agents/)')
STATE=re.compile(r'(/\.mvp/|\.claude/state/)')

def firstsub(r):
    for i,tl in enumerate(r['tools'],1):
        if any(n in SUBST for n,_ in tl): return i
    return None

def files_touched(tools):
    s=set()
    for tl in tools:
        for n,i in tl:
            if not isinstance(i,dict): continue
            if n in ('Read','Edit','Write','NotebookEdit','NotebookRead'):
                p=i.get('file_path')
                if p: s.add(str(p))
            elif n=='Bash':
                c=str(i.get('command') or '')
                for m in re.findall(r'[\w./~-]*/[\w./-]+\.\w+', c): s.add(m)
    return s

def cat_turn(tl):
    """H=handoff/instruction, S=state/report file, G=git, T=test/build, X=explore/other, F=repo file read"""
    c=set()
    for n,i in tl:
        if not isinstance(i,dict): i={}
        if n in ('Read','NotebookRead'):
            p=str(i.get('file_path') or '')
            c.add('H' if PLUG.search(p) else ('S' if STATE.search(p) else 'F'))
        elif n in ('Grep','Glob'): c.add('X')
        elif n=='Bash':
            cm=str(i.get('command') or '')
            if PLUG.search(cm): c.add('H')
            elif re.search(r'\bgit\b', cm): c.add('G')
            elif re.search(r'(pytest|npm |uv run|ci-mirror|ruff|vitest|jest|tsc|make |cargo|node -v)', cm): c.add('T')
            elif STATE.search(cm): c.add('S')
            else: c.add('X')
        else: c.add('X')
    return c

def report(label, pairs):
    """pairs: list of (cont_rec, pred_rec_or_None)"""
    rows_=[]
    for r,pred in pairs:
        f=firstsub(r) or r['n']
        pre=r['tools'][:f-1]
        cats=[cat_turn(tl) for tl in pre]
        cnt=collections.Counter()
        for c in cats:
            for k in c: cnt[k]+=1./len(c)
        predf = files_touched(pred['tools']) if pred else set()
        pf = files_touched(pre)
        dup = len([x for x in pf if x in predf])
        rows_.append(dict(agent=r['agent'],n=r['n'],first=f,pre=f-1,
             H=cnt['H'],S=cnt['S'],G=cnt['G'],T=cnt['T'],F=cnt['F'],X=cnt['X'],
             nfiles=len(pf),dup=dup,
             toks_pre=sum(r['tot'][:f-1]), toks_tot=sum(r['tot']),
             ctx1=r['ctx'][0], ctx_at_first=r['ctx'][f-1]))
    print('##',label,'n=',len(rows_))
    for k in ('pre','H','S','G','T','F','X','nfiles','dup','toks_pre','toks_tot','ctx1','ctx_at_first'):
        v=sorted(x[k] for x in rows_)
        print(f"   {k:13s} med={st.median(v):>9.1f} mean={st.mean(v):>9.1f} p10={v[int(.1*len(v))]:>9.1f} p90={v[min(len(v)-1,int(.9*len(v)))]:>9.1f}")
    if any(x['nfiles'] for x in rows_):
        tot_f=sum(x['nfiles'] for x in rows_); tot_d=sum(x['dup'] for x in rows_)
        print(f"   dup files share (pooled): {tot_d}/{tot_f} = {100*tot_d/max(1,tot_f):.0f}%")
    return rows_

byt=collections.defaultdict(list)
for r in rows:
    byt[(r['proj'],r['wf'],r['task'],r['role'])].append(r)

# 1. RETRY implementers paired with first attempt
retry=[]
for r in rows:
    if r['role']=='implementer' and 'This is a RETRY' in fu[r['agent']]:
        peers=[x for x in byt[(r['proj'],r['wf'],r['task'],'implementer')] if x is not r]
        pred = max(peers, key=lambda p:p['n']) if peers else None
        retry.append((r,pred))
R1=report('RETRY implementer (continuation, predecessor = first attempt)', retry)

# 2. fix agents paired with task implementer
fixp=[]
for r in rows:
    if r['role']=='fix':
        peers=byt[(r['proj'],r['wf'],r['task'],'implementer')]
        pred = max(peers, key=lambda p:p['n']) if peers else None
        fixp.append((r,pred))
R2=report('FIX agent (continuation by findings)', fixp)

# 3. control: first-attempt implementers (cold start, no predecessor)
cold=[(r,None) for r in rows if r['role']=='implementer' and 'This is a RETRY' not in fu[r['agent']]]
R3=report('IMPLEMENTER cold start (control: no predecessor)', cold)
pickle.dump({'retry':R1,'fix':R2,'cold':R3}, open('e_warm.pkl','wb'))
