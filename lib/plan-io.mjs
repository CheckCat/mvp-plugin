#!/usr/bin/env node
// plan-io.mjs — the ONLY reader/writer of .claude/state/plan.json at runtime.
//
// Run from the TARGET PROJECT root (not this plugin repo). State lives under
// .claude/state/ (plan.json, briefs/, reports/, ledger.md, telemetry/events.jsonl,
// user-interrupt.md, invariants.md). Node ESM, no dependencies beyond node builtins.
//
// Contract (every exit path, ruling R10): exactly one line of JSON on stdout —
//   {"ok":bool,"reason":str|null,"hint":str|null,"data":object|null}
// ok:false always exits 1. Errors never surface a raw stack trace (top-level
// try/catch). Halts (interrupt / dirty-tree / dag-stuck / all-done) are VALID
// outcomes: ok:true with data.halt set — not errors. A missing/unreadable
// plan.json IS an error: ok:false.
//
// Subcommands:
//   validate --schema <path>          schema/DAG/boundary checks -> data:{errors:[...]}
//   next [--task <id>]                atomic task pick + brief generation
//   complete <id> --tokens <n>        n = per-task delta (stored as actual_tokens)
//        [--dispatches <n>]           subagent dispatches this task cost (telemetry)
//        [--write-msg <path>]         also write the commit subject for finalize.sh
//   set-status <id> <status>          pending|in_progress|done|failed
//   add-task --json '<task>'          append one task, only if the plan stays valid
//   ledger --task <id> --sha <sha>    append-only ledger.md ('HEAD' resolves via git)
//        [--concern <text>]           append the task's non-blocking concerns
//   summary                           DAG summary for the plan->build gate
//
// Writes are atomic: tmp file in the same directory + fs.renameSync.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

// --- paths (relative to cwd == target project root) ------------------------

const STATE_DIR = path.join('.claude', 'state');
const PLAN_PATH = path.join(STATE_DIR, 'plan.json');
const BRIEFS_DIR = path.join(STATE_DIR, 'briefs');
const REPORTS_DIR = path.join(STATE_DIR, 'reports');
const LEDGER_PATH = path.join(STATE_DIR, 'ledger.md');
const TELEMETRY_DIR = path.join(STATE_DIR, 'telemetry');
const EVENTS_PATH = path.join(TELEMETRY_DIR, 'events.jsonl');
const INTERRUPT_PATH = path.join(STATE_DIR, 'user-interrupt.md');
const INVARIANTS_PATH = path.join(STATE_DIR, 'invariants.md');

const VALID_STATUSES = ['pending', 'in_progress', 'done', 'failed'];

// --- contract output ---------------------------------------------------------

// finish never calls process.exit(): it sets process.exitCode and returns, so
// stdout (a pipe under test/`$(...)`) always flushes fully before the process
// exits naturally at end of the (synchronous) event loop.
function finish(ok, reason, hint, data) {
  const out = { ok, reason: reason ?? null, hint: hint ?? null, data: data ?? null };
  process.stdout.write(JSON.stringify(out) + '\n');
  process.exitCode = ok ? 0 : 1;
}

// --- atomic I/O helpers -------------------------------------------------------

function writeTextAtomic(filePath, content) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, filePath);
}

function writeJsonAtomic(filePath, obj) {
  writeTextAtomic(filePath, JSON.stringify(obj, null, 2) + '\n');
}

function appendTextAtomic(filePath, chunk) {
  const existing = fs.existsSync(filePath) ? fs.readFileSync(filePath, 'utf8') : '';
  writeTextAtomic(filePath, existing + chunk);
}

function readPlan() {
  const raw = fs.readFileSync(PLAN_PATH, 'utf8');
  return JSON.parse(raw);
}

function tasksOf(plan) {
  return Array.isArray(plan.tasks) ? plan.tasks : [];
}

// --- argv parsing --------------------------------------------------------------

class UsageError extends Error {}
class SchemaError extends Error {}

