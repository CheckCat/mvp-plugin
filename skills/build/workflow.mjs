// skills/build/workflow.mjs — mvp:build DAG task loop.
//
// Run by the Workflow tool: `Workflow({scriptPath: <this file>, args:{run_id,
// now, max_tasks, task_id?, plugin_root, project_root?}})`. This module has NO filesystem
// access, NO Date.now()/Math.random()/argless `new Date()` (they throw in
// this sandbox), and no `import`/`require` of anything — it is pure
// standard JS plus a fixed set of ambient hooks the Workflow runtime injects
// into scope before evaluating this module:
//   agent(prompt, opts) -> Promise<result>   dispatch one subagent turn
//   parallel, pipeline                        (available, unused — see below)
//   phase(title)                              (available, unused — see below)
//   log(msg)                                  workflow-visible log line
//   args                                      the {run_id, now, max_tasks,
//                                              task_id?, plugin_root,
//                                              project_root?} object passed
//                                              to Workflow(); the SKILL
//                                              generates run_id/now once and
//                                              passes them in — this script
//                                              never calls Date/etc.
//   budget                                    token-budget accessor; only
//                                              `budget.spent()` is used here
//                                              (see design note 7).
//
// ---------------------------------------------------------------------------
// Design decisions (documented per task-14 instructions, updated by a
// controller review round — read before touching the ladders below):
//
// 1. ENTRY CONTRACT — now AUTHORITATIVE (round 3, R18 resolved by an
//    empirical controller test, not inference). The Workflow runtime
//    extracts the `export const meta = {...}` block above via its own
//    parsing, then wraps EVERYTHING AFTER IT in its own `async function`
//    before evaluating it. Two direct, load-bearing consequences, confirmed
//    by the runner actually failing on the wrong shape:
//      - `export default ...` is ILLEGAL below this point — the runner's
//        wrapper is a plain async function body, not an ES module, so an
//        `export` statement inside it is a SyntaxError (this is exactly how
//        round 1's `export default async function run() {...}` — dead code,
//        never invoked — and round 2's
//        `export default await (async () => {...})();` — syntactically
//        valid ESM, but wrong shape for THIS runner — both failed: the
//        runner's own parse step choked on `export` appearing after the
//        meta block).
//      - A plain top-level `return` IS legal below this point, and is
//        exactly how this script hands its result back — it returns from
//        the runner's implicit wrapper function, the same way a plain
//        `return` at the top of any CommonJS module body returns from
//        Node's implicit module-wrapper function. This is why `node --check`
//        on this file (which validates it as a standalone ES module, where
//        top-level `return` is always illegal) is EXPECTED to fail post-fix
//        — it is checking the wrong contract. See the file-level syntax
//        sanity check below (grep "ASYNCFUNCTION SANITY CHECK") for the
//        check that actually mirrors the runner's real parsing.
//    `args`/`agent`/`log`/`budget`/etc. are ambient bindings inside that
//    implicit wrapper, exactly as assumed since round 1. The entry point
//    below is therefore plain top-level statements (no IIFE, no exported
//    function), one try/catch (design note 9) ending in `return
//    withRunLabels(result)` at every exit — never a bare `return result`,
//    since there is no single outer point left to merge run labels at once
//    (design note 13).
//
// 2. relay() vs relayLine(). The brief's relay() sketch assumes the
//    underlying command's stdout is itself one line of JSON (true for every
//    lib/*.{mjs,sh,py} script: plan-io.mjs, validate-task.sh,
//    review-package.sh, apply-patches.py — all emit the {ok,reason,hint,data}
//    contract). But `git rev-parse HEAD` (needed for baseSha) is NOT JSON —
//    it is a bare sha — and park()'s `git checkout/restore/clean` reset line
//    produces no JSON either (often no stdout at all). relayLine(cmd) is the
//    primitive: dispatch a haiku relay agent, return the raw last-stdout-line
//    string, no parsing. relay(cmd) wraps relayLine with JSON.parse (retried
//    once by default — see design note 12 for when it is NOT retried), for
//    the lib-script contract calls. baseSha and park()'s reset both use
//    relayLine directly — using relay() on either was a CRITICAL bug (fix
//    round): JSON.parse("") throws on every single park() call.
//
// 3. Template self-read prompts. This workflow never reads agents/*.md
//    itself (no FS access). Each dispatch prompt instead tells the agent to
//    read its own template file and mentally substitute placeholders — the
//    values passed cover exactly each template's documented Placeholders
//    block (verified against skills/build/agents/*.md, Task 13).
//
// 4. Concerns/blockers are NOT written to ledger.md/blockers.md by this
//    workflow. Iron Law: "scripts move data" — plan-io.mjs has no
//    "append Ruling"/"append blockers" verb, and this script has no FS
//    access to write them directly even if it wanted to. DONE_WITH_CONCERNS
//    text and park() reasons are carried in the workflow's RETURN VALUE
//    (`concerns: [...]` on success, `detail` on a halt) for the calling
//    SKILL (main session, which DOES have scripts/FS access) to persist
//    through a script. This workflow stays a pure orchestrator.
//
// 5. Cross-file touch: lib/plan-io.mjs's `next` response gained `files` (the
//    task's declared files) and `title` (fix round, design note 11) keys,
//    with tests/lib/plan-io.test.sh updated to assert both. validate-task.sh
//    --files must be the plan's declared list (not the implementer's
//    self-reported FILES: line — that source lost fields before, per v1
//    lessons baked into this project's invariants); the commit subject needs
//    a human-readable title, not just a bare id. What a `declared` mismatch
//    MEANS, though, is a hint, not a block — see design note 17.
//
// 6. Caps: IMPLEMENTER_RETRY_CAP=1, TOTAL_ATTEMPTS_CAP=2 (1 initial + 1
//    retry, never more), RE_REVIEW_CYCLES_CAP=1 (one fix -> re-review pass,
//    never repeated — "NOT ADDRESSED" after that single pass parks).
//
// 7. Token-delta source (fix round). This workflow cannot measure a
//    dispatched subagent's own token usage (only the harness knows that).
//    `budget.spent()` — if present — is read at the very START of each
//    task's iteration (before baseSha capture / the implementer dispatch —
//    moved there in the fix round; it was previously read AFTER the
//    implementer had already run, silently excluding the single most
//    expensive call from its own task's delta) and again right before
//    `finalize`; the difference is the honest, per-task delta passed to
//    `plan-io.mjs complete --tokens`. Degrades to a delta of 0 (logged, never
//    thrown) if `budget.spent` isn't a function — a missing budget accessor
//    must not abort an otherwise-successful task.
//
// 8. `phase(title)` (the global hook) is deliberately NOT called anywhere in
//    this file. Every agent()/relay() call instead passes `phase` in its own
//    `opts` — per the task brief, using the global phase() mutator would
//    race across the concurrent-ish sequence of relay/agent calls within one
//    task. `parallel`/`pipeline` are similarly unused: v2's build loop is
//    intentionally sequential (see spec §1 non-goals — DAG parallelism is a
//    future iteration), so batching hooks have nothing to batch.
//
// 9. Error handling (fix round, RULED): every internal fault that isn't a
//    designed ladder outcome (a relay JSON-parse failure past its retry
//    budget, review-package.sh/finalize.sh/ledger reporting ok:false) still
//    `throw`s locally, but the top-level IIFE (design note 1) wraps its
//    entire body in one try/catch that converts any such throw into
//    `return {halt:'error', detail: e.message}` — never an unhandled
//    rejection. Full halt vocabulary this module can return:
//    all-done | dag-stuck | interrupt | dirty-tree | stop-and-ask | bad-args
//    | error | null (null = ordinary completion, cap reached, nothing wrong).
//    Confirmed with the controller (round-2 review): `halt: null` IS the
//    tasks-cap/success signal — Task 15's SKILL halt table treats a `null`
//    halt as "ran to completion cleanly," not as a case needing dispatch.
//
// 10. lib/review-package.sh was rewritten in this fix round (controller
//     ruling — authorized cross-file touch beyond plan-io.mjs): it used to
//     diff `BASE..HEAD` (committed refs), but implementer/fix agents never
//     `git commit` — HEAD never moves until `finalize` — so that diff was
//     always empty. It now diffs BASE against the working tree (staged +
//     unstaged tracked changes) and inlines untracked files' content
//     (capped) since no `git diff` ever shows those. See that file's header
//     for the full reasoning. tests/lib/review-package.test.sh gained a case
//     covering an uncommitted tracked change + a new untracked file.
//
// 11. Quoting (fix round): every path-shaped value interpolated into a relay
//     command string is double-quoted (`"${boundary}"`, `"${lib}/..."`,
//     etc.) so a value containing a space or shell metacharacter can't split
//     into extra argv words or get re-parsed by the shell the relay agent
//     runs the command through. This includes `finalize.sh`'s `--files`
//     argument, which since the final-review round is a SINGLE path — the
//     task's boundary (design note 17b) — not a list.
//
// 12. relay() retryability (fix round, RULED): a JSON-parse-failure retry is
//     safe only for read-only or overwrite-idempotent commands (plan-io.mjs
//     next/validate-task.sh/review-package.sh/plan-io.mjs set-status — a
//     second run produces the same end state). It is NOT safe for commands
//     that APPEND or MUTATE-ONCE state: `apply-patches.py --stage` (a
//     second run would try to re-apply an already-applied search/replace and
//     spuriously fail as "not-found"), the combined
//     `plan-io.mjs complete && finalize.sh build-task` (retrying could
//     double-commit or double-log a telemetry event), and
//     `plan-io.mjs ledger` (retrying would duplicate a ledger line). Those
//     three call sites pass `retryable: false`; relay() then throws
//     immediately on the first parse failure instead of trying again,
//     surfacing as `{halt:'error', ...}` via design note 9.
//
// 13. Return-payload labeling: every returned outcome — every halt AND the
//     ordinary-completion result — is stamped with `run_id`/`now` from
//     `args` via the shared `withRunLabels()` helper, so the calling SKILL
//     can label a ledger/blockers message with which run produced it.
//     `project_root` (design note 14) is included too, only when it was
//     actually provided. Round 1/2 merged this in ONCE, at a single outer
//     IIFE return point; round 3 (design note 1) removed that IIFE — the
//     entry point is now plain top-level code with several `return` sites —
//     so every one of those sites calls `return withRunLabels(...)`
//     explicitly instead. `withRunLabels()` itself stays a single function,
//     so the labeling logic is still defined exactly once.
//
// 14. project_root (round-2 fix, controller-discovered integration gap):
//     workflow subagents (relay agents AND implementer/validator/reviewer/
//     fix/re-review/patch-writer/commit-msg-writer) inherit the CONTROLLER
//     session's cwd, not necessarily the target project's root. In the
//     common case (mvp:build's SKILL already `cd`'d to the target project
//     before calling Workflow()) that's a no-op — cwd already IS the
//     project root. But the dry-run fixture (and any future out-of-cwd
//     invocation: a worktree run, a remote agent, etc.) needs an explicit
//     root, since the controller session's own cwd is this PLUGIN repo, not
//     the synthetic tmp git repo the fixture builds. `args.project_root` is
//     optional (validateArgs never fails on its absence — see design note
//     re: fail-fast). When set:
//       - relayLine() (and therefore every relay() call, since relay()
//         wraps it) prefixes the command with `cd "<project_root>" && `
//         before it ever reaches the relay agent's Bash prompt — every
//         relative path inside plan-io.mjs/validate-task.sh/
//         review-package.sh/apply-patches.py/finalize.sh's own logic (which
//         all assume cwd == target project root, per each script's own
//         header) then resolves correctly regardless of the controller's
//         actual cwd. `${lib}` stays a plugin-repo-absolute path
//         (`args.plugin_root` is unaffected by project_root — the plugin's
//         own scripts don't move), so the script itself is still found.
//       - Every non-relay agent dispatch (implementer, implementer-retry,
//         validator, reviewer, fix, re-review, and the two raw Write-tool
//         agents for patches.json/commit-msg) gets an explicit first line —
//         `Work from directory: <project_root> (cd there before any
//         command; all relative paths are relative to it).` — via the
//         shared `cwdPrefixLine()` helper, since those agents read
//         BRIEF_PATH/BOUNDARY/PACKAGE_PATH/etc. as paths relative to the
//         project root and have no other way to learn what that root is.
//     `project_root` is included in the workflow's return payload (merged
//     alongside `run_id`/`now`) whenever it was provided, so the calling
//     SKILL/ledger can see which root a given run actually operated against.
//
// 15. Known scope note, documentation only, no code change (round-2 review):
//     lib/review-package.sh's untracked-file listing (design note 10) is
//     repo-wide — it does not filter by task boundary. In a real bootstrapped
//     target project this is expected to stay quiet because state-adjacent
//     scratch paths are typically gitignored; the dry-run fixture
//     (tests/fixtures/dryrun/make-dryrun.sh) does NOT add a .gitignore, so
//     once a real run starts writing `.claude/state/briefs/`, `reports/`,
//     `review/`, `patches-*.json`, `commit-msg-*.txt`, etc., those will show
//     up as "untracked" noise in later tasks' review packages alongside the
//     actual new file(s) a task creates. Deliberately left the fixture as-is
//     rather than adding a `.gitignore`: the fixture's job is to exercise
//     the real, unfiltered behavior of review-package.sh end-to-end (which
//     is exactly what a controller dry-run needs to see), and inventing a
//     gitignore convention here would be presuming a real-project pattern
//     that isn't actually established anywhere else in this plugin
//     (checked: no other lib/skills output ships a .gitignore template).
//     If the noise proves genuinely disruptive at the dry-run, the fix is a
//     one-line `.claude/state/.gitignore` added to make-dryrun.sh, not a
//     change to review-package.sh itself.
//
// 18. park() SKIPS the reset relay entirely when the task's boundary
//     normalizes to the repo root (empirically discovered on a target
//     project's first live build smoke: task 001, role devops, service_path
//     "."). A structural DAG-order conflict (ci-mirror.sh referencing
//     directories a later task creates) correctly parked the task, but
//     park()'s reset line
//     — `git checkout -- "." ...; git restore --staged "." ...; git clean
//     -fd -e .claude/state -- "."` — is a repo-WIDE destructive reset once
//     boundary is `.`, and the platform's safety classifier BLOCKED it
//     (rightly: for a real project this is the whole repo, not a task-scoped
//     path). The relay then returned no `{line}`, and relayLine() threw,
//     turning a clean stop-and-ask into an unhandled `halt:'error'` crash —
//     worse than doing nothing. `git clean -fd`/`checkout`/`restore` are
//     irreversible; there is no safe repo-root subset to reset short of not
//     resetting at all. Fix: `isRepoRootBoundary()` normalizes the boundary
//     (strips trailing slashes; treats '', '.', './' as root) and park()
//     branches on it — root boundary skips the relay outright (logged, and
//     folded into the returned `detail` so the operator sees WHY nothing was
//     reset), non-root boundaries keep the exact prior reset behavior
//     unchanged. set-status/the stop-and-ask halt still happen either way —
//     only the destructive git reset is conditional.
//
// 16. args may arrive STRINGIFIED (round 4, empirical — controller dry-run
//     attempt #2 returned `{"halt":"bad-args","detail":"missing required
//     arg(s): run_id, now, plugin_root"}` even though the SKILL demonstrably
//     passed all three; diagnostics showed the harness delivered `args` as
//     a JSON-ENCODED STRING, e.g. `"{\"run_id\": ...}"`, not an object — so
//     `args.run_id` read as `undefined` off a String instance, and every
//     field looked "missing" to validateArgs). Fixed by coercing ONCE, as
//     the very first statement inside the entry point's try block, before
//     validateArgs or anything else reads a field: `if (typeof args ===
//     'string')`, `JSON.parse` it into the module-scoped `argv`; a parse
//     failure sets `argv = {}` and returns a `bad-args` halt whose `detail`
//     names the string form (so a genuinely malformed payload is
//     distinguishable from a merely-missing-field one). If `args` is
//     already an object (the normal, expected shape), `argv = args`
//     directly — no behavior change from rounds 1-3. From this point on,
//     EVERY reference to a workflow argument anywhere in this file reads
//     `argv`, never the ambient `args` binding — `withCwd()`,
//     `cwdPrefixLine()`, all five template-self-read prompt builders,
//     `withRunLabels()`, and the entry point's own `plugin_root`/
//     `max_tasks`/`task_id` reads. `args` itself is referenced in exactly
//     one place now: the `typeof args === 'string'` coercion check.
//
// 17. files = OBSERVABILITY HINT, boundary = CONTRACT (final-review round,
//     controller ruling on finding C1). The three-file contract used to
//     conflict with itself: plan.json's per-task `files` list was declared a
//     planning hint everywhere else in v2 (the brief calls it a hint, the
//     implementer template names the BOUNDARY as its only hard rule and
//     explicitly expects tests it wasn't told to declare), yet
//     validate-task.sh enforced it EXHAUSTIVELY — a test file the plan never
//     listed produced a `declared`/undeclared-files violation that blocked
//     the task through the whole validator ladder. Resolution, in two parts:
//     a) VALIDATE. runValidateLadder() checks the violation set BEFORE
//        entering the ladder: if validate-task.sh failed and EVERY violation
//        has `check === "declared"`, validation is treated as PASSED — the
//        detail is `log()`ged and pushed onto `ctx.concerns` as a one-line
//        note (so it still surfaces in the workflow's return payload, and
//        from there into the operator's ledger via the SKILL). `ci` and
//        `boundary` violations are unchanged: they block, they go to the
//        validator, they can park the task. A MIXED list (declared + ci
//        and/or boundary) also blocks exactly as before — the shortcut is
//        deliberately declared-ONLY, so a real CI/boundary failure can never
//        be waved through by an accompanying file-list mismatch.
//     b) FINALIZE. Staging is by BOUNDARY, not by the declared list:
//        finalize()'s `--files` argument is the task's `boundary` path (plus
//        `.claude/state`, which finalize.sh's build-task scope appends on its
//        own). Staging the declared list would have SILENTLY DROPPED exactly
//        the files part (a) just stopped blocking on — an undeclared test
//        file would pass validation, get reviewed, and then never be
//        committed. Still explicit (one named path, never `git add -A`), per
//        this pipeline's staging rule. The declared list is still passed to
//        validate-task.sh `--files` (that is what produces the hint in the
//        first place) and is still what plan.json holds; nothing patches
//        plan.json at runtime.

