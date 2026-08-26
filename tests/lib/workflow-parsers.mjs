// Harness + assertions for the pure parsing functions inside
// skills/build/workflow.mjs.
//
// Why this file exists: workflow.mjs is the only component in the plugin that
// parses UNTRUSTED text — every reply from every subagent goes through it —
// and until 2026-08-25 it had zero test coverage, while the deterministic
// shell scripts had thirteen suites. Both production failures of this
// pipeline happened in exactly this layer:
//   1. relay JSON drift (three successive shapes: escaped string-in-string,
//      `data` as a string plus "null" strings, whole envelope nested inside
//      `data`) — coerceRelayFields / looksLikeEnvelope;
//   2. task 037's malformed FINDINGS array, which parked the task and
//      discarded ~371k tokens of completed work — parseReviewerVerdict.
// Fixtures below are the REAL failing payloads, not invented ones.
//
// workflow.mjs cannot be imported: the Workflow runner supplies its own
// async wrapper, so the file is an AsyncFunction BODY with top-level returns,
// not an ES module. Instead of duplicating the functions here (a copy would
// drift and test nothing), the harness extracts the real declarations from
// the real file and evaluates them.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(here, '..', '..', 'skills', 'build', 'workflow.mjs');

const WANTED = [
  'parseStatus', 'extractField', 'extractJsonField', 'extractConcernLines',
  'parseValidatorVerdict', 'parseReviewerVerdict', 'parseCannotVerify', 'parseReReview',
  'looksLikeEnvelope', 'coerceRelayFields',
  'declaredOnly', 'truncatedPaths', 'shQuote', 'isRepoRootBoundary',
  'severityRank', 'findingKey', 'unionFindings',
];

// extractFn: pull one top-level `function NAME(...) { ... }` out of the source.
// Top-level functions in this file always close with `}` in column 0, which is
// what the scan keys on — a brace counter would also have to understand
// strings, regexes and template literals, all of which appear in these
// functions.
function extractFn(src, name) {
  const start = src.indexOf(`\nfunction ${name}(`);
  if (start < 0) throw new Error(`function ${name} not found in workflow.mjs — did it get renamed?`);
  const end = src.indexOf('\n}\n', start);
  if (end < 0) throw new Error(`could not find the end of ${name}`);
  return src.slice(start + 1, end + 3);
}

const src = fs.readFileSync(SRC, 'utf8');
const body = WANTED.map((n) => extractFn(src, n)).join('\n');
// eslint-disable-next-line no-new-func
const load = new Function(`${body}\nreturn { ${WANTED.join(', ')} };`);
const F = load();

let failures = 0;
function check(desc, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    console.error(`FAIL: ${desc}\n  expected ${e}\n  got      ${a}`);
    failures += 1;
  }
}
function checkTrue(desc, cond) {
  if (!cond) {
    console.error(`FAIL: ${desc}`);
    failures += 1;
  }
}

// --- REGRESSION: the real task-037 reply that parked a task -----------------
//
// Verbatim from the park detail of run build-20260824T193359. The array is
// unparseable: `"summary":"…","}` leaves a dangling key, and the payload is
// cut off mid-entry. The contract that matters is NOT "parse it anyway" — it
// is "degrade to request-changes with zero findings", because that is the
// state runReviewLadder treats as malformed and answers with one reviewer
// re-ask instead of throwing or, worse, dispatching fix.md with garbage.
const MALFORMED_037 = `VERDICT: request-changes
CANNOT_VERIFY: none
FINDINGS: [{"severity":"bug","file":"services/api/app/modules/orchestrator/tasks.py","line":179,"quote":"except AppError as exc:","summary":"ensure_run's own unique-constraint race raises IntegrityError, not AppError, uncaught here.","}, {"severity":"bug","file":"services/api/app/modules/orchestrator/tasks.py","line":194,"quote":"except AppError as exc:`;

const v037 = F.parseReviewerVerdict(MALFORMED_037);
check('037 regression: kind is a verdict, not patches', v037.kind, 'verdict');
check('037 regression: verdict survives as request-changes', v037.verdict, 'request-changes');
check('037 regression: findings degrade to empty (triggers the re-ask)', v037.findings, []);
check('037 regression: CANNOT_VERIFY on the same reply reads as none', F.parseCannotVerify(MALFORMED_037), null);

