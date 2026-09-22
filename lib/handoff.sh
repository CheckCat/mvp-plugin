#!/usr/bin/env bash
# lib/handoff.sh <task_id> <segment> — реконструктор указателя для CAP-рукава
# (спека 2026-09-22 §9). Вызывается релеем из workflow.mjs, когда имплементер
# оборван потолком ходов: собирает из git-состояния структурированное
# изложение «что уже сделано», которое читает агент-продолжение. Финальный
# вердикт дискуссии: указатель этого класса — УСЛОВИЕ применимости E=7;
# без него продолжение перепроходит разведку (E≈11.5).
# Чистое дерево — это НЕ обрыв по потолку (обрыв всегда оставляет правки):
# ok:false, диспетчер паркует задачу обычным путём.
set -u
TASK="${1:-}"; SEG="${2:-}"

# Валидируем аргументы ПЕРЕД любым выводом JSON
[ -n "$TASK" ] && [ -n "$SEG" ] || { printf '%s\n' '{"ok":false,"reason":"usage: handoff.sh <task_id> <segment>","hint":null,"data":null}'; exit 1; }

# Валидируем segment: должно быть число
if ! [[ "$SEG" =~ ^[0-9]+$ ]]; then
  printf '%s\n' '{"ok":false,"reason":"segment must be an integer","hint":"got: '"$SEG"'","data":null}'
  exit 1
fi

# Валидируем task_id: безопасные символы (недопустимы .. и /)
if ! [[ "$TASK" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  printf '%s\n' '{"ok":false,"reason":"task_id contains invalid characters","hint":"allowed: [a-zA-Z0-9_-]","data":null}'
  exit 1
fi

DIFF_CAP=4000
BYTES_CAP=102400  # 100KB — потолок по размеру встраивания untracked файлов

# Проверяем что это git репозиторий
status="$(git status --porcelain 2>/dev/null)" || { printf '%s\n' '{"ok":false,"reason":"not a git repo","hint":null,"data":null}'; exit 1; }

# Чистое дерево — не обрыв по потолку
if [ -z "$status" ]; then
  printf '%s\n' '{"ok":false,"reason":"clean tree — not a cap break","hint":"a turn-capped implementer always leaves edits; treat this as an ordinary failure and park","data":{"task":"'"$TASK"'"}}'
  exit 1
fi

# Вычисляем дифф один раз (git diff HEAD захватит staged и unstaged изменения)
# Также встраиваем untracked файлы, которые меньше порога по размеру
diff_output="$(
  git diff HEAD
  git ls-files --others --exclude-standard | while read -r f; do
    if [ -f "$f" ]; then
      fsize="$(wc -c < "$f" 2>/dev/null || echo "$((BYTES_CAP + 1))")"
      # Встраиваем только если файл меньше 50KB (половина потолка, для оставления места на форматирование)
      if [ "$fsize" -lt 51200 ]; then
        echo "diff --git a/$f b/$f"
        echo "new file"
        echo "--- /dev/null"
        echo "+++ b/$f"
        cat "$f"
        echo
      fi
    fi
  done
)"

# Обрезаем по числу строк для вывода
diff_for_output="$(echo "$diff_output" | head -n "$DIFF_CAP")"
diff_output_lines="$(echo "$diff_output" | wc -l)"
truncated=0

# Проверяем оба потолка: по строкам и по байтам
if [ "$diff_output_lines" -gt "$DIFF_CAP" ]; then
  truncated=1
fi

diff_bytes="$(echo "$diff_for_output" | wc -c)"
if [ "$diff_bytes" -gt "$BYTES_CAP" ]; then
  truncated=1
  # Обрезаем еще сильнее по байтам
  diff_for_output="$(echo "$diff_output" | head -c "$BYTES_CAP")"
fi

# Создаём директорию .mvp
mkdir -p .mvp || { printf '%s\n' '{"ok":false,"reason":"failed to create .mvp directory","hint":"check permissions and disk space","data":null}'; exit 1; }

out=".mvp/handoff-$TASK.md"

# Пишем файл-указатель
{
  echo "# Handoff pointer — task $TASK, segment: $SEG"
  echo
  echo "Предыдущий агент этой задачи оборван потолком ходов. Ниже — что уже"
  echo "сделано в рабочем дереве (НЕ переделывай это заново):"
  echo
  echo '## git status --short'
  echo '```'
  git status --short
  echo '```'
  echo
  echo "## git diff HEAD (первые $DIFF_CAP строк / $BYTES_CAP bytes)"
  echo '```diff'
  echo "$diff_for_output"
  if [ "$truncated" -eq 1 ]; then
    echo "[TRUNCATED — смотри полный diff: git diff HEAD]"
  fi
  echo '```'
  echo
  echo '## Untracked-файлы (созданы предыдущим сегментом, содержимое смотри сам)'
  echo '```'
  git ls-files --others --exclude-standard
  echo '```'
  echo
  echo "Отчёт предыдущего сегмента, если он успел его писать: .mvp/reports/task-$TASK.md"
} > "$out" || { printf '%s\n' '{"ok":false,"reason":"failed to write handoff file","hint":"check disk space and permissions for .mvp/","data":null}'; exit 1; }

# Проверяем что файл успешно создан и не пустой
if [ ! -s "$out" ]; then
  printf '%s\n' '{"ok":false,"reason":"handoff file is empty or was not written","hint":"check write permissions for '"$out"'","data":null}'
  exit 1
fi

# Успех: выводим путь и номер сегмента
printf '{"ok":true,"reason":null,"hint":null,"data":{"path":"%s","segment":%s}}\n' "$out" "$SEG"
