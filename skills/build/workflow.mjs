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
//    string, no parsing. relay(cmd) dispatches a SEPARATE structured-schema
//    relay call (see design note 19 — NOT a wrapper around relayLine as of
//    the fix round) for the lib-script contract calls, retried once by
//    default (see design note 12 for when it is NOT retried). baseSha and
//    park()'s reset both use relayLine directly — using relay() on either
//    was a CRITICAL bug (fix round): JSON.parse("") threw on every single
//    park() call (relay() parsed JSON at that time — see design note 19 for
//    why it no longer does).
//
// 3. Template self-read prompts. This workflow never reads agents/*.md
//    itself (no FS access). Each dispatch prompt instead tells the agent to
//    read its own template file and mentally substitute placeholders — the
//    values passed cover exactly each template's documented Placeholders
//    block (verified against skills/build/agents/*.md, Task 13).
//
// 4. Concerns ARE persisted, by a script, since 2026-08-25 — this note said
//    the opposite for the whole v2.0 line and the opposite was the bug.
//    Originally: plan-io.mjs had no "append" verb and this script has no FS
//    access, so concerns rode home in the RETURN VALUE and the calling SKILL
//    was instructed to write them into ledger.md. Measured over the vireo
//    run: concerns arose on 35 of 36 tasks, reached the payload on 30, and
//    ledger.md received ZERO — a state write left to an LLM was skipped 36
//    times out of 36, which is precisely what the Iron Law exists to
//    prevent. `plan-io.mjs ledger --concern` now writes them inside
//    finalize()'s single relay command. They still travel in the return
//    value as well, for the SKILL's run summary — but nothing depends on
//    the SKILL remembering. blockers.md remains the dispatched agent's own
//    file, written by the agent under the _common.md contract.
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
// 12. relay() retryability (fix round, RULED): a malformed/null structured-
//     result retry (JSON-parse-failure retry, pre-design-note-19) is safe
//     only for read-only or overwrite-idempotent commands (plan-io.mjs
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
//     once a real run starts writing `.mvp/briefs/`, `reports/`,
//     `review/`, `patches/`, `commit-messages/`, etc., those will show
//     up as "untracked" noise in later tasks' review packages alongside the
//     actual new file(s) a task creates. Deliberately left the fixture as-is
//     rather than adding a `.gitignore`: the fixture's job is to exercise
//     the real, unfiltered behavior of review-package.sh end-to-end (which
//     is exactly what a controller dry-run needs to see), and inventing a
//     gitignore convention here would be presuming a real-project pattern
//     that isn't actually established anywhere else in this plugin
//     (checked: no other lib/skills output ships a .gitignore template).
//     If the noise proves genuinely disruptive at the dry-run, the fix is a
//     one-line `.mvp/.gitignore` added to make-dryrun.sh, not a
//     change to review-package.sh itself.
//
// 18. park() SKIPS the reset relay entirely when the task's boundary
//     normalizes to the repo root (empirically discovered on a target
//     project's first live build smoke: task 001, role devops, service_path
//     "."). A structural DAG-order conflict (ci-mirror.sh referencing
//     directories a later task creates) correctly parked the task, but
//     park()'s reset line
//     — `git checkout -- "." ...; git restore --staged "." ...; git clean
//     -fd -e .mvp -- "."` — is a repo-WIDE destructive reset once
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
//        `.mvp`, which finalize.sh's build-task scope appends on its
//        own). Staging the declared list would have SILENTLY DROPPED exactly
//        the files part (a) just stopped blocking on — an undeclared test
//        file would pass validation, get reviewed, and then never be
//        committed. Still explicit (one named path, never `git add -A`), per
//        this pipeline's staging rule. The declared list is still passed to
//        validate-task.sh `--files` (that is what produces the hint in the
//        first place) and is still what plan.json holds; nothing patches
//        plan.json at runtime.
//
// 19. relay() TRANSPORT (fix round, empirical — live build smoke, task 002).
//     relay() used to be relayLine() + JSON.parse(): the relay agent copied
//     the target command's last stdout line into a SEPARATE {"line": "..."}
//     JSON envelope (string-in-string), and this file re-parsed that string
//     as JSON. On task 002 the validate-task.sh output line was ~1.5KB of
//     JSON containing nested `\n` escapes inside `data.violations[].detail`
//     (Russian text, long file lists) — the relay agent's own re-escaping of
//     that string into ITS {"line": ...} reply corrupted the escapes, and
//     JSON.parse(line) threw `Expected '}'` after the one built-in retry,
//     halting the whole run with `halt:'error'`. This was exactly the
//     spec's flagged risk ("I/O-реле исказит однострочный JSON") —
//     string-in-string transport was the weak link, not the target
//     command's own output.
//     Fix: relay() (the JSON-parsing variant only — relayLine() is
//     unchanged, still used for genuinely non-JSON output: `git rev-parse
//     HEAD`, park()'s reset line) now gives the dispatched agent the
//     CONTRACT schema directly (RELAY_RESULT_SCHEMA — {ok, reason, hint,
//     data}) instead of the generic {line:string} envelope, and tells it to
//     parse the command's last stdout line as JSON and return THAT object
//     via structured output. The platform validates the shape and hands
//     back an already-parsed OBJECT — there is no second JSON string for
//     this file to re-escape or re-parse, so the double-escaping failure
//     mode is structurally impossible now, not just less likely.
//     Schema looseness, deliberate: `ok` is the only field with `required`
//     and a strict `type: 'boolean'` — it is the one field every call site
//     actually branches on (`if (!val.ok)`, `if (!fin.ok)`, etc.).
//     `reason`/`hint`/`data` are left as permissive `{}` (no `type`
//     constraint) rather than `type: ['string','null']` / `type:
//     ['object','null']` union arrays: this sandbox's agent() schema hook is
//     not documented anywhere in this file's ambient-hooks contract (top of
//     file), and RELAY_SCHEMA (relayLine's schema, design note 2) only ever
//     exercised single, non-union `type` values before this change —
//     pushing a not-yet-proven union-type form onto the FIRST union-typed
//     schema this file gives the hook risked trading one transport failure
//     for a schema-validation failure with the identical symptom (an
//     unusable relay result). Permissive fields cost nothing here: every
//     call site already reads `reason`/`hint`/`data` defensively (`||`,
//     `(val.data && val.data.violations) || []`, etc.), so an unconstrained
//     value flowing through is not a new failure mode. If a future round
//     confirms union `type` arrays are safe on this hook, tightening
//     `reason`/`hint`/`data` to the commented-out strict forms is a
//     schema-only change, no call-site impact.
//     Retry/null-guard semantics are UNCHANGED from the old relay(): a
//     missing/malformed result (here: `out` is null/undefined — a dead
//     relay agent — OR `out.ok` is not a boolean, the one shape check this
//     file still performs) gets ONE retry when `opts.retryable` is not
//     `false` (design note 12), else throws immediately — surfacing as
//     `halt:'error'` via design note 9. relayLine() and RELAY_SCHEMA (the
//     {line:string} envelope) are untouched — still used exactly as design
//     note 2 describes for non-JSON commands.
//
// 19b. relay() FIELD-SHAPE DRIFT (round 2, empirical — live build smoke,
//     task 002 rerun, journal evidence: `{"ok": true, "reason": "null",
//     "hint": "null", "data": "{\n  \"task_id\": \"002\", ...}"}`). The
//     structured-output layer is schema-VALID per RELAY_RESULT_SCHEMA (note
//     19's deliberately permissive `{}` sub-schemas impose no type on
//     reason/hint/data) but WRONG for every call site's assumption: a haiku
//     relay agent returned `data` as a STRING of pretty-printed JSON instead
//     of the JSON object the target command actually printed, and
//     `reason`/`hint` as the LITERAL STRING "null" instead of JSON `null`
//     when the underlying command left them absent. `adv.data.boundary`
//     read as `undefined` off that string, and the implementer dispatch was
//     (correctly) blocked downstream as boundary-less. This is note 19's
//     transport-fragility risk recurring one layer up: not string-in-string
//     re-escaping this time, but the agent silently re-stringifying a field
//     it was asked to hand back as a real JSON value.
//     Fix: `coerceRelayFields(out)` runs on every successful `agent()` call
//     inside relay() before the result is accepted — `typeof out.data ===
//     'string'` gets `JSON.parse`d (its failure is treated exactly like a
//     missing/non-boolean `ok`: consumes the one retry, then throws, per
//     the existing ladder), `out.reason`/`out.hint === 'null'` (the string)
//     become real `null`, and a stringified `out.ok` ("true"/"false") is
//     coerced to a real boolean defensively (not yet observed, but the same
//     drift class — cheap to guard now rather than wait for a round 3).
//     Schema vs. coercion, the actual call made here: RELAY_RESULT_SCHEMA's
//     `data`/`reason`/`hint` STAY permissive `{}` rather than tightening to
//     `data: {type:'object', additionalProperties:true}` — tempting, since
//     that would reject a stringified `data` outright — because `data` is
//     legitimately `null` on several real contract replies (see
//     lib/*.{sh,py} headers: `"data":object|null`), and note 19 already
//     ruled union `type` arrays (`type:['object','null']`) too risky to be
//     the first union form handed to this sandbox's undocumented schema
//     hook. Round 2 is exactly the evidence that would be needed to revisit
//     that ruling, but this fix round chooses NOT to spend it on an
//     unproven schema change when a coercion layer already closes the
//     concrete failure observed — enforcement moves to application code
//     (coerceRelayFields), which this file can test and reason about
//     directly, instead of an opaque platform validator. If a future round
//     needs to reject shapes coercion can't recover (e.g. `data` a string
//     that ALSO fails to parse as JSON — already handled: treated as
//     malformed, retried/thrown, never silently accepted), that is the
//     trigger to revisit tightening the schema itself.
//     Prompt also strengthened accordingly: it now says explicitly that
//     `data` must be a JSON OBJECT (not a string of JSON) and `reason`/
//     `hint` must be JSON `null` (not the string "null") — coercion is the
//     enforcement backstop, not a substitute for asking correctly.
//
//     ROUND 3 (empirical, live build smoke, run 005, journal evidence):
//     `{"ok": true, "data": "{\n \"ok\": true, \"reason\": null,
//     \"hint\": null, \"data\": {\"path\": \".mvp/review/
//     task-002.md\"}}"}` — the relay agent stuffed the ENTIRE contract line
//     into `data` as a string, i.e. one full envelope nested inside
//     another. Round-2 coercion correctly `JSON.parse`s that string but then
//     leaves the WHOLE parsed envelope sitting in `out.data` — every call
//     site reading `out.data.<field>` (e.g. `rp.data.path`) got `undefined`
//     because the real value was one level deeper, at `out.data.data.path`.
//     Consequence: the reviewer was dispatched with PACKAGE_PATH=undefined,
//     the safety classifier (correctly) blocked it, and the task
//     fail-closed parked — the right guard tripped for the wrong reason.
//     Fix: `looksLikeEnvelope(v)` recognizes an object that itself has both
//     an `ok` key and a `data` key — the shape of a full contract reply,
//     never a legitimate `data` PAYLOAD shape (checked against every
//     lib/*.{sh,py,mjs} script's actual `data` fields — `violations`,
//     `sha`, `path`, `applied`/`failed`, etc. — none of which carry an `ok`
//     key of their own). `coerceRelayFields` now checks
//     `looksLikeEnvelope(out.data)` AFTER the string-parse step (so it
//     catches BOTH round 3's reported forms — `data` arriving as a
//     stringified envelope, and `data` arriving as an already-parsed
//     envelope OBJECT — with the one check) and, if true, replaces `out`
//     ENTIRELY with that nested object and re-runs the same normalization
//     on it (`depth` parameter caps this at exactly one unwrap — a relay
//     agent nesting two envelopes deep is not chased further; it falls
//     through as an ordinary malformed-result retry/throw instead of a
//     silent wrong value, same fail-safe shape as every other drift case
//     here). Not conditioned on top-level `reason`/`hint` being absent (an
//     earlier draft of this fix considered that an extra guard) — the
//     `ok`+`data` co-occurrence in `data`'s own shape is narrow enough on
//     its own, and adding the extra condition would have silently skipped
//     the unwrap on any future variant that happens to echo top-level
//     reason/hint too.

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

