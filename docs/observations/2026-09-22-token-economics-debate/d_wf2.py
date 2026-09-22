import json,os,glob,re,collections
ROOT=os.path.expanduser("~/.claude/projects")
SL={"vireo":"-Users-vadim-Documents-Pet-vireo","glotok":"-Users-vadim-Documents-Pet-glotok","trellis":"-Users-vadim-Documents-Pet-trellis"}
def per_request(path):
    per={}; order=[]
    for line in open(path,errors="replace"):
        if '"usage"' not in line: continue
        try: d=json.loads(line)
        except: continue
        m=d.get("message") or {}; u=m.get("usage")
        if not isinstance(u,dict): continue
        rid=d.get("requestId") or d.get("uuid")
        cc=u.get("cache_creation") or {}
        cw5=cc.get("ephemeral_5m_input_tokens"); cw1=cc.get("ephemeral_1h_input_tokens")
        if cw5 is None and cw1 is None: cw5,cw1=u.get("cache_creation_input_tokens",0) or 0,0
        v=[u.get("input_tokens",0) or 0,(cw5 or 0)+(cw1 or 0),u.get("cache_read_input_tokens",0) or 0,u.get("output_tokens",0) or 0]
        if rid not in per: per[rid]=[m.get("model"),v]; order.append(rid)
        else: per[rid][1]=[max(a,b) for a,b in zip(per[rid][1],v)]
    return [(r,per[r][0],per[r][1]) for r in order]
def first_user(path):
    for line in open(path,errors="replace"):
        if '"type":"user"' not in line: continue
        try: d=json.loads(line)
        except: continue
        if d.get("type")!="user": continue
        c=(d.get("message") or {}).get("content")
        return c if isinstance(c,str) else json.dumps(c,ensure_ascii=False)
    return ""
RE_TID=re.compile(r"TASK_ID=([0-9]{3})")
RE_ROLE=re.compile(r"agents/([a-z\-]+)\.md")
RE_Q=re.compile(r'[\\"\'"]([0-9]{3})[\\"\'"]')
RE_TASKFILE=re.compile(r"task-([0-9]{3})")
LIBS=[("validate-task","validate"),("review-package","reviewpkg"),("save-review","save-review"),
      ("apply-patches","apply-patches"),("plan-io.mjs next","plan-next"),("plan-io.mjs complete","plan-complete"),
      ("plan-io.mjs ledger","ledger"),("plan-io.mjs","plan-io"),("finalize","finalize"),("git","git")]
out=[]
for proj,slug in SL.items():
    for f in glob.glob(os.path.join(ROOT,slug,"*","subagents","workflows","wf_*","agent-*.jsonl")):
        wf=os.path.basename(os.path.dirname(f)); fu=first_user(f)
        reqs=per_request(f)
        if not reqs: continue
        role=None; task=None
        m=RE_ROLE.search(fu)
        if m: role="prompt:"+m.group(1)
        m=RE_TID.search(fu)
        if m: task=m.group(1)
        if task is None:
            m=RE_TASKFILE.search(fu)
            if m: task=m.group(1)
        if task is None:
            m=RE_Q.search(fu)
            if m: task=m.group(1)
        if role is None:
            low=fu[:400]
            for pat,name in LIBS:
                if pat in low: role="tool:"+name; break
            else: role="tool:other"
        tot=[sum(r[2][i] for r in reqs) for i in range(4)]
        first=reqs[0][2]
        out.append(dict(proj=proj,wf=wf,agent=os.path.basename(f),task=task,role=role,
            model=reqs[0][1],n=len(reqs),i=tot[0],cw=tot[1],cr=tot[2],o=tot[3],
            f_i=first[0],f_cw=first[1],f_cr=first[2],fu=fu[:160]))
json.dump(out,open("d_wfagents.json","w"),ensure_ascii=False)
print("agents",len(out),"with task",sum(1 for x in out if x["task"]))
for r,c in collections.Counter(x["role"] for x in out).most_common(): print(f"  {r:22s} {c}")
