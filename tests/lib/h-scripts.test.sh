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

# --- H1 (отложенная находка финального ревью): контрольной группы нет
# вовсе (n_control=0, ни одного события arm=control в файле) — не путать
# с «мало контроля» (n_control=3 ниже): здесь дошедших до control-плеча
# задач не было ни одной. ok:true, verdict:null, без деления на n_control=0.
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"z$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":1,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 n_control=0 (контрольной группы нет): ok" "True" "$(jd "$out" 'd["ok"]')"
assert_eq "h1 n_control=0: verdict null" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h1 n_control=0: value.n_control" "0" "$(jd "$out" 'd["data"]["value"]["n_control"]')"
assert_eq "h1 n_control=0: reason называет недостаточность" "True" "$(jd "$out" '"недостаточно контрольных" in d["reason"]')"

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

# --- H1 Finding 2: MIN_CONTROL=4 — n_control=3 недостаточно (шум выдаваемый
# за контроль), n_control=4 (порог) уже позволяет вынести вердикт.
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"m$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":1,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3; do echo "{\"event\":\"task_complete\",\"task\":\"n$i\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 n_control=3 < MIN_CONTROL(4): verdict null" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h1 n_control=3: reason называет недостаточность" "True" "$(jd "$out" '"недостаточно контрольных" in d["reason"]')"
echo "{\"event\":\"task_complete\",\"task\":\"n4\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl
out="$(run_h h1-cap.sh)"
assert_eq "h1 n_control=4 (порог достигнут): confirmed" "confirmed" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h1 confirmed: reason содержит числа" "True" "$(jd "$out" '"mean_disp_arm" in d["reason"]')"

