#!/usr/bin/env bash
# Brief contract shared by the mvp plugin skills (mvp:brief, mvp:clarify,
# mvp:bootstrap, mvp:plan, ...): required section headers, header validation,
# stack allowlist, and layout mapping.
#
# Usage:
#   source lib/brief-contract.sh
#
# All functions are pure: no side-effects, no I/O except reading the file
# argument and writing to stderr on failures.
#
# Ported from ~/.claude/playbooks/scripts/brief-contract.sh (v1). Header
# presence/content checks below rely on POSIX [[:space:]] character classes,
# which already match a trailing CRLF's \r — no separate CRLF stripping
# needed. Header lists are always consumed via `for h in "$@"` / here-docs,
# never via unquoted `$(...)` word-splitting.

# ---------------------------------------------------------------------------
# Required headers
# ---------------------------------------------------------------------------

# required_headers_tech
#   Print, one per line, headers that MUST exist in technical_solutions.md.
required_headers_tech() {
  cat <<'EOF'
## Stack
## Services
## Auth
## Deploy
EOF
}

# required_headers_biz
#   Print, one per line, headers that MUST exist in business_logic.md.
required_headers_biz() {
  cat <<'EOF'
## Goal
## Roles
## Core scenarios
## MVP scope
## Success criteria
EOF
}

# ---------------------------------------------------------------------------
# Header validation
# ---------------------------------------------------------------------------

# has_content_under_header <file> <header>
#   Return 0 if there is any non-whitespace content between <header> and the
#   next "## " heading (or EOF), 1 otherwise.
has_content_under_header() {
  local file="$1"
  local header="$2"
  awk -v hdr="^${header}[[:space:]]*$" '
    $0 ~ hdr { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /[^[:space:]]/ { found = 1; exit }
    END { exit !found }
  ' "$file"
}

# header_present <file> <header>
#   Return 0 if the exact header line is present (strict: no trailing chars),
#   1 otherwise. Used so "## Stack" does not match "## Stack overview".
header_present() {
  local file="$1"
  local header="$2"
  grep -qE "^${header}[[:space:]]*\$" "$file"
}

# validate_headers <file> <h1> <h2> ...
#   For each header, verify presence AND non-empty section content in <file>.
#   Returns 0 if all OK, 1 otherwise. Writes ❌ lines to stderr for whatever
#   is missing/empty.
validate_headers() {
  local file="$1"
  shift
  local rc=0
  local header
  for header in "$@"; do
    if ! header_present "$file" "$header"; then
      echo "❌ $file: заголовок '${header}' отсутствует" >&2
      rc=1
      continue
    fi
    if ! has_content_under_header "$file" "$header"; then
      echo "❌ $file: секция '${header}' пуста" >&2
      rc=1
    fi
  done
  return $rc
}

# ---------------------------------------------------------------------------
# Stack allowlist + layout mapping
# ---------------------------------------------------------------------------

ALLOWED_BACKEND="nestjs fastapi"; ALLOWED_FRONTEND="nextjs react none"
ALLOWED_DEPLOY="docker-dokploy"
validate_stack() { # $1 backend $2 frontend $3 deploy $4 db csv
  local errs=()
  case " $ALLOWED_BACKEND "  in *" $1 "*) ;; *) errs+=("backend '$1' not in [$ALLOWED_BACKEND]");; esac
  case " $ALLOWED_FRONTEND " in *" $2 "*) ;; *) errs+=("frontend '$2' not in [$ALLOWED_FRONTEND]");; esac
  case " $ALLOWED_DEPLOY "   in *" $3 "*) ;; *) errs+=("deploy '$3' not in [$ALLOWED_DEPLOY]");; esac
  case ",$4," in *,postgresql,*) ;; *) errs+=("db must contain postgresql");; esac
  if [ ${#errs[@]} -gt 0 ]; then
    local hint="${errs[*]}"
    python3 -c 'import json,sys;print(json.dumps({"ok":False,"reason":"stack not allowed","hint":sys.argv[1],"data":None}))' "$hint"
    return 1
  fi
  printf '{"ok":true,"reason":null,"hint":null,"data":null}\n'
}
layout_for_stack() { # $1 backend $2 frontend $3 services_count
  if [ "$1" = nestjs ]; then echo packages
  elif [ "${3:-1}" -gt 1 ]; then echo services
  else echo app; fi
}
