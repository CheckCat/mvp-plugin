#!/usr/bin/env bash
# lib/handoff.sh <task_id> <segment> — реконструктор указателя для CAP-рукава
# (спека 2026-09-22 §9). Вызывается релеем из workflow.mjs, когда имплементер
# оборван потолком ходов: собирает из git-состояния структурированное
# изложение «что уже сделано», которое читает агент-продолжение. Финальный
# вердикт дискуссии: указатель этого класса — УСЛОВИЕ применимости E=7;
# без него продолжение перепроходит разведку (E≈11.5).
# Чистое дерево — это НЕ обрыв по потолку (обрыв всегда оставляет правки):
# ok:false, диспетчер паркует задачу обычным путём.
#
# Single-line JSON contract on every exit path (см. lib/gate.sh):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false всегда exit 1. Скрипт никогда не меняет состояние репозитория:
# только читает git, пишет ровно один файл под .mvp/.
#
# Round 2 fix log (ре-ревью раунда 1 нашло дыры в этих же местах):
#   A (critical) — ветка «segment не число» строила JSON вручную через
#     printf с конкатенацией необработанного аргумента прямо в JSON-текст:
#     `'"$SEG"'`. Аргумент с кавычкой ломал JSON, аргумент с переводом
#     строки размножал строки stdout — оба прямое нарушение центрального
#     инварианта. Исправлено радикально: единственная точка вывода —
#     emit_result, значения идут в python ТОЛЬКО через env, program-текст
#     статичен. Стиль — skills/bootstrap/scripts/verify-agents-drift.sh
#     (её emit_result) / lib/gate.sh.
#   B (important) — untracked-файлы, похожие на бинарные, раньше либо
#     встраивались как есть, либо отсекались произвольным байтовым
#     порогом (не то же самое, что определение бинарности). Теперь перед
#     встраиванием каждый untracked-файл сканируется на NUL-байт в первых
#     8000 байтах — та же эвристика, что использует сам git (см. коммент в
#     lib/review-package.sh: "git calls a file binary when it finds a NUL
#     byte in the first 8000" — уже прецедент в этом репозитории). Бинарные
#     файлы получают видимую пометку вместо содержимого, самим содержимым
#     скрипт больше не рискует.
#   D — ветки «mkdir .mvp не удался» / «запись не удалась» покрыты тестами.
#     Проверка непустоты итогового файла оставлена как defense-in-depth
#     поверх атомарной записи — см. отчёт задачи, почему её нельзя честно
#     дискриминирующе протестировать чёрным ящиком (контент всегда
#     непустой по построению — заголовок пишется безусловно).
#   E (minor) — усечение диффа теперь текстовое (python str), а не
#     байтовое: границы режутся по символам, а незавершённый хвост UTF-8
#     после байтового потолка отбрасывается, не превращаясь в мусор
#     посреди кириллицы (в этом репозитории комментарии и markdown — на
#     русском).
#
# Round 3 fix (ре-ревью раунда 2, переклассифицировано в Important):
#   раунд 2 убрал per-file порог на untracked-файл, который был в раунде 1,
#   и стал читать/склеивать ВСЕ не-бинарные untracked-файлы целиком,
#   применяя общий потолок только к итоговой склейке. Обход алфавитный
#   (git ls-files), поэтому один крупный артефакт/дамп, оказавшийся раньше
#   по имени, съедал весь байтовый бюджет — от всех файлов после него в
#   указателе не оставалось ни байта содержимого, только имя в списке.
#   Вернул отсечение по размеру НА УРОВНЕ ОТДЕЛЬНОГО ФАЙЛА, до склейки:
#   файл больше FILE_CAP получает ту же видимую пометку, что и бинарный,
#   вместо содержимого. Общий потолок (DIFF_CAP/BYTES_CAP) остаётся вторым
#   рубежом поверх — на случай когда много мелких файлов вместе всё равно
#   превышают бюджет.
#
# Round 4 fix (финальное ревью ветки, находки 1 и 3):
#   A (important) — самовключение: `git ls-files --others` захватывает и
#     .mvp/** — а там лежит ПРЕДЫДУЩИЙ указатель этого же задания
#     (.mvp/handoff-<task>.md), бриф задачи, незакоммиченные отчёты. На
#     втором сегменте скрипт инлайнил их как untracked-контент — указатель
#     встраивал сам себя, сжигая бюджет на дубли. Тот же класс бага уже был
#     пойман в lib/review-package.sh (см. её заголовочный коммент про
#     self-inclusion) — здесь унаследовано то же решение: .mvp/** исключён
#     из untracked-встраивания целиком, до всех остальных фильтров (bin/
#     large). git status --short для .mvp/** не фильтруется отдельно — это
#     обычно один схлопнутый untracked-каталог ("?? .mvp/") или несколько
#     СТРОК статуса, не содержимое; проблема только в инлайне содержимого.
#   B (minor) — у секций «git status --short» и «список untracked-путей»
#     не было СВОИХ потолков (только у диффа+untracked-контента: DIFF_CAP/
#     BYTES_CAP). Дерево с тысячами untracked-путей (например: неигнорируемый
#     каталог сборки) раздувало указатель мимо всех ограничений через эти
#     две секции. Добавлены STATUS_CAP/UNTRACKED_LIST_CAP (строк) с той же
#     видимой пометкой обрезки, что уже есть у диффа.
set -u

