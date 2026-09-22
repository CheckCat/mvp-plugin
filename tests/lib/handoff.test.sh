#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
ok_of() { O="$1" python3 -c 'import json,os; print(json.loads(os.environ["O"])["ok"])'; }

cd "$tmpdir"; git init -q .; git commit -q --allow-empty -m init; mkdir -p .mvp

# (1) чистое дерево → ok:false «не обрыв»
out="$(bash "$repo_root/lib/handoff.sh" 007 2 | tail -n 1)" || true
assert_eq "clean tree" "False" "$(ok_of "$out")"
echo "$out" | grep -q "clean tree" || { echo "FAIL: причина не названа" >&2; fail=1; }

# (2) грязное дерево → файл-указатель со status, diff, сегментом
mkdir -p src && printf 'line1\nline2\n' > src/a.txt && git add src/a.txt && git commit -qm one
printf 'line1\nCHANGED\n' > src/a.txt && echo new > src/new.txt
out="$(bash "$repo_root/lib/handoff.sh" 007 2 | tail -n 1)"
assert_eq "dirty tree ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
assert_eq "путь" ".mvp/handoff-007.md" "$p"
grep -q "segment: 2" "$p" || { echo "FAIL: нет номера сегмента" >&2; fail=1; }
grep -q "src/a.txt" "$p" || { echo "FAIL: нет git status" >&2; fail=1; }
grep -q "CHANGED" "$p" || { echo "FAIL: нет диффа" >&2; fail=1; }
grep -q "new.txt" "$p" || { echo "FAIL: untracked не виден" >&2; fail=1; }

# (3) огромный дифф режется с маркером
python3 -c "print('x\n' * 20000, end='')" > src/big.txt
out="$(bash "$repo_root/lib/handoff.sh" 007 3 | tail -n 1)"
assert_eq "big ok" "True" "$(ok_of "$out")"
lines="$(wc -l < .mvp/handoff-007.md | tr -d ' ')"
[ "$lines" -le 4200 ] || { echo "FAIL: указатель $lines строк, cap 4000+обвязка" >&2; fail=1; }
grep -q "TRUNCATED" .mvp/handoff-007.md || { echo "FAIL: нет маркера обрезки" >&2; fail=1; }

exit $fail