// parseFlags(args, allowedFlagNames) -> {positionals, flags}
// Only `--name value` (space-separated) is supported — matches every
// subcommand's contract above. Unknown flags / missing values throw
// UsageError, caught by the top-level try/catch (ruling R10: argv guard).
function parseFlags(args, allowed) {
  const positionals = [];
  const flags = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) {
      const name = a.slice(2);
      if (!allowed.includes(name)) throw new UsageError(`unknown flag: --${name}`);
      const val = args[i + 1];
      if (val === undefined || val.startsWith('--')) {
        throw new UsageError(`missing value for --${name}`);
      }
      flags[name] = val;
      i++;
    } else {
      positionals.push(a);
    }
  }
  return { positionals, flags };
}

// --- validate ------------------------------------------------------------------

const FALLBACK_SCHEMA = {
  required_fields: [
    'id', 'title', 'level', 'service', 'service_path', 'role',
    'files', 'depends_on', 'estimate_tokens', 'status', 'complexity_class',
  ],
  enums: {
    complexity_class: ['boilerplate', 'follow-pattern', 'novel-design'],
    status: VALID_STATUSES,
  },
  max_estimate_tokens: 25000,
};

// loadSchema(schemaPath) -> {required_fields, enums, max_estimate_tokens}
// --schema omitted -> FALLBACK_SCHEMA (the brief's hardcoded default list).
// --schema given -> read that JSON file; a later task authors the real
// plan/references/plan-schema.json to this same simple shape:
//   {"required_fields": [...], "enums": {"<field>": [...]}, "max_estimate_tokens": N}
// Missing fields in the schema file fall back to FALLBACK_SCHEMA per-field.
const SCHEMA_RECOGNIZED_KEYS = ['required_fields', 'enums', 'max_estimate_tokens'];

function loadSchema(schemaPath) {
  if (!schemaPath) return FALLBACK_SCHEMA;
  const raw = fs.readFileSync(schemaPath, 'utf8');
  const parsed = JSON.parse(raw);
  const hasRecognizedKey = SCHEMA_RECOGNIZED_KEYS.some(
    (k) => Object.prototype.hasOwnProperty.call(parsed, k),
  );
  if (!hasRecognizedKey) {
    throw new SchemaError(
      `schema file has none of the recognized keys (${SCHEMA_RECOGNIZED_KEYS.join(', ')}): ${schemaPath}`,
    );
  }
  return {
    required_fields: parsed.required_fields ?? FALLBACK_SCHEMA.required_fields,
    enums: parsed.enums ?? FALLBACK_SCHEMA.enums,
    max_estimate_tokens: parsed.max_estimate_tokens ?? FALLBACK_SCHEMA.max_estimate_tokens,
  };
}

// isUnderBoundary(file, servicePath) -> true iff `file` resolves to a path
// inside `servicePath`. Uses path.relative (not string prefix matching) so
// `..`-traversal that escapes the boundary is rejected even when the raw
// string happens to start with the boundary prefix, and equivalent forms
// (leading `./`, redundant `..` segments that cancel out) are accepted.
function isUnderBoundary(file, servicePath) {
  const rel = path.relative(servicePath, file);
  return !path.isAbsolute(rel) && !rel.startsWith('..');
}

// findCycle(tasks) -> array of task ids forming a cycle, or null.
function findCycle(tasks) {
  const deps = new Map(tasks.map((t) => [t.id, Array.isArray(t.depends_on) ? t.depends_on : []]));
  const WHITE = 0, GRAY = 1, BLACK = 2;
  const color = new Map(tasks.map((t) => [t.id, WHITE]));
  const stack = [];

  function dfs(id) {
    color.set(id, GRAY);
    stack.push(id);
    for (const dep of deps.get(id) || []) {
      if (!deps.has(dep)) continue; // unknown dep reported separately
      if (color.get(dep) === GRAY) {
        return stack.slice(stack.indexOf(dep)).concat(dep);
      }
      if (color.get(dep) === WHITE) {
        const found = dfs(dep);
        if (found) return found;
      }
    }
    stack.pop();
    color.set(id, BLACK);
    return null;
  }

  for (const t of tasks) {
    if (color.get(t.id) === WHITE) {
      const found = dfs(t.id);
      if (found) return found;
    }
  }
  return null;
}

