import json, os, glob, re, collections, sys

BASE = os.path.expanduser('~/.claude/projects')
PROJ = {'vireo':'-Users-vadim-Documents-Pet-vireo',
        'glotok':'-Users-vadim-Documents-Pet-glotok',
        'trellis':'-Users-vadim-Documents-Pet-trellis'}

def turns(path):
    """Return ordered list of turns.
    Each turn: dict(rid, vals[5], tools=[(name, input)], text=str)
    Dedup by requestId (max per field), preserving first-seen order.
    Also returns user/tool_result entries keyed by position."""
    order = []
    per = {}
    events = []   # chronological stream of ('assistant', rid) / ('result', tool_use_id, chars)
    for line in open(path, errors='replace'):
        if '"message"' not in line: continue
        try: d = json.loads(line)
        except: continue
        t = d.get('type')
        m = d.get('message') or {}
        if t == 'assistant':
            u = m.get('usage')
            if not isinstance(u, dict): continue
            rid = d.get('requestId') or d.get('uuid')
            cc = u.get('cache_creation') or {}
            cw5 = cc.get('ephemeral_5m_input_tokens'); cw1 = cc.get('ephemeral_1h_input_tokens')
            if cw5 is None and cw1 is None:
                cw5, cw1 = u.get('cache_creation_input_tokens',0) or 0, 0
            vals = [u.get('input_tokens',0) or 0, cw5 or 0, cw1 or 0,
                    u.get('cache_read_input_tokens',0) or 0, u.get('output_tokens',0) or 0]
            tools = []; text = []
            c = m.get('content')
            if isinstance(c, list):
                for b in c:
                    if not isinstance(b, dict): continue
                    if b.get('type') == 'tool_use':
                        tools.append((b.get('name'), b.get('input') or {}, b.get('id')))
                    elif b.get('type') == 'text':
                        text.append(b.get('text') or '')
            elif isinstance(c, str):
                text.append(c)
            if rid not in per:
                per[rid] = {'rid': rid, 'vals': vals, 'tools': tools, 'text': ''.join(text),
                            'model': m.get('model')}
                order.append(rid)
            else:
                p = per[rid]
                p['vals'] = [max(a,b) for a,b in zip(p['vals'], vals)]
                if tools and not p['tools']: p['tools'] = tools
                if len(''.join(text)) > len(p['text']): p['text'] = ''.join(text)
        elif t == 'user':
            c = m.get('content')
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get('type') == 'tool_result':
                        cc2 = b.get('content')
                        if isinstance(cc2, list):
                            s = sum(len(x.get('text','')) for x in cc2 if isinstance(x,dict))
                        else:
                            s = len(cc2 or '') if isinstance(cc2,str) else 0
                        events.append(('result', b.get('tool_use_id'), s))
    res = {tid: chars for (_k, tid, chars) in events}
    out = [per[r] for r in order]
    for t in out:
        t['ctx'] = t['vals'][0] + t['vals'][1] + t['vals'][2] + t['vals'][3]
        t['tot'] = sum(t['vals'])
        t['res_chars'] = sum(res.get(tid,0) for (_n,_i,tid) in t['tools'])
    return out

def first_user(path):
    for line in open(path, errors='replace'):
        if '"type":"user"' not in line and '"type": "user"' not in line: continue
        try: d = json.loads(line)
        except: continue
        if d.get('type') != 'user': continue
        m = d.get('message') or {}
        c = m.get('content')
        if isinstance(c, str): return c
        if isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get('type') == 'text':
                    return b.get('text') or ''
        return ''
    return ''

def meta(path):
    mp = path[:-6] + '.meta.json'
    if os.path.exists(mp):
        try: return json.load(open(mp))
        except: return {}
    return {}

def wf_agents(proj):
    root = os.path.join(BASE, PROJ[proj])
    return sorted(glob.glob(root + '/*/subagents/workflows/wf_*/agent-*.jsonl'))

def sub_agents(proj):
    return sorted(glob.glob(os.path.join(BASE, PROJ[proj]) + '/*/subagents/agent-*.jsonl'))
