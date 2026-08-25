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
//        | --json-file <path>         append a BATCH (array) in one transaction
//   reopen --reason <text>            continue a FINISHED plan: bump epoch, phase
//        [--invariant <line>]         -> plan-done, optionally append one rule
//   ledger --task <id> --sha <sha>    append-only ledger.md ('HEAD' resolves via git)
//        [--concern <text>]           append the task's non-blocking concerns
//   summary                           DAG summary for the plan->build gate
//
// Writes are atomic: tmp file in the same directory + fs.renameSync.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

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

// state.json is NOT written here. `reopen` needs to move `phase`, and state.sh
// is that file's single writer — so this script shells out to it rather than
// becoming a second writer of the same state (the exact duplication the Iron
// Law forbids for plan.json).
const LIB_DIR = path.dirname(fileURLToPath(import.meta.url));
const STATE_SH = path.join(LIB_DIR, 'state.sh');

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
// --json  -> exactly one task object (unchanged contract; build/SKILL.md uses it)
// --json-file -> a BATCH: one array of task objects, applied as ONE transaction.
//
// Why the batch form exists: continuing a finished project means adding a
// handful of related tasks at once. Doing that as N separate calls costs N
// relay dispatches (~30 200 tokens of boot each, measured) and opens N windows
// in which the plan is half-extended — a crash between calls leaves tasks whose
// depends_on point at siblings that were never written. The batch validates the
// WHOLE resulting plan once and writes once, so the plan is either fully
// extended or untouched.
const ADD_TASK_USAGE = 'usage: plan-io.mjs add-task (--json \'{"title":...}\' | --json-file <path>) [--schema <path>]';

function cmdAddTask(args) {
  const { flags } = parseFlags(args, ['json', 'json-file', 'schema']);
  const inline = flags.json;
  const fromFile = flags['json-file'];

  if (inline !== undefined && fromFile !== undefined) {
    return finish(false, '--json and --json-file are mutually exclusive', ADD_TASK_USAGE, null);
  }
  if (inline === undefined && fromFile === undefined) {
    return finish(false, 'missing --json or --json-file', ADD_TASK_USAGE, null);
  }

  let schema;
  try {
    schema = loadSchema(flags.schema);
  } catch (e) {
    return finish(false, `cannot read --schema file: ${e.message}`, null, null);
  }

  let raw;
  if (fromFile !== undefined) {
    try {
      raw = fs.readFileSync(fromFile, 'utf8');
    } catch (e) {
      return finish(false, `cannot read --json-file: ${e.message}`, null, null);
    }
  } else {
    raw = inline;
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    const src = fromFile !== undefined ? '--json-file' : '--json';
    return finish(false, `${src} is not valid JSON: ${e.message}`, 'pass one JSON object (--json) or an array of them (--json-file)', null);
  }

  let incoming;
  if (Array.isArray(parsed)) {
    if (fromFile === undefined) {
      return finish(false, '--json takes ONE task object', 'use --json-file <path> for an array of tasks', null);
    }
    incoming = parsed;
  } else {
    incoming = [parsed];
  }

  if (incoming.length === 0) {
    return finish(false, '--json-file contains an empty array', 'nothing to add; plan.json was NOT modified', null);
  }
  for (let i = 0; i < incoming.length; i++) {
    const t = incoming[i];
    if (!t || typeof t !== 'object' || Array.isArray(t)) {
      return finish(false, `entry ${i} is not a JSON object`, 'every task must be a JSON object', null);
    }
  }

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  const tasks = tasksOf(plan);
  const existing = new Set(tasks.map((t) => t.id));
  const planEpoch = Number.isInteger(plan.epoch) ? plan.epoch : 1;
  let maxId = tasks.reduce((acc, t) => Math.max(acc, Number.parseInt(t.id, 10) || 0), 0);
  const addedIds = [];

  for (const task of incoming) {
    // id: caller-supplied must be unique (against the plan AND against earlier
    // entries of this same batch); otherwise continue the sequence. A silently
    // reused id would make `next`/`complete` address two tasks at once.
    if (task.id !== undefined) {
      if (existing.has(task.id)) {
        return finish(false, `task id '${task.id}' already exists`, 'omit "id" to let plan-io assign the next one; plan.json was NOT modified', null);
      }
      maxId = Math.max(maxId, Number.parseInt(task.id, 10) || 0);
    } else {
      maxId += 1;
      task.id = String(maxId).padStart(3, '0');
    }
    existing.add(task.id);

    // A directory in `files` is always a defect, and a silent one: the
    // `declared` check in validate-task.sh is an exact-string set difference
    // against changed FILE paths, so a directory can never match and the task
    // reports missing-declared no matter what the implementer does. Measured
    // on vireo epoch 2: a task declaring `services/frontend/src/components`
    // burned a validation retry and produced two meaningless concerns before
    // anyone noticed the entry was a directory. Caught here — when the task is
    // written — instead of forty minutes into the implementer's run.
    //
    // Only paths that EXIST as directories are rejected: a path that is absent
    // is a file the task is about to create, which is the normal case.
    if (Array.isArray(task.files)) {
      for (const f of task.files) {
        if (typeof f !== 'string') continue;
        if (f.endsWith('/') || (fs.existsSync(f) && fs.statSync(f).isDirectory())) {
          return finish(false, `task ${task.id}: '${f}' is a directory, not a file`,
            'list the individual files — validate-task.sh matches declared paths exactly, so a directory always reports missing-declared; plan.json was NOT modified',
            null);
        }
      }
    }

    // A task added to a running plan is unstarted by definition. Accepting
    // "done" here would let a caller mark work complete without a commit.
    task.status = 'pending';
    // Stamp the plan's current epoch so `summary` can report progress for THIS
    // continuation instead of drowning it in the original run's task count.
    if (task.epoch === undefined) task.epoch = planEpoch;
    addedIds.push(task.id);
  }

  const candidate = { ...plan, tasks: [...tasks, ...incoming] };
  const errors = validatePlanShape(candidate, schema);
  if (errors.length) {
    const what = incoming.length === 1 ? 'adding this task' : `adding these ${incoming.length} tasks`;
    return finish(false, `${what} would make the plan invalid`, 'fix the listed errors; plan.json was NOT modified', { errors });
  }

  writeJsonAtomic(PLAN_PATH, candidate);
  const data = { total: candidate.tasks.length, epoch: planEpoch };
  if (fromFile === undefined) data.task_id = addedIds[0];
  else data.task_ids = addedIds;
  finish(true, null, null, data);
}