export const meta = {
  name: 'mvp-build',
  description: 'DAG task loop: advance→implement→validate→review→finalize',
  phases: [
    { title: 'Advance' },
    { title: 'Implement' },
    { title: 'Validate' },
    { title: 'Review' },
    { title: 'Finalize' },
  ],
};

// --- caps --------------------------------------------------------------------

const IMPLEMENTER_RETRY_CAP = 1; // one implementer retry after a validator "retry" verdict
const TOTAL_ATTEMPTS_CAP = 2; // 1 initial implementer dispatch + at most 1 retry
// RE_REVIEW_CYCLES_CAP = 1 (one fix -> re-review pass, never repeated) has no
// dedicated constant: runReviewLadder() below is written as a single
// straight-line pass with no loop, so the cap is structural, not a runtime
// check — there is nothing to compare a counter against.

// --- module-scoped state set at the top of the entry point, before anything else --

let lib = ''; // argv.plugin_root + '/lib', set once argv is known-valid
// argv: the COERCED args object (design note 16, round 4) — see the entry
// point below. Every reference in this file that needs a workflow argument
// reads `argv`, never the ambient `args` binding directly (the one
// exception is the coercion check itself, which must inspect `args` to
// decide whether it needs parsing at all).
let argv = {};

// --- relay primitives ---------------------------------------------------------