// --- parseCannotVerify ------------------------------------------------------
//
// A MISSING line must read as "none": the parser ships alongside a prompt
// change, and a reviewer still answering in the old format must not park
// every task in the plan. The script-side gate (truncatedPaths) is what
// catches an incomplete package regardless of what the reviewer says.
check('cannot-verify: absent line -> null', F.parseCannotVerify('VERDICT: approve\nFINDINGS: []'), null);
check('cannot-verify: none -> null', F.parseCannotVerify('CANNOT_VERIFY: none'), null);
check('cannot-verify: None (case) -> null', F.parseCannotVerify('CANNOT_VERIFY: None'), null);
check('cannot-verify: no -> null', F.parseCannotVerify('CANNOT_VERIFY: no'), null);
check('cannot-verify: n/a -> null', F.parseCannotVerify('CANNOT_VERIFY: n/a'), null);
check(
  'cannot-verify: real text is returned',
  F.parseCannotVerify('VERDICT: approve\nCANNOT_VERIFY: state validation and the redirect-URI allowlist are not in the package\nFINDINGS: []'),
  'state validation and the redirect-URI allowlist are not in the package',
);
checkTrue(
  'cannot-verify: "none of the OAuth checks are visible" must NOT read as none',
  F.parseCannotVerify('CANNOT_VERIFY: none of the OAuth checks are visible in this package') !== null,
);

// --- extractField: an empty field must not swallow the next line -----------
//
// `\s` matches newlines (deliberately — a value on the next line still
// reads). Without a guard, an EMPTY field captured the following contract
// line instead: `CANNOT_VERIFY:\nFINDINGS: []` yielded "FINDINGS: []", which
// parseCannotVerify treated as a real complaint and parked a task whose
// review was fine.
check('extractField: empty field does not eat the next contract line', F.extractField('CANNOT_VERIFY:\nFINDINGS: []', 'CANNOT_VERIFY'), null);
check('extractField: empty CANNOT_VERIFY therefore reads as none', F.parseCannotVerify('VERDICT: approve\nCANNOT_VERIFY:\nFINDINGS: []'), null);
check('extractField: a value on the next line is still read', F.extractField('VERDICT:\napprove', 'VERDICT'), 'approve');
check('extractField: same-line value', F.extractField('VERDICT: approve\nFINDINGS: []', 'VERDICT'), 'approve');
check('extractField: absent label -> null', F.extractField('FINDINGS: []', 'VERDICT'), null);

// --- truncatedPaths ---------------------------------------------------------
check('truncated: null envelope -> []', F.truncatedPaths(null), []);
check('truncated: no data -> []', F.truncatedPaths({ ok: true }), []);
check('truncated: field absent -> []', F.truncatedPaths({ data: { path: 'x' } }), []);
check('truncated: not an array -> []', F.truncatedPaths({ data: { truncated: 'oops' } }), []);
check('truncated: empty list -> []', F.truncatedPaths({ data: { truncated: [] } }), []);
check(
  'truncated: entries are rendered with path and hidden count',
  F.truncatedPaths({ data: { truncated: [{ path: 'a.py', hidden_lines: 12 }, { path: 'b.ts', hidden_lines: 3 }] } }),
  ['a.py (+12 lines hidden)', 'b.ts (+3 lines hidden)'],
);

// --- parseReviewerVerdict ---------------------------------------------------
check('reviewer: approve with empty findings', F.parseReviewerVerdict('VERDICT: approve\nFINDINGS: []').verdict, 'approve');
const good = F.parseReviewerVerdict('VERDICT: request-changes\nFINDINGS: [{"severity":"bug","file":"a.py","line":1,"quote":"x","summary":"y"}]');
check('reviewer: well-formed findings parse', good.findings.length, 1);
check('reviewer: PATCHES wins over VERDICT', F.parseReviewerVerdict('PATCHES: [{"file":"a.py","search":"x","replace":"y"}]').kind, 'patches');
check('reviewer: unparseable defaults to request-changes (fail closed)', F.parseReviewerVerdict('lgtm, ship it').verdict, 'request-changes');
check('reviewer: unparseable has no findings', F.parseReviewerVerdict('lgtm, ship it').findings, []);

