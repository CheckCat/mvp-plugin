#!/usr/bin/env bash
# Enforces the SKILL.md size budgets from docs/specs (§ "Размер").
# Convention (tests/run.sh): exit 0 = pass.
#
# Why this is a test and not a convention: the budgets existed only as prose
# in the spec, so nothing noticed when a skill grew past them. Adding two
# paragraphs to skills/retro/SKILL.md on 2026-08-25 pushed it 23% over its
# stated ceiling and the only thing that caught it was a manual `wc -c`.
# A budget nobody measures is a wish.
#
# The numbers come from the spec, not from current file sizes — a test
# rewritten to match whatever the files happen to weigh today enforces
# nothing. If a skill genuinely needs a bigger budget, raise it HERE and in
# the spec, deliberately, in a commit that says why.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0

# gate skills: 2–4 KB (spec). Short, terminal, read in full every time.
GATE_MAX=4096
# orchestrators: <= 10–12 KB (spec). The upper bound is the hard one.
ORCH_MAX=12288

check_size() { # <path> <max> <label>
  local path="$1" max="$2" label="$3" size
  if [ ! -f "$path" ]; then
    echo "FAIL: $label missing: $path" >&2
    fail=1
    return
  fi
  size="$(wc -c <"$path" | tr -d ' ')"
  if [ "$size" -gt "$max" ]; then
    echo "FAIL: $label is $size bytes, budget is $max (over by $((size - max)))" >&2
    echo "      trim it, or raise the budget in this test AND in docs/specs — deliberately." >&2
    fail=1
  fi
}

for name in resume retro; do
  check_size "$repo_root/skills/$name/SKILL.md" "$GATE_MAX" "gate skill $name"
done

for name in brief clarify bootstrap plan build; do
  check_size "$repo_root/skills/$name/SKILL.md" "$ORCH_MAX" "orchestrator $name"
done

# Every skill must exist and carry exactly the two frontmatter fields the
# loader reads (name, description) — a third field is silently ignored at
# load time, which makes it a trap rather than a feature.
for path in "$repo_root"/skills/*/SKILL.md; do
  name="$(basename "$(dirname "$path")")"
  fm_lines="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside && /^[a-z_]+:/ {n++} END {print n+0}' "$path")"
  if [ "$fm_lines" != "2" ]; then
    echo "FAIL: skill $name has $fm_lines frontmatter field(s), expected exactly 2 (name, description)" >&2
    fail=1
  fi
done

exit $fail
