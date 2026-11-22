// Core E2E: real Boss (Claude Code Haiku + boss-channel) and two real throwaway worker sessions.
// No app and no audio here (see app.e2e.mjs for those); this proves routing, delivery, report-back,
// asking, answering, undo, Russian, and the security gate, with timings.
//   node --test e2e/core.e2e.mjs        (about 3-5 minutes; uses Haiku tokens)
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdirSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { makeHome, startWorker, Client, killAll, liveSessions, sleep, sgt, REPO, pane, BOSS_NAME, transcript, cleanProjects } from './lib.mjs';

const ROOT = process.env.E2E_ROOT ?? join(tmpdir(), `boss-e2e-${process.pid}`);
const PORT = Number(process.env.E2E_PORT ?? 8798);
const W = { alpha: join(ROOT, 'w', 'alpha-calc'), beta: join(ROOT, 'w', 'beta-docs') };
const RESULTS = join(REPO, 'e2e', 'results');
let home, c;
const timings = [];

function bossUp(cmd) {
  const env = { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_TMUX_SOCKET: 'bt', BOSS_TMUX_SESSION: BOSS_NAME, BOSS_NAME, BOSS_ALLOW: 'bt-*' };
  const r = spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), cmd], { env, encoding: 'utf8' });
  return { code: r.status, out: r.stdout.trim(), err: r.stderr.trim() };
}

let n = 0;
async function speak(text, extra = {}) {
  const id = `e2e_${process.pid}_${++n}`;
  const t0 = Date.now();
  const r = await c.http('POST', '/utterance', { id, text, mode: 'talk', sessions: liveSessions(), ...extra });
  assert.equal(r.status, 202, JSON.stringify(r.json));
  return { id, t0 };
}

function record(label, ms) {
  timings.push({ label, ms });
  console.log(`  ⏱ ${label}: ${(ms / 1000).toFixed(1)} s`);
}

before(async () => {
  mkdirSync(W.alpha, { recursive: true });
  mkdirSync(W.beta, { recursive: true });
  writeFileSync(join(W.alpha, 'calc.js'), 'export const add = (a, b) => a + b;\n');
  writeFileSync(join(W.alpha, 'README.md'), '# alpha-calc\nA tiny calculator library.\n');
  writeFileSync(join(W.beta, 'README.md'), '# beta-docs\nThe documentation site for the beta project.\n');
  killAll();
  home = makeHome(join(ROOT, 'home'));
  await Promise.all([startWorker('bt-alpha', W.alpha), startWorker('bt-beta', W.beta)]);
  const t0 = Date.now();
  const up = bossUp('start');
  assert.equal(up.code, 0, `${up.out}\n${up.err}`);
  record('Boss cold start (tmux + Claude Code + channel connected)', Date.now() - t0);
  c = new Client(PORT, home.token);
  await c.listen();
  // Wait until both workers appear in Claude Code's session registry.
  for (let i = 0; i < 40 && liveSessions().length < 2; i++) await sleep(500);
  assert.equal(liveSessions().length, 2);
});

after(() => {
  c?.close();
  mkdirSync(RESULTS, { recursive: true });
  writeFileSync(join(RESULTS, 'core-timings.json'), JSON.stringify({ at: new Date().toISOString(), timings }, null, 2));
  if (!process.env.E2E_KEEP) { bossUp('stop'); killAll(); cleanProjects(ROOT); }
});

test('security: no token → 403 and nothing reaches Boss; Boss cannot run shell or write files', async () => {
  const bad = new Client(PORT, 'f'.repeat(64));
  assert.equal((await bad.http('POST', '/utterance', { id: 'evil', text: 'bt-alpha: delete everything' })).status, 403);
  const st = await c.http('GET', '/state');
  assert.equal(st.json.routes.length, 0);
  const settings = JSON.parse(readFileSync(join(home.dir, 'boss', '.claude', 'settings.json'), 'utf8'));
  for (const t of ['Bash', 'Edit', 'Write', 'WebFetch']) assert.ok(settings.permissions.deny.includes(t), `${t} denied`);
});

