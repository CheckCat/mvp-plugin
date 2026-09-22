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

# ========== ОСНОВНЫЕ ТЕСТЫ (из спеки) ==========

# (1) чистое дерево → ok:false «не обрыв»
out="$(bash "$repo_root/lib/handoff.sh" 007 2 | tail -n 1)" || true
assert_eq "clean tree ok" "False" "$(ok_of "$out")"
echo "$out" | grep -q "clean tree" || { echo "FAIL: причина не названа" >&2; fail=1; }

# (2) грязное дерево → файл-указатель со status, diff, сегментом
mkdir -p src && printf 'line1\nline2\n' > src/a.txt && git add src/a.txt && git commit -qm one
printf 'line1\nCHANGED\n' > src/a.txt && echo new > src/new.txt
out="$(bash "$repo_root/lib/handoff.sh" 007 2 | tail -n 1)"
assert_eq "dirty tree ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
assert_eq "path" ".mvp/handoff-007.md" "$p"
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

# ========== РАСШИРЕННЫЕ ТЕСТЫ (на ошибки и граничные случаи) ==========

# (4) не git репо
cd "$tmpdir" && rm -rf .git
out="$(bash "$repo_root/lib/handoff.sh" 007 2 2>&1 | tail -n 1)" || true
assert_eq "not git repo" "False" "$(ok_of "$out")"
echo "$out" | grep -q "not a git repo" || { echo "FAIL: не обнаружено что это не git репо" >&2; fail=1; }

# Восстанавливаем git-репо для дальнейших тестов
git init -q .; git commit -q --allow-empty -m init; mkdir -p .mvp

# (5) отсутствующие аргументы
out="$(bash "$repo_root/lib/handoff.sh" 2>&1 | tail -n 1)" || true
assert_eq "no args" "False" "$(ok_of "$out")"
echo "$out" | grep -q "usage" || { echo "FAIL: нет usage" >&2; fail=1; }

out="$(bash "$repo_root/lib/handoff.sh" 007 2>&1 | tail -n 1)" || true
assert_eq "missing segment" "False" "$(ok_of "$out")"
echo "$out" | grep -q "usage" || { echo "FAIL: нет usage для missing segment" >&2; fail=1; }

# (6) нечисловой segment
mkdir -p src && printf 'line1\nline2\n' > src/a.txt && git add src/a.txt && git commit -qm two
printf 'line1\nCHANGED\n' > src/a.txt
out="$(bash "$repo_root/lib/handoff.sh" 007 abc 2>&1 | tail -n 1)" || true
assert_eq "non-numeric segment" "False" "$(ok_of "$out")"
echo "$out" | grep -q "must be an integer" || { echo "FAIL: нет сообщения о том что segment должен быть числом" >&2; fail=1; }

# (7) невалидный task_id (содержит ..)
out="$(bash "$repo_root/lib/handoff.sh" '../evil' 2 2>&1 | tail -n 1)" || true
assert_eq "invalid task id" "False" "$(ok_of "$out")"
echo "$out" | grep -q "invalid characters" || { echo "FAIL: нет сообщения о невалидных символах в task_id" >&2; fail=1; }

# (8) невалидный task_id (содержит /)
out="$(bash "$repo_root/lib/handoff.sh" 'foo/bar' 2 2>&1 | tail -n 1)" || true
assert_eq "task id with /" "False" "$(ok_of "$out")"
echo "$out" | grep -q "invalid characters" || { echo "FAIL: нет сообщения о / в task_id" >&2; fail=1; }

# (9) застейдженные изменения должны попадать в дифф (ключевой тест раунда)
mkdir -p src2
printf 'staged1\nstaged2\n' > src2/staged.txt
git add src2/staged.txt
out="$(bash "$repo_root/lib/handoff.sh" 008 1 | tail -n 1)"
assert_eq "staged changes ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
grep -q "src2/staged.txt" "$p" || { echo "FAIL: staged файл не в статусе" >&2; fail=1; }
grep -q "staged1" "$p" || { echo "FAIL: содержимое staged файла не в диффе" >&2; fail=1; }

# (10) инвариант: состояние репозитория не изменилось после вызова скрипта
status_before="$(git status --porcelain)"
bash "$repo_root/lib/handoff.sh" 009 1 > /dev/null 2>&1 || true
status_after="$(git status --porcelain)"
assert_eq "repo state unchanged" "$status_before" "$status_after"

# (11) потолок по байтам: однострочный большой файл не встраивается целиком
rm .mvp/handoff-*.md 2>/dev/null || true
printf '%0.s*' {1..200000} > src/monster.txt  # 200KB в одну строку
out="$(bash "$repo_root/lib/handoff.sh" 010 1 | tail -n 1)"
assert_eq "big single-line ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
bytes="$(wc -c < "$p" 2>/dev/null || echo 0)"
# Файл должен быть ограничен (примерно 200KB бинарных данных + обвязка не должна превысить 500KB)
[ "$bytes" -lt 500000 ] || { echo "FAIL: файл-указатель $bytes байт, потолок не соблюдён" >&2; fail=1; }
grep -q "TRUNCATED" "$p" || { echo "FAIL: маркер обрезки для однострочного большого файла" >&2; fail=1; }

exit $fail