# --- H1 Finding 1: failed-задача в .mvp/plan.json — страховка. confirmed
# понижается до null (потерянная рукавом задача не видна метрике dispatches),
# refuted страховка не трогает (отрицательный вывод не пострадал бы всё равно).
cat > .mvp/plan.json <<'EOF'
{"tasks":[{"id":"001","status":"failed"},{"id":"002","status":"done"}]}
EOF
out="$(run_h h1-cap.sh)"
assert_eq "h1 failed-задача блокирует confirmed" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h1 failed-задача: reason упоминает failed" "True" "$(jd "$out" '"failed" in d["reason"]')"
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"p$i\",\"delta_tokens\":10,\"dispatches\":30,\"arm\":\"cap30\",\"segments\":3,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3 4; do echo "{\"event\":\"task_complete\",\"task\":\"q$i\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 failed-задача НЕ блокирует refuted" "refuted" "$(jd "$out" 'd["data"]["verdict"]')"
rm -f .mvp/plan.json

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

# --- H2 с JOURNALS_DIR: median_reviewer_prefix и verdict по числовым порогам.
# MIN_OBS=3 (Finding 3) — три mvp-reviewer журнала, ровно на пороге.
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
cat > j3/agent-r3.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j3/agent-r3.jsonl <<'EOF'
{"type":"assistant","requestId":"r3","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":12000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j3" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
# median(10000, 12000, 14000) = 12000 <= 16000, нет generic, n=3=MIN_OBS — confirmed
assert_eq "h2 с журналами: median" "12000" "$(jd "$out" 'd["data"]["value"]["median_reviewer_prefix"]')"
assert_eq "h2 с журналами: generic_ladder_agents" "0" "$(jd "$out" 'd["data"]["value"]["generic_ladder_agents"]')"
assert_eq "h2 с журналами: confirmed" "confirmed" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h2 confirmed: reason содержит числа" "True" "$(jd "$out" '"median_reviewer_prefix" in d["reason"]')"

# --- H2 Finding 3, граница снизу: n_reviewer=2 (MIN_OBS-1) — те же «хорошие»
# значения (median<=16000, нет generic), но вердикт всё равно null.
mkdir -p j7
cat > j7/agent-r1.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j7/agent-r1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":10000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j7/agent-r2.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j7/agent-r2.jsonl <<'EOF'
{"type":"assistant","requestId":"r2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":12000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j7" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
assert_eq "h2 n_reviewer=2 < MIN_OBS(3): verdict null несмотря на хорошие числа" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h2 n_reviewer=2: reason называет недостаточность" "True" "$(jd "$out" '"недостаточно наблюдений" in d["reason"]')"

# --- H2 с генериком в лестнице: даже при хорошей медиане (n=3=MIN_OBS) generic_ladder_agents>0 блокирует confirmed
mkdir -p j4
cp j3/agent-r1.meta.json j3/agent-r1.jsonl j3/agent-r2.meta.json j3/agent-r2.jsonl j3/agent-r3.meta.json j3/agent-r3.jsonl j4/
cat > j4/agent-g1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j4/agent-g1.jsonl <<'EOF'
{"type":"assistant","requestId":"g1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j4" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
assert_eq "h2 generic в лестнице: не confirmed" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h2 generic в лестнице: generic_ladder_agents" "1" "$(jd "$out" 'd["data"]["value"]["generic_ladder_agents"]')"

# --- H2 refuted: медиана > 24000, n=3=MIN_OBS
mkdir -p j5
cat > j5/agent-r1.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j5/agent-r1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":28000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j5/agent-r2.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j5/agent-r2.jsonl <<'EOF'
{"type":"assistant","requestId":"r2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":30000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j5/agent-r3.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j5/agent-r3.jsonl <<'EOF'
{"type":"assistant","requestId":"r3","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":32000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j5" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
assert_eq "h2 refuted (медиана 30000 > 24000)" "refuted" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h2 refuted: reason содержит числа" "True" "$(jd "$out" '"median_reviewer_prefix" in d["reason"]')"

# --- H2 (отложенная находка финального ревью): промежуточный диапазон
# медианы между порогом confirmed (16000) и порогом refuted (24000),
# n=3=MIN_OBS, generic_ladder_agents=0 — ни одно решающее условие не
# выполнено, вердикта быть не должно.
mkdir -p j8
cat > j8/agent-r1.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j8/agent-r1.jsonl <<'EOF'
{"type":"assistant","requestId":"r1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":18000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j8/agent-r2.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j8/agent-r2.jsonl <<'EOF'
{"type":"assistant","requestId":"r2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":20000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j8/agent-r3.meta.json <<'EOF'
{"agentType":"mvp-reviewer"}
EOF
cat > j8/agent-r3.jsonl <<'EOF'
{"type":"assistant","requestId":"r3","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":22000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j8" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
assert_eq "h2 промежуточная медиана: значение" "20000" "$(jd "$out" 'd["data"]["value"]["median_reviewer_prefix"]')"
assert_eq "h2 промежуточная медиана (16000 < 20000 <= 24000): нет вердикта" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h2 промежуточная медиана: reason не укладывается ни в одно правило" "True" "$(jd "$out" '"не укладываются" in d["reason"]')"

# --- H2 (второй проход финального ревью, мелкая находка 1): refuted выносится
# по превышению медианы НЕЗАВИСИМО от generic в лестнице — generic блокирует
# только confirmed. Текст порога в registry.json раньше говорил «есть generic
# -> вердикта нет», числа этой ветки сторожит drift-тест, а саму логику — этот
# ассерт: j5 (медиана 30000 > 24000) плюс generic-журнал — всё равно refuted.
mkdir -p j5g
cp j5/agent-r1.meta.json j5/agent-r1.jsonl j5/agent-r2.meta.json j5/agent-r2.jsonl j5/agent-r3.meta.json j5/agent-r3.jsonl j5g/
cat > j5g/agent-g1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j5g/agent-g1.jsonl <<'EOF'
{"type":"assistant","requestId":"g1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j5g" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h2-tier12.sh" | tail -n 1)"
assert_eq "h2 refuted при generic в лестнице (generic блокирует только confirmed)" "refuted" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h2 refuted при generic: generic_ladder_agents виден в value" "1" "$(jd "$out" 'd["data"]["value"]["generic_ladder_agents"]')"

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

# --- H1 (отложенная находка финального ревью): эпоха рукава. events.jsonl
# копится по ВСЕМ прогонам проекта — фикстура мешает старые события ДО
# появления поля arm (Task 9, dispatches=999 — заведомо ломает среднее,
# если бы попали в выборку) с новыми cap30/control-событиями. Естественный
# признак эпохи — само присутствие поля arm; старые события его не несут.
: > .mvp/telemetry/events.jsonl
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"old$i\",\"delta_tokens\":10,\"dispatches\":999,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"e$i\",\"delta_tokens\":10,\"dispatches\":8,\"arm\":\"cap30\",\"segments\":1,\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
for i in 1 2 3 4 5 6 7 8; do echo "{\"event\":\"task_complete\",\"task\":\"f$i\",\"delta_tokens\":10,\"dispatches\":9,\"arm\":\"control\",\"ts\":\"t\"}" >> .mvp/telemetry/events.jsonl; done
out="$(run_h h1-cap.sh)"
assert_eq "h1 эпоха рукава: дорукавные события не входят в n_arm" "8" "$(jd "$out" 'd["data"]["value"]["n_arm"]')"
assert_eq "h1 эпоха рукава: дорукавные события не входят в n_control" "8" "$(jd "$out" 'd["data"]["value"]["n_control"]')"
assert_eq "h1 эпоха рукава: mean_disp_control не смещено (999 исключён)" "9.0" "$(jd "$out" 'd["data"]["value"]["mean_disp_control"]')"
assert_eq "h1 эпоха рукава: вердикт по чистой выборке — confirmed" "confirmed" "$(jd "$out" 'd["data"]["verdict"]')"

# results.jsonl получает «предыдущий прогон» этой гипотезы с gap<2000 —
# нужен ниже и для граничного (недостаточно), и для достаточного кейса.
# n_generic/n_role >= MIN_OBS помечают эту запись СОСТОЯТЕЛЬНОЙ (находка
# I4) — без них она не смогла бы стать первым из «двух прогонов подряд»
# для refuted ниже (см. отдельный тест «ненадёжный предыдущий прогон»).
# src (находка I-2) — отпечаток ДРУГОГО набора журналов: без него, или с
# совпадающим с текущим замером, запись за «другой прогон» не считается.
echo '{"hypothesis":"t","run_label":"r0","value":{"gap":500,"n_generic":3,"n_role":3,"src":"prev-run-src-0001"},"verdict":null,"ts":"t"}' >> .mvp/experiments/results.jsonl

# --- H3 Finding 3, граница снизу: 2 generic + 2 mvp- (MIN_OBS-1 по каждой
# группе) — gap<2000 и подходящий предыдущий прогон есть, но данных мало →
# verdict остаётся null (не refuted).
mkdir -p j9
cat > j9/agent-c1.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j9/agent-c1.jsonl <<'EOF'
{"type":"assistant","requestId":"c1","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j9/agent-c1b.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j9/agent-c1b.jsonl <<'EOF'
{"type":"assistant","requestId":"c1b","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j9/agent-c2.meta.json <<'EOF'
{"agentType":"mvp-relay"}
EOF
cat > j9/agent-c2.jsonl <<'EOF'
{"type":"assistant","requestId":"c2","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":4500,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j9/agent-c2b.meta.json <<'EOF'
{"agentType":"mvp-relay"}
EOF
cat > j9/agent-c2b.jsonl <<'EOF'
{"type":"assistant","requestId":"c2b","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":4500,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
out="$(JOURNALS_DIR="$(pwd)/j9" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 2+2 наблюдений (< MIN_OBS=3): gap всё равно посчитан как факт" "500.0" "$(jd "$out" 'd["data"]["value"]["gap"]')"
assert_eq "h3 2+2 наблюдений: verdict null несмотря на gap<2000 и подходящий prev" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h3 2+2 наблюдений: reason называет недостаточность" "True" "$(jd "$out" '"недостаточно наблюдений" in d["reason"]')"

# --- H3 refuted: 3 generic + 3 mvp- (MIN_OBS достигнут по обеим группам),
# два прогона подряд с gap < 2000 в results.jsonl
mkdir -p j6
cp j9/agent-c1.meta.json j9/agent-c1.jsonl j9/agent-c1b.meta.json j9/agent-c1b.jsonl j9/agent-c2.meta.json j9/agent-c2.jsonl j9/agent-c2b.meta.json j9/agent-c2b.jsonl j6/
cat > j6/agent-c1c.meta.json <<'EOF'
{"agentType":"workflow-subagent"}
EOF
cat > j6/agent-c1c.jsonl <<'EOF'
{"type":"assistant","requestId":"c1c","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
cat > j6/agent-c2c.meta.json <<'EOF'
{"agentType":"mvp-relay"}
EOF
cat > j6/agent-c2c.jsonl <<'EOF'
{"type":"assistant","requestId":"c2c","message":{"model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":4500,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
# generic median(5000,5000,5000)=5000; role median(4500,4500,4500)=4500; gap=500<2000
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=t RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 refuted: gap" "500" "$(jd "$out" 'd["data"]["value"]["gap"]')"
assert_eq "h3 refuted: 3+3 наблюдений, предыдущий СОСТОЯТЕЛЬНЫЙ прогон тоже <2000 → refuted" "refuted" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h3 refuted: reason содержит числа" "True" "$(jd "$out" '"gap=" in d["reason"]')"
assert_eq "h3 refuted: value несёт n_generic состоятельного замера" "3" "$(jd "$out" 'd["data"]["value"]["n_generic"]')"
assert_eq "h3 refuted: value несёт n_role состоятельного замера" "3" "$(jd "$out" 'd["data"]["value"]["n_role"]')"
# без предыдущей записи (чужой HYP_ID) — тот же текущий gap<2000, наблюдений хватает, но одного прогона мало
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=other RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 один прогон с малым gap, нет своей предыдущей записи → null" "None" "$(jd "$out" 'd["data"]["verdict"]')"

# --- H3 находка I4: предыдущая запись есть и её gap<2000, но она СТАРОГО
# формата — без n_generic/n_role (как писал check-скрипт до этого фикса,
# или как результат ручной правки журнала). Ложный вердикт хуже отсутствия
# вердикта: такая запись не может быть первым из «двух прогонов подряд»,
# потому что её состоятельность неизвестна — «два прогона подряд»
# не должно вырождаться в «один настоящий плюс один шумовой».
echo '{"hypothesis":"unreliable-prev","run_label":"r0","value":{"gap":500},"verdict":null,"ts":"t"}' >> .mvp/experiments/results.jsonl
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=unreliable-prev RUN_LABEL=r RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 I4: gap<2000 текущий, но prev без n_generic/n_role → НЕ refuted" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h3 I4: reason называет неизвестную состоятельность prev" "True" "$(jd "$out" '"состоятельность" in d["reason"]')"

# --- H3 находка I-2 (второй проход финального ревью): «два прогона подряд»
# по данным ОДНОГО прогона. mvp:retro перезапускаем по построению, и повторный
# разбор меряет те же журналы под новым run_label — раньше вторая запись с тем
# же значением давала уверенное refuted. Теперь запись зачитывается только из
# другого прогона: по отличающемуся отпечатку источника данных value.src.
# (a) src пишется в каждую запись, где посчитан gap.
cur_src="$(jd "$out" 'd["data"]["value"]["src"]')"
assert_eq "h3 I-2: src посчитан и непуст" "16" "${#cur_src}"
# (b) prev СОСТОЯТЕЛЕН по n_*, но src СОВПАДАЕТ с текущим замером (те же
# журналы j6, повторный разбор; run_label при этом другой — r-again vs r0) →
# НЕ refuted, reason называет повторный разбор.
echo "{\"hypothesis\":\"same-src\",\"run_label\":\"r0\",\"value\":{\"gap\":500,\"n_generic\":3,\"n_role\":3,\"src\":\"$cur_src\"},\"verdict\":null,\"ts\":\"t\"}" >> .mvp/experiments/results.jsonl
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=same-src RUN_LABEL=r-again RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 I-2: prev с совпадающим src (повторный разбор того же прогона) → НЕ refuted" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h3 I-2: reason называет повторный разбор тех же журналов" "True" "$(jd "$out" '"ТЕМ ЖЕ журналам" in d["reason"]')"
# (c) prev состоятелен по n_*, src ОТЛИЧАЕТСЯ (настоящий другой прогон) →
# refuted; это же доказывает, что (b) ломается именно на совпадении src.
echo '{"hypothesis":"other-src","run_label":"r0","value":{"gap":500,"n_generic":3,"n_role":3,"src":"another-run-src-2"},"verdict":null,"ts":"t"}' >> .mvp/experiments/results.jsonl
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=other-src RUN_LABEL=r-again RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 I-2: prev с отличающимся src → refuted (другой прогон зачтён)" "refuted" "$(jd "$out" 'd["data"]["verdict"]')"
# (d) prev состоятелен по n_*, но БЕЗ src (запись формата до I-2) — старый
# формат пригодным по умолчанию не считается: НЕ refuted.
echo '{"hypothesis":"no-src","run_label":"r0","value":{"gap":500,"n_generic":3,"n_role":3},"verdict":null,"ts":"t"}' >> .mvp/experiments/results.jsonl
out="$(JOURNALS_DIR="$(pwd)/j6" HYP_ID=no-src RUN_LABEL=r-again RESULTS_PATH=.mvp/experiments/results.jsonl PLUGIN_ROOT="$repo_root" PROJECT_ROOT="$(pwd)" bash "$repo_root/scripts/experiments/h3-prefix-gap.sh" | tail -n 1)"
assert_eq "h3 I-2: prev без src (старый формат) → НЕ refuted" "None" "$(jd "$out" 'd["data"]["verdict"]')"
assert_eq "h3 I-2: reason для старого формата называет отсутствие src" "True" "$(jd "$out" '"src" in d["reason"]')"

exit $fail