// --- reopen -----------------------------------------------------------------------

// cmdReopen: turn a FINISHED plan back into a buildable one without touching a
// single completed task.
//
// Why this verb exists: mvp:plan writes plan.json exactly once, and gate_build
// requires phase == "plan-done". Once a run reaches all-done (phase == "done")
// there was no legal way to continue the project. Re-running mvp:plan
// re-dispatches a planner that writes plan.json WHOLE via Write (plan/SKILL.md
// step 2), erasing every completed task together with its real commit sha. The
// only remaining path was `state.sh set phase plan-done` typed by hand — a
// state write with no precondition, no audit trail and no record of why, which
// is precisely what the Iron Law exists to prevent.
//
// What it does NOT do: reset, edit or remove any existing task. Done tasks are
// history and their commits are real. Continuation happens by APPENDING new
// tasks (add-task), never by reopening old ones.
//
// Why --invariant belongs on this same transaction: measured on vireo, the
// interface language was never written down in docs/product/, CLAUDE.md or
// invariants.md, so every agent defaulted to English — and the next component
// added would have done so again. Translating the files fixes the symptom; the
// rule only sticks if it enters the document that build pastes into every task
// brief (writeBrief inlines invariants.md). Making "continue the project" and
// "record the rule that made it necessary" one atomic act is the difference
// between fixing a project and fixing it repeatedly.
function cmdReopen(args) {
  const { flags } = parseFlags(args, ['reason', 'invariant', 'schema']);
  if (!flags.reason) {
    return finish(false, 'missing --reason', 'usage: plan-io.mjs reopen --reason "<why>" [--invariant "<rule>"]', null);
  }

  let schema;
  try {
    schema = loadSchema(flags.schema);
  } catch (e) {
    return finish(false, `cannot read --schema file: ${e.message}`, null, null);
  }

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  const phase = readPhase();
  if (phase !== 'done') {
    const currentEpoch = Number.isInteger(plan.epoch) ? plan.epoch : 1;
    const pending = tasksOf(plan).filter((t) => t.status === 'pending').length;
    // phase already plan-done with nothing pending == a previous reopen that
    // died between the plan write and the phase write. Bumping epoch a second
    // time would invent a continuation that never happened; say what the real
    // next step is instead.
    if (phase === 'plan-done' && pending === 0) {
      return finish(false, `plan is already open (epoch ${currentEpoch})`,
        'add tasks with: plan-io.mjs add-task --json-file <path>',
        { epoch: currentEpoch, phase });
    }
    return finish(false, `phase != done (got: ${phase ?? 'null'})`,
      'reopen continues a FINISHED plan — run mvp:build through to all-done first', null);
  }

  const epoch = (Number.isInteger(plan.epoch) ? plan.epoch : 1) + 1;
  const record = {
    epoch,
    reason: String(flags.reason).replace(/\s+/g, ' ').trim(),
    base_sha: gitHeadSha(),
    at: new Date().toISOString(),
  };
  const invariantLine = flags.invariant
    ? String(flags.invariant).replace(/\s+/g, ' ').trim()
    : '';
  if (invariantLine) record.invariant = invariantLine;

  const candidate = {
    ...plan,
    epoch,
    reopened: [...(Array.isArray(plan.reopened) ? plan.reopened : []), record],
  };
  const errors = validatePlanShape(candidate, schema);
  if (errors.length) {
    return finish(false, 'plan does not validate — refusing to reopen it',
      'fix the listed errors first; plan.json was NOT modified', { errors });
  }

  writeJsonAtomic(PLAN_PATH, candidate);

  const needsCommit = [PLAN_PATH];
  if (invariantLine) {
    appendTextAtomic(INVARIANTS_PATH, `- ${invariantLine} (epoch ${epoch})\n`);
    needsCommit.push(INVARIANTS_PATH);
  }

  // Phase LAST: until it moves, gate_build still refuses, so a crash before
  // this point leaves a plan that is merely annotated, never a half-open one.
  try {
    setPhase('plan-done');
  } catch (e) {
    return finish(false, `plan.json was updated but the phase write failed: ${e.message}`,
      'run: lib/state.sh set phase plan-done', { epoch, needs_commit: needsCommit });
  }

  finish(true, null,
    'next: add-task --json-file <path>, then finalize.sh plan, then mvp:build',
    {
      epoch,
      phase: 'plan-done',
      base_sha: record.base_sha,
      invariant: invariantLine || null,
      needs_commit: needsCommit,
    });
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

// readPhase() -> the current state.json `phase` string, or null when state.sh
// cannot answer (no state.json, unreadable, ok:false). Never throws: callers
// decide what a null phase means for them.
function readPhase() {
  try {
    const out = execFileSync('bash', [STATE_SH, 'get', 'phase'], {
      cwd: process.cwd(), encoding: 'utf8',
    });
    const last = out.trim().split('\n').pop();
    const parsed = JSON.parse(last);
    if (!parsed || parsed.ok !== true) return null;
    const v = parsed.data ? parsed.data.value : null;
    return typeof v === 'string' ? v : null;
  } catch {
    return null;
  }
}

// setPhase(value) -> throws on failure (unlike readPhase). A phase write that
// silently no-ops would leave `reopen` reporting success on a plan that
// gate_build still refuses.
function setPhase(value) {
  const out = execFileSync('bash', [STATE_SH, 'set', 'phase', value], {
    cwd: process.cwd(), encoding: 'utf8',
  });
  const last = out.trim().split('\n').pop();
  const parsed = JSON.parse(last);
  if (!parsed || parsed.ok !== true) {
    throw new Error(parsed && parsed.reason ? parsed.reason : 'state.sh set phase failed');
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
  // Epoch buckets exist so a continuation reads as "3/4 of epoch 2" instead of
  // "58/59 overall" — after a reopen the original run's task count otherwise
  // swamps the progress signal for the work actually in flight. Tasks written
  // before epochs existed carry no field and belong to epoch 1.
  const epochs = {};

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

    const ep = String(Number.isInteger(t.epoch) ? t.epoch : 1);
    if (!epochs[ep]) epochs[ep] = { total: 0, done: 0, pending: 0, failed: 0 };
    epochs[ep].total++;
    if (t.status === 'done') epochs[ep].done++;
    else if (t.status === 'pending') epochs[ep].pending++;
    else if (t.status === 'failed') epochs[ep].failed++;
  }

  finish(true, null, null, {
    ...counts,
    phases,
    epochs,
    epoch: Number.isInteger(plan.epoch) ? plan.epoch : 1,
    reopened: Array.isArray(plan.reopened) ? plan.reopened.length : 0,
  });
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
    case 'reopen': return cmdReopen(rest);
    case 'summary': return cmdSummary(rest);
    default:
      return finish(
        false,
        `unknown subcommand: ${cmd ?? '<missing>'}`,
        'usage: plan-io.mjs <validate|next|complete|set-status|ledger|add-task|reopen|summary> [...args]',
        null,
      );
  }
}

try {
  main();
} catch (err) {
  finish(false, err && err.message ? String(err.message) : String(err), null, null);
}
