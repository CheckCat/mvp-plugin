#!/usr/bin/env bash
# Tests for lib/handoff.sh
# Convention (tests/run.sh / tests/lib/gate.test.sh): exit 0 = pass.
#
# Round 2 fix C: round 1's suite reused ONE evolving git repo across every
# scenario. By the time the "single big line" scenario ran, src/big.txt (a
# 20000-line file from an earlier scenario) was still sitting untracked in
# the same tree, ahead of it alphabetically — so that scenario's TRUNCATED
# marker and final-size assertion were actually caused by big.txt, not by
# the thing it claimed to test. Verified: deleting BOTH byte-cap and
# line-cap code still left that assertion green as long as big.txt was
# present. Fixed by giving every scenario its own fresh git repo via
# new_repo() (same pattern as tests/lib/gate.test.sh's new_project_dir()).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
handoff="$repo_root/lib/handoff.sh"
fail=0
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

assert_eq() { local d="$1" e="$2" a="$3"; [ "$e" = "$a" ] || { echo "FAIL: $d — expected [$e], got [$a]" >&2; fail=1; }; }
ok_of() { O="$1" python3 -c 'import json,os; print(json.loads(os.environ["O"])["ok"])'; }
# valid_single_line_json <full-stdout> — exits 0 iff the string contains no
# literal newline AND is itself valid JSON. Used to prove finding A stays
# fixed: an attacker-controlled argument (embedded quote or embedded
# newline) must never be able to break stdout into more than one physical
# line or produce malformed JSON on that line. Checked against the FULL raw
# stdout (not a tail -n1 of it) — tail would trivially "fix" a multi-line
# break by discarding the corrupted prefix, hiding exactly the bug this is
# meant to catch.
valid_single_line_json() {
  local s="$1"
  case "$s" in
    *$'\n'*) return 1 ;;
  esac
  O="$s" python3 -c 'import json,os; json.loads(os.environ["O"])' >/dev/null 2>&1
}

# new_repo — fresh, isolated git repo + .mvp/, cd's into it, echoes its path.
new_repo() {
  local d
  d="$(mktemp -d -p "$tmproot")"
  (cd "$d" && git init -q . && git config user.email t@t.com && git config user.name t && git commit -q --allow-empty -m init)
  mkdir -p "$d/.mvp"
  cd "$d"
  echo "$d"
}

# ========== ОСНОВНЫЕ ТЕСТЫ (из спеки) ==========

# (1) чистое дерево → ok:false «не обрыв»
new_repo >/dev/null
out="$(bash "$handoff" 007 2 | tail -n 1)" || true
assert_eq "clean tree ok" "False" "$(ok_of "$out")"
echo "$out" | grep -q "clean tree" || { echo "FAIL: причина не названа" >&2; fail=1; }

# (2) грязное дерево → файл-указатель со status, diff, сегментом
new_repo >/dev/null
mkdir -p src && printf 'line1\nline2\n' > src/a.txt && git add src/a.txt && git commit -qm one
printf 'line1\nCHANGED\n' > src/a.txt && echo new > src/new.txt
out="$(bash "$handoff" 007 2 | tail -n 1)"
assert_eq "dirty tree ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
assert_eq "path" ".mvp/handoff-007.md" "$p"
grep -q "segment: 2" "$p" || { echo "FAIL: нет номера сегмента" >&2; fail=1; }
grep -q "src/a.txt" "$p" || { echo "FAIL: нет git status" >&2; fail=1; }
grep -q "CHANGED" "$p" || { echo "FAIL: нет диффа" >&2; fail=1; }
grep -q "new.txt" "$p" || { echo "FAIL: untracked не виден" >&2; fail=1; }

# (3) огромный дифф режется с маркером (изолированное дерево — только этот
# файл, никаких соседей от других сценариев)
new_repo >/dev/null
mkdir -p src && printf 'line1\nline2\n' > src/a.txt && git add src/a.txt && git commit -qm one
python3 -c "print('x\n' * 20000, end='')" > src/big.txt
out="$(bash "$handoff" 007 3 | tail -n 1)"
assert_eq "big ok" "True" "$(ok_of "$out")"
lines="$(wc -l < .mvp/handoff-007.md | tr -d ' ')"
[ "$lines" -le 4200 ] || { echo "FAIL: указатель $lines строк, cap 4000+обвязка" >&2; fail=1; }
grep -q "TRUNCATED" .mvp/handoff-007.md || { echo "FAIL: нет маркера обрезки" >&2; fail=1; }