function cmdValidate(args) {
  const { flags } = parseFlags(args, ['schema']);

  let schema;
  try {
    schema = loadSchema(flags.schema);
  } catch (e) {
    if (e instanceof SchemaError) {
      return finish(false, e.message, 'schema JSON must define at least one of required_fields/enums/max_estimate_tokens', null);
    }
    return finish(false, `cannot read --schema file: ${e.message}`, null, null);
  }

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  const errors = validatePlanShape(plan, schema);

  if (errors.length) {
    return finish(false, 'plan validation failed', 'fix the listed errors in plan.json', { errors });
  }
  finish(true, null, null, { errors: [] });
}

// validatePlanShape(plan, schema) -> array of error strings (empty === valid).
//
// Extracted from cmdValidate so `add-task` can run the SAME checks against the
// plan it is about to write. A second, parallel implementation of "is this
// plan legal" is how a DAG acquires two different notions of legality.
function validatePlanShape(plan, schema) {
  const errors = [];

  // structural check FIRST: plan.tasks must be a non-empty array. A missing,
  // non-array, or empty `tasks` field is a plan-shape error, not silently
  // treated as "zero tasks, therefore valid".
  if (!Array.isArray(plan.tasks) || plan.tasks.length === 0) {
    errors.push(`plan.tasks must be a non-empty array (got: ${JSON.stringify(plan.tasks)})`);
  }
  const tasks = tasksOf(plan);
  const ids = new Set(tasks.map((t) => t.id));

  for (const t of tasks) {
    const label = t.id ?? '<unknown>';
    for (const field of schema.required_fields) {
      if (t[field] === undefined || t[field] === null) {
        errors.push(`task ${label}: missing required field '${field}'`);
      }
    }
    if (typeof t.estimate_tokens === 'number' && t.estimate_tokens > schema.max_estimate_tokens) {
      errors.push(`task ${label}: estimate_tokens ${t.estimate_tokens} exceeds max ${schema.max_estimate_tokens}`);
    }
    if (schema.enums?.complexity_class && t.complexity_class !== undefined
        && !schema.enums.complexity_class.includes(t.complexity_class)) {
      errors.push(`task ${label}: complexity_class '${t.complexity_class}' not in ${schema.enums.complexity_class.join('|')}`);
    }
    if (schema.enums?.status && t.status !== undefined && !schema.enums.status.includes(t.status)) {
      errors.push(`task ${label}: status '${t.status}' not in ${schema.enums.status.join('|')}`);
    }
    if (Array.isArray(t.depends_on)) {
      for (const dep of t.depends_on) {
        if (!ids.has(dep)) errors.push(`task ${label}: depends_on unknown task '${dep}'`);
      }
    }
    if (Array.isArray(t.files) && typeof t.service_path === 'string') {
      for (const f of t.files) {
        if (!isUnderBoundary(f, t.service_path)) {
          errors.push(`task ${label}: file '${f}' not under service_path '${t.service_path}'`);
        }
      }
    }
  }

  const cycle = findCycle(tasks);
  if (cycle) errors.push(`dependency cycle detected: ${cycle.join(' -> ')}`);

  return errors;
}

// --- add-task -------------------------------------------------------------------

