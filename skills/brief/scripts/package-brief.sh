#!/usr/bin/env bash
# package-brief.sh <discover|skeleton|swap|archive> ...
#
# Deterministic sub-operations for the mvp:brief skill. In v1 this logic was
# inline bash in the skill body — including the awk range-pattern bug that
# made SERVICES_COUNT always come out as 1 (see _services_count comment
# below). Pulling it into a tested script is the fix. Run from the TARGET
# PROJECT root (not this plugin repo). Single-line JSON contract on every
# exit path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
# ok:false always exits 1.
#
# Subcommands:
#   discover [path]   — find candidate raw-source locations under <path>
#                        (default "."): standard dir names (non-empty) and
#                        loose root-level .md/.txt/.json files, excluding
#                        well-known project filenames. data:{"candidates":[...]}
#                        (dir candidates end in "/"). Never fewer/more than
#                        what's on disk — the skill decides what to do with
#                        0/1/>1 candidates (Stop&Ask lives in SKILL.md, not
#                        here).
#   skeleton <dir>    — ensure <dir> has the 4 canonical brief files
#                        (technical-solutions.md, business-logic.md,
#                        glossary.md, analysis-grey-zones.md) with every
#                        required header (lib/brief-contract.sh) present.
#                        Missing headers are appended at EOF in contract
#                        order; existing headers/content are never touched
#                        (idempotent — safe to call again after the Stack
#                        section has been filled in, to pick up ## Layout).
#                        Also auto-fills "## Layout" via layout_for_stack
#                        when backend+frontend are extractable from an
#                        existing "## Stack" section AND "## Layout" isn't
#                        already present (an operator's/LLM's own Layout is
#                        never overwritten). data:{"headers_added":{...},
#                        "services_count":N,"layout":str|null}
#   swap <tmpdir>     — atomically move <tmpdir> to ./docs/product. If
#                        docs/product already exists, back it up first to
#                        docs/product.bak.<ts> (collision-suffixed if the
#                        same timestamp is already taken). data:{"target":
#                        "docs/product","backup":str|null}
#   archive <src>...  — no-clobber move of raw sources into
#                        ./docs/product/_raw (created if missing). Each
#                        <src> may be a file (moved as-is) or a directory
#                        (its contents are moved, dotglob — dotfiles
#                        included; the directory itself is not nested into
#                        docs/product/_raw). All sources are pre-checked for
#                        basename collisions (against the existing raw/ dir
#                        AND against each other) before anything is moved:
#                        any collision aborts the whole operation with
#                        ok:false and data:{"conflicts":[...]} instead of
#                        silently clobbering or partially moving — the skill
#                        resolves conflicts via AskUserQuestion and reruns.
#                        Success: data:{"dest":"docs/product/_raw","moved":[...]}
#
# Stack section format this script expects/writes (there is no canonical
# format enforced by lib/brief-contract.sh — mvp:brief owns it since it's
# the skill that authors technical-solutions.md):
#   ## Stack
#   - backend: fastapi
#   - frontend: react
#   - deploy: docker-dokploy
#   - db: postgresql, redis

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$here/../../../lib/brief-contract.sh"

USAGE="usage: package-brief.sh <discover [path]|skeleton <dir>|swap <tmpdir>|archive <src>...>"

# `docs` is deliberately NOT a source directory: it is now the pipeline's
# OUTPUT root (docs/product/, docs/architecture.md, docs/plan.md). Leaving it
# here would make discover treat the brief's own destination as raw input, and
# `archive docs` would then move docs/product into docs/product/_raw — a
# directory swallowing itself. Operators put raw material in
# project_prompt_files/ (the documented path), brief/, spec/ or requirements/.
STANDARD_DIRS=(project_prompt_files docs/product/_raw brief spec requirements)
STANDARD_ROOT_FILES=(
  README.md CLAUDE.md ARCHITECTURE.md PROJECT_PLAN.md REVIEW.md
  LICENSE.md LICENSE CHANGELOG.md CONTRIBUTING.md SECURITY.md
  package.json package-lock.json composer.json turbo.json nx.json
  biome.json pnpm-workspace.yaml renovate.json
)

