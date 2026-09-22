#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
wf="$repo_root/skills/build/workflow.mjs"

need() { grep -qE "$1" "$wf" || { echo "FAIL: workflow.mjs: не найдено /$1/ — $2" >&2; fail=1; }; }

need "agentType: 'mvp-relay'" "релеи без узкой роли"
need "agentType: 'mvp-reviewer'" "опросы ревью без узкой роли"
need "agentType: 'mvp-validator'" "валидатор без узкой роли"
need "abstain" "нет ветки «обрыв ≠ отказ» (воздержавшийся опрос)"
# Закон: no-fallback релея не молчит — при падении узкой роли идёт retry без agentType
need "mvp-relay.*fallback|fallback.*mvp-relay" "нет generic-fallback у релея"
# Sanity-parse (та же команда, что в Global Constraints)
node -e "const src=require('fs').readFileSync('$wf','utf8').replace(/^export const meta[\s\S]*?^}/m,''); new (Object.getPrototypeOf(async function(){}).constructor)('agent','parallel','pipeline','log','phase','args','budget','workflow', src)" || { echo "FAIL: sanity-parse" >&2; fail=1; }

exit $fail
