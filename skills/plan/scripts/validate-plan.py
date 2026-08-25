#!/usr/bin/env python3
"""
Deterministic post-planner validation for mvp:plan. Run from the TARGET
PROJECT root (not this plugin repo). Single-line JSON contract on stdout,
always the last (only) line:
    {"ok": bool, "reason": str|null, "hint": str|null,
     "data": {"errors": [str, ...], "total_estimate": int} | None}
ok:false always exits 1. Never a bare traceback (top-level guard, R10).

Usage: validate-plan.py [--schema <path>]
    --schema defaults to the schema shipped next to this script:
    skills/plan/references/plan-schema.json (the recognized-format schema
    consumed by lib/plan-io.mjs's `validate --schema`).

What this does, in order:

1. Locates lib/plan-io.mjs RELATIVE TO THIS SCRIPT'S OWN PATH (not cwd, not
   an env var) so it works regardless of where the plugin is installed:
       this file:  <plugin_root>/skills/plan/scripts/validate-plan.py
       -> parents[3] of this file == <plugin_root>
       -> <plugin_root>/lib/plan-io.mjs
   This mirrors the `$(dirname)/../../..`-style resolution used elsewhere
   in the plugin's shell scripts, just expressed with pathlib.
2. Runs `node <lib_plan_io> validate --schema <schema-path>` (cwd inherited
   from this process, i.e. the target project root) and captures its
   single-line JSON contract output. Its `data.errors` (schema/DAG/boundary
   violations) are folded into this script's own `errors` list verbatim.
3. Reads `.mvp/plan.json` directly, READ-ONLY (never writes it —
   the planner subagent is the only Write path, see skills/plan/SKILL.md),
   and adds two more classes of plan-level error, both computed from task
   FIELDS only (role, files) — never from title substrings:
     a. role-enum: every task's `role` must be one of the values in the
        schema file's `enums.role` (falls back to a hardcoded list — the
        same 5 roles the brief specifies — if the schema omits that key).
        lib/plan-io.mjs's generic validator only special-cases
        `enums.complexity_class`/`enums.status`, so an unrecognized `role`
        would otherwise pass through silently; this closes that gap using
        the schema file as the single source of truth for the allowed set.
     b. frontend/backend contract dependency: any task with
        `role == "frontend-implementer"` whose `files` include at least one
        api-client-ish path (heuristic below) must have, TRANSITIVELY
        through `depends_on`, at least one ancestor task with
        `role == "backend-implementer"`. Transitivity is a deliberate
        choice: a frontend task's real dependency is "the API contract
        exists somewhere upstream", not necessarily as a direct parent —
        requiring a direct edge would force the planner to add redundant
        depends_on entries that duplicate what the DAG already expresses
        through an intermediate task (e.g. a test-writer or another
        frontend task sitting between them). "backend-role" is read
        narrowly as role == "backend-implementer" (not
        integration-specialist): per this plugin's architecture invariants,
        integration-* services are stateless HTTP gateways behind the
        backend service, not something the frontend talks to directly, so
        the API contract a frontend api-client depends on is always
        exposed by a backend-implementer task.
   `total_estimate` (sum of every task's `estimate_tokens`) is always
   computed and reported in `data`, independent of ok/errors, whenever
   plan.json is at least readable as `{"tasks": [...]}`.
4. Merges everything into ONE contract JSON. `ok` is true iff the merged
   `errors` list is empty.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

USAGE = "usage: validate-plan.py [--schema <path>]"

# Fallback role enum — used only if the schema file's enums.role is absent
# (kept in sync with skills/plan/references/plan-schema.json by hand; the
# schema file is the source of truth whenever it defines the key).
FALLBACK_ROLE_ENUM = [
    "backend-implementer",
    "frontend-implementer",
    "test-writer",
    "devops-engineer",
    "integration-specialist",
]


class UsageError(Exception):
    pass


def emit(ok: bool, reason: str | None, hint: str | None, data: dict | None) -> None:
    print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))


def guard_fail(reason: str, hint: str = "") -> int:
    emit(False, reason, hint or None, None)
    return 1


def parse_args(argv: list[str]) -> str | None:
    """Returns the --schema override path, or None. Raises UsageError on any
    unrecognized flag/arity mismatch (R10 argv guard)."""
    schema_override: str | None = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--schema":
            if i + 1 >= len(argv):
                raise UsageError("--schema requires a value")
            schema_override = argv[i + 1]
            i += 2
        else:
            raise UsageError(f"unknown argument: {a}")
    return schema_override


def is_api_client_path(f: object) -> bool:
    """Field-based heuristic on a `files` entry — never on task titles.
    Matches a path that looks like it belongs to a frontend API-client
    layer: an `api` path segment, or a filename combining "api"+"client"."""
    if not isinstance(f, str):
        return False
    fl = f.lower().replace("\\", "/")
    segments = [s for s in fl.split("/") if s]
    if "api" in segments:
        return True
    base = segments[-1] if segments else fl
    compact = fl.replace("-", "").replace("_", "")
    if "apiclient" in compact:
        return True
    if "api" in fl and "client" in base:
        return True
    return False


def read_plan_tasks() -> tuple[list[dict], int]:
    """Read `.mvp/plan.json` (cwd-relative, same convention as
    lib/plan-io.mjs), READ-ONLY. Returns (tasks, total_estimate). Any
    read/parse failure returns ([], 0) — the node-side error already
    reports the underlying cause; this function just degrades gracefully
    so the plan-level checks below simply have nothing to check."""
    plan_path = Path(".mvp/plan.json")
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return [], 0
    raw_tasks = plan.get("tasks") if isinstance(plan, dict) else None
    tasks = [t for t in raw_tasks if isinstance(t, dict)] if isinstance(raw_tasks, list) else []

    total = 0
    for t in tasks:
        et = t.get("estimate_tokens")
        if isinstance(et, (int, float)) and not isinstance(et, bool):
            total += et
    return tasks, total


def load_role_enum(schema_path: Path) -> set[str]:
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        schema = {}
    roles = (schema.get("enums") or {}).get("role") if isinstance(schema, dict) else None
    if isinstance(roles, list) and roles:
        return {str(r) for r in roles}
    return set(FALLBACK_ROLE_ENUM)


def check_role_enum(tasks: list[dict], schema_path: Path) -> list[str]:
    role_enum = load_role_enum(schema_path)
    errors = []
    for t in tasks:
        role = t.get("role")
        if role is not None and role not in role_enum:
            tid = t.get("id", "<unknown>")
            errors.append(f"task {tid}: role '{role}' not in {sorted(role_enum)}")
    return errors


def has_backend_ancestor(task_id: str, by_id: dict) -> bool:
    """DFS over depends_on (transitive). Guards against cycles with a
    `seen` set — plan-io.mjs's own cycle check reports cycles separately;
    this just must not infinite-loop if one slips through."""
    seen: set[str] = set()
    stack = list((by_id.get(task_id) or {}).get("depends_on") or [])
    while stack:
        dep_id = stack.pop()
        if not isinstance(dep_id, str) or dep_id in seen:
            continue
        seen.add(dep_id)
        dep = by_id.get(dep_id)
        if dep is None:
            continue
        if dep.get("role") == "backend-implementer":
            return True
        stack.extend(dep.get("depends_on") or [])
    return False


def check_frontend_backend_dep(tasks: list[dict]) -> list[str]:
    by_id = {t["id"]: t for t in tasks if isinstance(t.get("id"), str)}
    errors = []
    for t in tasks:
        if t.get("role") != "frontend-implementer":
            continue
        files = t.get("files")
        if not isinstance(files, list):
            continue
        api_files = [f for f in files if is_api_client_path(f)]
        if not api_files:
            continue
        tid = t.get("id", "<unknown>")
        if not has_backend_ancestor(tid, by_id):
            errors.append(
                f"task {tid}: frontend task touches api-client path(s) "
                f"{api_files} but has no backend-implementer task in "
                f"depends_on (checked transitively)"
            )
    return errors


def run_plan_io_validate(lib_plan_io: Path, schema_path: Path) -> list[str]:
    """Runs `node lib/plan-io.mjs validate --schema <schema_path>` and
    returns its `data.errors` folded into this script's error vocabulary.
    Never raises — a node/parse failure becomes a single descriptive error
    string so the caller always gets a contract JSON, never a crash."""
    try:
        proc = subprocess.run(
            ["node", str(lib_plan_io), "validate", "--schema", str(schema_path)],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return ["node executable not found — install Node.js (required by lib/plan-io.mjs)"]

    stdout = proc.stdout.strip()
    last_line = stdout.splitlines()[-1] if stdout else ""
    node_result = None
    if last_line:
        try:
            node_result = json.loads(last_line)
        except json.JSONDecodeError:
            node_result = None

    if not isinstance(node_result, dict):
        detail = (proc.stderr or proc.stdout or "no output").strip()[:300]
        return [f"plan-io validate produced no parseable JSON output: {detail}"]

    data = node_result.get("data") or {}
    raw_errors = data.get("errors") if isinstance(data, dict) else None
    if isinstance(raw_errors, list) and raw_errors:
        return [str(e) for e in raw_errors]
    if not node_result.get("ok"):
        # ok:false with no per-item errors (e.g. SchemaError, missing
        # plan.json) — surface the reason itself so it isn't swallowed.
        return [str(node_result.get("reason") or "plan-io validate failed")]
    return []


def main() -> int:
    script_dir = Path(__file__).resolve().parent  # .../skills/plan/scripts
    plugin_root = script_dir.parents[2]  # scripts -> plan -> skills -> plugin_root
    lib_plan_io = plugin_root / "lib" / "plan-io.mjs"
    default_schema = script_dir.parent / "references" / "plan-schema.json"

    try:
        schema_override = parse_args(sys.argv[1:])
    except UsageError as e:
        return guard_fail(str(e), USAGE)

    schema_path = Path(schema_override) if schema_override else default_schema
    if not schema_path.is_file():
        return guard_fail(
            f"schema file not found: {schema_path}",
            "check --schema, or the shipped skills/plan/references/plan-schema.json",
        )
    if not lib_plan_io.is_file():
        return guard_fail(
            f"lib/plan-io.mjs not found at resolved path: {lib_plan_io}",
            "plugin layout mismatch — check installation",
        )

    node_errors = run_plan_io_validate(lib_plan_io, schema_path)

    tasks, total_estimate = read_plan_tasks()
    plan_errors: list[str] = []
    if tasks:
        plan_errors += check_role_enum(tasks, schema_path)
        plan_errors += check_frontend_backend_dep(tasks)

    errors = node_errors + plan_errors
    data_out = {"errors": errors, "total_estimate": total_estimate}

    if errors:
        emit(False, f"{len(errors)} plan validation error(s)", "fix .mvp/plan.json (see data.errors)", data_out)
        return 1

    emit(True, None, None, data_out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # last-resort guard: R10 — never a bare traceback on stdout
        emit(False, f"internal error: {e}", None, None)
        sys.exit(1)