// dispatchCount: every subagent dispatch this run has made, incremented at
// each of the four call sites that actually invoke agent() (relayLine, relay,
// agentText, the patch-writer). Telemetry records the per-task delta.
//
// Why it exists: `budget.spent()` — the number stored as delta_tokens — only
// sees the CONTROLLER's usage, and measured against the workflow runtime's own
// per-agent records it understates the true cost by ~8.4x. Dispatch count is
// not a token figure, but unlike delta_tokens it scales with the real spend
// (each dispatch carries a ~30 200-token boot floor), so it is an honest
// proxy. It is added ALONGSIDE delta_tokens, never replacing it: events.jsonl
// is append-only and a project's history may span plugin versions.
let dispatchCount = 0;

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
  dispatchCount += 1;
  const out = await agent(prompt, callOpts);
  if (!out || typeof out.line !== 'string') {
    throw new Error(`relayLine: agent did not return a {line:string} object for cmd=${fullCmd}`);
  }
  return out.line;
}

// RELAY_RESULT_SCHEMA: the {ok,reason,hint,data} contract every lib/*.{mjs,
// sh,py} script emits on its last stdout line (see design note 19 for why
// this is given to the agent directly instead of a {line:string} envelope,
// and why reason/hint/data are deliberately left permissive rather than
// `type: ['string','null']` / `type: ['object','null']` union forms).
const RELAY_RESULT_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    reason: {},
    hint: {},
    data: {},
  },
  required: ['ok'],
  additionalProperties: true,
};