// cmdAddTask: append ONE task to an existing plan, atomically, only if the
// resulting plan still validates.
//
// Why this verb exists: until now a plan was frozen the moment mvp:plan
// committed it, and the pipeline had no way to record work it discovered
// mid-run. That gap was hit twice on vireo. The second time cost real damage:
// the devops agents on tasks 048 and 052 found a circular import that put the
// worker and beat deploy units into a restart loop, correctly refused to fix
// application code outside their boundary, and wrote a blocker — and there
// the finding sat, because nothing could turn it into a task. It was fixed by
// hand, outside the pipeline, after the DAG had already reported all-done.
//
// Deliberately narrow: appends one task, never edits or removes an existing
// one. Re-planning a live DAG is a different (and much more dangerous)
// operation — done tasks are history and their commits are real.
function cmdAddTask(args) {
  const { flags } = parseFlags(args, ['json', 'schema']);
  if (!flags.json) {
    return finish(false, 'missing --json', 'usage: plan-io.mjs add-task --json \'{"title":...}\' [--schema <path>]', null);
  }

  let schema;
  try {
    schema = loadSchema(flags.schema);
  } catch (e) {
    return finish(false, `cannot read --schema file: ${e.message}`, null, null);
  }

  let task;
  try {
    task = JSON.parse(flags.json);
  } catch (e) {
    return finish(false, `--json is not valid JSON: ${e.message}`, 'pass one JSON object describing the task', null);
  }
  if (!task || typeof task !== 'object' || Array.isArray(task)) {
    return finish(false, '--json must be a JSON object', null, null);
  }

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  const tasks = tasksOf(plan);
  const existing = new Set(tasks.map((t) => t.id));

  // id: caller-supplied must be unique; otherwise continue the sequence. A
  // silently-reused id would make `next`/`complete` address two tasks at once.
  if (task.id !== undefined) {
    if (existing.has(task.id)) {
      return finish(false, `task id '${task.id}' already exists`, 'omit "id" to let plan-io assign the next one', null);
    }
  } else {
    const maxId = tasks.reduce((acc, t) => Math.max(acc, Number.parseInt(t.id, 10) || 0), 0);
    task.id = String(maxId + 1).padStart(3, '0');
  }

  // A task added to a running plan is unstarted by definition. Accepting
  // "done" here would let a caller mark work complete without a commit.
  task.status = 'pending';

  const candidate = { ...plan, tasks: [...tasks, task] };
  const errors = validatePlanShape(candidate, schema);
  if (errors.length) {
    return finish(false, 'adding this task would make the plan invalid', 'fix the listed errors; plan.json was NOT modified', { errors });
  }

  writeJsonAtomic(PLAN_PATH, candidate);
  finish(true, null, null, { task_id: task.id, total: candidate.tasks.length });
}

// --- next ------------------------------------------------------------------------

// getDirtyFilesOutsideState() -> file paths from `git status --porcelain` that
// are NOT under .claude/state (files inside state are allowed to be dirty —
// this script itself writes there).
function getDirtyFilesOutsideState() {
  let raw;
  try {
    raw = execFileSync('git', ['status', '--porcelain'], { cwd: process.cwd(), encoding: 'utf8' });
  } catch (e) {
    throw new Error(`git status failed: ${e.message}`);
  }
  const files = [];
  for (const line of raw.split('\n')) {
    if (!line) continue;
    let filePart = line.slice(3);
    if (filePart.includes(' -> ')) filePart = filePart.split(' -> ')[1];
    filePart = filePart.replace(/^"(.*)"$/, '$1').trim();
    if (filePart === STATE_DIR || filePart.startsWith(STATE_DIR + '/')) continue;
    files.push(filePart);
  }
  return files;
}

// gitHeadSha() -> full HEAD sha, or null when git can't answer (no repo, no
// commits yet). Never throws: `next` must still hand back a task on a repo
// without HEAD, and `ledger --sha HEAD` validates the result itself.
//
// Why this exists (relay diet, 2026-08-24): every subagent dispatch costs a
// flat ~30 200 tokens of boot regardless of payload, so a whole relay spent
// on `git rev-parse HEAD` cost ~1.5 M tokens across the vireo run. Folding
// the sha into `next`'s payload removes that dispatch entirely. See
// docs/observations/2026-08-24-pipeline-economics-and-review-yield.md §2.
function gitHeadSha() {
  try {
    const out = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: process.cwd(), encoding: 'utf8' });
    return out.trim() || null;
  } catch {
    return null;
  }
}

function formatValue(v) {
  if (Array.isArray(v)) return v.length ? v.join(', ') : '(none)';
  return String(v);
}

// writeBrief(task, byId) -> relative path of the written briefs/task-<id>.md
function writeBrief(task, byId) {
  const lines = [];

  lines.push('## Task');
  for (const [k, v] of Object.entries(task)) {
    lines.push(`- ${k}: ${formatValue(v)}`);
  }
  lines.push('');

  lines.push('## Boundary');
  lines.push(task.service_path);
  lines.push('');

  lines.push('## Interfaces from dependencies');
  const deps = Array.isArray(task.depends_on) ? task.depends_on : [];
  if (deps.length === 0) {
    lines.push('(none)');
  } else {
    for (const dep of deps) {
      lines.push(`### ${dep}`);
      const reportPath = path.join(REPORTS_DIR, `task-${dep}.md`);
      if (fs.existsSync(reportPath)) {
        lines.push(fs.readFileSync(reportPath, 'utf8').trimEnd());
      } else {
        lines.push('(no report)');
      }
      lines.push('');
    }
  }

  lines.push('## Project invariants');
  lines.push(fs.existsSync(INVARIANTS_PATH) ? fs.readFileSync(INVARIANTS_PATH, 'utf8').trimEnd() : '(none)');
  lines.push('');

  const briefPath = path.join(BRIEFS_DIR, `task-${task.id}.md`);
  writeTextAtomic(briefPath, lines.join('\n') + '\n');
  return briefPath;
}

