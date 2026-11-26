// The Desk's Settings (docs/desk.md → Settings): the work/CONFIG.md keys the page shows and the
// page's owner changes, with their kinds, limits and defaults as docs/config.md states them. A key
// outside this table is never written from the page.
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { writeFile } from './lib.mjs';

const SW = { type: 'switch', values: ['enabled', 'disabled'] };
const PUB = { type: 'enum', values: ['dam', 'off'] };
export const KEYS = {
  review_progress: { ...SW, def: 'disabled' },
  approve_after_rounds: { type: 'int_off', min: 1, max: 10, def: 'off', label: 'Approve from round', about: 'From this round on, no open critical finding means Approve; the warnings stay listed.' },
  rereview_trigger: { type: 'enum', values: ['label', 'review-request', 'both'], def: 'label', label: 'What asks for a re-review', about: 'The re-review label, a review request to the bot, or both.' },
  ci_triage: { ...SW, def: 'disabled' },
  mention_replies: { ...SW, def: 'enabled' },
  mention_authors: { type: 'enum', values: ['collaborators', 'anyone'], def: 'collaborators', label: 'Whose mentions', about: 'Only the repository\'s collaborators, or anyone.' },
  human_review_paths: { type: 'text', re: /^[A-Za-z0-9_*./ ,{}-]{0,300}$/, def: '', label: 'Paths a person must review', about: 'Comma-separated globs, for example migrations/*, src/auth/*. A PR that changes one never auto-merges.' },
  agent_fixes: { ...SW, def: 'disabled' },
  auto_merge: { ...SW, def: 'disabled' },
  auto_merge_max_lines: { type: 'int', min: 1, max: 5000, def: '100', label: 'Largest change that merges', about: 'Added plus deleted lines.' },
  auto_merge_method: { type: 'enum', values: ['squash', 'merge', 'rebase'], def: 'squash', label: 'How it merges' },
  slack_notifications: { ...SW, def: 'disabled' },
  merge_ready_nudge: { ...SW, def: 'disabled' },
  shepherd_scope: { type: 'enum', values: ['needs_human', 'all'], def: 'needs_human', label: 'Which PRs get reminders', about: 'Only the PRs that need a human review, or every waiting PR.' },
  daily_brief: { ...SW, def: 'disabled' },
  brief_language: { type: 'text', re: /^[A-Za-z][A-Za-z ]{1,29}$/, def: 'English', label: 'Language of the brief', about: 'A plain name, for example English or Czech.' },
  monitor_slack_direct: { ...SW, def: 'disabled' },
  audit_report: { ...SW, def: 'enabled' },
  audit_trend: { ...PUB, def: 'dam', label: 'Trend page', about: 'Publish the weekly trend page, or keep only the history.' },
  audit_infographic: { ...SW, def: 'disabled', label: 'Infographic', about: 'An image of the week with the report.' },
  survey: { ...SW, def: 'disabled' },
  survey_interval_days: { type: 'int', min: 1, max: 60, def: '7', label: 'Days between passes' },
  survey_report: { ...PUB, def: 'dam', label: 'Survey page' },
  benchmark: { ...SW, def: 'disabled' },
  benchmark_report: { ...PUB, def: 'dam', label: 'Benchmark page' },
  health_dashboard: { ...PUB, def: 'off', label: 'Health dashboard', about: 'Publish the health dashboard, or keep only the history.' },
  stall_alert_threshold: { type: 'int', min: 1, max: 50, def: '4', label: 'Stalled reviews a day before an incident' },
  model_alert_threshold: { type: 'int', min: 1, max: 20, def: '2', label: 'Model failures before an alert' },
  github_alert_threshold: { type: 'int', min: 1, max: 20, def: '2', label: 'GitHub failures before an alert' },
  classifier_alert_threshold: { type: 'int_off', min: 1, max: 200, def: '20', label: 'Refused commands a day before an incident' },
  review_anomaly_factor: { type: 'int_off', min: 1, max: 20, def: '4', label: 'Unusual review: times the median', about: 'A review this many times dearer, slower or larger than usual records an incident.' },
  log_level: { type: 'enum', values: ['info', 'debug'], def: 'info', label: 'Log detail', about: 'Debug also logs each tool call that worked.' },
  // Shown, not changed here: the schedules follow them, and the labels live in GitHub too.
  active_hours: { type: 'fixed', def: '00-23', label: 'Active hours' },
  active_days: { type: 'fixed', def: 'Mon-Sun', label: 'Active days' },
  review_interval_active: { type: 'fixed', def: '5', label: 'Minutes between checks, active' },
  review_interval_quiet: { type: 'fixed', def: '15', label: 'Minutes between checks, quiet' },
  rereview_label: { type: 'fixed', def: '', label: 'Re-review label' },
  rereview_delta_label: { type: 'fixed', def: '', label: 'Delta re-review label' },
  guide_label: { type: 'fixed', def: '', label: 'Review guide label' },
  urgent_label: { type: 'fixed', def: '', label: 'Urgent label' },
  auto_merge_label: { type: 'fixed', def: '', label: 'Auto-merge label' },
  agent_fix_label: { type: 'fixed', def: '', label: 'Fix label' },
};