// looksLikeEnvelope(v) -> true iff v is a plain object that itself has the
// shape of a full {ok,...,data} contract reply (round-3 evidence below):
// specifically `ok` present AND a `data` key present. Checked against every
// lib/*.{sh,py,mjs} script's own `data` payload shapes (`{violations:[...]}`,
// `{sha:...}`, `{path:...}`, `{applied:[...],failed:[...]}`, etc.) — none of
// them legitimately carry BOTH an `ok` and a `data` key of their own, so this
// heuristic never misfires on a real (non-nested) data payload.
function looksLikeEnvelope(v) {
  return !!v && typeof v === 'object' && !Array.isArray(v) && typeof v.ok !== 'undefined' && 'data' in v;
}

// coerceRelayFields(out, depth) -> out (or a replacement object), with
// empirical field-shape drift normalized (design note 19b):
//   - round 2: a haiku relay agent has been observed returning `data` as a
//     STRING of pretty-printed JSON (instead of the JSON object
//     RELAY_RESULT_SCHEMA and the prompt both ask for) and `reason`/`hint`
//     as the LITERAL STRING "null" (instead of JSON `null`) when the
//     underlying command left them absent — schema-valid under the
//     deliberately permissive `{}` sub-schemas (design note 19), but wrong
//     for every call site that reads `val.data.violations`/`fin.data.sha`/
//     etc. assuming a real object. Also defensively coerces a stringified
//     `ok` ("true"/"false") to a real boolean, the same drift class.
//   - round 3: the relay agent has ALSO been observed nesting the ENTIRE
//     {ok,reason,hint,data} envelope one level inside `data` — either as
//     the stringified JSON handled above, or directly as an object — e.g.
//     `{"ok":true,"data":"{\n \"ok\":true,\"reason\":null,\"hint\":null,
//     \"data\":{\"path\":\"...\"}}"}`. Round-2 coercion alone JSON.parses
//     the string correctly but then leaves the WHOLE envelope sitting in
//     `out.data`, so `out.data.path` reads as `undefined` (the real value
//     is one level deeper, at `out.data.data.path`) — a fail-closed park
//     with the wrong trigger (PACKAGE_PATH=undefined instead of the
//     structural issue this guard is actually for). Fix: after the
//     string-parse step, if `out.data` looksLikeEnvelope(), that nested
//     object IS the real relay result — replace `out` entirely with it and
//     re-run this same normalization on the replacement (`depth` guards
//     against recursing past one unwrap; a relay agent nesting the
//     envelope two levels deep is not a case worth chasing — it will
//     surface as a normal malformed-result retry/throw instead of a
//     silent wrong value). Applies uniformly whether `data` arrived as a
//     string that parsed into an envelope shape or as an object already in
//     that shape — one check covers both of round 3's reported forms.
// Throws (never swallows) if `data` is a string that fails to JSON.parse —
// the caller treats that identically to a missing/malformed `ok`: one
// retry, then a throw, per the existing retry ladder.
function coerceRelayFields(out, depth = 0) {
  if (typeof out.ok === 'string') out.ok = out.ok === 'true';
  if (out.reason === 'null') out.reason = null;
  if (out.hint === 'null') out.hint = null;
  if (typeof out.data === 'string') out.data = JSON.parse(out.data);

  if (depth === 0 && looksLikeEnvelope(out.data)) {
    return coerceRelayFields({ ...out.data }, depth + 1);
  }
  return out;
}

