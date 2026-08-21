// skills/build/workflow.mjs — mvp:build DAG task loop.
//
// Run by the Workflow tool: `Workflow({scriptPath: <this file>, args:{run_id,
// now, max_tasks, task_id?, plugin_root}})`. This module has NO filesystem
// access, NO Date.now()/Math.random()/argless `new Date()` (they throw in
// this sandbox), and no `import`/`require` of anything — it is pure
// standard JS plus a fixed set of ambient hooks the Workflow runtime injects
// into scope before evaluating this module:
//   agent(prompt, opts) -> Promise<result>   dispatch one subagent turn
//   parallel, pipeline                        (available, unused — see below)
//   phase(title)                              (available, unused — see below)
//   log(msg)                                  workflow-visible log line
//   args                                      the {run_id, now, max_tasks,
//                                              task_id?, plugin_root} object
//                                              passed to Workflow(); the
//                                              SKILL generates run_id/now
//                                              once and passes them in — this
//                                              script never calls Date/etc.
//   budget                                    token-budget accessor; only
//                                              `budget.spent()` is used here
//                                              (see "Token-delta source").
//
// ---------------------------------------------------------------------------
// Design decisions (documented per task-14 instructions — read before
// touching the ladders below):
//
// 1. ENTRY CONTRACT (inferred, not verified against a Workflow-runtime spec
//    — no such spec exists in this repo; flagged for the controller to
//    confirm at the Step-3 dry-run). `export const meta` is a pure literal.
//    The workflow's actual logic is `export default async function run()`,
//    reading `args`/`agent`/`log`/`budget` as ambient bindings (not
//    parameters) and returning the `{halt, ...}` result the calling SKILL
//    inspects. JS modules cannot `return` at top level, so an exported
//    entry function is the only way to produce that return value.
//
// 2. relay() vs relayLine(). The brief's relay() sketch assumes the
//    underlying command's stdout is itself one line of JSON (true for every
//    lib/*.{mjs,sh,py} script: plan-io.mjs, validate-task.sh,
//    review-package.sh, apply-patches.py — all emit the {ok,reason,hint,data}
//    contract). But `git rev-parse HEAD` (needed for baseSha) is NOT JSON —
//    it is a bare sha. relayLine(cmd) is the primitive: dispatch a haiku
//    relay agent, return the raw last-stdout-line string. relay(cmd) wraps
//    relayLine with JSON.parse (one retry on parse failure, per the brief),
//    for the lib-script contract calls. baseSha uses relayLine directly.
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
//    text and park() reasons are carried in this function's RETURN VALUE
//    (`concerns: [...]` on success, `detail` on a halt) for the calling
//    SKILL (main session, which DOES have scripts/FS access) to persist
//    through a script. This workflow stays a pure orchestrator.
//
// 5. Cross-file touch: lib/plan-io.mjs's `next` response gained a `files`
//    key (the task's declared files from plan.json), with
//    tests/lib/plan-io.test.sh updated to assert it. `next`'s payload had no
//    files list, and validate-task.sh's --files must be the plan's declared
//    list (not the implementer's self-reported FILES: line — that source
//    lost fields before, per v1 lessons baked into this project's
//    invariants). See that file's diff for the one-line addition.
//
// 6. Caps: IMPLEMENTER_RETRY_CAP=1, TOTAL_ATTEMPTS_CAP=2 (1 initial + 1
//    retry, never more), RE_REVIEW_CYCLES_CAP=1 (one fix -> re-review pass,
//    never repeated — "NOT ADDRESSED" after that single pass parks).
//
// 7. Token-delta source: this workflow cannot measure a dispatched
//    subagent's own token usage (only the harness knows that). `budget`s
//    `.spent()` — if present — is read before and after each task; the
//    difference is the honest, per-task delta passed to
//    `plan-io.mjs complete --tokens`. If `budget.spent` is unavailable for
//    any reason, this degrades to a delta of 0 (logged, never thrown — a
//    missing budget accessor must not abort a task that otherwise
//    succeeded).
//
// 8. `phase(title)` (the global hook) is deliberately NOT called anywhere in
//    this file. Every agent()/relay() call instead passes `phase` in its own
//    `opts` — per the task brief, using the global phase() mutator would
//    race across the concurrent-ish sequence of relay/agent calls within one
//    task. `parallel`/`pipeline` are similarly unused: v2's build loop is
//    intentionally sequential (see spec §1 non-goals — DAG parallelism is a
//    future iteration), so batching hooks have nothing to batch.
//
// 9. Known grey zone (NOT fixed here — out of this task's file scope):
//    lib/review-package.sh diffs `BASE..HEAD` (committed refs). Since
//    implementer/fix agents leave their work uncommitted until `finalize`
//    (per agents/implementer.md: "you do NOT git commit"), HEAD never moves
//    between baseSha capture and the review step, so the review package can
//    legitimately be an empty diff for an as-yet-uncommitted task. This is a
//    property of lib/review-package.sh (Task 8, already review-clean) and
//    plan-io.mjs/finalize.sh's single-commit-per-task design — not something
//    this workflow can or should paper over. Reviewer prompts already handle
//    "nothing to verify" gracefully (approve with empty findings). Flagged
//    for the controller in the Task 14 report.

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

