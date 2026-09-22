import e_scan as E, re, json, os, pickle, collections

SUBST = ('Edit','Write','NotebookEdit','MultiEdit')

def classify(fu):
    m = re.search(r'agents/([a-z\-]+)\.md', fu)
    role = m.group(1) if m else None
    task = None
    m2 = re.search(r'TASK_ID=(\d+)', fu)
    if m2: task = m2.group(1)
    else:
        m3 = re.search(r'\b(?:validate-task|review-package|save-review)\.sh"?\s+"?(\d+)', fu)
        if m3: task = m3.group(1)
    if role is None:
        if 'plan-io' in fu: role='tool:plan-io'
        elif re.search(r'\bgit\b', fu[:200]): role='tool:git'
        elif 'apply-patches' in fu: role='tool:apply-patches'
        else: role='tool:other'
    return role, task

rows=[]
for proj in ('vireo','glotok','trellis'):
    for p in E.wf_agents(proj):
        fu = E.first_user(p)
        role, task = classify(fu)
        T = E.turns(p)
        if not T: continue
        wf = re.search(r'/workflows/(wf_[^/]+)/', p).group(1)
        rec = dict(proj=proj, path=p, wf=wf, agent=os.path.basename(p), role=role, task=task,
                   n=len(T), fu_len=len(fu),
                   ctx=[t['ctx'] for t in T], tot=[t['tot'] for t in T],
                   out=[t['vals'][4] for t in T],
                   res=[t['res_chars'] for t in T],
                   tools=[[(n,i) for n,i,_ in t['tools']] for t in T])
        rows.append(rec)
pickle.dump(rows, open('e_wf.pkl','wb'))
print(len(rows), collections.Counter(r['role'] for r in rows).most_common())