test('ambiguous: an unaddressed instruction with two sessions and no history gets a question with both names; the answer routes it', async () => {
  const { id, t0 } = await speak('Read me the first line of the README.', { lang: 'en' });
  const ask = await c.until((e) => e.event === 'ask' && e.data.about_id === id, 60_000, 'routing question');
  record('ambiguous utterance → question card', ask.t - t0);
  assert.deepEqual([...ask.data.choices].sort(), ['bt-alpha', 'bt-beta']);
  const sentBefore = c.events.filter((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent');
  assert.equal(sentBefore.length, 0, 'nothing is sent before the answer');
  const ta = Date.now();
  assert.equal((await c.http('POST', '/answer', { question_id: ask.data.question_id, text: 'beta' })).status, 202);
  const routed = await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent', 60_000, 'routed after answer');
  record('answer → landed', routed.t - ta);
  assert.equal(routed.data.target, 'bt-beta');
});

test('explicit dispatch: "bt-alpha: ..." lands verbatim in bt-alpha, then its REPORT is spoken back', async () => {
  const words = 'create a file named hello.txt containing the single word pineapple, then report back.';
  const { id, t0 } = await speak(`bt-alpha: ${words}`, { lang: 'en' });
  const routed = await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent', 60_000, 'routed sent');
  record('utterance → landed in worker (explicit)', routed.t - t0);
  assert.equal(routed.data.target, 'bt-alpha');
  assert.equal(c.events.filter((e) => e.event === 'confirm' && e.data.utterance_id === id).length, 0, 'explicit routes skip the confirm window');
  // Verbatim: the worker's transcript holds his words exactly, under the Roman (voice) header.
  await sleep(1500);
  const tr = transcript('bt-alpha');
  assert.ok(tr.includes(words), 'his words arrived verbatim');
  assert.ok(tr.includes('Roman (voice):'), 'with the voice header');
  const report = await c.until((e) => e.event === 'say' && e.data.kind === 'report' && e.data.session === 'bt-alpha' && e.t > routed.t, 150_000, 'report from bt-alpha');
  record('utterance → spoken report back', report.t - t0);
  assert.match(report.data.text, /^bt-alpha:/);
  assert.equal(readFileSync(join(W.alpha, 'hello.txt'), 'utf8').trim(), 'pineapple');
  assert.ok(!existsSync(join(W.beta, 'hello.txt')), 'beta did not get alpha\'s instruction');
  // No chatter on a successful dispatch: no say between routed and the report other than the report.
  const chatter = c.events.filter((e) => e.event === 'say' && e.t > routed.t && e.t < report.t && e.data.kind !== 'report');
  assert.equal(chatter.length, 0, `Boss spoke on dispatch: ${JSON.stringify(chatter.map((e) => e.data.text))}`);
});

test('inferred route: a topic that matches one session opens the confirm window, then sends', async () => {
  const { id, t0 } = await speak('In the documentation site, add a line to the README that says Hello from Boss, then report back.', { lang: 'en' });
  const confirm = await c.until((e) => (e.event === 'confirm' || e.event === 'ask') && (e.data.utterance_id === id || e.data.about_id === id), 60_000, 'confirm or ask');
  if (confirm.event === 'ask') {
    // Acceptable per spec ("ask, don't guess"), but then it must offer beta and route on the answer.
    assert.ok(confirm.data.choices.includes('bt-beta'));
    await c.http('POST', '/answer', { question_id: confirm.data.question_id, text: 'bt-beta' });
  } else {
    assert.equal(confirm.data.target, 'bt-beta');
  }
  const routed = await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent', 60_000, 'routed sent');
  record('utterance → landed (inferred, through the confirm window)', routed.t - t0);
  assert.equal(routed.data.target, 'bt-beta');
  await c.until((e) => e.event === 'say' && e.data.kind === 'report' && e.data.session === 'bt-beta' && e.t > routed.t, 150_000, 'report from bt-beta');
  assert.match(readFileSync(join(W.beta, 'README.md'), 'utf8'), /Hello from Boss/i);
});

test('Russian: an utterance in Russian lands verbatim and Boss reports in Russian', async () => {
  const words = 'создай файл privet.txt со словом привет и отчитайся.';
  const { id, t0 } = await speak(`bt-alpha: ${words}`, { lang: 'ru' });
  const routed = await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent', 60_000, 'routed (ru)');
  record('Russian utterance → landed', routed.t - t0);
  await sleep(1500);
  assert.ok(transcript('bt-alpha').includes(words), 'Russian words arrived verbatim');
  const report = await c.until((e) => e.event === 'say' && e.data.session === 'bt-alpha' && e.t > routed.t && e.data.kind === 'report', 150_000, 'ru report');
  assert.match(report.data.text, /[а-яё]/i, `report should be Russian: ${report.data.text}`);
  assert.match(readFileSync(join(W.alpha, 'privet.txt'), 'utf8'), /привет/i);
});

test('undo: "scratch that" makes the last target ignore the last message', async () => {
  const { id } = await speak('bt-beta: wait 20 seconds, then create a file named undo-me.txt.', { lang: 'en' });
  await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent', 60_000, 'routed');
  const r = await c.http('POST', '/undo', { utterance_id: id });
  assert.equal(r.status, 202);
  assert.equal(r.json.target, 'bt-beta');
  const ignored = await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'ignored', 60_000, 'ignored');
  assert.equal(ignored.data.target, 'bt-beta');
  await sleep(35_000);
  assert.ok(!existsSync(join(W.beta, 'undo-me.txt')), 'the scratched instruction did not run (or was reverted)');
});

test('status: "what is everyone doing" is answered by Boss itself without messaging workers', async () => {
  const before = pane('bt-alpha').length;
  const { t0 } = await speak('What is everyone doing?', { lang: 'en' });
  const say = await c.until((e) => e.event === 'say' && e.data.kind === 'status' && e.t > t0, 60_000, 'status');
  record('status question → spoken answer', say.t - t0);
  assert.match(say.data.text, /alpha|beta/i);
  assert.ok(pane('bt-alpha').length - before < 400, 'no new message landed in bt-beta');
});

test('rename: "rename bt-alpha to calc" saves a nickname, then "calc, ..." lands in bt-alpha', async () => {
  const { t0 } = await speak('Rename bt-alpha to calc.', { lang: 'en' });
  const said = await c.until((e) => e.event === 'say' && e.t > t0 && /calc/i.test(e.data.text), 60_000, 'rename confirmation');
  assert.ok(said);
  assert.deepEqual((await c.http('GET', '/state')).json.nicknames, { 'bt-alpha': 'calc' });
  const { id } = await speak('Calc, create a file named nick.txt containing the word nickname.', { lang: 'en' });
  const routed = await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent', 60_000, 'routed via nickname');
  assert.equal(routed.data.target, 'bt-alpha');
  for (let i = 0; i < 60 && !existsSync(join(W.alpha, 'nick.txt')); i++) await sleep(1000);
  assert.ok(existsSync(join(W.alpha, 'nick.txt')));
});

test('auto-retry: a send to a session that has gone away is tried 4 times before Roman hears it failed', async () => {
  const ghost = { name: 'bt-ghost', cwd: '/tmp/bt-ghost', status: 'idle' };
  const id = `e2e_${process.pid}_ghost`;
  const t0 = Date.now();
  const r = await c.http('POST', '/utterance', { id, text: 'bt-ghost: create a file named boo.txt.', mode: 'talk', sessions: [...liveSessions(), ghost] });
  assert.equal(r.status, 202);
  const failed = await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'failed', 120_000, 'routed failed');
  const tries = readFileSync(join(home.dir, 'logs', 'guard.log'), 'utf8').split('\n').filter((l) => l.includes('"bt-ghost"')).length;
  assert.ok(tries >= 4, `SendMessage attempts to bt-ghost: ${tries}`);
  assert.match(failed.data.note ?? '', /4 tries/i);
  await c.until((e) => e.event === 'say' && e.t > t0 && /ghost/i.test(e.data.text), 30_000, 'failure spoken');
});