// --- parseStatus ------------------------------------------------------------
check('status: DONE', F.parseStatus('STATUS: DONE\nFILES: a.py'), 'DONE');
check('status: DONE_WITH_CONCERNS', F.parseStatus('STATUS: DONE_WITH_CONCERNS'), 'DONE_WITH_CONCERNS');
check('status: BLOCKED', F.parseStatus('STATUS: BLOCKED\nreason'), 'BLOCKED');
check('status: NEEDS_CONTEXT', F.parseStatus('STATUS: NEEDS_CONTEXT'), 'NEEDS_CONTEXT');
checkTrue('status: prose without a STATUS line is not DONE', F.parseStatus('I finished the task') !== 'DONE');

// --- parseReReview: ADDRESSED / REFUTED / anything else ---------------------
const rr = F.parseReReview('FINDINGS: [{"summary":"a","verdict":"ADDRESSED"},{"summary":"b","verdict":"REFUTED"},{"summary":"c","verdict":"NOT ADDRESSED"}]');
check('re-review: all three verdicts parse', rr.map((f) => f.verdict), ['ADDRESSED', 'REFUTED', 'NOT ADDRESSED']);
check('re-review: garbage -> empty (caller fails closed)', F.parseReReview('everything looks fine now'), []);

// --- coerceRelayFields: the three historical drift shapes -------------------
//
// Each of these actually arrived from a haiku relay in production and each
// broke the run once. They are the reason the relay contract is defensive.
check(
  'relay drift 1: data delivered as a JSON string',
  F.coerceRelayFields({ ok: true, reason: null, hint: null, data: '{"task_id":"007"}' }).data,
  { task_id: '007' },
);
const drift2 = F.coerceRelayFields({ ok: true, reason: 'null', hint: 'null', data: '{"halt":"all-done"}' });
check('relay drift 2: the STRING "null" becomes real null (reason)', drift2.reason, null);
check('relay drift 2: the STRING "null" becomes real null (hint)', drift2.hint, null);
check(
  'relay drift 3: a whole envelope nested inside data is unwrapped',
  F.coerceRelayFields({ ok: true, reason: null, hint: null, data: { ok: true, reason: null, hint: null, data: { sha: 'abc' } } }).data,
  { sha: 'abc' },
);
check('relay: a normal envelope is left alone', F.coerceRelayFields({ ok: true, reason: null, hint: null, data: { x: 1 } }).data, { x: 1 });

// --- looksLikeEnvelope ------------------------------------------------------
checkTrue('envelope: recognises the real shape', F.looksLikeEnvelope({ ok: true, reason: null, hint: null, data: null }));
checkTrue('envelope: a plain payload is not an envelope', !F.looksLikeEnvelope({ task_id: '001', boundary: 'services/api' }));

// --- declaredOnly -----------------------------------------------------------
check('declaredOnly: empty violation set is NOT "declared only"', F.declaredOnly([]), false);
check('declaredOnly: all declared', F.declaredOnly([{ check: 'declared', detail: 'x' }]), true);
check('declaredOnly: a ci failure mixed in blocks the shortcut', F.declaredOnly([{ check: 'declared' }, { check: 'ci' }]), false);
check('declaredOnly: a boundary violation blocks the shortcut', F.declaredOnly([{ check: 'boundary', detail: 'x' }]), false);

// --- shQuote: arbitrary text must survive the shell ------------------------
//
// Concern text carries file paths, semicolons and free prose straight into a
// relay's command string. Anything that re-enters the shell as syntax here is
// a command-injection bug, not a formatting nit.
check('shQuote: plain text', F.shQuote('hello world'), `'hello world'`);
check('shQuote: single quote is escaped, not dropped', F.shQuote("it's fine"), `'it'\\''s fine'`);
checkTrue('shQuote: $VAR is inside single quotes', F.shQuote('$HOME and `id`').startsWith(`'`));
checkTrue('shQuote: a quote-and-semicolon injection attempt stays quoted', F.shQuote(`'; rm -rf /; echo '`).includes(`\\'`));
check('shQuote: newlines survive', F.shQuote('a\nb'), `'a\nb'`);

// --- isRepoRootBoundary -----------------------------------------------------
checkTrue('root boundary: "."', F.isRepoRootBoundary('.'));
checkTrue('root boundary: empty string', F.isRepoRootBoundary(''));
checkTrue('root boundary: "./"', F.isRepoRootBoundary('./'));
checkTrue('root boundary: trailing slashes', F.isRepoRootBoundary('.//'));
checkTrue('root boundary: a service path is NOT root', !F.isRepoRootBoundary('services/api'));
checkTrue('root boundary: a dotted path is NOT root', !F.isRepoRootBoundary('./services/api'));

