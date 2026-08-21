#!/usr/bin/env bash
# check-meta.sh [--claude-md PATH] [--architecture-md PATH] [--invariants PATH]
#
# Deterministic gate for LLM-generated project meta-files (mvp:bootstrap Step
# 6). Run from the TARGET PROJECT root (not this plugin repo). Single-line
# JSON contract on every exit path (same shape as lib/gate.sh's emit_result):
#   {"ok":bool,"reason":str|null,"hint":str|null,"data":{"violations":[...]}}
# ok:false always exits 1. ok:true iff violations is empty.
#
# Checks (always run all of them, so a single call reports everything wrong
# at once — same "report it all, not just the first failure" rule as
# lib/validate-task.sh):
#
#   1. claude-md-missing    — CLAUDE.md does not exist at --claude-md.
#   2. claude-md-length     — CLAUDE.md has more than 150 lines.
#   3. claude-md-section    — CLAUDE.md is missing one of the required
#                              section headers (see REQUIRED_SECTIONS below).
#                              Matched by PREFIX ("^## <name>"), not exact
#                              equality, so a header with trailing detail
#                              (e.g. "## Команды (CI = local)") still counts
#                              as the "Команды" section — the generated
#                              CLAUDE.md is allowed to annotate headers.
#   4. architecture-md-missing — ARCHITECTURE.md does not exist.
#   5. architecture-forbidden-edge — an edge in ARCHITECTURE.md's mermaid
#                              diagram matches a FORBIDDEN_EDGE rule read
#                              from --invariants (default:
#                              .claude/state/invariants.md). Missing
#                              invariants file is NOT a violation of this
#                              script (no rules to check yet is a valid
#                              state before Step 3 of mvp:bootstrap writes
#                              it) — it just means zero rules are checked.
#
# --- Required CLAUDE.md sections (documented mapping, see task-11 report) --
# ## Стек     — matches project_brief/technical_solutions.md's "## Stack"
# ## Команды  — matches the CI = local command block (ruling: CI is single
#               source of truth, see skills/brief conventions)
# ## Правила  — project-specific rules / hard constraints section
#
# --- FORBIDDEN_EDGE pattern syntax (invariants.md) -------------------------
# One rule per line: "FORBIDDEN_EDGE: <src-pattern> --> <dst-pattern>".
# Patterns are glob-ish: '*' expands to "any characters" (regex '.*'); the
# characters '(', ')', '|' pass through UNESCAPED so a pattern can also be a
# regex alternation group, e.g. "FORBIDDEN_EDGE: integration-* --> (DB|PG)".
# Every other character is treated literally (regex-escaped). Both src/dst
# patterns are anchored (^...$) against the bare node id on each side of a
# mermaid edge (bracket/paren/brace shape decorators like "DB[(Database)]"
# are stripped before matching — only the id itself is compared).
#
# Mermaid edge syntax supported: "A --> B", "A -->|label| B", "A --- B",
# "A -.-> B", "A ==> B", each side optionally decorated with a node shape
# ("id[Label]", "id(Label)", "id{Label}"). This is a lint subset, not a full
# mermaid parser — good enough to catch the FORBIDDEN_EDGE class of mistake
# without pulling in a JS mermaid dependency.

set -u

USAGE="usage: check-meta.sh [--claude-md PATH] [--architecture-md PATH] [--invariants PATH]"

# emit_result <ok:true|false> <reason> <hint> <data-json> — see lib/gate.sh.
emit_result() {
  CM_OK="$1" CM_REASON="$2" CM_HINT="$3" CM_DATA="$4" python3 -c '
import json, os
ok = os.environ["CM_OK"] == "true"
reason = os.environ.get("CM_REASON") or None
hint = os.environ.get("CM_HINT") or None
data_raw = os.environ.get("CM_DATA") or ""
data = json.loads(data_raw) if data_raw else None
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))
'
}

fail() { # <reason> [hint]
  emit_result false "$1" "${2:-}" ""
  exit 1
}

# --- parse argv --------------------------------------------------------------

CLAUDE_MD="CLAUDE.md"
ARCHITECTURE_MD="ARCHITECTURE.md"
INVARIANTS_MD=".claude/state/invariants.md"

while [ $# -gt 0 ]; do
  case "$1" in
    --claude-md)
      if [ $# -lt 2 ]; then fail "--claude-md requires a value" "$USAGE"; fi
      CLAUDE_MD="$2"
      shift 2
      ;;
    --architecture-md)
      if [ $# -lt 2 ]; then fail "--architecture-md requires a value" "$USAGE"; fi
      ARCHITECTURE_MD="$2"
      shift 2
      ;;
    --invariants)
      if [ $# -lt 2 ]; then fail "--invariants requires a value" "$USAGE"; fi
      INVARIANTS_MD="$2"
      shift 2
      ;;
    *)
      fail "unexpected argument: $1" "$USAGE"
      ;;
  esac
