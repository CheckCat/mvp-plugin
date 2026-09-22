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
[ -n "$TASK" ] && [ -n "$SEG" ] || { printf '%s\n' '{"ok":false,"reason":"usage: handoff.sh <task_id> <segment>","hint":null,"data":null}'; exit 1; }
DIFF_CAP=4000

status="$(git status --porcelain 2>/dev/null)" || { printf '%s\n' '{"ok":false,"reason":"not a git repo","hint":null,"data":null}'; exit 1; }
if [ -z "$status" ]; then
  H_T="$TASK" python3 -c 'import json,os; print(json.dumps({"ok":False,"reason":"clean tree — not a cap break","hint":"a turn-capped implementer always leaves edits; treat this as an ordinary failure and park","data":{"task":os.environ["H_T"]}}))'
  exit 1
fi

mkdir -p .mvp
out=".mvp/handoff-$TASK.md"
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
  echo "## git diff (первые $DIFF_CAP строк)"
  echo '```diff'
  {
    git diff
    git ls-files --others --exclude-standard | while read -r f; do
      if [ -f "$f" ]; then
        echo "diff --git a/$f b/$f"
        echo "new file"
        echo "--- /dev/null"
        echo "+++ b/$f"
        cat "$f"
        echo
      fi
    done
  } | head -n "$DIFF_CAP"
  diff_content="$({ git diff; git ls-files --others --exclude-standard | while read -r f; do if [ -f "$f" ]; then echo "diff --git a/$f b/$f"; echo "new file"; echo "--- /dev/null"; echo "+++ b/$f"; cat "$f"; echo; fi; done; })"
  diff_lines="$(echo "$diff_content" | wc -l)"
  if [ "$diff_lines" -gt "$DIFF_CAP" ]; then echo "[TRUNCATED at $DIFF_CAP lines — смотри полный diff командой git diff]"; fi
  echo '```'
  echo
  echo '## Untracked-файлы (созданы предыдущим сегментом, содержимое смотри сам)'
  echo '```'
  git ls-files --others --exclude-standard
  echo '```'
  echo
  echo "Отчёт предыдущего сегмента, если он успел его писать: .mvp/reports/task-$TASK.md"
} > "$out"

H_OUT="$out" H_SEG="$SEG" python3 -c 'import json,os; print(json.dumps({"ok":True,"reason":None,"hint":None,"data":{"path":os.environ["H_OUT"],"segment":int(os.environ["H_SEG"])}}))'