# ========== ГРАНИЧНЫЕ И ОШИБОЧНЫЕ ВЕТКИ ==========

# (4) не git репо
d="$(mktemp -d -p "$tmproot")"; cd "$d"
out="$(bash "$handoff" 007 2 2>&1 | tail -n 1)" || true
assert_eq "not git repo" "False" "$(ok_of "$out")"
echo "$out" | grep -q "not a git repo" || { echo "FAIL: не обнаружено что это не git репо" >&2; fail=1; }

# (5) отсутствующие аргументы
new_repo >/dev/null
out="$(bash "$handoff" 2>&1 | tail -n 1)" || true
assert_eq "no args" "False" "$(ok_of "$out")"
echo "$out" | grep -q "usage" || { echo "FAIL: нет usage" >&2; fail=1; }

out="$(bash "$handoff" 007 2>&1 | tail -n 1)" || true
assert_eq "missing segment" "False" "$(ok_of "$out")"
echo "$out" | grep -q "usage" || { echo "FAIL: нет usage для missing segment" >&2; fail=1; }

# (6) нечисловой segment
new_repo >/dev/null
mkdir -p src && printf 'line1\nline2\n' > src/a.txt && git add src/a.txt && git commit -qm two
printf 'line1\nCHANGED\n' > src/a.txt
out="$(bash "$handoff" 007 abc 2>&1 | tail -n 1)" || true
assert_eq "non-numeric segment" "False" "$(ok_of "$out")"
echo "$out" | grep -q "must be an integer" || { echo "FAIL: нет сообщения о том что segment должен быть числом" >&2; fail=1; }

# (6a) round 2 fix A — критично: segment с кавычкой и segment с переводом
# строки не должны ломать JSON-контракт. Воспроизводит ровно то, чем это
# было поймано в ре-ревью: аргумент x"y и аргумент с \n. Проверяем ПОЛНЫЙ
# stdout (не tail -n1 от него — tail молча "чинит" разрыв на несколько
# строк, отбрасывая испорченный кусок, и тогда именно эта поломка
# перестаёт быть видна тесту).
out="$(bash "$handoff" 007 'x"y' 2>&1)"
valid_single_line_json "$out" || { echo "FAIL: кавычка в segment ломает JSON: [$out]" >&2; fail=1; }
assert_eq "quoted segment -> ok false" "False" "$(ok_of "$out")"
echo "$out" | grep -q 'x\\"y' || { echo "FAIL: значение с кавычкой не попало в hint экранированным" >&2; fail=1; }

out="$(bash "$handoff" 007 "$(printf 'a\nb')" 2>&1)"
valid_single_line_json "$out" || { echo "FAIL: перевод строки в segment ломает JSON stdout на несколько физических строк: [$out]" >&2; fail=1; }
assert_eq "newline segment -> ok false" "False" "$(ok_of "$out")"

# (7) невалидный task_id (содержит ..)
out="$(bash "$handoff" '../evil' 2 2>&1 | tail -n 1)" || true
assert_eq "invalid task id" "False" "$(ok_of "$out")"
echo "$out" | grep -q "invalid characters" || { echo "FAIL: нет сообщения о невалидных символах в task_id" >&2; fail=1; }

# (8) невалидный task_id (содержит /)
out="$(bash "$handoff" 'foo/bar' 2 2>&1 | tail -n 1)" || true
assert_eq "task id with /" "False" "$(ok_of "$out")"
echo "$out" | grep -q "invalid characters" || { echo "FAIL: нет сообщения о / в task_id" >&2; fail=1; }

# (9) застейдженные изменения должны попадать в дифф
new_repo >/dev/null
mkdir -p src2
printf 'staged1\nstaged2\n' > src2/staged.txt
git add src2/staged.txt
out="$(bash "$handoff" 008 1 | tail -n 1)"
assert_eq "staged changes ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
grep -q "src2/staged.txt" "$p" || { echo "FAIL: staged файл не в статусе" >&2; fail=1; }
grep -q "staged1" "$p" || { echo "FAIL: содержимое staged файла не в диффе" >&2; fail=1; }