const RELAY_SCHEMA = {
  type: 'object',
  properties: { line: { type: 'string' } },
  required: ['line'],
  additionalProperties: false,
};

// withCwd(cmd) -> cmd, prefixed with `cd "<project_root>" && ` when
// argv.project_root is set (design note 14). No-op (returns cmd unchanged)
// in the common case where the calling session's cwd already IS the target
// project root.
function withCwd(cmd) {
  return argv.project_root ? `cd "${argv.project_root}" && ${cmd}` : cmd;
}

// cwdPrefixLine() -> a prompt-prefix line for non-relay agent dispatches
// (design note 14), or '' when argv.project_root is unset. Every dispatched
// agent (implementer, validator, reviewer, fix, re-review, patch-writer,
// commit-msg-writer) reads paths that are relative to the target project
// root and has no other way to learn what that root is when it differs from
// the controller session's own cwd.
function cwdPrefixLine() {
  return argv.project_root
    ? `Work from directory: ${argv.project_root} (cd there before any command; all relative paths are relative to it).\n\n`
    : '';
}

// relayLine(cmd, opts) -> raw last-stdout-line string, unparsed. Relays never
// receive file contents — only the command to run and a one-line JSON reply
// back. Used directly (never via relay()'s JSON.parse layer) for commands
// whose output is not itself JSON: `git rev-parse HEAD`, park()'s git reset.
async function relayLine(cmd, opts = {}) {
  const fullCmd = withCwd(cmd);
  const prompt = `Run exactly this command via Bash:\n${fullCmd}\nReturn the LAST line of stdout verbatim as {"line": "..."}. Do not add anything.`;
  const callOpts = {
    model: 'haiku',
    effort: 'low',
    schema: RELAY_SCHEMA,
    label: opts.label || cmd,
    phase: opts.phase,
  };
  const out = await agent(prompt, callOpts);
  if (!out || typeof out.line !== 'string') {
    throw new Error(`relayLine: agent did not return a {line:string} object for cmd=${fullCmd}`);
  }
  return out.line;
}

