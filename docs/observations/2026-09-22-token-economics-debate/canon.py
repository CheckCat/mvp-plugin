import sys,glob,os; sys.path.insert(0,'.')
from agents_c import *
def decomp(files,label,verbose=True):
    # exact, from observed usage fields only
    A={'1 билет: ПЕРВАЯ запись в кеш (cache write, 1 раз на агента)':0,
       '1b билет: прочитан из кеша СОСЕДНЕГО агента (cache read, ход 1)':0,
       '2 билет: перечитывание своим же агентом (cache read, ходы 2..n)':0,
       '3 наросшее: первое попадание в контекст (cache write + base in)':0,
       '4 наросшее: ПЕРЕЧИТЫВАНИЕ (cache read)':0,
       '5 output':0}
    K=list(A)
    nag=0; nturn=0
    for f in files:
        s=series(f)
        if not s: continue
        nag+=1; nturn+=len(s)
        C=[v[0]+v[1]+v[2]+v[3] for _,_,v in s]
        P=C[0]
        for i,(_,_,v) in enumerate(s):
            bi,cw5,cw1,cr,out=v
            cw=cw5+cw1
            A[K[5]]+=out
            if i==0:
                A[K[0]]+=cw+bi; A[K[1]]+=cr
            else:
                tick=min(cr,P); A[K[2]]+=tick; A[K[3+1]]+=cr-tick
                A[K[3]]+=cw+bi
    T=sum(A.values())
    if verbose:
        print('=== %s — %d агентов, %d ходов, %.2fM токенов'%(label,nag,nturn,T/1e6))
        for k in K: print('   %-62s %9.2fM  %5.1f%%'%(k,A[k]/1e6,100*A[k]/T))
        rr=A[K[1]]+A[K[2]]+A[K[4]]
        print('   --- ПЕРЕЧИТЫВАНИЕ ВСЕГО (1b+2+4) %.2fM = %.1f%% | впервые в контексте (1+3) %.2fM = %.1f%% | output %.1f%%'%(rr/1e6,100*rr/T,(A[K[0]]+A[K[3]])/1e6,100*(A[K[0]]+A[K[3]])/T,100*A[K[5]]/T))
        print()
    return A,T,K