// What Code Guardian does, grouped by when: a feature has its switch and the settings that open under it.
export const FEATURES = [
  { id: 'progress', group: 'pr', title: 'Progress comment', about: 'One comment on the PR that says where the review stands while it runs.', switch: 'review_progress', keys: [] },
  { id: 'rounds', group: 'pr', title: 'Rounds and approval', about: 'What asks for a new round, and from which round a review approves when nothing critical is open.', switch: null, keys: ['rereview_trigger', 'approve_after_rounds', 'human_review_paths'] },
  { id: 'ci', group: 'pr', title: 'CI triage', about: 'After a review, Code Guardian reads the failed checks and says which failure the change caused.', switch: 'ci_triage', keys: [] },
  { id: 'mentions', group: 'pr', title: 'Answers to mentions', about: 'Code Guardian answers a person who mentions it on a PR.', switch: 'mention_replies', keys: ['mention_authors'] },
  { id: 'fixes', group: 'merge', title: 'Fixes by Code Guardian', about: 'On a PR with the fix label, Code Guardian pushes a fix for its blocking findings.', switch: 'agent_fixes', keys: ['agent_fix_label'] },
  { id: 'automerge', group: 'merge', title: 'Auto-merge', about: 'A small approved PR with the consent label merges by itself.', switch: 'auto_merge', keys: ['auto_merge_max_lines', 'auto_merge_method', 'auto_merge_label'] },
  { id: 'slack', group: 'slack', title: 'Slack', about: 'Everything Code Guardian says on Slack: alerts, reminders, reports. Off, it says nothing there.', switch: 'slack_notifications', keys: [] },
  { id: 'nudges', group: 'slack', title: 'Reminders to reviewers', about: 'Reminds the human reviewers of a waiting PR, and says once when an approved PR is ready to land.', switch: null, keys: ['shepherd_scope', 'merge_ready_nudge'] },
  { id: 'brief', group: 'slack', title: 'Morning brief', about: 'Each weekday morning, one message on the PRs merged since the last one.', switch: 'daily_brief', keys: ['brief_language'] },
  { id: 'audit', group: 'week', title: 'Weekly audit', about: 'Each week Code Guardian checks its own work and reports what to change.', switch: 'audit_report', keys: ['audit_trend', 'audit_infographic'] },
  { id: 'survey', group: 'week', title: 'Security survey', about: 'A slow pass over one area of the code at a time, for security problems only.', switch: 'survey', keys: ['survey_interval_days', 'survey_report'] },
  { id: 'benchmark', group: 'week', title: 'Benchmark', about: 'How well the review finds known defects, measured version by version.', switch: 'benchmark', keys: ['benchmark_report'] },
  { id: 'health', group: 'health', title: 'Health check', about: 'Code Guardian watches its own runs and tells the operator when something stops.', switch: null, keys: ['health_dashboard', 'monitor_slack_direct', 'model_alert_threshold', 'github_alert_threshold', 'stall_alert_threshold', 'classifier_alert_threshold', 'review_anomaly_factor', 'log_level'] },
];
KEYS.merge_ready_nudge.label = 'Say when a PR is ready to land'; KEYS.merge_ready_nudge.about = 'One Slack message when an approved, green PR can merge.';
KEYS.monitor_slack_direct.label = 'Alerts straight to Slack'; KEYS.monitor_slack_direct.about = 'The health check sends its alerts itself, with no model in the loop.';
export const FIXED_GROUPS = [['When it works', ['active_hours', 'active_days', 'review_interval_active', 'review_interval_quiet'], 'The review schedules follow these. The operator changes them, and the schedules with them.'],
  ['Labels', ['rereview_label', 'rereview_delta_label', 'guide_label', 'urgent_label', 'auto_merge_label', 'agent_fix_label'], 'People add these labels on GitHub to ask Code Guardian for something.']];