# emit_result <ok:true|false> <reason> <hint> <data-json-or-empty>
#   Единственная точка вывода итогового JSON — используется ВСЕМИ ветками,
#   отказными и успешной. reason/hint: пустая строка -> null. data: пустая
#   строка -> null, иначе обязана быть валидным JSON-текстом. Значения
#   попадают в python только через env (HO_*), как аргументы bash-функции
#   ($1..$4), а не как подстрока внутри текста python-программы, так что
#   кавычка/перевод строки/что угодно в значении не может сломать вывод.
emit_result() {
  HO_OK="$1" HO_REASON="$2" HO_HINT="$3" HO_DATA="$4" python3 -c '
import json, os
ok = os.environ["HO_OK"] == "true"
reason = os.environ.get("HO_REASON") or None
hint = os.environ.get("HO_HINT") or None
data_raw = os.environ.get("HO_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

TASK="${1:-}"; SEG="${2:-}"

[ -n "$TASK" ] && [ -n "$SEG" ] || {
  emit_result false "usage: handoff.sh <task_id> <segment>" "" ""
  exit 1
}

if ! [[ "$SEG" =~ ^[0-9]+$ ]]; then
  emit_result false "segment must be an integer" "got: $SEG" ""
  exit 1
fi

if ! [[ "$TASK" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  emit_result false "task_id contains invalid characters" "allowed: [a-zA-Z0-9_-], got: $TASK" ""
  exit 1
fi

DIFF_CAP=4000       # строк
BYTES_CAP=102400    # 100KB
FILE_CAP=51200      # 50KB — потолок на ОТДЕЛЬНЫЙ untracked-файл (round 3
                    # fix): половина общего байтового потолка, тот же
                    # выбор, что уже был обоснован в round 1 для этой роли
                    # (оставляет место под обвязку/другие файлы, не даёт
                    # одному артефакту съесть весь бюджет до общего среза)
STATUS_CAP=500          # строк — потолок секции `git status --short` (round 4
                        # fix B: без него дерево с тысячами путей раздувает
                        # указатель мимо DIFF_CAP/BYTES_CAP, у которых эта
                        # секция вообще не в области действия)
UNTRACKED_LIST_CAP=500  # строк — потолок секции «список untracked-путей»
                        # (тот же класс проблемы, что у STATUS_CAP выше;
                        # содержимое untracked-файлов режется отдельно —
                        # FILE_CAP/DIFF_CAP/BYTES_CAP — это только ИМЕНА)

status="$(git status --porcelain 2>/dev/null)" || {
  emit_result false "not a git repo" "" ""
  exit 1
}

if [ -z "$status" ]; then
  DATA="$(HO_TASK="$TASK" python3 -c 'import json,os; print(json.dumps({"task": os.environ["HO_TASK"]}))')"
  emit_result false "clean tree — not a cap break" \
    "a turn-capped implementer always leaves edits; treat this as an ordinary failure and park" "$DATA"
  exit 1
fi

mkdir -p .mvp || {
  emit_result false "failed to create .mvp directory" "check permissions and disk space" ""
  exit 1
}

out=".mvp/handoff-$TASK.md"

# Сырые куски git-состояния уходят во временные файлы, а не в env: у env
# есть предел размера (ARG_MAX), а грязное дерево может дать дифф на
# десятки тысяч строк ещё до всякого усечения. python читает файлы.
work="$(mktemp -d)" || {
  emit_result false "failed to create temp workspace" "" ""
  exit 1
}
trap 'rm -rf "$work"' EXIT

git status --short > "$work/status.txt" 2>/dev/null
# git diff HEAD, а не просто git diff: захватывает и staged, и unstaged
# изменения tracked-файлов одной командой (round 1 fix — сохраняем).
git diff HEAD > "$work/diff.txt" 2>/dev/null
git ls-files --others --exclude-standard -z > "$work/untracked.nul" 2>/dev/null

# Основная сборка + атомарная запись — одним python-процессом. На успехе
# печатает {"ok":true,...}; на любой ошибке (включая падение записи) ловит
# исключение и печатает {"ok":false,"error":...} сама, ничего не теряя
# молча. Итоговый CLI-ответ всё равно строит только emit_result — этот
# вывод бэш разбирает и передаёт в emit_result дальше.
BUILD_JSON="$(
  HO_TASK="$TASK" HO_SEG="$SEG" HO_OUT_DIR=".mvp" HO_OUT_NAME="handoff-$TASK.md" \
  HO_STATUS_FILE="$work/status.txt" HO_DIFF_FILE="$work/diff.txt" \
  HO_UNTRACKED_FILE="$work/untracked.nul" \
  HO_DIFF_CAP="$DIFF_CAP" HO_BYTES_CAP="$BYTES_CAP" HO_FILE_CAP="$FILE_CAP" \
  HO_STATUS_CAP="$STATUS_CAP" HO_UNTRACKED_LIST_CAP="$UNTRACKED_LIST_CAP" \
  python3 - <<'PY'
import json, os, sys, tempfile


def looks_binary(path, sniff=8000):
    # Та же эвристика, что git: NUL-байт в первых 8000 байтах файла — см.
    # заголовочный коммент lib/review-package.sh. Нечитаемый файл тоже
    # трактуем как "нельзя встраивать" (fail closed, не молча пропустить).
    try:
        with open(path, "rb") as fh:
            chunk = fh.read(sniff)
    except OSError:
        return True
    return b"\x00" in chunk


def truncate_text_safely(text, cap_bytes):
    # Round 2 fix E: режем по UTF-8 БАЙТОВОМУ потолку, но не байтовым
    # срезом str-объекта — кодируем, режем bytes, декодируем обратно с
    # errors="ignore", так что незавершённая хвостовая последовательность
    # отбрасывается, а не превращается в мусор посреди русского текста.
    data = text.encode("utf-8")
    if len(data) <= cap_bytes:
        return text, False
    return data[:cap_bytes].decode("utf-8", errors="ignore"), True


def truncate_lines(items, cap):
    # Round 4 fix B: тот же приём, что truncate_text_safely, но по числу
    # строк/элементов списка, а не по байтам — для секций, у которых
    # единица измерения "одна строка/один путь", не "поток текста".
    if len(items) <= cap:
        return items, False
    return items[:cap], True


try:
    task = os.environ["HO_TASK"]
    seg = int(os.environ["HO_SEG"])
    out_dir = os.environ["HO_OUT_DIR"]
    out_name = os.environ["HO_OUT_NAME"]
    out_path = os.path.join(out_dir, out_name)
    diff_cap = int(os.environ["HO_DIFF_CAP"])
    bytes_cap = int(os.environ["HO_BYTES_CAP"])
    file_cap = int(os.environ["HO_FILE_CAP"])
    status_cap = int(os.environ["HO_STATUS_CAP"])
    untracked_list_cap = int(os.environ["HO_UNTRACKED_LIST_CAP"])

    with open(os.environ["HO_STATUS_FILE"], encoding="utf-8", errors="replace") as fh:
        status_text = fh.read()
    with open(os.environ["HO_DIFF_FILE"], encoding="utf-8", errors="replace") as fh:
        diff_text = fh.read()
    with open(os.environ["HO_UNTRACKED_FILE"], "rb") as fh:
        raw = fh.read()
    untracked = [p.decode("utf-8", "replace") for p in raw.split(b"\x00") if p]

    # Round 4 fix A — самовключение: .mvp/** несёт ПРЕДЫДУЩИЙ указатель этого
    # же задания (.mvp/handoff-<task>.md), бриф, незакоммиченные отчёты —
    # git ls-files --others их видит как untracked. Без исключения второй
    # сегмент инлайнил бы их как содержимое untracked-файлов, встраивая
    # указатель сам в себя. Тот же класс бага и то же решение, что в
    # lib/review-package.sh (см. её заголовочный коммент про self-inclusion).
    # Фильтр — ДО эмбеддинга и ДО отображаемого списка путей, единой точкой.
    STATE_PREFIX = ".mvp/"
    untracked = [p for p in untracked if p != ".mvp" and not p.startswith(STATE_PREFIX)]

    parts = [diff_text]
    skipped_binary = []
    skipped_large = []
    for f in untracked:
        if not os.path.isfile(f):
            continue
        if looks_binary(f):
            skipped_binary.append(f)
            parts.append(
                "diff --git a/%s b/%s\nnew file\n"
                "[BINARY FILE — содержимое пропущено (round 2 fix B): %s]\n" % (f, f, f)
            )
            continue
        try:
            fsize = os.path.getsize(f)
        except OSError:
            fsize = file_cap + 1  # неизвестный размер — не встраиваем (fail closed)
        if fsize > file_cap:
            # Round 3 fix: отсечение ПО ОТДЕЛЬНОМУ ФАЙЛУ, до склейки в общий
            # diff_output. Без этого один крупный файл, идущий раньше по
            # алфавиту в git ls-files, съедал общий байтовый потолок целиком
            # и вытеснял содержимое всех файлов после себя — а они как раз
            # обычно собственная незакоммиченная работа агента, в отличие от
            # крупного файла, который чаще артефакт сборки/дамп.
            skipped_large.append(f)
            parts.append(
                "diff --git a/%s b/%s\nnew file\n"
                "[FILE TOO LARGE — содержимое пропущено (round 3 fix, %d > %d bytes): %s]\n"
                % (f, f, fsize, file_cap, f)
            )
            continue
        with open(f, encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        parts.append(
            "diff --git a/%s b/%s\nnew file\n--- /dev/null\n+++ b/%s\n%s\n" % (f, f, f, content)
        )

    diff_output = "".join(parts)

    truncated = False
    lines = diff_output.splitlines(keepends=True)
    if len(lines) > diff_cap:
        diff_output = "".join(lines[:diff_cap])
        truncated = True

    diff_output, byte_truncated = truncate_text_safely(diff_output, bytes_cap)
    truncated = truncated or byte_truncated

    # Round 4 fix B: у секций "git status" и "список untracked-путей" не было
    # СВОИХ потолков — дерево с тысячами путей раздувало указатель мимо
    # DIFF_CAP/BYTES_CAP, которые эту пару секций вообще не ограничивают.
    # Список для эмбеддинга (`untracked`, цикл выше) остаётся ПОЛНЫМ — режется
    # только его текстовое ОТОБРАЖЕНИЕ ниже, содержимого файлов это не касается.
    status_lines, status_truncated = truncate_lines(status_text.splitlines(), status_cap)
    untracked_display, untracked_list_truncated = truncate_lines(untracked, untracked_list_cap)

    body = [
        "# Handoff pointer — task %s, segment: %d" % (task, seg),
        "",
        "Предыдущий агент этой задачи оборван потолком ходов. Ниже — что уже",
        "сделано в рабочем дереве (НЕ переделывай это заново):",
        "",
        "## git status --short (потолок %d строк)" % status_cap,
        "```",
        "\n".join(status_lines),
    ]
    if status_truncated:
        body.append("[TRUNCATED — смотри полное состояние: git status --short]")
    body += [
        "```",
        "",
        "## git diff HEAD + untracked-файлы (потолок %d строк / %d байт)" % (diff_cap, bytes_cap),
        "```diff",
        diff_output.rstrip("\n"),
    ]
    if truncated:
        body.append("[TRUNCATED — смотри полное состояние: git diff HEAD]")
    body += [
        "```",
        "",
        "## Untracked-файлы (созданы предыдущим сегментом, потолок %d строк)" % untracked_list_cap,
        "```",
        "\n".join(untracked_display),
    ]
    if untracked_list_truncated:
        body.append("[TRUNCATED — смотри полный список: git ls-files --others --exclude-standard]")
    body += [
        "```",
    ]
    if skipped_binary:
        body += [
            "",
            "## Похожие на бинарные — содержимое НЕ встроено (round 2 fix B)",
            "```",
            "\n".join(skipped_binary),
            "```",
        ]
    if skipped_large:
        body += [
            "",
            "## Слишком крупные (> %d байт) — содержимое НЕ встроено (round 3 fix)" % file_cap,
            "```",
            "\n".join(skipped_large),
            "```",
        ]
    body += [
        "",
        "Отчёт предыдущего сегмента, если он успел его писать: .mvp/reports/task-%s.md" % task,
        "",
    ]
    content = "\n".join(body)

    # Атомарная запись: NamedTemporaryFile в ТОЙ ЖЕ директории (гарантирует
    # os.replace как переименование на одном разделе, не кросс-device
    # copy) + os.replace. Наблюдатель никогда не увидит частично записанный
    # .mvp/handoff-<task>.md.
    tmp = tempfile.NamedTemporaryFile(
        mode="w", dir=out_dir, prefix=".handoff-tmp-", suffix=".md",
        delete=False, encoding="utf-8",
    )
    try:
        tmp.write(content)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        # Непустота итогового файла — defense-in-depth поверх атомарной
        # записи (см. отчёт: content всегда непустой по построению, эта
        # проверка ловит гипотетическую порчу самой записи, не логики
        # сборки контента).
        if os.path.getsize(tmp.name) == 0:
            raise RuntimeError("written file is empty")
        os.replace(tmp.name, out_path)
    except BaseException:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        raise

    print(json.dumps({
        "ok": True,
        "path": out_path,
        "segment": seg,
    }))
except Exception as e:
    print(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}))
    sys.exit(1)
PY
)"
build_rc=$?

if [ "$build_rc" -ne 0 ]; then
  reason="$(HO_ERRJSON="$BUILD_JSON" python3 -c '
import json, os
try:
    d = json.loads(os.environ.get("HO_ERRJSON") or "")
    msg = d.get("error")
except Exception:
    msg = None
print(msg or "failed to write handoff file")
')"
  emit_result false "$reason" "check disk space and permissions for $out" ""
  exit 1
fi

DATA="$(HO_BUILD="$BUILD_JSON" python3 -c '
import json, os
d = json.loads(os.environ["HO_BUILD"])
print(json.dumps({"path": d["path"], "segment": d["segment"]}))
')"
emit_result true "" "" "$DATA"
exit 0