// relay(cmd, opts) -> JSON.parse(relayLine(cmd, opts)). For the lib scripts
// that always emit the {ok,reason,hint,data} contract on one stdout line.
// `opts.retryable` (default true) gates whether a parse failure gets one
// retry — see design note 12: append/mutate-once commands pass
// `retryable: false` and fail immediately instead of risking a duplicate
// side effect.
async function relay(cmd, opts = {}) {
  const retryable = opts.retryable !== false;
  let line = await relayLine(cmd, opts);
  try {
    return JSON.parse(line);
  } catch (e1) {
    if (!retryable) {
      throw new Error(
        `relay: could not parse JSON stdout (non-retryable command, no second attempt). cmd=${cmd} line=${JSON.stringify(line)} error=${e1 && e1.message}`,
      );
    }
    line = await relayLine(cmd, opts);
    try {
      return JSON.parse(line);
    } catch (e2) {
      throw new Error(
        `relay: could not parse JSON stdout after 1 retry. cmd=${cmd} line=${JSON.stringify(line)} error=${e2 && e2.message}`,
      );
    }
  }
}

// --- agent text dispatch -------------------------------------------------------

// agentText(prompt, opts) -> string | null. agent() with no `schema` is
// documented to return the agent's final free-text message, but the exact
// return shape for the schema-less case is not pinned down anywhere in this
// sandbox's contract, so this coerces defensively. A dead/unknown dispatch
// target (agentType that doesn't exist) may resolve to `null`/`undefined`
// rather than throwing — that is propagated as an explicit `null`, NOT
// stringified to the literal text "null", so callers can null-guard it
// (design note / fix round item 8).
async function agentText(prompt, opts) {
  const res = await agent(prompt, opts);
  if (res == null) return null;
  if (typeof res === 'string') return res;
  if (typeof res.text === 'string') return res.text;
  return JSON.stringify(res);
}

// dispatchAgentText(prompt, {model, phase, label, agentType}) -> string | null.
// agentType is only meaningful for role-specific project agents generated by
// mvp:bootstrap (.claude/agents/<role>.md) — those exist only in the TARGET
// project, not universally. A dispatch that throws OR resolves to
// null/undefined for a given agentType is retried once as 'general-purpose'.
// If BOTH attempts fail/return nothing, this returns `null` — every call
// site null-guards the result and parks rather than letting a null flow into
// a STATUS/VERDICT regex (fix round item 8).
async function dispatchAgentText(prompt, { model, phase, label, agentType }) {
  const opts = { model, phase, label };
  if (!agentType) return agentText(prompt, opts);

  const attempt = async (type) => {
    try {
      return await agentText(prompt, { ...opts, agentType: type });
    } catch (e) {
      log(`agent dispatch with agentType=${type} threw (${e && e.message ? e.message : e})`);
      return null;
    }
  };

  let res = await attempt(agentType);
  if (res == null) {
    log(`agent dispatch with agentType=${agentType} returned no result (dead/unknown agentType or a throw); retrying as general-purpose`);
    res = await attempt('general-purpose');
  }
  return res;
}

// --- prompt builders (template self-read — see design note 3) ----------------

function implementerPrompt({ briefPath, boundary, taskId, reportPath }) {
  return cwdPrefixLine() + [
    `Read ${argv.plugin_root}/skills/build/agents/implementer.md and follow it exactly with these substitutions:`,
    `BRIEF_PATH=${briefPath}`,
    `BOUNDARY=${boundary}`,
    `TASK_ID=${taskId}`,
    `REPORT_PATH=${reportPath}`,
  ].join('\n');
}

function implementerRetryPrompt(basePrompt, violations) {
  return `${basePrompt}\n\nThis is a RETRY after validation failed. The previous attempt left these violations (JSON array of {"check","detail"}):\n${JSON.stringify(violations)}\nFix them within the same hard boundary before finishing.`;
}

function validatorPrompt({ taskId, boundary, violations }) {
  return cwdPrefixLine() + [
    `Read ${argv.plugin_root}/skills/build/agents/validator.md and follow it exactly with these substitutions:`,
    `TASK_ID=${taskId}`,
    `BOUNDARY=${boundary}`,
    `VIOLATIONS=${JSON.stringify(violations)}`,
  ].join('\n');
}

function reviewerPrompt({ taskId, briefPath, packagePath }) {
  return cwdPrefixLine() + [
    `Read ${argv.plugin_root}/skills/build/agents/reviewer.md and follow it exactly with these substitutions:`,
    `TASK_ID=${taskId}`,
    `BRIEF_PATH=${briefPath}`,
    `PACKAGE_PATH=${packagePath}`,
  ].join('\n');
}

function fixPrompt({ taskId, boundary, findings, reportPath }) {
  return cwdPrefixLine() + [
    `Read ${argv.plugin_root}/skills/build/agents/fix.md and follow it exactly with these substitutions:`,
    `TASK_ID=${taskId}`,
    `BOUNDARY=${boundary}`,
    `FINDINGS=${JSON.stringify(findings)}`,
    `REPORT_PATH=${reportPath}`,
  ].join('\n');
}

function reReviewPrompt({ taskId, packagePath, findings }) {
  return cwdPrefixLine() + [
    `Read ${argv.plugin_root}/skills/build/agents/re-review.md and follow it exactly with these substitutions:`,
    `TASK_ID=${taskId}`,
    `PACKAGE_PATH=${packagePath}`,
    `FINDINGS=${JSON.stringify(findings)}`,
  ].join('\n');
}

// --- final-message parsers (grep the agents' ≤15-line contract lines) --------

// Missing STATUS -> BLOCKED (park), per the brief: never silently treat an
// unparseable agent reply as success.
function parseStatus(text) {
  const m = /^STATUS:\s*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)/m.exec(text || '');
  return m ? m[1] : 'BLOCKED';
}

// extractField(text, label) -> the rest of the SAME line after "<LABEL>: ",
// trimmed, or null if the label never appears at the start of a line. For
// single-token contract fields (STATUS, VERDICT) which are guaranteed
// single-line by every template's contract.
function extractField(text, label) {
  const re = new RegExp(`^${label}:\\s*(.*)$`, 'm');
  const m = re.exec(text || '');
  return m ? m[1].trim() : null;
}