// relay(cmd, opts) -> the platform-validated, field-coerced {ok,reason,hint,
// data} object, straight from agent()'s structured output — no JSON.parse
// of the WHOLE reply (design note 19; `data` alone may still need a nested
// JSON.parse per coerceRelayFields, design note 19b). For the lib scripts
// that always emit that contract on one stdout line. `opts.retryable`
// (default true) gates whether a null/malformed structured result (missing/
// non-boolean `ok` after coercion, OR a `data` string that fails to parse)
// gets one retry — see design note 12: append/mutate-once commands pass
// `retryable: false` and fail immediately instead of risking a duplicate
// side effect.
async function relay(cmd, opts = {}) {
  const retryable = opts.retryable !== false;
  const fullCmd = withCwd(cmd);
  const prompt = `Run exactly this command via Bash from the current project root:\n${fullCmd}\nParse the LAST line of stdout as JSON and return the parsed JSON object itself via structured output: "data" must be a JSON OBJECT (not a string of JSON), "reason"/"hint" must be JSON null (not the string "null") when absent. Copy every field verbatim (ok, reason, hint, data). Do not summarize, do not add fields of your own, do not run anything else.`;
  const callOpts = {
    model: 'haiku',
    effort: 'low',
    schema: RELAY_RESULT_SCHEMA,
    label: opts.label || cmd,
    phase: opts.phase,
  };

  const attempt = async () => {
    dispatchCount += 1;
    const out = await agent(prompt, callOpts);
    if (!out || (typeof out.ok !== 'boolean' && typeof out.ok !== 'string')) return null;
    try {
      const coerced = coerceRelayFields(out);
      return typeof coerced.ok === 'boolean' ? coerced : null;
    } catch (e) {
      log(`relay: coerceRelayFields failed (data string did not parse as JSON) for cmd=${fullCmd}: ${e && e.message ? e.message : e}`);
      return null;
    }
  };

  let result = await attempt();
  if (result) return result;

  if (!retryable) {
    throw new Error(
      `relay: agent did not return a valid, coercible {ok:boolean,...} structured result (non-retryable command, no second attempt). cmd=${fullCmd}`,
    );
  }
  result = await attempt();
  if (result) return result;
  throw new Error(
    `relay: agent did not return a valid, coercible {ok:boolean,...} structured result after 1 retry. cmd=${fullCmd}`,
  );
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
  dispatchCount += 1;
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
    agentTypeFallbacks.add(agentType);
    res = await attempt('general-purpose');
  }
  return res;
}

// agentTypes that had to fall back to general-purpose this run. The fallback
// used to be visible only in the narrator log, so a whole run could execute
// without the stack-specific agents mvp:bootstrap assembled — no _common.md
// contract, no boundary rules — and review would still approve it. Agents are
// registered when a Claude Code session starts, so a bootstrap in THIS session
// produces files that are not dispatchable until the next one. Surfaced as a
// per-task concern (see runOneTask) so it reaches ledger.md, not just the log.
const agentTypeFallbacks = new Set();

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