// --- severityRank / findingKey / unionFindings ------------------------------
// Polling the reviewer k times and unioning the findings is the fix for the
// measured failure of the one-poll gate: over 28 real review packages polled
// three times each, 8 of 9 distinct blocking defects were raised by exactly
// one poll. These three functions are the whole of that union, so a bug here
// silently reverts the gate to one poll's worth of coverage.

const poll = (kind, verdict, findings) => ({ verdict: { kind, verdict, findings } });

check('severityRank: security outranks bug', F.severityRank({ severity: 'security' }) > F.severityRank({ severity: 'bug' }), true);
check('severityRank: bug outranks pattern-violation', F.severityRank({ severity: 'bug' }) > F.severityRank({ severity: 'pattern-violation' }), true);
check('severityRank: pattern-violation outranks minor', F.severityRank({ severity: 'pattern-violation' }) > F.severityRank({ severity: 'minor' }), true);
check('severityRank: unknown severity ranks 0', F.severityRank({ severity: 'whatever' }), 0);
check('severityRank: missing severity ranks 0', F.severityRank({}), 0);
check('severityRank: case-insensitive', F.severityRank({ severity: 'BUG' }), F.severityRank({ severity: 'bug' }));

check('findingKey: same file and line collide', F.findingKey({ file: 'a/b.py', line: 42 }), F.findingKey({ file: 'A/B.py', line: 42 }));
checkTrue('findingKey: different lines do NOT collide', F.findingKey({ file: 'a.py', line: 1 }) !== F.findingKey({ file: 'a.py', line: 2 }));
checkTrue('findingKey: different files do NOT collide', F.findingKey({ file: 'a.py', line: 1 }) !== F.findingKey({ file: 'b.py', line: 1 }));
checkTrue('findingKey: two file-less findings with different summaries do NOT collide',
  F.findingKey({ summary: 'one thing' }) !== F.findingKey({ summary: 'another thing' }));
check('findingKey: a non-numeric line degrades to the file alone',
  F.findingKey({ file: 'a.py', line: 'x' }), F.findingKey({ file: 'a.py' }));

// The real measured case: task 027 of the replay. Two polls called the leaked
// db engine `minor`, the third called the same line a `bug`. Downgrading it
// would have turned a blocking finding into an advisory one.
const t027 = F.unionFindings([
  poll('verdict', 'approve', [{ severity: 'minor', file: '__main__.py', line: 66, summary: 'leaks the engine' }]),
  poll('verdict', 'approve', [{ severity: 'minor', file: '__main__.py', line: 66, summary: 'same, worded differently' }]),
  poll('verdict', 'request-changes', [{ severity: 'bug', file: '__main__.py', line: 66, summary: 'same defect' }]),
]);
check('union: one defect seen by three polls stays one finding', t027.length, 1);
check('union: the most severe reading wins', t027[0].severity, 'bug');

// The dominant case: eight of nine defects were seen by exactly one poll.
const spread = F.unionFindings([
  poll('verdict', 'request-changes', [{ severity: 'bug', file: 'a.py', line: 1, summary: 'a' }]),
  poll('verdict', 'approve', []),
  poll('verdict', 'request-changes', [{ severity: 'pattern-violation', file: 'b.py', line: 2, summary: 'b' }]),
]);
check('union: minority findings from different polls all survive', spread.length, 2);

check('union: no polls -> no findings', F.unionFindings([]).length, 0);
check('union: every poll approved with nothing -> no findings',
  F.unionFindings([poll('verdict', 'approve', []), poll('verdict', 'approve', [])]).length, 0);
check('union: a PATCHES poll contributes no findings',
  F.unionFindings([{ verdict: { kind: 'patches', patches: [{ file: 'a.py' }] } }]).length, 0);
check('union: junk inside FINDINGS is skipped, not crashed on',
  F.unionFindings([poll('verdict', 'request-changes', ['nonsense', null, 7, { severity: 'bug', file: 'a.py', line: 1 }])]).length, 1);
checkTrue('union: a null poll does not throw', F.unionFindings([null, poll('verdict', 'approve', [])]).length === 0);

if (failures) {
  console.error(`\n${failures} assertion(s) failed`);
  process.exitCode = 1;
}
