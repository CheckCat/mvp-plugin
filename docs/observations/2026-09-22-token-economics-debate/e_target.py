import pickle, json, math, statistics as st, collections, itertools
exec(open('e_cap.py').read().split("ALL=[r for r in rows]")[0])
TC={(t['proj'],t['id']):t for t in json.load(open('d_taskcost.json'))}
byt=collections.defaultdict(list)
for r in rows:
    if r['task']: byt[(r['proj'],r['task'].zfill(3))].append(r)
keys=[k for k in TC if k in byt]
print('joined tasks:',len(keys),'of',len(TC))

# ---- predictor: log(n_req of task) from plan-only fields, leave-one-out ----
cc=sorted({TC[k]['cclass'] for k in keys})
def feats(t, use):
    v=[1.0]
    if 'deps' in use: v.append(t['deps'])
    if 'files' in use: v.append(t['files'])
    if 'est' in use: v.append(math.log(max(t['est'],1)))
    if 'level' in use: v.append(t['level'])
    if 'cc' in use: v += [1.0 if t['cclass']==c else 0.0 for c in cc[1:]]
    return v
def ols(X,y):
    n=len(X[0]); XtX=[[sum(X[r][i]*X[r][j] for r in range(len(X))) for j in range(n)] for i in range(n)]
    Xty=[sum(X[r][i]*y[r] for r in range(len(X))) for i in range(n)]
    # gaussian elim with ridge
    for i in range(n): XtX[i][i]+=1e-6
    M=[row[:]+[Xty[i]] for i,row in enumerate(XtX)]
    for i in range(n):
        p=max(range(i,n), key=lambda r:abs(M[r][i]))
        M[i],M[p]=M[p],M[i]
        if abs(M[i][i])<1e-12: continue
        for r in range(n):
            if r!=i:
                f=M[r][i]/M[i][i]
                for c2 in range(i,n+1): M[r][c2]-=f*M[i][c2]
    return [M[i][n]/M[i][i] if abs(M[i][i])>1e-12 else 0.0 for i in range(n)]

def loo(use, target='n_req'):
    y=[math.log(max(TC[k][target],1)) for k in keys]
    X=[feats(TC[k],use) for k in keys]
    # within-project centering of y (as D did)
    pm=collections.defaultdict(list)
    for k,yy in zip(keys,y): pm[k[0]].append(yy)
    mu={p:st.mean(v) for p,v in pm.items()}
    yz=[yy-mu[k[0]] for k,yy in zip(keys,y)]
    pred=[]
    for i in range(len(keys)):
        Xi=[X[j] for j in range(len(keys)) if j!=i]; yi=[yz[j] for j in range(len(keys)) if j!=i]
        b=ols(Xi,yi); pred.append(sum(a*c for a,c in zip(b,X[i])))
    ssr=sum((a-b)**2 for a,b in zip(yz,pred)); sst=sum((a-st.mean(yz))**2 for a in yz)
    # in-sample
    b=ols(X,yz); ins=[sum(a*c for a,c in zip(b,x)) for x in X]
    r2in=1-sum((a-b2)**2 for a,b2 in zip(yz,ins))/sst
    # spearman of pred vs actual
    def rank(v):
        s=sorted(range(len(v)), key=lambda i:v[i]); r=[0]*len(v)
        for i,j in enumerate(s): r[j]=i
        return r
    ra,rb=rank(yz),rank(pred)
    n=len(ra); rho=1-6*sum((a-b3)**2 for a,b3 in zip(ra,rb))/(n*(n*n-1))
    return dict(use=use,target=target,R2_in=r2in,R2_loo=1-ssr/sst,rho_loo=rho,pred=pred,actual=yz)

print("\n## Predictor quality (within-project z of log target), leave-one-out")
print(f"{'features':28s} {'target':8s} {'R2 in-sample':>13s} {'R2 LOO':>9s} {'rho LOO':>9s}")
best=None
for use in (('deps',),('files',),('est',),('deps','files'),('deps','files','cc'),
            ('deps','files','est'),('deps','files','est','level','cc')):
    for tgt in ('n_req','tot'):
        m=loo(use,tgt)
        print(f"{'+'.join(use):28s} {tgt:8s} {m['R2_in']:13.3f} {m['R2_loo']:9.3f} {m['rho_loo']:9.3f}")
        if tgt=='tot' and (best is None or m['R2_loo']>best['R2_loo']): best=m
print('\nbest for targeting:',best['use'],'R2_loo=%.3f rho=%.3f'%(best['R2_loo'],best['rho_loo']))
pickle.dump({'keys':keys,'best':{k:v for k,v in best.items()}}, open('e_pred.pkl','wb'))
