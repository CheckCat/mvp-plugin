#!/usr/bin/env bash
# Tests for scripts/experiments/h1-cap.sh, h2-tier12.sh, h3-prefix-gap.sh —
# check-скрипты гипотез из docs/experiments/registry.json (спека 2026-09-22
# §7, task-10-brief.md). Каждый скрипт читает телеметрию/журналы прогона и
# отвечает JSON-контрактом check-скрипта; results.jsonl пишет lib/experiments.sh,
# не эти скрипты (здесь их зовём напрямую).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
jd() { O="$1" E="$2" python3 -c 'import json,os; d=json.loads(os.environ["O"]); print(eval(os.environ["E"]))'; }
run_h() { # <script> — общий запуск с контрактным env
  HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/$1" | tail -n 1
}

cd "$tmpdir"; mkdir -p .mvp/telemetry .mvp/experiments

# --- H1: мало данных → verdict null; рукав не хуже контроля при n>=8 → confirmed
for i in 1 2 3; do echo "{\"event\":\"task_complete\",\"task\":\"00$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":1,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 мало данных: ok" "True" "$(jd "$out" 'd["ok"]')"
assert_eq "h1 мало данных: verdict null" "None" "$(jd "$out" 'd["data"]["verdict"]')"
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"a$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":1,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"c$i\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 confirmed" "confirmed" "$(jd "$out" 'd["data"]["verdict"]')"
# рукав с dispatches хуже порога → refuted не выносится (условие 2 — refuted только по потере задач),
# но confirmed невозможен:
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"a$i\",\"delta_tokens\":10,\"dispatches\":20,\"arm\":\"cap30\",\"segments\":3,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"c$i\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 дорогой рукав: не confirmed" "None" "$(jd "$out" 'd["data"]["verdict"]')"

# --- H2/H3: без JOURNALS_DIR — ok:true, verdict null, note
out="$(run_h h2-tier12.sh)"
assert_eq "h2 без журналов ok" "True" "$(jd "$out" 'd["ok"]')"
assert_eq "h2 без журналов verdict" "None" "$(jd "$out" 'd["data"]["verdict"]')"

