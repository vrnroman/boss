// App E2E: the real Boss.app (debug control on), real whisper-server, real Boss session, real
// throwaway workers. Speech is synthesized with macOS `say` (English and Russian voices) and
// injected through the app's /inject, which runs the same pipeline as the microphone from the
// outbox onward: outbox → whisper → channel → Boss → SendMessage → worker → REPORT → spoken.
//   node --test e2e/app.e2e.mjs
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { request } from 'node:http';
import { makeHome, startWorker, killAll, liveSessions, sleep, REPO, BOSS_NAME, transcript, cleanProjects, Client } from './lib.mjs';

const ROOT = process.env.E2E_ROOT ?? join(tmpdir(), `boss-app-e2e-${process.pid}`);
const PORT = 8798;
const W = { alpha: join(ROOT, 'w', 'alpha-calc'), beta: join(ROOT, 'w', 'beta-docs') };
const AUDIO = join(ROOT, 'audio');
const RESULTS = join(REPO, 'e2e', 'results');
const APP = join(REPO, 'app', 'build', 'Boss.app');
let home, ch, appProc, appExit = null;
const timings = [];

function record(label, ms, extra = {}) {
  timings.push({ label, ms, ...extra });
  console.log(`  ⏱ ${label}: ${(ms / 1000).toFixed(1)} s`);
}

function bossUp(cmd) {
  const env = { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_TMUX_SOCKET: 'bt', BOSS_TMUX_SESSION: BOSS_NAME, BOSS_NAME, BOSS_ALLOW: 'bt-*' };
  const r = spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), cmd], { env, encoding: 'utf8' });
  return { code: r.status, out: r.stdout.trim() };
}

/** Synthesizes speech to a 16 kHz mono WAV, like the mic path produces. */
function speech(name, text, voice = 'Samantha') {
  mkdirSync(AUDIO, { recursive: true });
  const aiff = join(AUDIO, `${name}.aiff`);
  const wav = join(AUDIO, `${name}.wav`);
  execFileSync('say', ['-v', voice, '-o', aiff, text]);
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', aiff, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav]);
  return wav;
}