# (10) инвариант: скрипт не меняет состояние git-репозитория (не коммитит,
# не стейджит, не переключает ветки — см. «Ограничения» в задаче). Это НЕ
# то же самое, что «working tree байт-в-байт не меняется»: сам скрипт
# САНКЦИОНИРОВАННО создаёт ровно один новый файл, .mvp/handoff-<task>.md —
# это его единственная задача, а не побочный эффект, который надо ловить.
# Прежняя версия теста сравнивала сырой `git status --porcelain` целиком и
# «проходила» только потому, что в общем (незаизолированном, см. round 2
# fix C) дереве .mvp/ к этому моменту уже был untracked-каталогом с
# файлами от предыдущих сценариев — git схлопывает такой каталог в одну
# строку "?? .mvp/" независимо от того, сколько файлов внутри, так что
# появление ещё одного файла ничего не меняло в выводе. В изолированном
# дереве этого сценария .mvp/ пуст до вызова (пустые untracked-каталоги
# git вообще не показывает), поэтому та же самая сырая проверка красит
# тест ложно-красным на совершенно корректном поведении скрипта — то есть
# была не строгой проверкой инварианта, а совпадением фикстуры. Проверяем
# вместо этого именно то, что запрещено (HEAD, индекс, всё вне .mvp/).
new_repo >/dev/null
mkdir -p src3 && echo x > src3/f.txt
head_before="$(git rev-parse HEAD)"
staged_before="$(git diff --cached --name-only)"
outside_before="$(git status --porcelain -- ':!.mvp')"
bash "$handoff" 009 1 > /dev/null 2>&1 || true
head_after="$(git rev-parse HEAD)"
staged_after="$(git diff --cached --name-only)"
outside_after="$(git status --porcelain -- ':!.mvp')"
assert_eq "HEAD unchanged" "$head_before" "$head_after"
assert_eq "index (staged) unchanged" "$staged_before" "$staged_after"
assert_eq "nothing outside .mvp touched" "$outside_before" "$outside_after"

# (11) потолок по байтам: огромный ДИФФ ОТСЛЕЖИВАЕМОГО файла в СВОЁМ
# изолированном дереве (round 2 fix C) — ничего от других сценариев рядом.
# round 3 fix ввёл отдельный per-file потолок для UNTRACKED-файлов
# (см. сценарий 12a) — однострочный untracked-монстр теперь перехватывается
# ИМ раньше, чем успевает добраться до общего байтового среза, так что для
# проверки именно общего BYTES_CAP нужен путь, который per-file потолку не
# подчиняется: git diff HEAD у отслеживаемого файла per-file-порогу не
# подвергается вообще (тот применяется только к содержимому untracked-
# файлов при встраивании).
new_repo >/dev/null
mkdir -p src
echo x > src/monster.txt && git add src/monster.txt && git commit -qm "track monster"
python3 -c "open('src/monster.txt','w').write('*'*200000)"  # 200KB в одну строку, tracked-правка
out="$(bash "$handoff" 010 1 | tail -n 1)"
assert_eq "big single-line ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
bytes="$(wc -c < "$p" 2>/dev/null || echo 0)"
[ "$bytes" -lt 200000 ] || { echo "FAIL: файл-указатель $bytes байт, байтовый потолок не соблюдён" >&2; fail=1; }
grep -q "TRUNCATED" "$p" || { echo "FAIL: маркер обрезки для однострочного большого файла" >&2; fail=1; }

# (12) round 2 fix B — untracked-файл, похожий на бинарный (NUL-байт в
# начале), НЕ встраивается содержимым: маркер есть, имя файла видно,
# полезной нагрузки (SECRETPAYLOAD) в указателе нет.
new_repo >/dev/null
mkdir -p src
printf '\x00SECRETPAYLOAD\x01\x02\x03' > src/blob.bin
out="$(bash "$handoff" 011 1 | tail -n 1)"
assert_eq "binary file ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
grep -q "BINARY FILE" "$p" || { echo "FAIL: нет пометки о пропущенном бинарном файле" >&2; fail=1; }
grep -q "blob.bin" "$p" || { echo "FAIL: имя бинарного файла не видно в указателе" >&2; fail=1; }
grep -q "SECRETPAYLOAD" "$p" && { echo "FAIL: содержимое бинарного файла встроено в текстовый указатель" >&2; fail=1; }
true