done

# --- checks, all via one python3 call (env vars, never string-interpolated) -

RESULT="$(
  CM_CLAUDE_MD="$CLAUDE_MD" CM_ARCHITECTURE_MD="$ARCHITECTURE_MD" CM_INVARIANTS_MD="$INVARIANTS_MD" python3 -c '
import json, os, re

claude_md = os.environ["CM_CLAUDE_MD"]
architecture_md = os.environ["CM_ARCHITECTURE_MD"]
invariants_md = os.environ["CM_INVARIANTS_MD"]

REQUIRED_SECTIONS = ["Стек", "Команды", "Правила"]
MAX_LINES = 150

violations = []

# --- CLAUDE.md ---------------------------------------------------------------

if not os.path.isfile(claude_md):
    violations.append({"check": "claude-md-missing", "detail": f"not found: {claude_md}"})
else:
    text = open(claude_md, encoding="utf-8").read()
    lines = text.splitlines()
    if len(lines) > MAX_LINES:
        violations.append({
            "check": "claude-md-length",
            "detail": f"{len(lines)} lines > {MAX_LINES} max",
        })
    for section in REQUIRED_SECTIONS:
        pat = re.compile(r"^##\s+" + re.escape(section), re.MULTILINE)
        if not pat.search(text):
            violations.append({
                "check": "claude-md-section",
                "detail": f"missing required section: ## {section}",
            })

# --- ARCHITECTURE.md + invariants.md (FORBIDDEN_EDGE) ------------------------

if not os.path.isfile(architecture_md):
    violations.append({"check": "architecture-md-missing", "detail": f"not found: {architecture_md}"})
else:
    arch_text = open(architecture_md, encoding="utf-8").read()

    # extract all ```mermaid ... ``` fenced blocks
    mermaid_blocks = re.findall(r"```mermaid\s*\n(.*?)```", arch_text, re.DOTALL)

    # id[Label] / id(Label) / id{Label} -> id (strip shape decorator)
    shape_re = re.compile(r"^([A-Za-z0-9_\-]+)")
    edge_re = re.compile(
        r"([A-Za-z0-9_\-]+(?:\[[^\]]*\]|\([^)]*\)|\{[^}]*\})?)"
        r"\s*(?:-->|---|-\.->|==>)\s*(?:\|[^|]*\|\s*)?"
        r"([A-Za-z0-9_\-]+(?:\[[^\]]*\]|\([^)]*\)|\{[^}]*\})?)"
    )

    def bare_id(token):
        m = shape_re.match(token)
        return m.group(1) if m else token

    edges = []
    for block in mermaid_blocks:
        for line in block.splitlines():
            m = edge_re.search(line)
            if m:
                edges.append((bare_id(m.group(1)), bare_id(m.group(2))))

    # parse FORBIDDEN_EDGE rules
    rules = []
    if os.path.isfile(invariants_md):
        inv_text = open(invariants_md, encoding="utf-8").read()
        rule_re = re.compile(r"^FORBIDDEN_EDGE:\s*(.+?)\s*-->\s*(.+?)\s*$", re.MULTILINE)
        for m in rule_re.finditer(inv_text):
            rules.append((m.group(1), m.group(2)))

    def pattern_to_regex(pat):
        passthrough = set("()|")
        out = []
        for ch in pat:
            if ch == "*":
                out.append(".*")
            elif ch in passthrough:
                out.append(ch)
            else:
                out.append(re.escape(ch))
        return re.compile("^" + "".join(out) + "$")

    compiled_rules = [(pattern_to_regex(s), pattern_to_regex(d), s, d) for s, d in rules]

    for src, dst in edges:
        for src_re, dst_re, src_pat, dst_pat in compiled_rules:
            if src_re.match(src) and dst_re.match(dst):
                violations.append({
                    "check": "architecture-forbidden-edge",
                    "detail": f"{src} --> {dst} violates FORBIDDEN_EDGE: {src_pat} --> {dst_pat}",
                })

ok = len(violations) == 0
reason = None if ok else f"{len(violations)} meta violation(s)"
hint = None if ok else "fix CLAUDE.md/ARCHITECTURE.md per data.violations and rerun check-meta.sh"
print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": {"violations": violations}}))
'
)"
RC=$?

if [ "$RC" -ne 0 ]; then
  fail "check-meta.sh internal error" "python3 failed unexpectedly, rc=$RC"
fi

OK_FIELD="$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"

printf '%s\n' "$RESULT"
if [ "$OK_FIELD" = "True" ]; then
  exit 0
else
  exit 1
fi