# --- H3 с синтетическим журналом: gap считается
mkdir -p j
cat > j/agent-a1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j/agent-a1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":24000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j/agent-a2.meta.json <<'EOF'
{"agentType":"mvp-relay"}
EOF
cat > j/agent-a2.jsonl <<'EOF'
{"type":"assistant","requestId":"r2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":9000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 gap" "15000" "$(jd "$out" 'd["data"]["value"]["gap"]')"

# --- H3 доп. фикстура: output_tokens != cache_read_input_tokens по обоим файлам,
# чтобы отличить правильную формулу (input+cache_creation+cache_read) от
# случайно совпадающей при read=0/output=1 в обоих файлах выше (мутация
# «взять output вместо cache_read» там не меняет gap, т.к. +1 сокращается
# при вычитании; здесь смещения разные и mutation её ловит).
mkdir -p j2
cat > j2/agent-b1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j2/agent-b1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":100,"cache_creation_input_tokens":5000,"cache_read_input_tokens":900,"output_tokens":50}}}
EOF
cat > j2/agent-b2.meta.json <<'EOF'
{"agentType":"mvp-relay"}
EOF
cat > j2/agent-b2.jsonl <<'EOF'
{"type":"assistant","requestId":"r2","message":{"model":"m","usage":{"input_tokens":50,"cache_creation_input_tokens":2000,"cache_read_input_tokens":450,"output_tokens":999}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j2" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
# generic (b1) = 100+5000+900 = 6000; role (b2) = 50+2000+450 = 2500; gap = 3500
assert_eq "h3 gap (cache_read != output, различает формулу)" "3500" "$(jd "$out" 'd["data"]["value"]["gap"]')"

# --- H2 с JOURNALS_DIR: median_reviewer_prefix и verdict по числовым порогам
mkdir -p j3
cat > j3/agent-r1.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j3/agent-r1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":10000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j3/agent-r2.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j3/agent-r2.jsonl <<'EOF'
{"type":"assistant","requestId":"r2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":14000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j3" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
# median(10000, 14000) = 12000 <= 16000, нет generic — confirmed
assert_eq "h2 с журналами: median" "12000.0" "$(jd "$out" 'd["data"]["value"]["median_reviewer_prefix"]')"
assert_eq "h2 с журналами: generic_ladder_agents" "0" "$(jd "$out" 'd["data"]["value"]["generic_ladder_agents"]')"
assert_eq "h2 с журналами: confirmed" "confirmed" "$(jd "$out" 'd["data"]["verdict"]')"

# --- H2 с генериком в лестнице: даже при хорошей медиане generic_ladder_agents>0 блокирует confirmed
mkdir -p j4
cp j3/agent-r1.meta.json j3/agent-r1.jsonl j3/agent-r2.meta.json j3/agent-r2.jsonl j4/
cat > j4/agent-g1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j4/agent-g1.jsonl <<'EOF'
{"type":"assistant","requestId":"g1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j4" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
assert_eq "h2 generic в лестнице: не confirmed" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h2 generic в лестнице: generic_ladder_agents" "1" "$(jd "$out" 'd["data"]["value"]["generic_ladder_agents"]')"

# --- H2 refuted: медиана > 24000
mkdir -p j5
cat > j5/agent-r1.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j5/agent-r1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":30000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j5" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
assert_eq "h2 refuted (медиана 30000 > 24000)" "refuted" "$(jd "$out" 'd["data"]["verdict"]')"

# --- H1 mean_segments считается по рукаву (8 событий segments:1 из confirmed-кейса выше остались в events.jsonl)
out="$(run_h h1-cap.sh)"
assert_eq "h1 мало данных: mean_segments из последнего прогона (segments=3 x8)" "3.0" "$(jd "$out" 'd["data"]["value"]["mean_segments"]')"

# --- H1 mean_segments: событие рукава без поля segments (старая телеметрия до Task 8)
# не должно ни падать, ни попадать в знаменатель — среднее считается только
# по событиям, где segments реально есть.
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7; do echo "{\"event\":\"task_complete\",\"task\":\"s$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":2,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
echo '{"event":"task_complete","task":"s8","delta_tokens":10,"dispatches":8,"arm":"cap30","ts":"t"}' >> .mvp/telemetry/events.jsonl
out="$(run_h h1-cap.sh)"
assert_eq "h1 mean_segments игнорирует событие без поля segments" "2.0" "$(jd "$out" 'd["data"]["value"]["mean_segments"]')"
assert_eq "h1 n_arm считает и событие без segments" "8" "$(jd "$out" 'd["data"]["value"]["n_arm"]')"

# --- H3 refuted: два прогона подряд с gap < 2000 в results.jsonl
mkdir -p j6
cat > j6/agent-c1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j6/agent-c1.jsonl <<'EOF'
{"type":"assistant","requestId":"c1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j6/agent-c2.meta.json <<'EOF'
{"agentType":"mvp-relay"}
EOF
cat > j6/agent-c2.jsonl <<'EOF'
{"type":"assistant","requestId":"c2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":4500,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
# gap = 5000-4500 = 500 < 2000; results.jsonl ещё не содержит предыдущей записи H3 → verdict null
echo '{"hypothesis":"t","run_label":"r0","value":{"gap":500},"verdict":null,"ts":"t"}' >> .mvp/experiments/results.jsonl
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 refuted: gap" "500" "$(jd "$out" 'd["data"]["value"]["gap"]')"
assert_eq "h3 refuted: предыдущий прогон тоже <2000 → refuted" "refuted" "$(jd "$out" 'd["data"]["verdict"]')"
# без предыдущей записи (чужой HYP_ID) — тот же текущий gap<2000, но одного прогона мало
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=other RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 один прогон с малым gap, нет своей предыдущей записи → null" "None" "$(jd "$out" 'd["data"]["verdict"]')"

exit $fail