// extractJsonField(text, label) -> {found, value}. `found` is true iff
// "<LABEL>:" appears at the start of a line; `value` is the parsed JSON, or
// null if present-but-unparseable. Unlike extractField, this tolerates the
// JSON value spanning MULTIPLE lines: templates ask agents for single-line
// JSON (PATCHES/FINDINGS), but real replies sometimes pretty-print despite
// the instruction. Strategy: starting from the label's own line, accumulate
// one more line at a time and try JSON.parse on the growing trimmed buffer;
// stop accumulating (and give up) once a line that looks like the START of
// another ALL-CAPS contract token (e.g. "STATUS:", "VERDICT:") is hit, since
// that means the JSON block already ended without ever parsing.
function extractJsonField(text, label) {
  const re = new RegExp(`^${label}:[ \\t]*`, 'm');
  const m = re.exec(text || '');
  if (!m) return { found: false, value: null };

  const rest = (text || '').slice(m.index + m[0].length);
  const lines = rest.split('\n');
  let acc = '';
  for (let i = 0; i < lines.length; i++) {
    acc += (i > 0 ? '\n' : '') + lines[i];
    const trimmed = acc.trim();
    if (trimmed) {
      try {
        return { found: true, value: JSON.parse(trimmed) };
      } catch {
        // keep accumulating unless the next line starts a new contract token
      }
    }
    const next = lines[i + 1];
    if (next !== undefined && /^[A-Z][A-Z_-]*:/.test(next)) break;
  }
  return { found: true, value: null };
}

function extractConcernLines(text) {
  return (text || '')
    .split('\n')
    .filter((l) => l.trim() && !/^STATUS:/i.test(l) && !/^FILES:/i.test(l))
    .join(' ')
    .slice(0, 500);
}

// validator.md replies PATCHES:<json> OR VERDICT: retry|park. Anything
// unparseable defaults to a 'park' verdict — fail closed, not open.
function parseValidatorVerdict(text) {
  const patches = extractJsonField(text, 'PATCHES');
  if (patches.found && Array.isArray(patches.value)) {
    return { kind: 'patches', patches: patches.value };
  }
  const verdictRaw = extractField(text, 'VERDICT');
  const word = verdictRaw && /^(retry|park)/i.exec(verdictRaw);
  return { kind: 'verdict', verdict: word ? word[1].toLowerCase() : 'park' };
}

// reviewer.md replies VERDICT: approve|request-changes + FINDINGS:<json>, OR
// PATCHES:<json> for an all-trivial batch. Unparseable defaults to
// 'request-changes' with no findings — the caller (runReviewLadder) treats
// request-changes-with-empty-findings as fail-closed park, not a silent
// fix-dispatch with nothing to act on (fix round item 5).
function parseReviewerVerdict(text) {
  const patches = extractJsonField(text, 'PATCHES');
  if (patches.found && Array.isArray(patches.value)) {
    return { kind: 'patches', patches: patches.value };
  }
  const verdictRaw = extractField(text, 'VERDICT');
  const findings = extractJsonField(text, 'FINDINGS');
  const findingsArr = Array.isArray(findings.value) ? findings.value : [];
  const word = verdictRaw && /^(approve|request-changes)/i.exec(verdictRaw);
  return { kind: 'verdict', verdict: word ? word[1].toLowerCase() : 'request-changes', findings: findingsArr };
}

// re-review.md replies FINDINGS:<json array with a "verdict" field per item>
function parseReReview(text) {
  const findings = extractJsonField(text, 'FINDINGS');
  return Array.isArray(findings.value) ? findings.value : [];
}

// --- patches application (shared by the validate and review ladders) ---------

// applyPatchesFlow: the workflow writes patches.json itself, via a dedicated
// haiku agent using the Write tool (never a heredoc — patches.json can
// contain arbitrary code text that must not be shell-interpolated). Then a
// NON-RETRYABLE relay stages the apply (design note 12 — re-running an
// already-applied patch batch would spuriously fail). Returns the relay
// result; callers decide whether a failed apply is fatal (validate path
// re-validates and lets that be the judge; review path parks directly on a
// failed apply — fix round item 6).
async function applyPatchesFlow(id, patches, phaseTitle) {
  const patchesPath = `.claude/state/patches-${id}.json`;
  await agent(
    `${cwdPrefixLine()}Write EXACTLY this JSON to ${patchesPath} using the Write tool (create the file, overwrite any existing content, no extra text, no markdown code fences):\n${JSON.stringify(patches)}`,
    { model: 'haiku', effort: 'low', phase: phaseTitle, label: `patch-writer-${id}` },
  );
  const applyResult = await relay(`python3 "${lib}/apply-patches.py" "${patchesPath}" --stage`, {
    phase: phaseTitle,
    label: `apply-patches-${id}`,
    retryable: false,
  });
  if (!applyResult.ok) {
    log(`apply-patches.py reported failures for task ${id}: ${JSON.stringify(applyResult.data)}`);
  }
  return applyResult;
}

// --- budget (token-delta source — design note 7) ------------------------------

function safeBudgetSpent() {
  try {
    if (budget && typeof budget.spent === 'function') {
      const n = Number(budget.spent());
      return Number.isFinite(n) ? n : 0;
    }
  } catch (e) {
    log(`budget.spent() unavailable: ${e && e.message ? e.message : e}`);
  }
  return 0;
}

// --- validate ladder -----------------------------------------------------------

// declaredOnly(violations) -> true iff there IS at least one violation and
// every single one is a `declared` (file-list) mismatch. Design note 17a:
// the declared list is an observability hint, so a violation set made up of
// nothing but declared mismatches is a concern, never a block. Written as
// "some violations AND all of them declared" so an empty array (which never
// reaches here — an empty set means val.ok) can't be mistaken for a pass.
function declaredOnly(violations) {
  return violations.length > 0 && violations.every((v) => v && v.check === 'declared');
}

// noteDeclaredOnly: record the hint on the task's concerns so it still
// reaches the operator (through the workflow's return payload -> the SKILL's
// ledger line), then let the task proceed.
function noteDeclaredOnly(ctx, violations, stage) {
  const detail = violations.map((v) => (v && v.detail) || '').join('; ');
  log(
    `task ${ctx.id}: validate-task.sh (${stage}) reported ONLY declared-file mismatches — plan.json's files list is an observability hint, not a contract (design note 17a), so this does NOT block: ${detail}`,
  );
  ctx.concerns.push(`declared-files hint mismatch (non-blocking, ${stage}): ${detail}`);
}

