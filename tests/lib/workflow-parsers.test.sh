#!/usr/bin/env bash
# Tests for the pure parsing functions inside skills/build/workflow.mjs.
# Convention (tests/run.sh): exit 0 = pass. Assertions live in the .mjs
# harness next to this file — workflow.mjs is an AsyncFunction body, not an
# importable module, so the harness extracts the real declarations from the
# real source rather than keeping a copy that would drift.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$here/workflow-parsers.mjs"