const BULLET = (k) => new RegExp(`^- ${k}:[ \\t]*(.*)$`, 'm');
const valueOf = (text, k) => { const m = BULLET(k).exec(text); if (!m) return null; return m[1].replace(/\s+#.*$/, '').trim().replace(/^(['"`])(.*)\1$/, '$2'); };

export function settingsOf(work) {
  const text = existsSync(join(work, 'CONFIG.md')) ? readFileSync(join(work, 'CONFIG.md'), 'utf8') : '';
  const keys = Object.fromEntries(Object.entries(KEYS).map(([k, d]) => { const raw = valueOf(text, k), v = raw ?? d.def;
    const ok = check(k, v) === null || raw === null; return [k, { ...d, re: undefined, value: ok ? v : d.def, raw, invalid: !ok }]; }));
  return { keys, features: FEATURES, fixed: FIXED_GROUPS };
}

// null when the value fits the key, else why not.
export function check(key, value) {
  const d = KEYS[key]; const v = String(value ?? '').trim();
  if (!d || d.type === 'fixed') return 'This setting is not changed on the Desk.';
  if (d.type === 'switch' || d.type === 'enum') return d.values.includes(v) ? null : `Choose one of: ${d.values.join(', ')}.`;
  if (d.type === 'int' || d.type === 'int_off') return (d.type === 'int_off' && v === 'off') || (/^\d{1,5}$/.test(v) && +v >= d.min && +v <= d.max) ? null : `Write a number from ${d.min} to ${d.max}${d.type === 'int_off' ? ', or off' : ''}.`;
  if (d.type === 'text') return d.re.test(v) ? null : 'This value has letters the setting does not take.';
  return 'Unknown setting.';
}

// Writes one bullet: in place when the key has one, else after the file's first block of bullets.
export function setValue(work, key, value) {
  const why = check(key, value); if (why) throw new Error(why);
  const f = join(work, 'CONFIG.md'), text = existsSync(f) ? readFileSync(f, 'utf8') : '# Code Guardian configuration\n', v = String(value).trim();
  const old = valueOf(text, key), line = `- ${key}: ${v}`;
  let out;
  if (BULLET(key).test(text)) out = text.replace(BULLET(key), line);
  else { const ls = text.split('\n'); let at = -1; for (let k = 0; k < ls.length; k++) { if (/^- [a-z_]+:/.test(ls[k])) at = k; else if (at >= 0 && /^## /.test(ls[k])) break; }
    ls.splice(at >= 0 ? at + 1 : ls.length, 0, line); out = ls.join('\n'); }
  writeFile(f, out);
  return { key, old, value: v };
}
