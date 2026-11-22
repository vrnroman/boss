// Routing quiz: how well a Boss model routes instructions that name no session, given each session's
// recent work. Real Boss + two real workers; prints accuracy and decision latency.
//   BOSS_MODEL=haiku node e2e/routing-quiz.mjs      BOSS_MODEL=sonnet node e2e/routing-quiz.mjs
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { makeHome, startWorker, Client, killAll, liveSessions, sleep, REPO, BOSS_NAME, cleanProjects } from './lib.mjs';

const MODEL = process.env.BOSS_MODEL ?? 'haiku';
const ROOT = join(tmpdir(), `boss-quiz-${MODEL}-${process.pid}`);
const PORT = 8797;
const W = { alpha: join(ROOT, 'w', 'payments-service'), beta: join(ROOT, 'w', 'landing-site') };
mkdirSync(W.alpha, { recursive: true });
mkdirSync(W.beta, { recursive: true });
writeFileSync(join(W.alpha, 'fee.js'), 'export const fee = (a) => a * 0.029 + 0.3;\n');
writeFileSync(join(W.beta, 'index.html'), '<h1>Welcome to Acme, the fastest way to move money</h1>\n');
killAll();
const home = makeHome(join(ROOT, 'home'));
const env = { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_TMUX_SOCKET: 'bt', BOSS_TMUX_SESSION: BOSS_NAME, BOSS_NAME, BOSS_ALLOW: 'bt-*', BOSS_MODEL: MODEL };
await Promise.all([startWorker('bt-alpha', W.alpha), startWorker('bt-beta', W.beta)]);
spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), 'start'], { env });
const c = new Client(PORT, home.token);
await c.listen();
const sessions = () => {
  // Same as the app: name, cwd, status and the Claude Code session id.
  const out = [];
  for (const s of liveSessions()) out.push(s);
  const dir = join(process.env.HOME, '.claude', 'sessions');
  for (const f of spawnSync('ls', [dir], { encoding: 'utf8' }).stdout.split('\n').filter((x) => x.endsWith('.json'))) {
    try { const j = JSON.parse(spawnSync('cat', [join(dir, f)], { encoding: 'utf8' }).stdout); const o = out.find((x) => x.name === j.name); if (o) o.sessionId = j.sessionId; } catch {}
  }
  return out;
};
let n = 0;
async function speak(text) {
  const id = `quiz_${process.pid}_${++n}`;
  const t0 = Date.now();
  await c.http('POST', '/utterance', { id, text, mode: 'talk', lang: 'en', sessions: sessions() });
  return { id, t0 };
}
// Give each worker a topic.
for (const [w, task] of [['bt-alpha', 'bt-alpha: in fee.js, add a comment above the fee function saying it is the card fee calculator, then report back.'],
                         ['bt-beta', 'bt-beta: in index.html, add a subtitle under the headline saying "Pay anyone in seconds", then report back.']]) {
  const { t0 } = await speak(task);
  await c.until((e) => e.event === 'say' && e.data.kind === 'report' && e.data.session === w && e.t > t0, 180_000, `${w} report`);
}
await sleep(4000); // let follow-up windows pass so last_target does not decide
const quiz = [
  ['Make that calculator round the result to whole cents.', 'bt-alpha'],
  ['Make the headline shorter, five words at most.', 'bt-beta'],
  ['Change the fixed part of the fee from 30 cents to 25 cents.', 'bt-alpha'],
  ['Put the subtitle in italics.', 'bt-beta'],
  ['Run the tests.', 'ASK'],
];
const rows = [];
for (const [text, want] of quiz) {
  await sleep(6000);
  const { id, t0 } = await speak(text);
  const e = await c.until((e) => (e.event === 'confirm' && e.data.utterance_id === id) || (e.event === 'ask' && e.data.about_id === id)
    || (e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent'), 90_000, 'decision').catch(() => null);
  const got = !e ? 'none' : e.event === 'ask' ? 'ASK' : e.data.target;
  rows.push({ text, want, got, ok: got === want, decision_s: e ? ((e.t - t0) / 1000).toFixed(1) : '-' });
  if (e?.event === 'ask') await c.http('POST', '/answer', { question_id: e.data.question_id, text: 'bt-alpha' });
  await sleep(4000);
}
console.log(JSON.stringify({ model: MODEL, correct: rows.filter((r) => r.ok).length, of: rows.length, rows }, null, 2));
spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), 'stop'], { env });
c.close(); killAll(); cleanProjects(ROOT);
process.exit(0);
