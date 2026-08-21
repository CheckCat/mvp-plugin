#!/usr/bin/env python3
"""
Apply search-replace patches to files, with a deterministic JSON contract.

Usage: python3 apply-patches.py <patches.json> [--stage]

Run from the TARGET PROJECT root (not this plugin repo). Ported from
~/.claude/playbooks/scripts/apply-patches.py (see "Ported from v1" below for
what changed).

Input JSON (patches.json): a JSON array of objects, each
    {"file": str, "search": str, "replace": str}
`file` is a path relative to the current working directory.

Guarantees:
- `search` must occur in the CURRENT content of `file` exactly once. 0
  occurrences -> failed entry reason "not-found"; a missing file counts as
  "not-found" too (the search string cannot be found in a file that doesn't
  exist). >=2 occurrences -> reason "ambiguous". In both cases the file is
  left byte-for-byte untouched — writes are atomic (tmp file + os.replace)
  and only ever happen after the exactly-once check passes.
- Multiple patches may target the same file. They are applied strictly in
  the order they appear in patches.json; each patch reads the file's
  CURRENT on-disk content (i.e. reflecting any earlier patch already applied
  to that same file within this run). If a later patch on a file fails, any
  earlier successful patches on that SAME file still stand (not rolled
  back) — this matches v1 behavior (v1 wrote to disk immediately after each
  successful patch and read fresh per patch) and is the documented ordering
  semantics for this script. Patches to OTHER files are entirely unaffected
  by a failure on one file.
- `--stage`: after all patches are processed, `git add -- <file>` is run for
  every file that had at least one successfully-applied patch — including a
  file that ended up "dirty-but-patched" (some of its patches applied, a
  later one on the same file failed). Files are staged once each
  (de-duplicated), in first-applied order. Staging happens regardless of
  whether other patches/files failed elsewhere in the batch.

Output (stdout, always a single line of JSON, always via json.dumps — never
a bare print/traceback):
    {"ok": bool, "reason": str|null, "hint": str|null,
     "data": {"applied": [str, ...], "failed": [{"file": str, "reason": "not-found"|"ambiguous"}, ...]} | null}

`ok` is false and exit code is 1 whenever `data.failed` is non-empty, OR
when an argv-guard rejects the input outright (missing/unreadable
patches.json, malformed JSON, wrong shape, bad usage, or a `--stage` git-add
failure) — in the guard-reject case `data` is null since no patches were
processed at all.

Ported from v1 (~/.claude/playbooks/scripts/apply-patches.py):
- kept: the exactly-once uniqueness check, and the "untouched on failure"
  guarantee.
- changed: output contract is now {ok,reason,hint,data} instead of
  {applied,failures}; `failed[].reason` is exactly "not-found"|"ambiguous"
  (v1 had file-not-found / search-not-found / search-ambiguous-xN as three
  separate string reasons — collapsed to two here per this task's contract);
  writes are now atomic (tmp + os.replace) instead of a plain write_text();
  added `--stage`; added a top-level argv/shape guard so a malformed
  patches.json (not a list, or entries missing/mistyped keys) is rejected
  as ONE whole-batch failure before any file is touched, rather than v1's
  per-entry "patch-malformed" partial-failure handling — simpler contract,
  and it means a caller never has to distinguish "some patches structurally
  broken" from "some patches semantically failed".
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile

USAGE = "usage: apply-patches.py <patches.json> [--stage]"


def emit(ok: bool, reason: str | None, hint: str | None, data: dict | None) -> None:
    print(json.dumps({"ok": ok, "reason": reason, "hint": hint, "data": data}))


def guard_fail(reason: str, hint: str = "") -> int:
    emit(False, reason, hint or None, None)
    return 1


def atomic_write(path: pathlib.Path, content: str) -> None:
    """Write `content` to `path` atomically (tmp file in same dir + os.replace),
    preserving the original file's permission bits."""
    mode = path.stat().st_mode
    fd, tmp_name = tempfile.mkstemp(
        dir=str(path.parent) or ".", prefix=f".{path.name}.", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def main() -> int:
    args = sys.argv[1:]
    if not args or len(args) > 2:
        return guard_fail(f"bad usage: {len(args)} argument(s)", USAGE)

    patches_arg = args[0]
    stage = False
    if len(args) == 2:
        if args[1] != "--stage":
            return guard_fail(f"unknown argument: {args[1]}", USAGE)
        stage = True

    patches_path = pathlib.Path(patches_arg)
    try:
        raw = patches_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return guard_fail(f"patches.json not found: {patches_arg}", USAGE)
    except OSError as e:
        return guard_fail(f"cannot read patches.json: {e}", USAGE)

    try:
        patches = json.loads(raw)
    except json.JSONDecodeError as e:
        return guard_fail(f"invalid JSON in patches.json: {e}", "fix the JSON and retry")

    if not isinstance(patches, list):
        return guard_fail(
            "patches.json must be a JSON array of {file,search,replace} objects",
            "wrap the object(s) in a top-level array",
        )
    for i, p in enumerate(patches):
        if (
            not isinstance(p, dict)
            or not isinstance(p.get("file"), str)
            or not isinstance(p.get("search"), str)
            or not isinstance(p.get("replace"), str)
        ):
            return guard_fail(
                f"patches.json[{i}] must be an object with string file/search/replace",
                "each entry needs file, search, replace as strings",
            )

    applied: list[str] = []
    failed: list[dict] = []

    for p in patches:
        file_arg = p["file"]
        search = p["search"]
        replace = p["replace"]

        path = pathlib.Path(file_arg)
        if not path.is_file():
            failed.append({"file": file_arg, "reason": "not-found"})
            continue

        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            failed.append({"file": file_arg, "reason": "not-found"})
            continue

        cnt = text.count(search)
        if cnt == 0:
            failed.append({"file": file_arg, "reason": "not-found"})
            continue
        if cnt > 1:
            failed.append({"file": file_arg, "reason": "ambiguous"})
            continue

        atomic_write(path, text.replace(search, replace, 1))
        applied.append(file_arg)

    if stage:
        staged_files = list(dict.fromkeys(applied))  # de-dup, preserve order
        for file_arg in staged_files:
            proc = subprocess.run(
                ["git", "add", "--", file_arg],
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0:
                data = {"applied": applied, "failed": failed}
                emit(
                    False,
                    f"git add failed for: {file_arg} ({proc.stderr.strip()[:200]})",
                    "verify this is a git repository and the path is trackable",
                    data,
                )
                return 1

    data = {"applied": applied, "failed": failed}
    if failed:
        emit(
            False,
            f"{len(failed)} of {len(patches)} patch(es) failed",
            "see data.failed for the file/reason of each",
            data,
        )
        return 1

    emit(True, None, None, data)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # last-resort guard: R10 — never a bare traceback on stdout
        emit(False, f"internal error: {e}", None, None)
        sys.exit(1)
