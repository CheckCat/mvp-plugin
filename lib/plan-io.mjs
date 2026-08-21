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
//   set-status <id> <status>          pending|in_progress|done|failed
//   ledger --task <id> --sha <sha>    append-only ledger.md
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
function loadSchema(schemaPath) {
  if (!schemaPath) return FALLBACK_SCHEMA;
  const raw = fs.readFileSync(schemaPath, 'utf8');
  const parsed = JSON.parse(raw);
  return {
    required_fields: parsed.required_fields ?? FALLBACK_SCHEMA.required_fields,
    enums: parsed.enums ?? FALLBACK_SCHEMA.enums,
    max_estimate_tokens: parsed.max_estimate_tokens ?? FALLBACK_SCHEMA.max_estimate_tokens,
  };
}

function isUnderBoundary(file, servicePath) {
  const sp = String(servicePath).replace(/\/+$/, '');
  return file === sp || file.startsWith(sp + '/');
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
  const schema = loadSchema(flags.schema);

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  const tasks = tasksOf(plan);
  const ids = new Set(tasks.map((t) => t.id));
  const errors = [];

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

  if (errors.length) {
    return finish(false, 'plan validation failed', 'fix the listed errors in plan.json', { errors });
  }
  finish(true, null, null, { errors: [] });
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

  let plan;
  try {
    plan = readPlan();
  } catch (e) {
    return finish(false, `cannot read plan.json: ${e.message}`, 'run mvp:plan first', null);
  }

  if (fs.existsSync(INTERRUPT_PATH)) {
    return finish(true, null, null, { halt: 'interrupt' });
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
      const anyPending = tasks.some((t) => t.status === 'pending');
      if (anyPending) {
        return finish(true, null, null, {
          halt: 'dag-stuck',
          detail: 'pending tasks exist but none have all depends_on done',
        });
      }
      return finish(true, null, null, { halt: 'all-done' });
    }
  }

  const briefPath = writeBrief(chosen, byId);
  finish(true, null, null, {
    task_id: chosen.id,
    brief_path: briefPath,
    boundary: chosen.service_path,
    role: chosen.role,
    model_class: chosen.complexity_class,
  });
}

// --- complete ----------------------------------------------------------------------

function cmdComplete(args) {
  const { positionals, flags } = parseFlags(args, ['tokens']);
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

  const event = { event: 'task_complete', task: id, delta_tokens: n, ts: new Date().toISOString() };
  appendTextAtomic(EVENTS_PATH, JSON.stringify(event) + '\n');

  finish(true, null, null, { task_id: id, status: 'done', actual_tokens: n });
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
  const { flags } = parseFlags(args, ['task', 'sha']);
  if (!flags.task || !flags.sha) {
    return finish(false, 'missing --task/--sha', 'usage: plan-io.mjs ledger --task <id> --sha <sha>', null);
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
  appendTextAtomic(LEDGER_PATH, `Task ${flags.task}: complete (${flags.sha})\n`);

  finish(true, null, null, { ledger_path: LEDGER_PATH });
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
    case 'summary': return cmdSummary(rest);
    default:
      return finish(
        false,
        `unknown subcommand: ${cmd ?? '<missing>'}`,
        'usage: plan-io.mjs <validate|next|complete|set-status|ledger|summary> [...args]',
        null,
      );
  }
}

try {
  main();
} catch (err) {
  finish(false, err && err.message ? String(err.message) : String(err), null, null);
}