function cmdNext(args) {
  const { flags } = parseFlags(args, ['task']);

  // interrupt check FIRST (spec step order): must halt even if plan.json is
  // missing/unreadable — an operator-requested pause takes priority over a
  // plan-state error.
  if (fs.existsSync(INTERRUPT_PATH)) {
    return finish(true, null, null, { halt: 'interrupt' });
  }

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  const dirtyFiles = getDirtyFilesOutsideState();
  if (dirtyFiles.length) {
    return finish(true, null, null, { halt: 'dirty-tree', files: dirtyFiles });
  }

  const tasks = tasksOf(plan);
  const byId = new Map(tasks.map((t) => [t.id, t]));

  let chosen;
  if (flags.task) {
    const t = byId.get(flags.task);
    if (!t) {
      return finish(false, `task not found: ${flags.task}`, 'check the task id against plan.json', null);
    }
    const unmet = (Array.isArray(t.depends_on) ? t.depends_on : [])
      .filter((d) => byId.get(d)?.status !== 'done');
    if (unmet.length) {
      return finish(true, null, null, {
        halt: 'dag-stuck',
        detail: `task ${flags.task} has unmet deps: ${unmet.join(', ')}`,
      });
    }
    chosen = t;
  } else {
    chosen = tasks.find((t) => t.status === 'pending'
      && (Array.isArray(t.depends_on) ? t.depends_on : []).every((d) => byId.get(d)?.status === 'done'));
    if (!chosen) {
      // all-done is a TERMINAL state: every task in a non-empty plan is
      // 'done'. Anything else (no eligible pending task, but some task is
      // failed/in_progress/blocked-pending, or the plan has zero tasks) is
      // dag-stuck — the run cannot silently be treated as finished.
      const allDone = tasks.length > 0 && tasks.every((t) => t.status === 'done');
      if (allDone) {
        return finish(true, null, null, { halt: 'all-done' });
      }
      const blocking = tasks.filter((t) => t.status !== 'done');
      const detail = blocking.length
        ? `blocking tasks: ${blocking.map((t) => `${t.id}(${t.status})`).join(', ')}`
        : 'no tasks in plan';
      return finish(true, null, null, { halt: 'dag-stuck', detail });
    }
  }

  const briefPath = writeBrief(chosen, byId);
  finish(true, null, null, {
    task_id: chosen.id,
    brief_path: briefPath,
    boundary: chosen.service_path,
    role: chosen.role,
    model_class: chosen.complexity_class,
    // files: the task's declared file list, verbatim from plan.json. Added
    // for Task 14 (skills/build/workflow.mjs): validate-task.sh needs a
    // deterministic --files source and the implementer's self-reported FILES
    // line is not trustworthy for that (v1 lesson). Defaults to [] if a task
    // somehow has no `files` array (schema requires it, but `next` must not
    // crash on a plan that hasn't been through `validate` yet).
    files: Array.isArray(chosen.files) ? chosen.files : [],
    // title: same additive pattern as `files` above (Task 14 fix round).
    // workflow.mjs's finalize step uses this for the commit subject
    // (`feat: task <id>: <title>`) instead of a bare `feat: task <id>`.
    title: typeof chosen.title === 'string' ? chosen.title : null,
    // head_sha: the review-package BASE for this task, resolved here instead
    // of by a dedicated relay dispatch (see gitHeadSha's comment). null on a
    // repo without HEAD — callers must treat that as "no base yet".
    head_sha: gitHeadSha(),
  });
}

// --- complete ----------------------------------------------------------------------