function app(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : JSON.stringify(body);
    const req = request({ host: '127.0.0.1', port: 8789, method, path, headers: {
      authorization: `Bearer ${home.token}`, 'content-length': String(data ? Buffer.byteLength(data) : 0), ...(data ? { 'content-type': 'application/json' } : {}) } }, (res) => {
      let t = '';
      res.on('data', (c) => (t += c));
      res.on('end', () => { let json; try { json = JSON.parse(t); } catch {} resolve({ status: res.statusCode, json }); });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function poll(fn, ms, label) {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() - t0 > ms) throw new Error(`timeout (${ms} ms) waiting for ${label}`);
    await sleep(250);
  }
}

const cards = async () => (await app('GET', '/feed')).json.cards;
const spoken = async () => (await app('GET', '/spoken')).json.spoken;
const youSaid = async (id) => (await cards()).find((c) => c.kind === 'youSaid' && c.utteranceID === id);

before(async () => {
  spawnSync('pkill', ['-f', 'Boss.app/Contents/MacOS/Boss']);
  mkdirSync(W.alpha, { recursive: true });
  mkdirSync(W.beta, { recursive: true });
  writeFileSync(join(W.alpha, 'README.md'), '# alpha-calc\nA tiny calculator library.\n');
  writeFileSync(join(W.beta, 'README.md'), '# beta-docs\nThe documentation site for the beta project.\n');
  killAll();
  home = makeHome(join(ROOT, 'home'));
  if (!existsSync(APP) || process.env.E2E_REBUILD) execFileSync('sh', [join(REPO, 'app', 'scripts', 'build-app.sh')], { stdio: 'ignore' });
  await Promise.all([startWorker('bt-alpha', W.alpha), startWorker('bt-beta', W.beta)]);
  assert.equal(bossUp('start').code, 0);
  ch = new Client(PORT, home.token);
  await ch.listen();
  mkdirSync(RESULTS, { recursive: true });
  const { spawn } = await import('node:child_process');
  const { openSync } = await import('node:fs');
  const logFd = openSync(join(RESULTS, 'app-stderr.log'), 'w');
  appProc = spawn(join(APP, 'Contents', 'MacOS', 'Boss'), [], {
    env: { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_DEBUG_CONTROL: '1', BOSS_PANEL_EXPANDED: '1' },
    stdio: ['ignore', logFd, logFd],
  });
  appProc.on('exit', (code, signal) => { appExit = { code, signal, at: new Date().toISOString() }; console.log(`  !! Boss.app exited: code=${code} signal=${signal}`); });
  await poll(async () => { try { const s = (await app('GET', '/status')).json; return s?.boss_connected && s.sessions >= 2; } catch { return false; } }, 30_000, 'app connected with sessions');
});

after(() => {
  ch?.close();
  mkdirSync(RESULTS, { recursive: true });
  writeFileSync(join(RESULTS, 'app-timings.json'), JSON.stringify({ at: new Date().toISOString(), timings, appExit }, null, 2));
  if (!process.env.E2E_KEEP) {
    appProc?.kill();
    bossUp('stop');
    killAll();
    cleanProjects(ROOT);
  }
});

test('the timing tower lists the live worker sessions (and not Boss itself)', async () => {
  const s = (await app('GET', '/sessions')).json.sessions;
  const names = s.map((r) => r.name);
  assert.ok(names.includes('bt-alpha') && names.includes('bt-beta'), names.join(','));
  const st = (await app('GET', '/status')).json;
  assert.equal(st.boss_connected, true);
  assert.equal(st.recording, false);
});

test('ambiguous: Boss asks out loud, the mic window opens, a spoken "beta" answers it and routes the original words', async () => {
  const wav = speech('amb1', 'Read me the first line of the README.');
  const t0 = Date.now();
  const r = (await app('POST', '/inject', { wav_path: wav })).json;
  assert.equal(r.ok, true);
  const q = await poll(async () => (await cards()).find((c) => c.kind === 'question' && !c.answered && c.choices.length >= 2), 60_000, 'question card');
  record('ambiguous: end of speech → question card', Date.now() - t0);
  assert.deepEqual([...q.choices].sort(), ['bt-alpha', 'bt-beta']);
  assert.ok((await spoken()).some((s) => s.priority === 'question'), 'the question was spoken');
  const win = await poll(async () => (await app('GET', '/status')).json.answer_window, 15_000, 'answer window open');
  assert.equal(win.question_id, q.questionID);
  // Nothing was delivered yet.
  assert.notEqual((await youSaid(r.id))?.status, 'delivered');
  const t1 = Date.now();
  const ans = (await app('POST', '/inject', { wav_path: speech('ans1', 'Beta.') })).json;
  assert.equal(ans.ok, true, JSON.stringify(ans));
  const card = await poll(async () => { const c = await youSaid(r.id); return c && c.status === 'delivered' && c.target ? c : null; }, 60_000, 'original routed after answer');
  record('spoken answer → original words landed', Date.now() - t1);
  assert.equal(card.target, 'bt-beta');
  await poll(async () => /first line of the read ?me/i.test(transcript('bt-beta')), 15_000, 'original words in bt-beta transcript');
});

test('spoken English: transcribed, routed to the named worker, the work happens, the report is spoken', async () => {
  const wav = speech('en1', 'B T alpha, create a file named mango.txt containing the word mango, then report back.');
  const t0 = Date.now();
  const r = (await app('POST', '/inject', { wav_path: wav })).json;
  const tStt = Date.now() - t0;
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.match(r.text, /mango/i);
  assert.equal(r.lang, 'en');
  // The outbox kept the audio and the transcript.
  const ob = readdirSync(join(home.dir, 'outbox'));
  assert.ok(ob.includes(`${r.id}.wav`) && ob.includes(`${r.id}.json`), 'outbox has wav + json');
  const card = await poll(async () => { const c = await youSaid(r.id); return c && c.status === 'delivered' && c.target ? c : null; }, 60_000, 'You said card sent');
  record('end of speech → landed in worker (whisper + Boss + SendMessage)', Date.now() - t0, { whisper_ms: tStt });
  assert.equal(card.target, 'bt-alpha');
  await poll(async () => transcript('bt-alpha').includes('mango.txt'), 15_000, 'words in bt-alpha transcript');
  const said = await poll(async () => (await spoken()).find((s) => /bt-alpha/i.test(s.text) && /mango/i.test(s.text)), 150_000, 'spoken report');
  record('end of speech → report spoken back', Date.now() - t0);
  assert.equal(readFileSync(join(W.alpha, 'mango.txt'), 'utf8').trim().toLowerCase(), 'mango');
  assert.ok(!existsSync(join(W.beta, 'mango.txt')));
  assert.ok((await cards()).some((c) => c.kind === 'report' && c.session === 'bt-alpha'), 'report card in the feed');
  assert.ok(said.text.length < 400);
});

test('spoken Russian: transcribed in Russian, routed by the Russian name, reported in Russian', async () => {
  const wav = speech('ru1', 'Бета, создай файл под названием фрукты и напиши в нём слово вишня. Потом отчитайся.', 'Milena');
  const t0 = Date.now();
  const r = (await app('POST', '/inject', { wav_path: wav })).json;
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.equal(r.lang, 'ru');
  assert.match(r.text, /[а-яё]/i);
  const card = await poll(async () => { const c = await youSaid(r.id); return c && c.status === 'delivered' && c.target ? c : null; }, 60_000, 'ru card sent');
  record('Russian: end of speech → landed', Date.now() - t0);
  assert.equal(card.target, 'bt-beta');
  assert.equal(card.lang, 'ru');
  const since = Date.now();
  const fruitFile = () => readdirSync(W.beta).filter((f) => f !== 'README.md').find((f) => /вишн/i.test(readFileSync(join(W.beta, f), 'utf8')));
  const f = await poll(async () => fruitFile(), 150_000, 'a new file in beta containing вишня');
  assert.ok(f);
  const said = await poll(async () => (await spoken()).find((s) => /bt-beta/i.test(s.text) && /[а-яё]/i.test(s.text) && s.priority !== 'question' && new Date(s.at).getTime() >= t0), 150_000, 'Russian report');
  assert.equal(said.lang, 'ru');
  assert.match(said.text, /[а-яё]/i);
  assert.ok(since);
});

test('a worker asks Roman a question: card with choices, a tap answers, the worker acts on it', async () => {
  const r = (await app('POST', '/inject', { wav_path: speech('q1', 'B T alpha, send me a QUESTION asking whether to name the new file red.txt or blue.txt, wait for my answer, then create the file I choose.') })).json;
  assert.equal(r.ok, true);
  const q = await poll(async () => (await cards()).find((c) => c.kind === 'question' && !c.answered && c.session === 'bt-alpha'), 120_000, 'worker question card');
  assert.ok(q.choices.some((c) => /blue/i.test(c)), JSON.stringify(q.choices));
  // Let the 6 s voice window lapse silently first: silence must answer nothing.
  await sleep(7000);
  assert.ok(!(await app('GET', '/status')).json.answer_window, 'answer window closed after 6 s');
  assert.ok(!existsSync(join(W.alpha, 'blue.txt')) && !existsSync(join(W.alpha, 'red.txt')), 'nothing before the answer');
  const blue = q.choices.find((c) => /blue/i.test(c));
  assert.equal((await app('POST', '/tap', { choice: blue })).status, 200);
  await poll(async () => existsSync(join(W.alpha, 'blue.txt')), 120_000, 'blue.txt created');
  assert.ok(!existsSync(join(W.alpha, 'red.txt')));
  assert.ok((await cards()).find((c) => c.questionID === q.questionID)?.answered, 'card marked answered');
});

test('undo: the Undo action makes the last target drop the last message', async () => {
  const r = (await app('POST', '/inject', { wav_path: speech('undo1', 'B T beta, wait 25 seconds, then create a file named papaya.txt.') })).json;
  await poll(async () => { const c = await youSaid(r.id); return c && c.status === 'delivered' && c.target ? c : null; }, 60_000, 'sent');
  assert.equal((await app('POST', '/undo')).status, 200);
  await poll(async () => ['ignored', 'undone'].includes((await youSaid(r.id))?.status), 60_000, 'ignored');
  await sleep(35_000);
  assert.ok(!existsSync(join(W.beta, 'papaya.txt')), 'scratched instruction did not run (or was reverted)');
});

test('silence and a too-short click are dropped, never sent', async () => {
  mkdirSync(AUDIO, { recursive: true });
  const silent = join(AUDIO, 'silence.wav');
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono', '-t', '2', '-c:a', 'pcm_s16le', silent]);
  const click = join(AUDIO, 'click.wav');
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'sine=f=1000:d=0.1', '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', click]);
  const before = (await ch.http('GET', '/state')).json.routes.length;
  assert.equal((await app('POST', '/inject', { wav_path: silent })).json.ok, false);
  assert.equal((await app('POST', '/inject', { wav_path: click })).json.ok, false);
  await sleep(1500);
  assert.equal((await ch.http('GET', '/state')).json.routes.length, before);
});

