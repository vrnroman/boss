// Real acoustic E2E: speech is played out of the Mac's speakers and picked up by the real
// microphone through the app's real capture path (AVAudioEngine, pre-roll, 16 kHz conversion),
// then whisper, Boss and a real worker. Also the real 6 s answer window: Boss's question is spoken
// by the app, then the answer is played into the room.
// Needs microphone access for the app process; skips (does not fail) when it has none.
//   node --test e2e/mic.e2e.mjs
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, openSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { request } from 'node:http';
import { makeHome, startWorker, killAll, sleep, REPO, BOSS_NAME, transcript, cleanProjects } from './lib.mjs';

const ROOT = join(tmpdir(), `boss-mic-e2e-${process.pid}`);
const PORT = 8795;
const W = { alpha: join(ROOT, 'w', 'alpha-calc'), beta: join(ROOT, 'w', 'beta-docs') };
const RESULTS = join(REPO, 'e2e', 'results');
const APP = join(REPO, 'app', 'build', 'Boss.app', 'Contents', 'MacOS', 'Boss');
let home, appProc, micOK = false;
let savedVolume = null;
const results = [];

function app(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? '' : JSON.stringify(body);
    const req = request({ host: '127.0.0.1', port: 8789, method, path, headers: { authorization: `Bearer ${home.token}`, 'content-length': String(Buffer.byteLength(data)), ...(data ? { 'content-type': 'application/json' } : {}) } }, (res) => {
      let t = ''; res.on('data', (c) => (t += c)); res.on('end', () => { let json; try { json = JSON.parse(t); } catch {} resolve({ status: res.statusCode, json }); });
    });
    req.on('error', reject); req.end(data);
  });
}
async function poll(fn, ms, label) {
  const t0 = Date.now();
  for (;;) { const v = await fn().catch(() => null); if (v) return v; if (Date.now() - t0 > ms) throw new Error(`timeout waiting for ${label}`); await sleep(250); }
}
function bossUp(cmd) {
  const env = { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_TMUX_SOCKET: 'bt', BOSS_TMUX_SESSION: BOSS_NAME, BOSS_NAME, BOSS_ALLOW: 'bt-*' };
  return spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), cmd], { env, encoding: 'utf8' }).status;
}
/** Plays text out of the speakers with a macOS voice; returns the clip length in seconds. */
function play(text, voice = 'Samantha') {
  const f = join(ROOT, `say-${Date.now()}.aiff`);
  execFileSync('say', ['-v', voice, '-o', f, text]);
  execFileSync('afplay', [f]);
}
const words = (s) => s.toLowerCase().replace(/[^a-zа-яё0-9 ]/gi, ' ').split(/\s+/).filter(Boolean);
function wordAccuracy(ref, hyp) {
  const r = words(ref), h = new Set(words(hyp));
  return r.filter((w) => h.has(w)).length / r.length;
}

before(async () => {
  mkdirSync(W.alpha, { recursive: true }); mkdirSync(W.beta, { recursive: true });
  writeFileSync(join(W.alpha, 'README.md'), '# alpha-calc\nA tiny calculator.\n');
  writeFileSync(join(W.beta, 'README.md'), '# beta-docs\nDocumentation site.\n');
  killAll();
  home = makeHome(join(ROOT, 'home'));
  await Promise.all([startWorker('bt-alpha', W.alpha), startWorker('bt-beta', W.beta)]);
  assert.equal(bossUp('start'), 0);
  mkdirSync(RESULTS, { recursive: true });
  const log = openSync(join(RESULTS, 'mic-app.log'), 'w');
  appProc = spawn(APP, [], { env: { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_DEBUG_CONTROL: '1', BOSS_PANEL_EXPANDED: '1', BOSS_NAME, BOSS_SESSIONS_ONLY: 'bt-*' }, stdio: ['ignore', log, log] });
  const st = await poll(async () => { const s = (await app('GET', '/status')).json; return s?.boss_connected && s.sessions >= 2 ? s : null; }, 30_000, 'app ready');
  micOK = st.mic_permission === 'granted';
  // The Mac mini's own speakers play the speech into the room for the webcam mic: raise the
  // volume for the test and put the user's setting back afterwards.
  savedVolume = execFileSync('osascript', ['-e', 'output volume of (get volume settings)'], { encoding: 'utf8' }).trim();
  execFileSync('osascript', ['-e', 'set volume output volume 70']);
  if (!micOK) console.log(`  (microphone not available to this process: ${st.mic_permission}; real-mic tests skip)`);
});