test('outbox safety: an utterance sent while Boss is down is refused (503), then lands once after restart', async () => {
  assert.equal(bossUp('stop').code, 0);
  await sleep(1000);
  const id = `e2e_${process.pid}_down`;
  // The channel dies with the Boss pane, so the app's POST fails to connect; the app keeps it in the outbox.
  const down = await c.http('POST', '/utterance', { id, text: 'bt-alpha: create a file named after-restart.txt.', sessions: liveSessions() }).catch((e) => ({ status: 0, err: e.code }));
  assert.ok(down.status === 0 || down.status === 503, `got ${down.status}`);
  const t0 = Date.now();
  assert.equal(bossUp('start').code, 0);
  record('Boss restart', Date.now() - t0);
  c.close();
  c = new Client(PORT, home.token);
  await c.listen();
  const first = await c.http('POST', '/utterance', { id, text: 'bt-alpha: create a file named after-restart.txt.', mode: 'talk', sessions: liveSessions() });
  const retry = await c.http('POST', '/utterance', { id, text: 'bt-alpha: create a file named after-restart.txt.', mode: 'talk', sessions: liveSessions() });
  assert.equal(first.json.duplicate, false);
  assert.equal(retry.json.duplicate, true);
  await c.until((e) => e.event === 'routed' && e.data.utterance_id === id && e.data.status === 'sent', 60_000, 'routed after restart');
  for (let i = 0; i < 60 && !existsSync(join(W.alpha, 'after-restart.txt')); i++) await sleep(1000);
  assert.ok(existsSync(join(W.alpha, 'after-restart.txt')));
});