function cmdComplete(args) {
  const { positionals, flags } = parseFlags(args, ['tokens', 'dispatches', 'write-msg']);
  const id = positionals[0];
  if (!id) {
    return finish(false, 'missing task id', 'usage: plan-io.mjs complete <id> --tokens <n>', null);
  }
  if (flags.tokens === undefined) {
    return finish(false, 'missing --tokens', 'usage: plan-io.mjs complete <id> --tokens <n>', null);
  }
  const n = Number(flags.tokens);
  if (!Number.isFinite(n)) {
    return finish(false, `--tokens must be a number, got '${flags.tokens}'`, 'usage: plan-io.mjs complete <id> --tokens <n>', null);
  }

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }
  const task = tasksOf(plan).find((t) => t.id === id);
  if (!task) {
    return finish(false, `task not found: ${id}`, null, null);
  }

  // n is the PER-TASK DELTA: overwrite, never accumulate.
  task.status = 'done';
  task.actual_tokens = n;
  writeJsonAtomic(PLAN_PATH, plan);

  // --write-msg: write finalize.sh's commit-message file here instead of
  // spending a subagent dispatch on a one-line Write (relay diet, §2 of the
  // 2026-08-24 economics study — that agent cost ~1.2 M tokens across the
  // vireo run). Doing it in-process also removes the shell-quoting hazard of
  // passing a free-text task title (quotes, $, backticks) through a command
  // string. The subject shape must satisfy finalize.sh's prefix check.
  let msgPath = null;
  if (flags['write-msg']) {
    const rawTitle = typeof task.title === 'string' ? task.title : '';
    // One line only: finalize.sh validates the FIRST line, and a title with
    // an embedded newline would push the real subject into the body.
    const title = rawTitle.replace(/\s+/g, ' ').trim();
    const subject = title ? `feat: task ${id}: ${title}` : `feat: task ${id}`;
    writeTextAtomic(flags['write-msg'], subject + '\n');
    msgPath = flags['write-msg'];
  }

  // Telemetry is ADDITIVE, never renamed: events.jsonl is append-only and a
  // run may span plugin versions, so an existing consumer (mvp:retro) must
  // keep reading `delta_tokens`. What changed on 2026-08-24 is the honesty
  // of the surrounding fields: `delta_tokens` is budget.spent() as seen by
  // the CONTROLLER only — measured against the workflow runtime's own
  // records it understates true cost by ~8.4x, because subagent usage is
  // invisible to it. `dispatches` is the cheap proxy that does scale with
  // the real number: count of subagent calls the task actually made.
  const dispatches = flags.dispatches === undefined ? null : Number(flags.dispatches);
  const event = {
    event: 'task_complete',
    task: id,
    delta_tokens: n,
    controller_only: true,
    dispatches: Number.isFinite(dispatches) ? dispatches : null,
    ts: new Date().toISOString(),
  };
  appendTextAtomic(EVENTS_PATH, JSON.stringify(event) + '\n');

  finish(true, null, null, { task_id: id, status: 'done', actual_tokens: n, msg_path: msgPath });
}

// --- set-status ----------------------------------------------------------------------

function cmdSetStatus(args) {
  const { positionals } = parseFlags(args, []);
  const [id, status] = positionals;
  if (!id || !status) {
    return finish(false, 'missing arguments', `usage: plan-io.mjs set-status <id> <${VALID_STATUSES.join('|')}>`, null);
  }
  if (!VALID_STATUSES.includes(status)) {
    return finish(false, `invalid status: ${status}`, `usage: plan-io.mjs set-status <id> <${VALID_STATUSES.join('|')}>`, null);
  }

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }
  const task = tasksOf(plan).find((t) => t.id === id);
  if (!task) {
    return finish(false, `task not found: ${id}`, null, null);
  }

  task.status = status;
  writeJsonAtomic(PLAN_PATH, plan);
  finish(true, null, null, { task_id: id, status });
}

// --- ledger ----------------------------------------------------------------------

