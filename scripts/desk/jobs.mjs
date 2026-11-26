#!/usr/bin/env node
// jobs.mjs — the agent's side of the Desk (docs/desk.md → Jobs and questions). The Desk server records
// a press as a job J-<n> and a chat question as A-<n>; the page's ping names it. This reads and answers them:
//   node scripts/desk/jobs.mjs show J-<n>            → {id, command, label, item, note, role, state, may}
//   node scripts/desk/jobs.mjs start J-<n>
//   node scripts/desk/jobs.mjs done J-<n> <file>     the result for the person, two or three sentences
//   node scripts/desk/jobs.mjs fail J-<n> <file>     why it did not work
//   node scripts/desk/jobs.mjs ask A-<n>             → {id, text, context, role} the question and what was open
//   node scripts/desk/jobs.mjs answer A-<n> <file>   the answer, shown in the person's chat
// The role is the one of who pressed or asked (admin, developer, viewer); never an email.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { answer, asks, jobs, may, step, utc } from './lib.mjs';
import { build } from './data.mjs';

const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const DIR = join(WORK, 'desk'), JOBS = join(DIR, 'jobs.jsonl');
const [cmd, id, file] = process.argv.slice(2);
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
const text = () => { if (!file) throw new Error('name the file with the text'); return readFileSync(file, 'utf8').trim(); };
try {
  if (cmd === 'show') {
    const j = jobs(JOBS).find((x) => x.id === id); if (!j) throw new Error(`no job ${id}`);
    // A finding or a run the command names, as the page numbers them: what the agent acts on.
    const ref = /\b([FS])-(\d{1,6})\b/.exec(j.command ?? '');
    let about = null;
    if (ref) { const d = build(WORK); const x = ref[1] === 'F' ? d.findings.find((f) => f.id === ref[0]) : d.runs.find((r) => r.id === ref[0]);
      about = !x ? null : ref[1] === 'F' ? { pr: x.pr, file: x.file, line: x.line, summary: x.summary, state: x.state } : { run: x.run, job: x.job, start: x.start, end: x.end, errors: x.errors, warns: x.warns }; }
    out({ id: j.id, command: j.command, label: j.label, item: j.item, note: j.note, role: j.role, state: j.state, may: j.state === 'queued' && may(j.role, j.command), ...(ref ? { about } : {}) });
  } else if (cmd === 'start') out(step(JOBS, id, 'started', null, utc()));
  else if (cmd === 'done' || cmd === 'fail') out(step(JOBS, id, cmd === 'done' ? 'done' : 'failed', text(), utc()));
  else if (cmd === 'ask') { const a = asks(join(DIR, 'asks.jsonl')).find((x) => x.id === id); if (!a) throw new Error(`no question ${id}`); out({ id: a.id, text: a.text, context: a.context, role: a.role }); }
  else if (cmd === 'answer') out(answer(join(DIR, 'answers.jsonl'), id, text(), utc()));
  else throw new Error('usage: jobs.mjs show|start|done|fail J-<n> [file] · ask|answer A-<n> [file]');
} catch (e) { process.stderr.write(`jobs.mjs: ${e.message}\n`); process.exit(1); }
