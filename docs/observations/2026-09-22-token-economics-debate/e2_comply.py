import e_scan as E, pickle, json, re, collections, statistics as st
rows=pickle.load(open('e_wf.pkl','rb'))
def final_text(path):
    last=''
    for line in open(path, errors='replace'):
        if '"type":"assistant"' not in line: continue
        try: d=json.loads(line)
        except: continue
        if d.get('type')!='assistant': continue
        c=(d.get('message') or {}).get('content')
        t=''
        if isinstance(c,list):
            t=''.join(b.get('text','') for b in c if isinstance(b,dict) and b.get('type')=='text')
        elif isinstance(c,str): t=c
        if t.strip(): last=t
    return last
CONTRACT={'implementer':r'STATUS:\s*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)',
          'fix':r'STATUS:\s*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)',
          'reviewer':r'VERDICT:\s*(approve|request-changes)',
          're-review':r'FINDINGS:',
          'validator':r'(PATCHES:|VERDICT:\s*(retry|park))'}
LINECAP={'re-review':15,'validator':15,'reviewer':None}
res=collections.defaultdict(lambda: dict(n=0,ok=0,lines=[],overcap=0))
for r in rows:
    if r['role'] not in CONTRACT: continue
    t=final_text(r['path'])
    d=res[r['role']]; d['n']+=1
    if re.search(CONTRACT[r['role']], t): d['ok']+=1
    nl=len([l for l in t.strip().split('\n') if l.strip()])
    d['lines'].append(nl)
    cap=LINECAP.get(r['role'])
    if cap and nl>cap: d['overcap']+=1
print("## Соблюдение выходного контракта (обязательная строка в финальном сообщении)")
for role,d in res.items():
    cap=LINECAP.get(role)
    extra=''
    if cap: extra=f"   | численный самосчётный лимит '≤{cap} строк': нарушен {d['overcap']}/{d['n']} = {d['overcap']/d['n']:.0%}  (медиана строк {st.median(d['lines']):.0f}, p90 {sorted(d['lines'])[int(.9*len(d['lines']))]})"
    print(f"  {role:12s} n={d['n']:3d}  контракт соблюдён {d['ok']:3d} = {d['ok']/d['n']:5.1%}{extra}")
# prohibition: git commit by implementers/fix (forbidden by _common.md)
bad=0; tot=0
for r in rows:
    if r['role'] not in ('implementer','fix'): continue
    tot+=1
    for tl in r['tools']:
        if any(n=='Bash' and isinstance(i,dict) and re.search(r'git\s+commit', str(i.get('command') or '')) for n,i in tl):
            bad+=1; break
print(f"\n## Соблюдение ЗАПРЕТА ('git commit запрещён' в _common.md): нарушили {bad}/{tot} = {bad/tot:.1%}")
