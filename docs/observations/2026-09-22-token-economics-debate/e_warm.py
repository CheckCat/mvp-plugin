import pickle, re, json, statistics as st, collections
rows = pickle.load(open('e_wf.pkl','rb'))
SUBST = ('Edit','Write','NotebookEdit','MultiEdit')

def paths_of(name, inp):
    if not isinstance(inp, dict): return []
    if name in ('Read','Edit','Write','NotebookEdit','NotebookRead'):
        return [str(inp.get('file_path') or '')]
    if name=='Bash':
        c=str(inp.get('command') or '')
        return re.findall(r'[\w./~-]*/[\w./-]+', c)
    if name in ('Grep','Glob'):
        return [str(inp.get('path') or '')]
    return []

HANDOFF_PAT = re.compile(r'(plugins/cache/mvp|skills/build/agents/|/\.mvp/|\.claude/state/|reports/task-|review/task-|handoff)')
EXPLORE = ('Grep','Glob','Bash')

def warm(rec):
    """returns dict with idx of first substantive action (1-based), and per-turn class"""
    first=None
    for i,tl in enumerate(rec['tools'],1):
        if any(n in SUBST for n,_ in tl): first=i; break
    return first

def turn_class(tl):
    """H = handoff/instruction material, R = repo re-acquisition/exploration, N = none"""
    cls=set()
    for n,inp in tl:
        ps = paths_of(n,inp)
        h = any(HANDOFF_PAT.search(p) for p in ps if p)
        if n=='Read':
            cls.add('H' if h else 'Rread')
        elif n in ('Grep','Glob'):
            cls.add('Rexp')
        elif n=='Bash':
            c=str(inp.get('command') or '')
            if h and re.match(r'\s*(cat|head|sed|grep -n)', c): cls.add('H')
            elif re.search(r'\bgit\b', c): cls.add('Rgit')
            elif re.search(r'(npm|pytest|ci-mirror|make|cargo|vitest|jest|tsc|ruff)', c): cls.add('Rtest')
            else: cls.add('Rexp')
        else: cls.add('other')
    return cls

def summarize(role):
    sel=[r for r in rows if r['role']==role]
    out=[]
    for r in sel:
        f=warm(r)
        if f is None: continue
        pre=r['tools'][:f-1]
        classes=[turn_class(tl) for tl in pre]
        nH=sum(1 for c in classes if 'H' in c and len(c)==1)
        nR=sum(1 for c in classes if 'H' not in c)
        nMix=len(classes)-nH-nR
        toks=sum(r['tot'][:f])          # tokens up to & incl. the turn that makes first edit
        toks_pre=sum(r['tot'][:f-1])
        out.append(dict(agent=r['agent'],proj=r['proj'],task=r['task'],n=r['n'],first=f,
                        nH=nH,nR=nR,nMix=nMix,toks=toks,toks_pre=toks_pre,
                        tot=sum(r['tot']), ctx1=r['ctx'][0]))
    return out

for role in ('implementer','fix'):
    o=summarize(role)
    print('==',role,'n=',len(o),'/',sum(1 for r in rows if r['role']==role))
    for k in ('first','nH','nR','toks','toks_pre','n','tot'):
        v=sorted(x[k] for x in o)
        print(f"  {k:9s} med={st.median(v):>10.0f} mean={st.mean(v):>10.0f} p10={v[int(.1*len(v))]:>10.0f} p90={v[int(.9*len(v))]:>10.0f} max={v[-1]:>10.0f}")
    print('  share of agent tokens spent pre-first-edit: med %.1f%%'%(100*st.median([x['toks']/x['tot'] for x in o])))