// --- module-scoped state set by run() after args validation ------------------

let lib = ''; // args.plugin_root + '/lib', set once args are known-valid

// --- relay primitives ---------------------------------------------------------

const RELAY_SCHEMA = {
  type: 'object',
  properties: { line: { type: 'string' } },
  required: ['line'],
  additionalProperties: false,
};

// relayLine(cmd, opts) -> raw last-stdout-line string. Relays never receive
// file contents — only the command to run and a one-line JSON reply back.
async function relayLine(cmd, opts = {}) {
  const prompt = `Run exactly this command via Bash from the current project root:\n${cmd}\nReturn the LAST line of stdout verbatim as {"line": "..."}. Do not add anything.`;
  const callOpts = {
    model: 'haiku',
    effort: 'low',
    schema: RELAY_SCHEMA,
    label: opts.label || cmd,
    phase: opts.phase,
  };
  const out = await agent(prompt, callOpts);
  if (!out || typeof out.line !== 'string') {
    throw new Error(`relayLine: agent did not return a {line:string} object for cmd=${cmd}`);
  }
  return out.line;
}

// relay(cmd, opts) -> JSON.parse(relayLine(cmd, opts)). For the lib scripts
// that always emit the {ok,reason,hint,data} contract on one stdout line.
// One retry on a parse failure (the brief's instruction), then throws with
// full context — a persistently unparsable relay reply is not a designed
// ladder outcome, it is an infra fault.
async function relay(cmd, opts = {}) {
  let line = await relayLine(cmd, opts);
  try {
    return JSON.parse(line);
  } catch (e1) {
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

// agentText(prompt, opts) -> string. agent() with no `schema` is documented
// to return the agent's final free-text message, but the exact return shape
// for the schema-less case is not pinned down anywhere in this sandbox's
// contract, so this coerces defensively rather than assuming a bare string.
async function agentText(prompt, opts) {
  const res = await agent(prompt, opts);
  if (typeof res === 'string') return res;
  if (res && typeof res.text === 'string') return res.text;
  return JSON.stringify(res);
}

// dispatchAgentText(prompt, {model, phase, label, agentType}) -> string.
// agentType is only meaningful for role-specific project agents generated by
// mvp:bootstrap (.claude/agents/<role>.md) — those exist only in the TARGET
// project, not universally, so a dispatch error with a given agentType falls
// back once to 'general-purpose' rather than failing the whole task.
async function dispatchAgentText(prompt, { model, phase, label, agentType }) {
  const opts = { model, phase, label };
  if (!agentType) return agentText(prompt, opts);
  try {
    return await agentText(prompt, { ...opts, agentType });
  } catch (e) {
    log(`agent dispatch with agentType=${agentType} failed (${e && e.message ? e.message : e}); retrying as general-purpose`);
    return agentText(prompt, { ...opts, agentType: 'general-purpose' });
  }
}

// --- prompt builders (template self-read — see design note 3) ----------------

function implementerPrompt({ briefPath, boundary, taskId, reportPath }) {
  return [
    `Read ${args.plugin_root}/skills/build/agents/implementer.md and follow it exactly with these substitutions:`,
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
  return [
    `Read ${args.plugin_root}/skills/build/agents/validator.md and follow it exactly with these substitutions:`,
    `TASK_ID=${taskId}`,
    `BOUNDARY=${boundary}`,
    `VIOLATIONS=${JSON.stringify(violations)}`,
  ].join('\n');
}

function reviewerPrompt({ taskId, briefPath, packagePath }) {
  return [
    `Read ${args.plugin_root}/skills/build/agents/reviewer.md and follow it exactly with these substitutions:`,
    `TASK_ID=${taskId}`,
    `BRIEF_PATH=${briefPath}`,
    `PACKAGE_PATH=${packagePath}`,
  ].join('\n');
}

function fixPrompt({ taskId, boundary, findings, reportPath }) {
  return [
    `Read ${args.plugin_root}/skills/build/agents/fix.md and follow it exactly with these substitutions:`,
    `TASK_ID=${taskId}`,
    `BOUNDARY=${boundary}`,
    `FINDINGS=${JSON.stringify(findings)}`,
    `REPORT_PATH=${reportPath}`,
  ].join('\n');
}

function reReviewPrompt({ taskId, packagePath, findings }) {
  return [
    `Read ${args.plugin_root}/skills/build/agents/re-review.md and follow it exactly with these substitutions:`,
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

function extractField(text, label) {
  const re = new RegExp(`^${label}:\\s*(.*)$`, 'm');
  const m = re.exec(text || '');
  return m ? m[1].trim() : null;
}

function safeJsonParse(s, fallback) {
  try {
    return JSON.parse(s);
  } catch {
    return fallback;
  }
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
  const patchesRaw = extractField(text, 'PATCHES');
  if (patchesRaw !== null) {
    return { kind: 'patches', patches: safeJsonParse(patchesRaw, []) };
  }
  const verdictRaw = extractField(text, 'VERDICT');
  const word = verdictRaw && /^(retry|park)/i.exec(verdictRaw);
  return { kind: 'verdict', verdict: word ? word[1].toLowerCase() : 'park' };
}

// reviewer.md replies VERDICT: approve|request-changes + FINDINGS:<json>, OR
// PATCHES:<json> for an all-trivial batch. Unparseable defaults to
// 'request-changes' with no findings — fail closed (routes to a human-scoped
// fix/park path rather than a silent approve).
function parseReviewerVerdict(text) {
  const patchesRaw = extractField(text, 'PATCHES');
  if (patchesRaw !== null) {
    return { kind: 'patches', patches: safeJsonParse(patchesRaw, []) };
  }
  const verdictRaw = extractField(text, 'VERDICT');
  const findingsRaw = extractField(text, 'FINDINGS');
  const findings = findingsRaw !== null ? safeJsonParse(findingsRaw, []) : [];
  const word = verdictRaw && /^(approve|request-changes)/i.exec(verdictRaw);
  return { kind: 'verdict', verdict: word ? word[1].toLowerCase() : 'request-changes', findings };
}

// re-review.md replies FINDINGS:<json array with a "verdict" field per item>
function parseReReview(text) {
  const findingsRaw = extractField(text, 'FINDINGS');
  return findingsRaw !== null ? safeJsonParse(findingsRaw, []) : [];
}

// --- patches application (shared by the validate and review ladders) ---------

// applyPatchesFlow: the workflow writes patches.json itself, via a dedicated
// haiku agent using the Write tool (never a heredoc — patches.json can
// contain arbitrary code text that must not be shell-interpolated). Then a
// relay stages the apply. A partial/failed apply is logged, not thrown — the
// caller's next validate/review step is the real judge of whether the state
// is now acceptable.
async function applyPatchesFlow(id, patches, phaseTitle) {
  const patchesPath = `.claude/state/patches-${id}.json`;
  await agent(
    `Write EXACTLY this JSON to ${patchesPath} using the Write tool (create the file, overwrite any existing content, no extra text, no markdown code fences):\n${JSON.stringify(patches)}`,
    { model: 'haiku', effort: 'low', phase: phaseTitle, label: `patch-writer-${id}` },
  );
  const applyResult = await relay(`python3 ${lib}/apply-patches.py ${patchesPath} --stage`, {
    phase: phaseTitle,
    label: `apply-patches-${id}`,
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

// Returns {parked:false} on success, or {parked:true, why} to park the task.
// Ladder (design note in the file header + task-14 report): a validator
// PATCHES verdict gets one direct apply+re-validate attempt that does NOT
// consume the implementer-retry budget; a 'retry' verdict (or a patch that
// still leaves violations) falls through to the single capped implementer
// retry; anything still failing after that parks.
async function runValidateLadder(ctx) {
  const validateCmd = () => `bash ${lib}/validate-task.sh ${ctx.id} --boundary ${ctx.boundary} --files ${ctx.filesCsv}`;

  let val = await relay(validateCmd(), { phase: 'Validate', label: `validate-${ctx.id}-1` });
  if (val.ok) return { parked: false };

  let violations = (val.data && val.data.violations) || [];
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
  const retryStatus = parseStatus(retryText);
  if (retryStatus === 'BLOCKED' || retryStatus === 'NEEDS_CONTEXT') {
    return { parked: true, why: `implementer retry ${retryStatus}: ${retryText.slice(0, 400)}` };
  }
  if (retryStatus === 'DONE_WITH_CONCERNS') ctx.concerns.push(extractConcernLines(retryText));

  val = await relay(validateCmd(), { phase: 'Validate', label: `validate-${ctx.id}-3` });
  if (!val.ok) {
    return { parked: true, why: `validate-task.sh still failing after implementer retry: ${JSON.stringify((val.data && val.data.violations) || [])}` };
  }
  return { parked: false };
}

// --- review ladder ---------------------------------------------------------------

// Returns {parked:false} on success (approve, or a trivial-patches shortcut),
// or {parked:true, why}. One fix -> re-review cycle, capped, never repeated.
async function runReviewLadder(ctx) {
  const packageCmd = () => `bash ${lib}/review-package.sh ${ctx.id} --base ${ctx.baseSha}`;

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
    await applyPatchesFlow(ctx.id, verdict.patches, 'Review');
    return { parked: false };
  }
  if (verdict.verdict === 'approve') {
    return { parked: false };
  }

  // request-changes: exactly one fix -> re-review cycle (RE_REVIEW_CYCLES_CAP).
  const fixText = await dispatchAgentText(
    fixPrompt({ taskId: ctx.id, boundary: ctx.boundary, findings: verdict.findings, reportPath: ctx.reportPath }),
    { model: 'sonnet', phase: 'Review', label: `fix-${ctx.id}`, agentType: ctx.agentType },
  );
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
  const verdicted = parseReReview(reReviewText);
  const stillOpen = verdicted.filter((f) => String(f && f.verdict).toUpperCase() !== 'ADDRESSED');
  if (stillOpen.length > 0) {
    // RE_REVIEW_CYCLES_CAP=1: this is the only re-review pass — no looping.
    return { parked: true, why: `re-review: ${stillOpen.length} finding(s) NOT ADDRESSED: ${JSON.stringify(stillOpen)}` };
  }
  return { parked: false };
}

// --- finalize ---------------------------------------------------------------------

async function finalize(id, title, declaredFiles, tokensDelta, phaseTitle) {
  const subject = title ? `feat: task ${id} ${title}` : `feat: task ${id}`;
  const msgPath = `.claude/state/commit-msg-${id}.txt`;
  await agent(
    `Write EXACTLY this text to ${msgPath} using the Write tool (create the file, overwrite any existing content, no extra text, no markdown code fences):\n${subject}\n`,
    { model: 'haiku', effort: 'low', phase: phaseTitle, label: `msg-writer-${id}` },
  );

  const filesSpaceList = declaredFiles.join(' ');
  const fin = await relay(
    `node ${lib}/plan-io.mjs complete ${id} --tokens ${tokensDelta} && bash ${lib}/finalize.sh build-task ${msgPath} --files ${filesSpaceList}`,
    { phase: phaseTitle, label: `finalize-${id}` },
  );
  if (!fin.ok) {
    throw new Error(`finalize failed for task ${id}: ${fin.reason || 'unknown'}`);
  }

  const ledgerResult = await relay(`node ${lib}/plan-io.mjs ledger --task ${id} --sha ${fin.data.sha}`, {
    phase: phaseTitle,
    label: `ledger-${id}`,
  });
  if (!ledgerResult.ok) {
    throw new Error(`ledger failed for task ${id}: ${ledgerResult.reason || 'unknown'}`);
  }
  return fin.data.sha;
}

// --- park ---------------------------------------------------------------------

// park(id, boundary, why): clean the working tree back to HEAD within the
// task's boundary, mark it failed via plan-io.mjs (the only mutating,
// park-safe subcommand — plan-io has no dedicated "park" verb), and return a
// stop-and-ask halt. Per design note 4, the Ruling/Parked ledger line and
// blockers.md entry are the calling SKILL's job, driven off this halt's
// `detail` — this workflow never writes prose files itself.
async function park(id, boundary, why) {
  await relay(`git checkout -- ${boundary} 2>/dev/null; git restore --staged ${boundary} 2>/dev/null; true`, {
    phase: 'Finalize',
    label: `park-clean-${id}`,
  });
  const statusResult = await relay(`node ${lib}/plan-io.mjs set-status ${id} failed`, {
    phase: 'Finalize',
    label: `park-status-${id}`,
  });
  if (!statusResult.ok) {
    log(`park: set-status failed for task ${id}: ${statusResult.reason || 'unknown'}`);
  }
  return { halt: 'stop-and-ask', task_id: id, detail: why };
}

// --- one task ---------------------------------------------------------------------

async function runOneTask(adv) {
  const id = adv.data.task_id;
  const briefPath = adv.data.brief_path;
  const boundary = adv.data.boundary;
  const role = adv.data.role;
  const modelClass = adv.data.model_class;
  const title = adv.data.title; // not present in plan-io.mjs's `next` payload today; fallback below
  const declaredFiles = Array.isArray(adv.data.files) ? adv.data.files : [];
  const filesCsv = declaredFiles.join(',');
  const reportPath = `.claude/state/reports/task-${id}.md`;

  const baseSha = await relayLine('git rev-parse HEAD', { phase: 'Advance', label: `basesha-${id}` });

  const initialModel = modelClass === 'novel-design' ? 'opus' : 'sonnet';
  const implPrompt = implementerPrompt({ briefPath, boundary, taskId: id, reportPath });
  const implText = await dispatchAgentText(implPrompt, {
    model: initialModel,
    phase: 'Implement',
    label: `implementer-${id}`,
    agentType: role,
  });

  const concerns = [];
  const status = parseStatus(implText);
  if (status === 'BLOCKED' || status === 'NEEDS_CONTEXT') {
    return park(id, boundary, `implementer ${status}: ${implText.slice(0, 400)}`);
  }
  if (status === 'DONE_WITH_CONCERNS') concerns.push(extractConcernLines(implText));

  const ctx = { id, boundary, filesCsv, briefPath, reportPath, agentType: role, attempts: 1, concerns, baseSha };

  const spentBefore = safeBudgetSpent();

  const valOutcome = await runValidateLadder(ctx);
  if (valOutcome.parked) return park(id, boundary, valOutcome.why);

  const revOutcome = await runReviewLadder(ctx);
  if (revOutcome.parked) return park(id, boundary, revOutcome.why);

  const spentAfter = safeBudgetSpent();
  const tokensDelta = Math.max(0, spentAfter - spentBefore);

  const sha = await finalize(id, title, declaredFiles, tokensDelta, 'Finalize');

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
  return null;
}

// --- entry point ---------------------------------------------------------------

export default async function run() {
  const badArgs = validateArgs(args);
  if (badArgs) return badArgs;

  lib = `${args.plugin_root}/lib`;

  const results = [];
  let tasksDone = 0;

  while (tasksDone < args.max_tasks) {
    const nextCmd = `node ${lib}/plan-io.mjs next${args.task_id ? ` --task ${args.task_id}` : ''}`;
    const adv = await relay(nextCmd, { phase: 'Advance', label: `advance-${tasksDone}` });
    if (!adv.ok) {
      throw new Error(`plan-io.mjs next failed: ${adv.reason || 'unknown'}`);
    }
    if (adv.data && adv.data.halt) {
      // all-done | dag-stuck | interrupt | dirty-tree — propagate verbatim,
      // the calling SKILL owns the halt-table dispatch.
      return { halt: adv.data.halt, detail: adv.data.detail };
    }

    const outcome = await runOneTask(adv);
    if (outcome.halt) return outcome; // park() propagates its stop-and-ask halt directly

    results.push({ task_id: outcome.task_id, sha: outcome.sha, tokens_delta: outcome.tokens_delta, concerns: outcome.concerns });
    tasksDone += 1;
    if (args.task_id) break;
  }

  // Normal, non-urgent completion: the requested cap (--tasks N, or a single
  // --task <id>) was reached with no ladder failure. Distinct from the
  // all-done/dag-stuck/interrupt/dirty-tree halt vocabulary — this is
  // success, not something needing an AskUserQuestion.
  return { halt: 'tasks-cap', tasks_done: tasksDone, results };
}