// Returns {parked:false} on success, or {parked:true, why} to park the task.
// Ladder: a validator PATCHES verdict gets one direct apply+re-validate
// attempt that does NOT consume the implementer-retry budget; a 'retry'
// verdict (or a patch that still leaves violations) falls through to the
// single capped implementer retry; anything still failing after that parks.
// At EVERY validate call, a declared-only violation set short-circuits to
// success first (design note 17a) — the ladder below only ever sees ci /
// boundary / mixed failures.
async function runValidateLadder(ctx) {
  const validateCmd = () => `bash "${lib}/validate-task.sh" "${ctx.id}" --boundary "${ctx.boundary}" --files "${ctx.filesCsv}"`;

  let val = await relay(validateCmd(), { phase: 'Validate', label: `validate-${ctx.id}-1` });
  if (val.ok) return { parked: false };

  let violations = (val.data && val.data.violations) || [];
  if (declaredOnly(violations)) {
    noteDeclaredOnly(ctx, violations, 'initial');
    return { parked: false };
  }

  const verdictText = await agentText(validatorPrompt({ taskId: ctx.id, boundary: ctx.boundary, violations }), {
    model: 'sonnet',
    phase: 'Validate',
    label: `validator-${ctx.id}`,
  });
  const verdict = parseValidatorVerdict(verdictText);

  if (verdict.kind === 'patches') {
    await applyPatchesFlow(ctx.id, verdict.patches, 'Validate');
    val = await relay(validateCmd(), { phase: 'Validate', label: `validate-${ctx.id}-2` });
    if (val.ok) return { parked: false };
    violations = (val.data && val.data.violations) || violations;
    if (declaredOnly(violations)) {
      noteDeclaredOnly(ctx, violations, 'post-patches');
      return { parked: false };
    }
  } else if (verdict.verdict === 'park') {
    return { parked: true, why: `validator VERDICT: park — violations: ${JSON.stringify(violations)}` };
  }

  // Fall through to the single capped implementer retry (opus).
  if (ctx.attempts >= TOTAL_ATTEMPTS_CAP) {
    return { parked: true, why: `validate-task.sh still failing, retry cap (${IMPLEMENTER_RETRY_CAP}) reached: ${JSON.stringify(violations)}` };
  }
  ctx.attempts += 1;
  const retryPrompt = implementerRetryPrompt(
    implementerPrompt({ briefPath: ctx.briefPath, boundary: ctx.boundary, taskId: ctx.id, reportPath: ctx.reportPath }),
    violations,
  );
  const retryText = await dispatchAgentText(retryPrompt, {
    model: 'opus',
    phase: 'Implement',
    label: `implementer-retry-${ctx.id}`,
    agentType: ctx.agentType,
  });
  if (retryText == null) {
    return { parked: true, why: 'implementer retry dispatch failed: both agentType and general-purpose fallback returned no result' };
  }
  const retryStatus = parseStatus(retryText);
  if (retryStatus === 'BLOCKED' || retryStatus === 'NEEDS_CONTEXT') {
    return { parked: true, why: `implementer retry ${retryStatus}: ${retryText.slice(0, 400)}` };
  }
  if (retryStatus === 'DONE_WITH_CONCERNS') ctx.concerns.push(extractConcernLines(retryText));

  val = await relay(validateCmd(), { phase: 'Validate', label: `validate-${ctx.id}-3` });
  if (!val.ok) {
    const retryViolations = (val.data && val.data.violations) || [];
    if (declaredOnly(retryViolations)) {
      noteDeclaredOnly(ctx, retryViolations, 'post-retry');
      return { parked: false };
    }
    return { parked: true, why: `validate-task.sh still failing after implementer retry: ${JSON.stringify(retryViolations)}` };
  }
  return { parked: false };
}

// --- review ladder ---------------------------------------------------------------

// Returns {parked:false} on success (approve, or a trivial-patches shortcut),
// or {parked:true, why}. One fix -> re-review cycle, capped, never repeated.
async function runReviewLadder(ctx) {
  const packageCmd = () => `bash "${lib}/review-package.sh" "${ctx.id}" --base "${ctx.baseSha}"`;

  let rp = await relay(packageCmd(), { phase: 'Review', label: `review-package-${ctx.id}-1` });
  if (!rp.ok) throw new Error(`review-package.sh failed for task ${ctx.id}: ${rp.reason || 'unknown'}`);

  const reviewText = await agentText(
    reviewerPrompt({ taskId: ctx.id, briefPath: ctx.briefPath, packagePath: rp.data.path }),
    { model: 'sonnet', phase: 'Review', label: `reviewer-${ctx.id}` },
  );
  const verdict = parseReviewerVerdict(reviewText);

  if (verdict.kind === 'patches') {
    // Reviewer judged every finding trivial-mechanical: apply directly, no
    // fix-dispatch / re-review round (per agents/reviewer.md's own contract).
    // A failed apply here has no re-validate step to catch it (unlike the
    // validate-ladder's patches path) — park directly (fix round item 6).
    const applyResult = await applyPatchesFlow(ctx.id, verdict.patches, 'Review');
    if (!applyResult.ok) {
      return { parked: true, why: `review PATCHES apply failed: ${JSON.stringify(applyResult.data)}` };
    }
    return { parked: false };
  }
  if (verdict.verdict === 'approve') {
    return { parked: false };
  }

  // request-changes with no findings is unparseable/malformed — fail closed
  // rather than dispatching fix.md with an empty findings array (nothing for
  // it to act on; "empty findings, please fix" is not a real fix task).
  if (!verdict.findings || verdict.findings.length === 0) {
    return {
      parked: true,
      why: `reviewer VERDICT: request-changes but FINDINGS was empty or unparseable — raw reply: ${(reviewText || '').slice(0, 400)}`,
    };
  }

  // request-changes with real findings: exactly one fix -> re-review cycle.
  const fixText = await dispatchAgentText(
    fixPrompt({ taskId: ctx.id, boundary: ctx.boundary, findings: verdict.findings, reportPath: ctx.reportPath }),
    { model: 'sonnet', phase: 'Review', label: `fix-${ctx.id}`, agentType: ctx.agentType },
  );
  if (fixText == null) {
    return { parked: true, why: 'fix dispatch failed: both agentType and general-purpose fallback returned no result' };
  }
  const fixStatus = parseStatus(fixText);
  if (fixStatus === 'BLOCKED' || fixStatus === 'NEEDS_CONTEXT') {
    return { parked: true, why: `fix ${fixStatus}: ${fixText.slice(0, 400)}` };
  }
  if (fixStatus === 'DONE_WITH_CONCERNS') ctx.concerns.push(extractConcernLines(fixText));

  rp = await relay(packageCmd(), { phase: 'Review', label: `review-package-${ctx.id}-2` });
  if (!rp.ok) throw new Error(`review-package.sh (post-fix) failed for task ${ctx.id}: ${rp.reason || 'unknown'}`);

  const reReviewText = await agentText(
    reReviewPrompt({ taskId: ctx.id, packagePath: rp.data.path, findings: verdict.findings }),
    { model: 'sonnet', phase: 'Review', label: `re-review-${ctx.id}` },
  );
  if (reReviewText == null) {
    return { parked: true, why: 're-review dispatch failed: agent returned no result' };
  }
  const verdicted = parseReReview(reReviewText);
  const stillOpen = verdicted.filter((f) => String(f && f.verdict).toUpperCase() !== 'ADDRESSED');
  if (stillOpen.length > 0) {
    // RE_REVIEW_CYCLES_CAP=1: this is the only re-review pass — no looping.
    return { parked: true, why: `re-review: ${stillOpen.length} finding(s) NOT ADDRESSED: ${JSON.stringify(stillOpen)}` };
  }
  return { parked: false };
}

// --- finalize ---------------------------------------------------------------------