test('Boss down: the utterance waits in the outbox and is delivered once when Boss is back', async () => {
  assert.equal(bossUp('stop').code, 0);
  await poll(async () => (await app('GET', '/status')).json.boss_connected === false, 30_000, 'app sees Boss offline');
  const r = (await app('POST', '/inject', { wav_path: speech('down1', 'B T alpha, create a file named kiwi.txt.') })).json;
  assert.equal(r.ok, true);
  const st = (await app('GET', '/status')).json;
  assert.ok(st.outbox_unsent >= 1, 'kept in the outbox');
  const t0 = Date.now();
  assert.equal(bossUp('start').code, 0);
  ch.close();
  ch = new Client(PORT, home.token);
  await ch.listen();
  await poll(async () => { const c = await youSaid(r.id); return c && c.status === 'delivered' && c.target ? c : null; }, 90_000, 'delivered after restart');
  record('Boss restart → queued utterance delivered', Date.now() - t0);
  await poll(async () => existsSync(join(W.alpha, 'kiwi.txt')), 90_000, 'kiwi.txt');
  assert.equal((await app('GET', '/status')).json.outbox_unsent, 0);
  const deliveries = transcript('bt-alpha').split('\n').filter((l) => l.includes('Roman (voice)') && l.includes('kiwi.txt') && l.includes('"type":"user"'));
  assert.equal(deliveries.length, 1, `delivered exactly once (got ${deliveries.length})`);
});

test('the app is still alive after the whole run (no crash, no silent exit)', () => {
  assert.equal(appExit, null, `Boss.app exited: ${JSON.stringify(appExit)}`);
});
