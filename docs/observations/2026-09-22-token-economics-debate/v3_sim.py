import sys,pickle
sys.path.insert(0,'.')
from n1 import run as n1run
rows=pickle.load(open('v3_rows.pkl','rb'))
def agg(R,T):
    A=dict(tokens=0,cw=0,cr=0,units=0,clears=0)
    for r in R:
        x=n1run(r['ctx'],T=T)
        for k in A: A[k]+=x[k]
    return A
print('%-8s %-8s %10s %10s %10s %8s %8s %7s'%('pop','T','tokens','cw','units','dtok','dprice','clears'))
for pop in ('main','sub','wf','ALL'):
    R=[r for r in rows if pop=='ALL' or r['pop']==pop]
    base=agg(R,None)
    for T in (None,250000,200000,150000,100000):
        a=agg(R,T)
        dt=100*(a['tokens']-base['tokens'])/base['tokens']
        dp=100*(a['units']-base['units'])/base['units']
        print('%-8s %-8s %9.1fM %9.1fM %9.1fM %7.1f%% %7.1f%% %7d'%(pop,T or 'base',a['tokens']/1e6,a['cw']/1e6,a['units']/1e6,dt,dp,a['clears']))
    print()