async function finalize(id, title, boundary, tokensDelta, phaseTitle) {
  const subject = title ? `feat: task ${id}: ${title}` : `feat: task ${id}`;
  const msgPath = `.claude/state/commit-msg-${id}.txt`;
  await agent(
    `${cwdPrefixLine()}Write EXACTLY this text to ${msgPath} using the Write tool (create the file, overwrite any existing content, no extra text, no markdown code fences):\n${subject}\n`,
    { model: 'haiku', effort: 'low', phase: phaseTitle, label: `msg-writer-${id}` },
  );

  // Staging scope is the task's BOUNDARY, not its declared file list (design
  // note 17b): the declared list is a hint, so anything the task legitimately
  // created inside the boundary but the plan never listed (a test file, a
  // fixture) must still be committed. One quoted path — explicit, never
  // `git add -A`; finalize.sh's build-task scope appends `.claude/state`
  // itself, which is where the report/brief/state files live.
  const fin = await relay(
    `node "${lib}/plan-io.mjs" complete "${id}" --tokens ${tokensDelta} && bash "${lib}/finalize.sh" build-task "${msgPath}" --files "${boundary}"`,
    { phase: phaseTitle, label: `finalize-${id}`, retryable: false },
  );
  if (!fin.ok) {
    throw new Error(`finalize failed for task ${id}: ${fin.reason || 'unknown'}`);
  }

  const ledgerResult = await relay(`node "${lib}/plan-io.mjs" ledger --task "${id}" --sha "${fin.data.sha}"`, {
    phase: phaseTitle,
    label: `ledger-${id}`,
    retryable: false,
  });
  if (!ledgerResult.ok) {
    throw new Error(`ledger failed for task ${id}: ${ledgerResult.reason || 'unknown'}`);
  }
  return fin.data.sha;
}

// --- park ---------------------------------------------------------------------

// isRepoRootBoundary(boundary) -> true iff the boundary string normalizes to
// the repo root: '', '.', './' (any number of trailing slashes stripped —
// no `path` import available here, see the file header's no-import
// constraint, so this is a plain string normalization, not path.normalize).
// Used by park() (design note 18) to decide whether the reset relay is safe
// to run at all — a root boundary means "the whole repo", not a task-scoped
// subtree.
function isRepoRootBoundary(boundary) {
  const norm = String(boundary || '').trim().replace(/\/+$/, '');
  return norm === '' || norm === '.';
}

// park(id, boundary, why): clean the working tree back to HEAD within the
// task's boundary — including untracked files the implementer created
// (`git clean -fd`, fix round item 2/7: without it, an untracked file left
// behind would make every subsequent `plan-io next` halt dirty-tree forever)
// but NEVER `.claude/state` (final-review finding I1: a root-level boundary
// — `.` — made that clean wipe the pipeline's own state directory, i.e. the
// brief, the report and the freshly-written failed-status plan.json, taking
// the run's memory with it). `-e .claude/state` must come BEFORE the `--`:
// after it, git parses `-e` as a pathspec, not a flag (verified empirically
// in a scratch repo — the post-`--` form removed .claude/state anyway)
// — mark it failed via plan-io.mjs (the only mutating, park-safe subcommand
// — plan-io has no dedicated "park" verb), and return a stop-and-ask halt.
// The reset line's output is not JSON (often no output at all), so this uses
// relayLine, NOT relay — using relay() here was a CRITICAL bug (fix round):
// JSON.parse("") threw on every single park() call. Per design note 4, the
// Ruling/Parked ledger line and blockers.md entry are the calling SKILL's
// job, driven off this halt's `detail` — this workflow never writes prose
// files itself.
//
// Design note 18 (empirical, first live smoke): when `boundary` normalizes
// to the repo root, the reset line above becomes a repo-WIDE `git
// checkout/restore/clean` — irreversible destruction of a real project's
// working tree, and exactly the shape the platform's safety classifier
// BLOCKS. A blocked relay returns no `{line}`, which used to throw inside
// relayLine() and turn a clean stop-and-ask into an unhandled `halt:'error'`
// crash. There is no safe partial reset at the repo root, so the relay is
// skipped ENTIRELY in that case — the working tree is left as-is for the
// operator to inspect and clean up by hand — and the skip is recorded both
// via log() and folded into the returned `why`/`detail` so the operator
// isn't left guessing why nothing was reset. Non-root boundaries are
// unaffected: same reset line, same behavior as before this fix.
async function park(id, boundary, why) {
  const atRoot = isRepoRootBoundary(boundary);
  if (atRoot) {
    log(
      `park: task ${id} boundary (${JSON.stringify(boundary)}) normalizes to the repo root — skipping the reset relay entirely (a repo-wide git checkout/restore/clean is irreversible and gets classifier-blocked); working tree left as-is for operator review`,
    );
  } else {
    await relayLine(
      `git checkout -- "${boundary}" 2>/dev/null; git restore --staged "${boundary}" 2>/dev/null; git clean -fd -e .claude/state -- "${boundary}" 2>/dev/null; true`,
      { phase: 'Finalize', label: `park-clean-${id}` },
    );
  }
  const statusResult = await relay(`node "${lib}/plan-io.mjs" set-status "${id}" failed`, {
    phase: 'Finalize',
    label: `park-status-${id}`,
  });
  if (!statusResult.ok) {
    log(`park: set-status failed for task ${id}: ${statusResult.reason || 'unknown'}`);
  }
  const detail = atRoot
    ? `${why} — boundary is repo root — working tree left as-is for operator review (no automatic reset)`
    : why;
  return { halt: 'stop-and-ask', task_id: id, detail };
}

// --- one task ---------------------------------------------------------------------

async function runOneTask(adv) {
  const id = adv.data.task_id;
  const briefPath = adv.data.brief_path;
  const boundary = adv.data.boundary;
  const role = adv.data.role;
  const modelClass = adv.data.model_class;
  const title = adv.data.title; // added to plan-io.mjs's `next` payload in the fix round
  const declaredFiles = Array.isArray(adv.data.files) ? adv.data.files : [];
  const filesCsv = declaredFiles.join(',');
  const reportPath = `.claude/state/reports/task-${id}.md`;

  // Token-delta measurement starts here, at the very top of the task
  // iteration — BEFORE baseSha capture and the implementer dispatch (fix
  // round item 4: it previously started only after the implementer had
  // already run, silently excluding that call's cost from its own task's
  // delta).
  const spentBefore = safeBudgetSpent();

  const baseSha = await relayLine('git rev-parse HEAD', { phase: 'Advance', label: `basesha-${id}` });

  const initialModel = modelClass === 'novel-design' ? 'opus' : 'sonnet';
  const implPrompt = implementerPrompt({ briefPath, boundary, taskId: id, reportPath });
  const implText = await dispatchAgentText(implPrompt, {
    model: initialModel,
    phase: 'Implement',
    label: `implementer-${id}`,
    agentType: role,
  });
  if (implText == null) {
    return park(id, boundary, 'implementer dispatch failed: both agentType and general-purpose fallback returned no result');
  }

  const concerns = [];
  const status = parseStatus(implText);
  if (status === 'BLOCKED' || status === 'NEEDS_CONTEXT') {
    return park(id, boundary, `implementer ${status}: ${implText.slice(0, 400)}`);
  }
  if (status === 'DONE_WITH_CONCERNS') concerns.push(extractConcernLines(implText));

  const ctx = { id, boundary, filesCsv, briefPath, reportPath, agentType: role, attempts: 1, concerns, baseSha };

  const valOutcome = await runValidateLadder(ctx);
  if (valOutcome.parked) return park(id, boundary, valOutcome.why);

  const revOutcome = await runReviewLadder(ctx);
  if (revOutcome.parked) return park(id, boundary, revOutcome.why);

  const spentAfter = safeBudgetSpent();
  const tokensDelta = Math.max(0, spentAfter - spentBefore);

  const sha = await finalize(id, title, boundary, tokensDelta, 'Finalize');

  return { done: true, task_id: id, sha, tokens_delta: tokensDelta, concerns: ctx.concerns };
}