# (12a) round 3 fix — крупный untracked-файл, идущий РАНЬШЕ по алфавиту,
# не должен вытеснять содержимое мелкого файла, идущего позже. Раунд 2
# читал/склеивал все не-бинарные untracked-файлы целиком и резал только
# итоговую склейку — один крупный артефакт съедал общий бюджет и от всех
# файлов после него в указателе не оставалось ни байта содержимого.
new_repo >/dev/null
mkdir -p src
python3 -c "open('src/aaa_big.txt','w').write('x'*160000)"  # раньше по алфавиту, крупный
printf 'SMALLMARKER\n' > src/zzz_small.txt                  # позже по алфавиту, маленький
out="$(bash "$handoff" 016 1 | tail -n 1)"
assert_eq "large-then-small ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
grep -q "SMALLMARKER" "$p" || { echo "FAIL: содержимое маленького файла вытеснено крупным (round 3 regression)" >&2; fail=1; }
grep -q "FILE TOO LARGE" "$p" || { echo "FAIL: нет пометки о пропущенном крупном файле" >&2; fail=1; }
grep -q "aaa_big.txt" "$p" || { echo "FAIL: имя крупного файла не видно в указателе" >&2; fail=1; }

# (13) round 2 fix E — усечение по байтовому потолку не должно рвать
# UTF-8: указатель целиком остаётся валидным UTF-8 даже когда обрезка
# приходится на середину многобайтового русского текста.
new_repo >/dev/null
mkdir -p src
python3 -c "open('src/ru.txt','w',encoding='utf-8').write('привет мир! '*20000)"
out="$(bash "$handoff" 012 1 | tail -n 1)"
assert_eq "utf8 truncation ok" "True" "$(ok_of "$out")"
p="$(O="$out" python3 -c 'import json,os; print(json.loads(os.environ["O"])["data"]["path"])')"
python3 -c "
import sys
data = open('$p', 'rb').read()
try:
    text = data.decode('utf-8')
except UnicodeDecodeError as e:
    sys.exit('invalid utf-8: %s' % e)
# Незавершённый хвост должен быть ОТБРОШЕН (errors='ignore'), а не
# заменён U+FFFD (errors='replace') — round 2 fix E требует именно отказ
# от хвоста, не видимый мусор посреди кириллицы. � в выводе означает,
# что усечение снова делает replace вместо ignore.
if '�' in text:
    sys.exit('replacement character U+FFFD found — truncation used errors=\"replace\" instead of dropping the incomplete tail')
" || { echo "FAIL: итоговый указатель — невалидный UTF-8 или содержит мусорный replacement-символ после усечения" >&2; fail=1; }

# (14) round 2 fix D — mkdir .mvp не удаётся, если .mvp уже существует как
# обычный файл (не каталог).
d="$(mktemp -d -p "$tmproot")"; cd "$d"
git init -q . && git config user.email t@t.com && git config user.name t && git commit -q --allow-empty -m init
echo dirty > f.txt
touch .mvp
out="$(bash "$handoff" 013 1 2>/dev/null | tail -n 1)" || true
assert_eq "mkdir .mvp fails" "False" "$(ok_of "$out")"
echo "$out" | grep -q "failed to create .mvp directory" || { echo "FAIL: причина не про mkdir .mvp" >&2; fail=1; }

# (15) round 2 fix D — запись файла-указателя не удаётся при .mvp только
# для чтения; предыдущий handoff-файл (если был) не портится (атомарность).
new_repo >/dev/null
mkdir -p src && echo dirty > src/f.txt
chmod 555 .mvp
out="$(bash "$handoff" 014 1 2>/dev/null | tail -n 1)" || true
chmod 755 .mvp
assert_eq "write to readonly .mvp fails" "False" "$(ok_of "$out")"
echo "$out" | grep -q "check disk space and permissions" || { echo "FAIL: нет hint про права/место" >&2; fail=1; }
[ -f .mvp/handoff-014.md ] && { echo "FAIL: частично записанный файл остался на диске" >&2; fail=1; }
true

exit $fail
