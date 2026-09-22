#!/usr/bin/env node
// workflow-noroles-harness.mjs — мини-стенд для skills/build/workflow.mjs.
//
// Зачем: сценарий «ролей механики нет» (финальное ревью, находка C1) нельзя
// проверить ни grep'ом, ни парсер-тестами — он живёт в ПОРЯДКЕ диспатчей:
// узкая роль, которой нет на диске, не должна диспатчиться вовсе, потому что
// пустой ответ на не-retryable команде (save-review, finalize, установка
// фазы) бросает исключение до запасной попытки, а повтор запрещён законом
// недублирования. До этого стенда ни одного теста на сценарий не
// существовало — поэтому дефект и дожил до финального ревью.
//
// Как работает: тело workflow.mjs исполняется как AsyncFunction (та же
// обвязка, что у sanity-parse и у реального Workflow-раннера), а хук agent()
// подменён:
//   - agentType mvp-* -> null: роль не существует/не зарегистрирована —
//     ровно то, что возвращает реальный раннер на неизвестный agentType;
//   - relay-диспатчи (по схеме {ok,...} или {line}) РЕАЛЬНО исполняют
//     команду из промпта через bash и возвращают последнюю строку stdout —
//     конвейер двигают настоящие lib-скрипты на настоящей git-фикстуре;
//   - свободнотекстовые диспатчи скриптованы по label: implementer пишет
//     файлы из env IMPL_FILES и отвечает STATUS: DONE, reviewer отвечает
//     approve.
//
// env: WF_PROJECT (корень фикстуры), WF_ARGS (JSON args Workflow),
//      IMPL_FILES (csv файлов, которые «пишет» имплементер).
// stdout: одна строка JSON {result, calls:[{agentType,label}], logs:[...]}.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const WF = path.join(here, '..', '..', 'skills', 'build', 'workflow.mjs');

const project = process.env.WF_PROJECT;
const wfArgs = JSON.parse(process.env.WF_ARGS);
const implFiles = (process.env.IMPL_FILES || '').split(',').filter(Boolean);

const calls = [];
const logs = [];

// Команда — вторая строка релей-промпта (обе формы промпта в workflow.mjs
// кладут её туда: «Run exactly this command via Bash...\n<cmd>\n...»).
function extractCmd(prompt) {
  return String(prompt).split('\n')[1];
}

function runCmd(cmd) {
  const res = spawnSync('bash', ['-c', cmd], { encoding: 'utf8' });
  const lines = (res.stdout || '').trim().split('\n');
  return lines[lines.length - 1] || '';
}

async function agentStub(prompt, opts = {}) {
  calls.push({ agentType: opts.agentType || null, label: opts.label || null });
  // Роли механики в этой фикстуре не существуют: реальный раннер на
  // неизвестный agentType возвращает пустой результат, не исключение.
  if (opts.agentType && String(opts.agentType).startsWith('mvp-')) return null;
  const props = opts.schema && opts.schema.properties;
  if (props && props.line) return { line: runCmd(extractCmd(prompt)) };
  if (props && props.ok) {
    const last = runCmd(extractCmd(prompt));
    try {
      return JSON.parse(last);
    } catch {
      return null;
    }
  }
  const label = String(opts.label || '');
  if (label.startsWith('implementer')) {
    for (const f of implFiles) {
      const p = path.join(project, f);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, 'HELLO\n');
    }
    return `STATUS: DONE\nFILES: ${implFiles.join(', ')}`;
  }
  if (label.startsWith('reviewer')) return 'VERDICT: approve\nCANNOT_VERIFY: none\nFINDINGS: []';
  throw new Error(`harness: неожиданный свободнотекстовый диспатч label=${label}`);
}

const src = fs.readFileSync(WF, 'utf8').replace(/^export const meta[\s\S]*?^}/m, '');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('agent', 'parallel', 'pipeline', 'log', 'phase', 'args', 'budget', 'workflow', src);

const result = await run(
  agentStub,
  null,
  null,
  (m) => logs.push(String(m)),
  null,
  wfArgs,
  { spent: () => 0 },
  null,
);
process.stdout.write(JSON.stringify({ result, calls, logs }) + '\n');
