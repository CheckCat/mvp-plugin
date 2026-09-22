#!/usr/bin/env bash
# experiments-threshold-drift.test.sh — тексты порогов в docs/experiments/
# registry.json обязаны называть ТЕ ЖЕ числа, по которым check-скрипты гипотез
# реально выносят вердикт (финальное ревью, находка 12). Предыдущая волна
# ревью привела тексты в соответствие с кодом вручную — сверка была ручной, и
# ничто не мешает им снова разойтись при правке одной стороны без другой.
# Способ: regex-экстракция констант из threshold-текста registry.json и из
# исходников scripts/experiments/h{1,2,3}-*.sh, попарное сравнение чисел.
# Формулировки текста МЕНЯТЬ можно свободно — этот тест не про стиль прозы, он
# ловит числовой дрейф между двумя местами, где число написано отдельно.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0

out="$(REPO_ROOT="$repo_root" python3 <<'PY'
import json, os, re, sys

repo_root = os.environ["REPO_ROOT"]
reg = json.load(open(os.path.join(repo_root, "docs/experiments/registry.json")))
hyps = {h["id"]: h for h in reg["hypotheses"]}

def read(path):
    return open(os.path.join(repo_root, path), encoding="utf-8").read()

problems = []

def num(pattern, text, what):
    m = re.search(pattern, text)
    if not m:
        problems.append("не нашли %s по паттерну %r — regex устарел или текст/код переписали мимо этого теста" % (what, pattern))
        return None
    return m.group(1)

def check(what, script_val, reg_val):
    if script_val is None or reg_val is None:
        return
    if script_val != reg_val:
        problems.append("DRIFT %s: скрипт=%s, текст порога в registry.json=%s" % (what, script_val, reg_val))

h1 = hyps["H1-cap-work-preservation"]
h1_script = read(h1["check_script"])
h1_text = h1["threshold"]
check("H1 n_arm (минимум арма)",
      num(r"if n_arm < (\d+):", h1_script, "h1-cap.sh: порог n_arm"),
      num(r"n_arm>=(\d+)", h1_text, "registry H1: n_arm>=N"))
check("H1 n_control (MIN_CONTROL)",
      num(r"MIN_CONTROL = (\d+)", h1_script, "h1-cap.sh: MIN_CONTROL"),
      num(r"n_control>=(\d+)", h1_text, "registry H1: n_control>=N"))
check("H1 confirmed-множитель",
      num(r"mean_disp_arm <= ([\d.]+) \* mean_disp_control:", h1_script, "h1-cap.sh: confirmed-ветка"),
      num(r"confirmed при mean_disp_arm <= ([\d.]+) \*", h1_text, "registry H1: confirmed <= N *"))
check("H1 refuted-множитель",
      num(r"mean_disp_arm > ([\d.]+) \* mean_disp_control:", h1_script, "h1-cap.sh: refuted-ветка"),
      num(r"refuted при mean_disp_arm > ([\d.]+) \*", h1_text, "registry H1: refuted > N *"))

h2 = hyps["H2-tier12-savings-match"]
h2_script = read(h2["check_script"])
h2_text = h2["threshold"]
check("H2 MIN_OBS / n_reviewer",
      num(r"MIN_OBS = (\d+)", h2_script, "h2-tier12.sh: MIN_OBS"),
      num(r"n_reviewer>=(\d+)", h2_text, "registry H2: n_reviewer>=N"))
check("H2 confirmed-порог",
      num(r"median_reviewer_prefix <= (\d+) and generic_count == 0:", h2_script, "h2-tier12.sh: confirmed-ветка"),
      num(r"confirmed при median_reviewer_prefix <= (\d+)", h2_text, "registry H2: confirmed <= N"))
check("H2 refuted-порог",
      num(r"elif median_reviewer_prefix > (\d+):", h2_script, "h2-tier12.sh: refuted-ветка"),
      num(r"refuted при median_reviewer_prefix > (\d+)", h2_text, "registry H2: refuted > N"))

h3 = hyps["H3-prefix-gap-alive"]
h3_script = read(h3["check_script"])
h3_text = h3["threshold"]
check("H3 MIN_OBS / n_generic",
      num(r"MIN_OBS = (\d+)", h3_script, "h3-prefix-gap.sh: MIN_OBS"),
      num(r"n_generic>=(\d+)", h3_text, "registry H3: n_generic>=N"))
check("H3 MIN_OBS / n_role",
      num(r"MIN_OBS = (\d+)", h3_script, "h3-prefix-gap.sh: MIN_OBS"),
      num(r"n_role>=(\d+)", h3_text, "registry H3: n_role>=N"))
check("H3 gap-порог",
      num(r"elif gap < (\d+):", h3_script, "h3-prefix-gap.sh: refuted-ветка"),
      num(r"gap<(\d+)", h3_text, "registry H3: gap<N"))

if problems:
    print("\n".join(problems))
    sys.exit(1)
sys.exit(0)
PY
)"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: текст порога(ов) в docs/experiments/registry.json разошёлся с константами check-скрипта:" >&2
  echo "$out" >&2
  fail=1
fi

exit $fail