function cmdLedger(args) {
  const { flags } = parseFlags(args, ['task', 'sha', 'concern']);
  if (!flags.task || !flags.sha) {
    return finish(false, 'missing --task/--sha', 'usage: plan-io.mjs ledger --task <id> --sha <sha> [--concern <text>]', null);
  }

  // --sha HEAD: resolve here so this call can be CHAINED after finalize.sh in
  // one shell command (`complete && finalize.sh && ledger --sha HEAD`) rather
  // than costing its own relay dispatch. The sha is only knowable after the
  // commit, so this call necessarily runs post-commit — the ledger line for
  // task N is therefore carried into git by task N+1's commit, and the last
  // task of a run leaves it uncommitted on disk. That ordering is inherent
  // (amending a just-made commit to insert its own sha is not worth the
  // history rewrite); chaining at least shrinks the crash window to a single
  // shell command instead of a whole dispatch round-trip.
  let sha = flags.sha;
  if (sha === 'HEAD') {
    sha = gitHeadSha();
    if (!sha) {
      return finish(false, 'cannot resolve HEAD', 'ledger --sha HEAD requires a git repo with at least one commit', null);
    }
  }

  let planBytes;
  try {
    planBytes = fs.readFileSync(PLAN_PATH);
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  if (!fs.existsSync(LEDGER_PATH)) {
    const hash = crypto.createHash('sha256').update(planBytes).digest('hex');
    const header = `# Ledger ${path.resolve(PLAN_PATH)} sha256:${hash}\n`;
    writeTextAtomic(LEDGER_PATH, header);
  }
  // Concerns are persisted HERE, by the script, not by the calling SKILL.
  // build/SKILL.md used to instruct the controller to append a `Ruling:` line
  // whenever a task returned a non-empty concerns[]. Measured over the vireo
  // run: concerns were raised on 35 of 36 tasks and reached the workflow's
  // return payload on 30 — and ledger.md ended up with ZERO of them. A state
  // write left to the LLM was skipped 36 times out of 36, which is exactly
  // the failure mode the Iron Law exists to prevent. Written before the Task
  // line so a concern can never look like it belongs to the next task.
  if (flags.concern) {
    const lines = String(flags.concern)
      .split('\n')
      .map((l) => l.trim())
      .filter(Boolean);
    for (const line of lines) {
      appendTextAtomic(LEDGER_PATH, `  concern (task ${flags.task}): ${line}\n`);
    }
  }

  appendTextAtomic(LEDGER_PATH, `Task ${flags.task}: complete (${sha})\n`);

  // sha is echoed back so a chained caller (complete && finalize && ledger)
  // can read the commit sha from THIS envelope — it is the last JSON line of
  // the chain, so finalize.sh's own envelope is no longer what the relay sees.
  finish(true, null, null, { ledger_path: LEDGER_PATH, sha });
}

// --- summary ----------------------------------------------------------------------

function cmdSummary(args) {
  parseFlags(args, []);

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  const tasks = tasksOf(plan);
  const counts = { total: tasks.length, done: 0, pending: 0, failed: 0 };
  const phases = {};

  for (const t of tasks) {
    if (t.status === 'done') counts.done++;
    else if (t.status === 'pending') counts.pending++;
    else if (t.status === 'failed') counts.failed++;

    const lvl = String(t.level);
    if (!phases[lvl]) phases[lvl] = { total: 0, done: 0, pending: 0, failed: 0 };
    phases[lvl].total++;
    if (t.status === 'done') phases[lvl].done++;
    else if (t.status === 'pending') phases[lvl].pending++;
    else if (t.status === 'failed') phases[lvl].failed++;
  }

  finish(true, null, null, { ...counts, phases });
}

// --- main ----------------------------------------------------------------------

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case 'validate': return cmdValidate(rest);
    case 'next': return cmdNext(rest);
    case 'complete': return cmdComplete(rest);
    case 'set-status': return cmdSetStatus(rest);
    case 'ledger': return cmdLedger(rest);
    case 'add-task': return cmdAddTask(rest);
    case 'summary': return cmdSummary(rest);
    default:
      return finish(
        false,
        `unknown subcommand: ${cmd ?? '<missing>'}`,
        'usage: plan-io.mjs <validate|next|complete|set-status|ledger|add-task|summary> [...args]',
        null,
      );
  }
}

try {
  main();
} catch (err) {
  finish(false, err && err.message ? String(err.message) : String(err), null, null);
}