after(() => {
  writeFileSync(join(RESULTS, 'mic-results.json'), JSON.stringify({ at: new Date().toISOString(), micOK, results }, null, 2));
  if (savedVolume !== null && /^\d+$/.test(savedVolume)) execFileSync('osascript', ['-e', `set volume output volume ${savedVolume}`]);
  appProc?.kill(); bossUp('stop'); killAll(); cleanProjects(ROOT);
});

test('real answer window: the app speaks the question, the answer is spoken into the room, it routes', async (t) => {
  if (!micOK) return t.skip('no microphone access');
  assert.equal((await app('POST', '/talk', { down: true })).status, 200);
  await sleep(300);
  play('Read me the first line of the README.');
  await sleep(400);
  const r = (await app('POST', '/talk', { down: false })).json;
  await poll(async () => (await app('GET', '/feed')).json.cards.find((c) => c.kind === 'question' && !c.answered), 60_000, 'question');
  await poll(async () => (await app('GET', '/status')).json.answer_window, 30_000, 'answer window (opens after the question is spoken)');
  await sleep(600);
  play('Beta.');
  const card = await poll(async () => (await app('GET', '/feed')).json.cards.find((c) => c.kind === 'youSaid' && c.utteranceID === r.id && c.status === 'delivered'), 60_000, 'routed after spoken answer');
  results.push({ test: 'answer window', routed_to: card.target });
  assert.equal(card.target, 'bt-beta');
});

test('room noise alone in an answer window sends nothing', async (t) => {
  if (!micOK) return t.skip('no microphone access');
  // A worker's question opens the window; nobody speaks.
  assert.equal((await app('POST', '/talk', { down: true })).status, 200);
  await sleep(300);
  play('B T alpha, send me a question asking whether to call the new file red or blue, and wait for my answer.');
  await sleep(400);
  await app('POST', '/talk', { down: false });
  const q = await poll(async () => (await app('GET', '/feed')).json.cards.find((c) => c.kind === 'question' && !c.answered && c.session === 'bt-alpha'), 120_000, 'worker question');
  await poll(async () => (await app('GET', '/status')).json.answer_window, 30_000, 'answer window');
  await poll(async () => !(await app('GET', '/status')).json.answer_window, 25_000, 'window closed');
  await sleep(4000);
  const since = Date.parse(q.createdAt);
  const sent = (await app('GET', '/feed')).json.cards.filter((c) => c.kind === 'youSaid' && c.mode === 'answer' && Date.parse(c.createdAt) >= since && ['delivered', 'sent'].includes(c.status));
  results.push({ test: 'silent window', answers_sent: sent.length, dropped: (await app('GET', '/feed')).json.cards.filter((c) => c.kind === 'youSaid' && c.status === 'dropped').length });
  assert.equal(sent.length, 0, `noise was sent as an answer: ${JSON.stringify(sent.map((c) => c.text))}`);
  assert.equal((await app('POST', '/tap', { choice: q.choices[0] ?? 'red' })).status, 200);
});

test('speakers → real mic → whisper: hold-to-talk transcribes accurately and lands in the named worker', async (t) => {
  if (!micOK) return t.skip('no microphone access');
  const said = 'B T alpha, create a file named lemon.txt containing the word lemon.';
  assert.equal((await app('POST', '/talk', { down: true })).status, 200);
  await sleep(400);
  const t0 = Date.now();
  play(said);
  await sleep(500);
  const r = (await app('POST', '/talk', { down: false })).json;
  const acc = wordAccuracy(said.replace('B T', 'bt'), r.text ?? '');
  results.push({ test: 'hold-to-talk', said, heard: r.text, accuracy: acc });
  console.log(`  heard: "${r.text}" (word accuracy ${(acc * 100).toFixed(0)}%)`);
  assert.ok(acc >= 0.7, `accuracy ${acc}`);
  const card = await poll(async () => (await app('GET', '/feed')).json.cards.find((c) => c.kind === 'youSaid' && c.utteranceID === r.id && c.status === 'delivered'), 60_000, 'delivered');
  assert.equal(card.target, 'bt-alpha');
  results.push({ test: 'hold-to-talk latency', end_of_speech_to_delivered_ms: Date.now() - t0 });
  await poll(async () => /lemon\.txt/.test(transcript('bt-alpha')), 20_000, 'in worker transcript');
});

