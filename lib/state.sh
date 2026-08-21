#!/usr/bin/env bash
set -eu
STATE="${STATE_DIR:-.claude/state}/state.json"
cmd="${1:-}"; shift || true
case "$cmd" in
  init) mkdir -p "$(dirname "$STATE")"; [ -f "$STATE" ] || echo '{"phase":"brief"}' > "$STATE"
        printf '{"ok":true,"reason":null,"hint":null,"data":null}\n' ;;
  get|set) python3 - "$cmd" "$STATE" "$@" <<'PY'
import json,sys,os,tempfile
cmd,path=sys.argv[1],sys.argv[2]
try: s=json.load(open(path))
except FileNotFoundError:
    print(json.dumps({"ok":False,"reason":"no state.json","hint":"run state.sh init","data":None})); sys.exit(1)
if cmd=="get":
    if len(sys.argv)<4:
        print(json.dumps({"ok":False,"reason":"missing argument","hint":"usage: state.sh get <key> | set <key> <value>","data":None})); sys.exit(1)
    print(json.dumps({"ok":True,"reason":None,"hint":None,"data":{"value":s.get(sys.argv[3])}}))
else:
    if len(sys.argv)<5:
        print(json.dumps({"ok":False,"reason":"missing argument","hint":"usage: state.sh get <key> | set <key> <value>","data":None})); sys.exit(1)
    v=sys.argv[4]
    try: v=json.loads(v)
    except ValueError: pass
    s[sys.argv[3]]=v
    with tempfile.NamedTemporaryFile(mode='w',dir=os.path.dirname(path),delete=False) as tmp:
        json.dump(s,tmp,indent=1)
        tmp_path=tmp.name
    os.replace(tmp_path,path)
    print(json.dumps({"ok":True,"reason":None,"hint":None,"data":None}))
PY
  ;;
  *) printf '{"ok":false,"reason":"unknown cmd","hint":"init|get|set","data":null}\n'; exit 1;;
esac