// reviewerRetryPrompt: one re-ask when the reviewer said request-changes but
// its FINDINGS payload did not parse as JSON.
//
// Live failure this exists for (task 037): the reviewer emitted a long
// findings array with a malformed entry (`"summary":"…", "}`), the array
// failed to parse, and the task was parked — discarding ~371k tokens of
// already-completed implementer work because the REVIEWER, not the code, had
// a bad turn. Parking is right when the code is unfit; it is a terrible
// answer to a transcription slip in the gate itself. A re-ask costs one
// reviewer dispatch against a full task re-run, so it is worth trying exactly
// once. Still fails closed: a second unparseable reply parks as before.
function reviewerRetryPrompt(basePrompt, rawReply) {
  return [
    basePrompt,
    '',
    'RETRY — your previous reply could not be used. You answered `VERDICT: request-changes`,',
    'but the `FINDINGS:` payload was not valid JSON and could not be parsed, so no fix could',
    'be dispatched from it. Do not re-do the review: you already read the package and reached',
    'a verdict. Re-state that same judgement, correctly encoded.',
    '',
    'Requirements for this reply:',
    '- `FINDINGS:` must be followed by ONE line of strict JSON — a single array, double quotes,',
    '  no trailing commas, no comments, no markdown fence, nothing after the closing bracket.',
    '- Keep every `summary` to one short sentence and every `quote` to the single offending line.',
    '  The previous reply was very long; length is what broke it.',
    '- If, restating it, you conclude the change is in fact acceptable, `VERDICT: approve` with',
    '  `FINDINGS: []` is a legitimate answer. Do not invent findings to justify the earlier verdict.',
    '',
    'Your previous (unparseable) reply, for reference:',
    String(rawReply || '').slice(0, 1500),
  ].join('\n');
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
// parseStatus: the agent's own STATUS line.
//
// DONE_WITH_CONCERNS MUST precede DONE in the alternation. Regex alternation
// is ordered and unanchored at the right, so `(DONE|DONE_WITH_CONCERNS)`
// matches the `DONE` prefix of `DONE_WITH_CONCERNS` and the long form is
// unreachable. That was the bug until 2026-08-25: across the vireo run, 21
// replies on 20 tasks reported DONE_WITH_CONCERNS and every one of them was
// read as a plain DONE — so `concerns.push(extractConcernLines(...))` never
// fired and every concern an implementer or fix agent raised in its own
// words was silently dropped. Only noteDeclaredOnly's concerns ever reached
// the ledger. The trailing \b makes the long form win on its own merits
// rather than by ordering luck alone.
function parseStatus(text) {
  const m = /^STATUS:\s*(DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT)\b/m.exec(text || '');
  return m ? m[1] : 'BLOCKED';
}

// extractField(text, label) -> the rest of the SAME line after "<LABEL>: ",
// trimmed, or null if the label never appears at the start of a line. For
// single-token contract fields (STATUS, VERDICT) which are guaranteed
// single-line by every template's contract.
// extractField(text, label) -> the label's value, or null.
//
// `\s` matches newlines, which is deliberate — an agent that puts the value
// on the line BELOW the label is still understood. The cost is that an EMPTY
// field would otherwise swallow whatever follows it: `CANNOT_VERIFY:\nFINDINGS: []`
// returned the string "FINDINGS: []" as the value, which parseCannotVerify
// then read as "the reviewer could not verify something" and parked a
// perfectly good task — the same ~371k-token loss shape as task 037, but on
// a reply that was fine. So a capture that is itself a contract token
// (`^[A-Z][A-Z_-]*:`) means the field was blank, not that it held the next
// line. Labels are hardcoded constants, never agent-supplied, so
// interpolating one into the pattern is safe.
function extractField(text, label) {
  const re = new RegExp(`^${label}:\\s*(.*)$`, 'm');
  const m = re.exec(text || '');
  if (!m) return null;
  const v = m[1].trim();
  if (/^[A-Z][A-Z_-]*:/.test(v)) return null;
  return v;
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

// parseCannotVerify(text) -> null when the reviewer could check everything,
// else the reviewer's own description of what it could not check.
//
// reviewer.md requires a literal `CANNOT_VERIFY:` line: `none` when the
// package supported a full judgement, otherwise the requirements left
// unverified. A MISSING line is deliberately treated as "none": this parser
// ships alongside prompt changes, and a reviewer that answered in the old
// format must not park every task in the plan. The gate that catches an
// incomplete package regardless of what the reviewer says is truncatedPaths()
// above — that one is script-side and cannot be talked out of.
function parseCannotVerify(text) {
  const raw = extractField(text, 'CANNOT_VERIFY');
  if (!raw) return null;
  const v = raw.trim();
  // WHOLE-value match, never a prefix. A prefix test (`/^(none|no)\b/`) reads
  // "none of the OAuth checks are visible in this package" — a reviewer
  // reporting that it verified nothing — as "nothing to report", opening a
  // gate whose entire purpose is to fail closed. Caught by
  // tests/lib/workflow-parsers.mjs before it could reach a run.
  if (!v || /^(none|no|n\/a)[.!]?$/i.test(v)) return null;
  return v.slice(0, 400);
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
  const patchesPath = `.mvp/patches/patches-${id}.json`;
  dispatchCount += 1;
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
// truncatedPaths(rp) -> [] or the paths whose content the package could not
// show in full. review-package.sh caps how many lines of a NEW file it
// inlines; on greenfield work new files are a median 90% of the package, so
// a cap hit means the reviewer is judging a partial change. Measured over the
// vireo run: 16 of 36 packages were truncated and all 16 were reviewed and
// approved anyway, because truncation was only prose inside the package.
// This is now a blocking fact — fail closed rather than accept a verdict
// issued on evidence the reviewer never saw.
function truncatedPaths(rp) {
  const t = rp && rp.data && rp.data.truncated;
  if (!Array.isArray(t)) return [];
  return t.map((x) => (x && x.path ? `${x.path} (+${x.hidden_lines} lines hidden)` : String(x)));
}

async function runReviewLadder(ctx) {
  const packageCmd = () => `bash "${lib}/review-package.sh" "${ctx.id}" --base "${ctx.baseSha}"`;

  let rp = await relay(packageCmd(), { phase: 'Review', label: `review-package-${ctx.id}-1` });
  if (!rp.ok) throw new Error(`review-package.sh failed for task ${ctx.id}: ${rp.reason || 'unknown'}`);
  const cut = truncatedPaths(rp);
  if (cut.length) {
    return {
      parked: true,
      why: `review package is incomplete — ${cut.length} file(s) exceeded the inline cap and were truncated: ${cut.join('; ')}. `
        + 'Reviewing a partial diff is not a review: split the task, or add the file to the lockfile/generated list in review-package.sh, '
        + 'or raise UNTRACKED_FILE_LINE_CAP if the file genuinely needs reviewing whole.',
    };
  }

  const reviewText = await agentText(
    reviewerPrompt({ taskId: ctx.id, briefPath: ctx.briefPath, packagePath: rp.data.path }),
    { model: 'sonnet', phase: 'Review', label: `reviewer-${ctx.id}` },
  );
  // CANNOT_VERIFY: reviewer.md already told reviewers to flag requirements
  // they could not check against the diff, and they did — but nothing acted
  // on it, so an `approve` issued over the top of "I could not verify the
  // OAuth state validation" was indistinguishable from a clean one. The
  // reviewer now declares it on its own line and it is a halt, not prose.
  const cannotVerify = parseCannotVerify(reviewText);
  if (cannotVerify) {
    return {
      parked: true,
      why: `reviewer could not verify part of this task against the package: ${cannotVerify}. `
        + 'A verdict issued over unverifiable requirements is not a gate — give the reviewer what it needs, or split the task.',
    };
  }

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

  // request-changes with no usable findings: the reply is malformed, not a
  // judgement we can act on — fix.md has nothing to work from. Re-ask the
  // reviewer ONCE for a correctly encoded restatement before giving up
  // (see reviewerRetryPrompt for why: a bad turn in the gate should not cost
  // a whole task's implementation). A second failure parks, as before.
  if (!verdict.findings || verdict.findings.length === 0) {
    const retryText = await agentText(
      reviewerRetryPrompt(
        reviewerPrompt({ taskId: ctx.id, briefPath: ctx.briefPath, packagePath: rp.data.path }),
        reviewText,
      ),
      { model: 'sonnet', phase: 'Review', label: `reviewer-retry-${ctx.id}` },
    );
    const retryVerdict = parseReviewerVerdict(retryText);

    // The restated reply is judged on its own terms — including the escape
    // hatches the first one had. A reviewer allowed to restate may legitimately
    // land on approve, or decide the findings were all trivial-mechanical.
    if (retryVerdict.kind === 'patches') {
      const applyRetry = await applyPatchesFlow(ctx.id, retryVerdict.patches, 'Review');
      if (!applyRetry.ok) {
        return { parked: true, why: `review PATCHES apply failed (after retry): ${JSON.stringify(applyRetry.data)}` };
      }
      return { parked: false };
    }
    if (retryVerdict.verdict === 'approve') {
      ctx.concerns.push('reviewer first reply was unparseable; restated verdict was approve');
      return { parked: false };
    }
    if (!retryVerdict.findings || retryVerdict.findings.length === 0) {
      return {
        parked: true,
        why: 'reviewer VERDICT: request-changes but FINDINGS was empty or unparseable twice (original + one retry) — '
          + `raw reply: ${(retryText || '').slice(0, 400)}`,
      };
    }
    verdict.findings = retryVerdict.findings;
    ctx.concerns.push('reviewer first reply was unparseable; findings taken from the restated reply');
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
  const cutAfterFix = truncatedPaths(rp);
  if (cutAfterFix.length) {
    return {
      parked: true,
      why: `post-fix review package is incomplete — truncated file(s): ${cutAfterFix.join('; ')}`,
    };
  }

  const reReviewText = await agentText(
    reReviewPrompt({ taskId: ctx.id, packagePath: rp.data.path, findings: verdict.findings }),
    { model: 'sonnet', phase: 'Review', label: `re-review-${ctx.id}` },
  );
  if (reReviewText == null) {
    return { parked: true, why: 're-review dispatch failed: agent returned no result' };
  }
  const verdicted = parseReReview(reReviewText);

  // ADDRESSED or REFUTED both close a finding. REFUTED exists because review
  // findings are not automatically true: of five findings a strong audit
  // raised against already-shipped vireo code, two did not survive
  // verification, and during the live run two more had to be overruled by the
  // operator. Before this, fix.md's only options were "change the code" or
  // "park" — so a wrong finding cost a full fix -> re-review round and an
  // operator interrupt. Now fix.md may refute, and THIS re-review pass is what
  // adjudicates that refutation: the fix agent cannot close its own finding,
  // it can only argue, and a separate reviewer rules. Anything else — a bare
  // "won't fix", an unparseable verdict — still parks.
  const CLOSED = new Set(['ADDRESSED', 'REFUTED']);
  const stillOpen = verdicted.filter((f) => !CLOSED.has(String(f && f.verdict).toUpperCase()));
  if (stillOpen.length > 0) {
    // RE_REVIEW_CYCLES_CAP=1: this is the only re-review pass — no looping.
    return { parked: true, why: `re-review: ${stillOpen.length} finding(s) not closed: ${JSON.stringify(stillOpen)}` };
  }

  // A refuted finding is not silently forgotten: it goes to the ledger as a
  // concern so the operator can see what the pipeline decided not to fix.
  const refuted = verdicted.filter((f) => String(f && f.verdict).toUpperCase() === 'REFUTED');
  for (const f of refuted) {
    ctx.concerns.push(`review finding refuted, not fixed: ${JSON.stringify(f).slice(0, 300)}`);
  }
  return { parked: false };
}

// --- finalize ---------------------------------------------------------------------

// shQuote(s) -> POSIX single-quoted literal, safe for ANY content (the only
// character needing care inside single quotes is the single quote itself:
// close, escape, reopen). Used for free-text values that must cross into a
// relay's shell command — concern lines carry file paths, semicolons and
// user-authored prose, and none of it may be re-parsed by the shell.
function shQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

// finalize: ONE relay for what used to be three dispatches plus an agent
// (relay diet, 2026-08-24 — each dispatch costs a flat ~30 200 tokens of
// subagent boot no matter how trivial the command):
//   - the commit subject is written by `plan-io.mjs complete --write-msg`
//     instead of a haiku agent calling Write. That also removes a real
//     hazard: the task title is free text and used to be interpolated into
//     a prompt, whereas plan-io reads it straight from plan.json.
//   - `plan-io.mjs ledger` is chained after finalize.sh in the same shell
//     command and resolves the new commit's sha itself (`--sha HEAD`), so
//     the run no longer pays a dispatch to pass one string along.
//   - concerns are persisted by that same call (`--concern`), by the script.
//     They used to be the calling SKILL's job and were dropped on all 36
//     vireo tasks; a state write that depends on the LLM remembering is not
//     a state write. Sorting concerns through shQuote keeps arbitrary text
//     out of the shell's hands.
// The chain's LAST json line is now the ledger envelope, so the commit sha
// is read from there (plan-io echoes it back for exactly this reason).
async function finalize(id, boundary, tokensDelta, dispatches, concerns, phaseTitle) {
  // Per-task scratch artifacts get their own directory, like briefs/, reports/
  // and review/: a 55-task run otherwise buries plan.json, ledger.md and
  // invariants.md under 55 commit-msg-*.txt files in the same listing.
  // plan-io's writeTextAtomic mkdir -p's the parent, so no setup step is
  // needed, and finalize.sh stages `.mvp` wholesale — the nested path
  // is committed exactly as the flat one was.
  const msgPath = `.mvp/commit-messages/commit-msg-${id}.txt`;
  const concernText = (concerns || []).filter(Boolean).join('\n');
  const concernArg = concernText ? ` --concern ${shQuote(concernText)}` : '';

  // Staging scope is the task's BOUNDARY, not its declared file list (design
  // note 17b): the declared list is a hint, so anything the task legitimately
  // created inside the boundary but the plan never listed (a test file, a
  // fixture) must still be committed. One quoted path — explicit, never
  // `git add -A`; finalize.sh's build-task scope appends `.mvp`
  // itself, which is where the report/brief/state files live.
  const cmd = [
    `node "${lib}/plan-io.mjs" complete "${id}" --tokens ${tokensDelta} --dispatches ${dispatches} --write-msg "${msgPath}"`,
    `bash "${lib}/finalize.sh" build-task "${msgPath}" --files "${boundary}"`,
    `node "${lib}/plan-io.mjs" ledger --task "${id}" --sha HEAD${concernArg}`,
  ].join(' && ');

  const fin = await relay(cmd, { phase: phaseTitle, label: `finalize-${id}`, retryable: false });
  if (!fin.ok) {
    throw new Error(`finalize failed for task ${id}: ${fin.reason || 'unknown'}`);
  }
  if (!fin.data || !fin.data.sha) {
    throw new Error(`finalize for task ${id} returned no sha: ${JSON.stringify(fin.data)}`);
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
// but NEVER `.mvp` (final-review finding I1: a root-level boundary
// — `.` — made that clean wipe the pipeline's own state directory, i.e. the
// brief, the report and the freshly-written failed-status plan.json, taking
// the run's memory with it). `-e .mvp` must come BEFORE the `--`:
// after it, git parses `-e` as a pathspec, not a flag (verified empirically
// in a scratch repo — the post-`--` form removed .mvp anyway)
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
      `git checkout -- "${boundary}" 2>/dev/null; git restore --staged "${boundary}" 2>/dev/null; git clean -fd -e .mvp -- "${boundary}" 2>/dev/null; true`,
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

// The task currently mid-flight, or null between tasks. Read only by the
// global catch below: a throw anywhere in the ladder used to return
// `halt:'error'` with the implementer's half-finished files still in the
// working tree and the task still `pending`, so plan state and tree state
// disagreed and the next run halted on `dirty-tree`. Observed three times on
// glotok (session limit, 403) — each time the operator had to reconstruct by
// hand which task had been in flight.
let inFlightTask = null;

async function runOneTask(adv) {
  const id = adv.data.task_id;
  const briefPath = adv.data.brief_path;
  const boundary = adv.data.boundary;
  const role = adv.data.role;
  inFlightTask = { id, boundary };
  const modelClass = adv.data.model_class;
  const declaredFiles = Array.isArray(adv.data.files) ? adv.data.files : [];
  const filesCsv = declaredFiles.join(',');
  const reportPath = `.mvp/reports/task-${id}.md`;

  // Token-delta measurement starts here, at the very top of the task
  // iteration — BEFORE the implementer dispatch (fix round item 4: it
  // previously started only after the implementer had already run, silently
  // excluding that call's cost from its own task's delta).
  const spentBefore = safeBudgetSpent();
  const dispatchesBefore = dispatchCount;

  // baseSha now rides along in `next`'s payload instead of costing its own
  // relay dispatch (relay diet, 2026-08-24 — `git rev-parse HEAD` was being
  // paid for at the same ~30 200-token boot price as a full ci-mirror run).
  // plan-io returns null only on a repo with no HEAD, which cannot happen
  // here: gate.sh requires a git repo from the plan stage onward and every
  // earlier task committed.
  const baseSha = adv.data.head_sha;
  if (!baseSha) {
    return park(id, boundary, 'plan-io next returned no head_sha — cannot establish a review base for this task');
  }

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
  // +1: this task's own finalize relay, which has not been dispatched yet at
  // the moment the count is taken.
  const dispatches = dispatchCount - dispatchesBefore + 1;

  // A silent degradation is worse than a loud one: without this the task ships
  // with `approve` and nothing records that the role's agent never ran.
  if (agentTypeFallbacks.has(role)) {
    ctx.concerns.push(
      `agentType "${role}" did not dispatch — this task ran on general-purpose, WITHOUT the ` +
        `_common.md contract (boundary rules, report format, blocker protocol) that ` +
        `mvp:bootstrap assembled for it. Agents register at session start, so a bootstrap ` +
        `run in this same session yields files that are not dispatchable until the next one. ` +
        `Restart the session and re-run this task if the role's rules mattered.`,
    );
  }

  const sha = await finalize(id, boundary, tokensDelta, dispatches, ctx.concerns, 'Finalize');

  // concerns still travel in the return value for the SKILL's run summary,
  // but they are no longer the SKILL's responsibility to persist — finalize()
  // hands them to plan-io, which writes them into ledger.md.
  inFlightTask = null;
  return { done: true, task_id: id, sha, tokens_delta: tokensDelta, dispatches, concerns: ctx.concerns };
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

      // all-done is the one halt with a deterministic state consequence, so
      // the script performs it instead of asking the SKILL to remember.
      // build/SKILL.md told the controller to run `state.sh set phase done`
      // here; on the vireo run the controller drove Workflow directly and the
      // phase sat at `plan-done` through all 55 tasks — which mvp:retro's own
      // gate then (correctly) refused. Same shape as the concerns bug: a
      // state write that depends on an LLM remembering is a state write that
      // eventually does not happen. There is no judgement in this transition
      // — every task in the plan is done — so it belongs in a script.
      // Reported, never fatal: a failed phase write must not turn a finished
      // plan into an error, but it must also not pass silently.
      if (adv.data.halt === 'all-done') {
        const phaseSet = await relay(`bash "${lib}/state.sh" set phase done`, {
          phase: 'Advance',
          label: 'phase-done',
          retryable: false,
        });
        haltPayload.phase_set = Boolean(phaseSet && phaseSet.ok);
        if (!phaseSet || !phaseSet.ok) {
          haltPayload.detail = `${haltPayload.detail || ''} (WARNING: could not set phase=done: ${(phaseSet && phaseSet.reason) || 'unknown'} — mvp:retro will refuse to start until it is set)`.trim();
        }
      }
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
  const payload = { halt: 'error', detail: e && e.message ? e.message : String(e) };

  // Try to leave the tree consistent with the plan. This runtime has no
  // filesystem or shell of its own — every side effect is a dispatched agent —
  // so recovery travels the same channel that just failed and may fail with
  // it. That is precisely why the outcome is reported instead of assumed:
  // on glotok `park-status-014` and `park-clean-021` both died of the same
  // session limit as the task they were compensating for, and the operator
  // discovered the dirty tree only on the next run's `dirty-tree` halt.
  if (inFlightTask) {
    payload.in_flight_task = inFlightTask.id;
    try {
      await park(inFlightTask.id, inFlightTask.boundary, payload.detail);
      payload.recovery = 'parked';
    } catch (parkErr) {
      payload.recovery = 'failed';
      payload.recovery_error = parkErr && parkErr.message ? parkErr.message : String(parkErr);
      payload.detail =
        `${payload.detail} — RECOVERY FAILED for task ${inFlightTask.id}: the working tree may still hold ` +
        `unreviewed files under "${inFlightTask.boundary}" while the task is still pending. ` +
        `Check "git status" and reset that boundary before the next run.`;
    }
    inFlightTask = null;
  }
  return withRunLabels(payload);
}