# emit_result <ok:true|false> <reason> <hint> <data-json> — see lib/gate.sh.
emit_result() {
  PB_OK="$1" PB_REASON="$2" PB_HINT="$3" PB_DATA="$4" python3 -c '
import json, os
ok = os.environ["PB_OK"] == "true"
reason = os.environ.get("PB_REASON") or None
hint = os.environ.get("PB_HINT") or None
data_raw = os.environ.get("PB_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint]
  emit_result false "$1" "${2:-}" ""
  exit 1
}

# --- discover ----------------------------------------------------------------

_norm_path() { # <base> <name> -> joined path, without a redundant "./" prefix
  if [ "$1" = "." ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi
}

cmd_discover() {
  local base="${1:-.}"
  if [ ! -d "$base" ]; then
    fail "path not found: $base"
  fi

  local -a candidates=()
  local d
  for d in "${STANDARD_DIRS[@]}"; do
    if [ -d "$base/$d" ] && [ -n "$(find "$base/$d" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
      candidates+=("$(_norm_path "$base" "$d")/")
    fi
  done

  local f name skip a
  shopt -s nullglob
  for f in "$base"/*.md "$base"/*.txt "$base"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in
      tsconfig*.json | .eslintrc.json) continue ;;
    esac
    skip=0
    for a in "${STANDARD_ROOT_FILES[@]}"; do
      [ "$name" = "$a" ] && skip=1 && break
    done
    [ "$skip" -eq 1 ] && continue
    candidates+=("$(_norm_path "$base" "$name")")
  done
  shopt -u nullglob

  local data
  data="$(printf '%s\n' "${candidates[@]:-}" | sed '/^$/d' | sort | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().split("\n") if l]
print(json.dumps({"candidates": lines}))
')"
  emit_result true "" "" "$data"
}

# --- skeleton ------------------------------------------------------------------

# _services_count <file>
#   Count "- " bullets strictly inside the "## Services" section, using the
#   awk FLAG technique (set a flag at the header, `next` past that line so
#   the exit-check below never re-examines it, exit the moment a following
#   "## " header is seen). The v1 implementation used an awk RANGE pattern
#   (`/^## Services$/,/^## /`) instead — per POSIX awk semantics, when the
#   start pattern's own line ALSO matches the end pattern (it does here:
#   "## Services" itself matches `/^## /`), the range collapses to that one
#   line. `grep -c '^- '` on that single line found nothing, exited 1, and
#   the `|| echo 1` fallback silently produced "1" — always, regardless of
#   actual content. This flag-based version fixes that.
_services_count() {
  awk '
    /^## Services[[:space:]]*$/ { flag=1; next }
    flag && /^## / { exit }
    flag && /^- / { count++ }
    END { print count+0 }
  ' "$1"
}

# _extract_stack_value <file> <key>
#   Read "- key: value" (or "key: value") lines inside "## Stack", flag-
#   scoped the same way as _services_count. Case-insensitive key match,
#   trimmed value. Empty output if the section or key is absent.
_extract_stack_value() {
  awk -v key="$2" '
    /^## Stack[[:space:]]*$/ { flag=1; next }
    flag && /^## / { exit }
    flag {
      line = $0
      sub(/^-[[:space:]]*/, "", line)
      idx = index(line, ":")
      if (idx == 0) next
      k = substr(line, 1, idx-1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (tolower(k) != tolower(key)) next
      v = substr(line, idx+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$1"
}

# _ensure_headers <file> <header-list-newline-separated> -> prints added headers, one per line
_ensure_headers() {
  local file="$1" h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if ! header_present "$file" "$h"; then
      printf '\n%s\n\n' "$h" >>"$file"
      printf '%s\n' "$h"
    fi
  done <<<"$2"
}

cmd_skeleton() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    fail "missing dir" "usage: package-brief.sh skeleton <dir>"
  fi
  mkdir -p "$dir"

  local tech="$dir/technical-solutions.md"
  local biz="$dir/business-logic.md"
  local glossary="$dir/glossary.md"
  local grey="$dir/analysis-grey-zones.md"
  [ -f "$tech" ] || : >"$tech"
  [ -f "$biz" ] || : >"$biz"
  [ -f "$glossary" ] || : >"$glossary"
  [ -f "$grey" ] || : >"$grey"

  local tech_added biz_added
  tech_added="$(_ensure_headers "$tech" "$(required_headers_tech)")"
  biz_added="$(_ensure_headers "$biz" "$(required_headers_biz)")"

  local services_count backend frontend layout=""
  services_count="$(_services_count "$tech")"
  backend="$(_extract_stack_value "$tech" backend)"
  frontend="$(_extract_stack_value "$tech" frontend)"
  if [ -n "$backend" ] && [ -n "$frontend" ] && ! header_present "$tech" "## Layout"; then
    layout="$(layout_for_stack "$backend" "$frontend" "$services_count")"
    printf '\n## Layout\n%s\n' "$layout" >>"$tech"
  fi

  local data
  data="$(python3 -c '
import json, sys
tech_added_raw, biz_added_raw, services_count, layout = sys.argv[1:5]
d = {
    "headers_added": {
        "technical-solutions.md": [l for l in tech_added_raw.split("\n") if l],
        "business-logic.md": [l for l in biz_added_raw.split("\n") if l],
    },
    "services_count": int(services_count),
    "layout": layout or None,
}
print(json.dumps(d))
' "$tech_added" "$biz_added" "$services_count" "$layout")"
  emit_result true "" "" "$data"
}

# --- swap ----------------------------------------------------------------------

cmd_swap() {
  local tmpdir="${1:-}"
  if [ -z "$tmpdir" ]; then
    fail "missing tmpdir" "usage: package-brief.sh swap <tmpdir>"
  fi
  if [ ! -d "$tmpdir" ]; then
    fail "tmpdir not found: $tmpdir"
  fi

  local target="docs/product"
  local backup=""
  # The target is nested now (docs/product, not a top-level project_brief), and
  # `mv` does not create parents: without this the swap fails on a fresh
  # project, which is the ONLY kind of project mvp:brief runs on.
  if ! mkdir -p "$(dirname "$target")"; then
    fail "cannot create parent directory for $target"
  fi
  if [ -e "$target" ]; then
    local ts n
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="${target}.bak.${ts}"
    n=1
    while [ -e "$backup" ]; do
      backup="${target}.bak.${ts}-${n}"
      n=$((n + 1))
    done
    if ! mv "$target" "$backup"; then
      fail "backup mv failed: $target -> $backup"
    fi
  fi

  if ! mv "$tmpdir" "$target"; then
    fail "swap mv failed: $tmpdir -> $target"
  fi

  local data
  data="$(python3 -c '
import json, sys
target, backup = sys.argv[1], sys.argv[2]
print(json.dumps({"target": target, "backup": backup or None}))
' "$target" "$backup")"
  emit_result true "" "" "$data"
}

# --- archive ---------------------------------------------------------------------

cmd_archive() {
  if [ $# -eq 0 ]; then
    fail "missing src" "usage: package-brief.sh archive <src>..."
  fi
  local -a srcs=("$@")
  local s
  for s in "${srcs[@]}"; do
    if [ ! -e "$s" ]; then
      fail "src not found: $s"
    fi
  done

  local dest="docs/product/_raw"

  # Expand directory sources (dotglob) into a flat (source-path, basename)
  # list. The directory itself is never nested into dest — only its
  # contents move.
  local -a move_from=() move_base=()
  local entry
  shopt -s dotglob nullglob
  for s in "${srcs[@]}"; do
    if [ -d "$s" ]; then
      for entry in "$s"/*; do
        [ -e "$entry" ] || continue
        move_from+=("$entry")
        move_base+=("$(basename "$entry")")
      done
    else
      move_from+=("$s")
      move_base+=("$(basename "$s")")
    fi
  done
  shopt -u dotglob nullglob

  mkdir -p "$dest"

  # Pre-check ALL collisions before moving anything (all-or-nothing): a
  # basename already present in dest, or duplicated across the sources
  # themselves. O(n^2) is fine — these are raw-source file counts, never
  # large. No associative arrays (target bash 3.2 / macOS default).
  local -a conflicts=()
  local i j b dup
  for ((i = 0; i < ${#move_base[@]}; i++)); do
    b="${move_base[$i]}"
    if [ -e "$dest/$b" ]; then
      conflicts+=("$b")
      continue
    fi
    dup=0
    for ((j = 0; j < i; j++)); do
      if [ "${move_base[$j]}" = "$b" ]; then
        dup=1
        break
      fi
    done
    [ "$dup" -eq 1 ] && conflicts+=("$b")
  done

  if [ ${#conflicts[@]} -gt 0 ]; then
    local data
    data="$(printf '%s\n' "${conflicts[@]}" | sort -u | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().split("\n") if l]
print(json.dumps({"conflicts": lines}))
')"
    emit_result false "archive conflicts: filename collisions in $dest" \
      "resolve via overwrite/rename/abort, then rerun archive" "$data"
    exit 1
  fi

  for ((i = 0; i < ${#move_from[@]}; i++)); do
    if ! mv "${move_from[$i]}" "$dest/${move_base[$i]}"; then
      fail "mv failed: ${move_from[$i]} -> $dest/${move_base[$i]}"
    fi
  done

  local data
  data="$(printf '%s\n' "${move_base[@]:-}" | sed '/^$/d' | sort | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().split("\n") if l]
print(json.dumps({"dest": sys.argv[1], "moved": lines}))
' "$dest")"
  emit_result true "" "" "$data"
}

# --- main -------------------------------------------------------------------

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    discover) cmd_discover "$@" ;;
    skeleton) cmd_skeleton "$@" ;;
    swap) cmd_swap "$@" ;;
    archive) cmd_archive "$@" ;;
    *) fail "unknown command: ${cmd:-<missing>}" "$USAGE" ;;
  esac
}

main "$@"
