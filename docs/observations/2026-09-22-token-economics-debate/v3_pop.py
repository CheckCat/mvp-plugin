import sys,glob,os,json,pickle
sys.path.insert(0,'/private/tmp/claude-501/-Users-vadim-Documents-Pet-trellis/ffbe66c3-5d41-424f-b4eb-27417e32a7fc/scratchpad/debate')
from agents_c import agent_stats, meta
from n1 import run as n1run

SLUGS=('-Users-vadim-Documents-Pet-vireo','-Users-vadim-Documents-Pet-glotok','-Users-vadim-Documents-Pet-trellis')
pops={}
for slug in SLUGS:
    base=os.path.expanduser('~/.claude/projects/'+slug)
    pops.setdefault('main',[]).extend(glob.glob(base+'/*.jsonl'))
    pops.setdefault('sub',[]).extend(glob.glob(base+'/*/subagents/agent-*.jsonl'))
    pops.setdefault('wf',[]).extend(glob.glob(base+'/*/subagents/workflows/wf_*/agent-*.jsonl'))

rows=[]
for pop,files in pops.items():
    for f in files:
        st=agent_stats(f)
        if not st: continue
        st['pop']=pop
        st['meta']=meta(f) if pop!='main' else {}
        rows.append(st)
pickle.dump([{k:v for k,v in r.items()} for r in rows], open('v3_rows.pkl','wb'))
print('entities',len(rows))

def units(cw,cr,bi):
    return bi*1.0+cw*1.25+cr*0.1

tot_all=0
for pop in ('main','sub','wf'):
    R=[r for r in rows if r['pop']==pop]
    tok=sum(r['alltok'] for r in R)
    tot_all+=tok
print('TOTAL tokens %.1fM'%(tot_all/1e6))
print()
print('%-6s %6s %8s %10s %8s %8s %8s %8s'%('pop','n','turns','tokens','%tok','n>=150k','tok>=150k','%of_pop'))
for pop in ('main','sub','wf'):
    R=[r for r in rows if r['pop']==pop]
    tok=sum(r['alltok'] for r in R)
    turns=sum(r['n'] for r in R)
    big=[r for r in R if r['ctxmax']>=150000]
    bt=sum(r['alltok'] for r in big)
    print('%-6s %6d %8d %9.1fM %7.1f%% %8d %8.1fM %7.1f%%'%(pop,len(R),turns,tok/1e6,100*tok/tot_all,len(big),bt/1e6,100*bt/max(tok,1)))