// --- args validation (design note: fail fast, before any agent() call) -------

function validateArgs(a) {
  const missing = [];
  if (!a || typeof a.run_id !== 'string' || a.run_id === '') missing.push('run_id');
  if (!a || typeof a.now !== 'string' || a.now === '') missing.push('now');
  if (!a || typeof a.plugin_root !== 'string' || a.plugin_root === '') missing.push('plugin_root');
  if (missing.length) {
    return { halt: 'bad-args', detail: `missing required arg(s): ${missing.join(', ')}` };
  }
  if (typeof a.max_tasks !== 'number' || !Number.isFinite(a.max_tasks) || a.max_tasks <= 0) {
    return { halt: 'bad-args', detail: `max_tasks must be a positive number, got: ${JSON.stringify(a.max_tasks)}` };
  }
  // project_root is OPTIONAL (design note 14) — absence is never a bad-args
  // failure. When present it must be a non-empty string, same shape rule as
  // every other path-like arg.
  if (a.project_root !== undefined && (typeof a.project_root !== 'string' || a.project_root === '')) {
    return { halt: 'bad-args', detail: `project_root, if given, must be a non-empty string, got: ${JSON.stringify(a.project_root)}` };
  }
  return null;
}

// withRunLabels(result) -> result, stamped with run_id/now (and project_root
// when provided) from argv (the coerced args — design note 16). Called at
// every return site below, since (per design note 1, round 3) there is no
// single outer wrapper to merge these in once anymore — the runner supplies
// its own wrapper function, and this script's body runs directly inside it.
function withRunLabels(result) {
  const labels = { run_id: argv?.run_id, now: argv?.now };
  if (argv?.project_root) labels.project_root = argv.project_root;
  return { ...result, ...labels };
}

// ASYNCFUNCTION SANITY CHECK (round 3 — replaces `node --check` for this
// file, see design note 1). `node --check` validates this file as a
// standalone ES module, where a top-level `return` below is ALWAYS a
// SyntaxError — but that is not the contract the real runner uses, so
// `node --check` on this file is now EXPECTED to fail and is no longer part
// of this task's verification. The check that actually mirrors the runner
// (strip the `export const meta` block, wrap the rest as an AsyncFunction
// body, confirm construction doesn't throw) is a one-liner, run from the
// plugin repo root:
//
//   node -e "const src=require('fs').readFileSync('skills/build/workflow.mjs','utf8').replace(/^export const meta[\s\S]*?^}/m,''); new (Object.getPrototypeOf(async function(){}).constructor)('agent','parallel','pipeline','log','phase','args','budget','workflow', src)"
//
// A clean exit (no SyntaxError) means the runner's own parse step will
// accept this file's shape.

// --- entry point ---------------------------------------------------------------
//
// Plain top-level statements — NOT an IIFE, NOT an exported function (design
// note 1, round 3 — see there for the full story). Ends in a top-level
// `return`, which is legal here because the Workflow runtime extracts
// `export const meta` above and wraps everything AFTER it in its own async
// function before evaluating it — this script's body runs as that function's
// body, not as a standalone ES module. One try/catch (design note 9): any
// internal throw becomes {halt:'error', ...} instead of an unhandled
// rejection/crash.

try {
  // Coerce a possibly-STRINGIFIED args (round 4 — empirically observed on
  // the controller's dry-run: the harness delivered `args` as a
  // JSON-encoded string, e.g. `"{\"run_id\": ...}"`, not an object — every
  // field on the real `args` binding then read as `undefined`, since a
  // String instance has no `.run_id` property, and validateArgs reported
  // ALL of run_id/now/plugin_root missing even though they were present
  // inside the string). This MUST happen before validateArgs, and before
  // any other statement reads a field off an args-shaped value — see
  // design note 16.
  if (typeof args === 'string') {
    try {
      argv = JSON.parse(args);
    } catch (e) {
      argv = {};
      return withRunLabels({
        halt: 'bad-args',
        detail: `args arrived as a string and failed to JSON.parse: ${e && e.message ? e.message : e}. raw (first 200 chars): ${args.slice(0, 200)}`,
      });
    }
  } else {
    argv = args;
  }

  const badArgs = validateArgs(argv);
  if (badArgs) return withRunLabels(badArgs);

  lib = `${argv.plugin_root}/lib`;

  const results = [];
  let tasksDone = 0;

  while (tasksDone < argv.max_tasks) {
    const nextCmd = `node "${lib}/plan-io.mjs" next${argv.task_id ? ` --task "${argv.task_id}"` : ''}`;
    const adv = await relay(nextCmd, { phase: 'Advance', label: `advance-${tasksDone}` });
    if (!adv.ok) {
      throw new Error(`plan-io.mjs next failed: ${adv.reason || 'unknown'}`);
    }
    if (adv.data && adv.data.halt) {
      // all-done | dag-stuck | interrupt | dirty-tree — propagate verbatim,
      // the calling SKILL owns the halt-table dispatch. `files` is carried
      // through too when plan-io.mjs supplied it (final-review finding M5:
      // the dirty-tree halt puts the offending paths in `data.files`, and
      // reading only `data.detail` here dropped them, leaving the SKILL to
      // re-derive the list with its own `git status`).
      const haltPayload = { halt: adv.data.halt, detail: adv.data.detail };
      if (adv.data.files !== undefined) haltPayload.files = adv.data.files;
      return withRunLabels(haltPayload);
    }

    const outcome = await runOneTask(adv);
    if (outcome.halt) return withRunLabels(outcome); // park() propagates its stop-and-ask halt directly

    results.push({ task_id: outcome.task_id, sha: outcome.sha, tokens_delta: outcome.tokens_delta, concerns: outcome.concerns });
    tasksDone += 1;
    if (argv.task_id) break;
  }

  // Ordinary completion: the requested cap (--tasks N, or a single
  // --task <id>) was reached with no ladder failure. halt: null — not part
  // of the operator-attention halt vocabulary (design note 9).
  return withRunLabels({ halt: null, tasks_done: tasksDone, results });
} catch (e) {
  log(`workflow error: ${e && e.stack ? e.stack : e}`);
  return withRunLabels({ halt: 'error', detail: e && e.message ? e.message : String(e) });
}
