import e_scan as E, os, glob, json, collections
BASE=os.path.expanduser('~/.claude/projects')
PROJ=['-Users-vadim-Documents-Pet-vireo','-Users-vadim-Documents-Pet-glotok','-Users-vadim-Documents-Pet-trellis']
SUBST=('Edit','Write','NotebookEdit','MultiEdit')
events=[]
files=[]
for p in PROJ:
    files += sorted(glob.glob(os.path.join(BASE,p,'*.jsonl')))          # main loops
    files += sorted(glob.glob(os.path.join(BASE,p,'*/subagents/agent-*.jsonl')))
print('files',len(files))
for f in files:
    try: T=E.turns(f)
    except Exception as e: continue
    if len(T)<20: continue
    for i in range(1,len(T)):
        prev=T[i-1]['ctx']; cur=T[i]['ctx']
        if prev>60000 and cur < prev*0.6:
            events.append((f,i,len(T),prev,cur))
for e in events:
    print(f"{os.path.basename(e[0])[:40]:42s} turn {e[1]+1:4d}/{e[2]:4d}  ctx {e[3]:8d} -> {e[4]:8d}  ({100*e[4]/e[3]:.0f}%)")
print('total drop events:',len(events))
json.dump([[e[0],e[1],e[2],e[3],e[4]] for e in events], open('e_compacts.json','w'))
