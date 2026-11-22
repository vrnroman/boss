// Records the presentation: a real demo run (real Boss.app, whisper, Boss session, two real Claude
// Code workers named payments and site) while capturing the Boss panel window and an iTerm window
// attached to the workers, frame by frame, plus a timeline of every event.
//   node e2e/film/record.mjs <outDir>
// Speech in is synthesized (macOS say); everything after the microphone is the real product.
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync, openSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { request } from 'node:http';
import { makeHome, startWorker, sleep, REPO, liveSessions, Client } from '../lib.mjs';

const OUT = process.argv[2] ?? join(REPO, 'e2e', 'results', 'film');
const SOCK = process.env.E2E_SOCK ?? 'bt'; // run with E2E_SOCK=film so it never meets the test suites
const PORT = 8796;
const BOSS = 'boss-demo';
const W = { payments: join(OUT, 'work', 'payments-service'), site: join(OUT, 'work', 'landing-site') };
const WINS = process.env.WINS_BIN;
const APP = join(REPO, 'app', 'build', 'Boss.app', 'Contents', 'MacOS', 'Boss');
mkdirSync(join(OUT, 'panel'), { recursive: true });
mkdirSync(join(OUT, 'term'), { recursive: true });
mkdirSync(join(OUT, 'audio'), { recursive: true });

const T0 = Date.now();
const timeline = { t0: T0, scenes: [], injects: [], marks: [] };
const now = () => Date.now() - T0;
const mark = (label) => { timeline.marks.push({ t: now(), label }); console.log(`[${(now() / 1000).toFixed(1)}] ${label}`); };

// ---------- the two worker projects ----------
function seed() {
  mkdirSync(join(W.payments, 'src'), { recursive: true });
  mkdirSync(join(W.payments, 'test'), { recursive: true });
  writeFileSync(join(W.payments, 'package.json'), JSON.stringify({ name: 'payments-service', type: 'module', scripts: { test: 'node --test', lint: 'node lint.mjs' } }, null, 2));
  writeFileSync(join(W.payments, 'src', 'fee-calculator.js'), `// Fee calculator for card payments.\nexport function calculateFee(amount, rate = 0.029, fixed = 0.3) {\n  return Math.round((amount * rate + fixed) * 100) / 100;\n}\n`);
  writeFileSync(join(W.payments, 'test', 'fee.test.js'), `import { test } from 'node:test';\nimport assert from 'node:assert/strict';\nimport { calculateFee } from '../src/fee-calculator.js';\n\ntest('standard fee', () => assert.equal(calculateFee(100), 3.2));\ntest('zero amount pays the fixed part', () => assert.equal(calculateFee(0), 0.3));\ntest('custom rate', () => assert.equal(calculateFee(200, 0.01, 0), 2));\n`);
  writeFileSync(join(W.payments, 'lint.mjs'), `import { readFileSync, readdirSync } from 'node:fs';\nlet bad = 0;\nfor (const f of readdirSync('src')) { if (/\\t/.test(readFileSync('src/' + f, 'utf8'))) { console.log('tab in', f); bad++; } }\nconsole.log(bad ? bad + ' problems' : 'lint clean');\nprocess.exit(bad ? 1 : 0);\n`);
  writeFileSync(join(W.payments, 'README.md'), '# payments-service\nCard payment fees and settlement.\n');
  mkdirSync(W.site, { recursive: true });
  writeFileSync(join(W.site, 'index.html'), `<!doctype html><html><head><title>Acme</title><style>body{font-family:sans-serif} .card{border:1px solid #ccc;padding:16px;display:inline-block;margin:8px}.highlight{border-color:#888}</style></head>\n<body><h1>Welcome to Acme, the fastest way to move money between teams</h1>\n<div class="card">Starter</div><div class="card highlight">Pro</div><div class="card">Enterprise</div></body></html>\n`);
  writeFileSync(join(W.site, 'README.md'), '# landing-site\nThe Acme marketing landing page.\n');
}

// ---------- capture ----------
function windowId(owner, pred) {
  const out = execFileSync(WINS, [owner], { encoding: 'utf8' }).trim().split('\n').filter(Boolean).map((l) => l.split(' '));
  const w = out.find(pred);
  return w ? w[0] : null;
}

const capturing = { on: true };
async function captureLoop(wid, dir, fps = 4) {
  let n = 0;
  while (capturing.on) {
    const t = now();
    spawnSync('screencapture', ['-x', '-o', '-l', String(wid), join(dir, `${String(t).padStart(7, '0')}.png`)]);
    n++;
    const wait = Math.max(0, 1000 / fps - (now() - t));
    await sleep(wait);
  }
  return n;
}

// ---------- app control ----------
let token;
let itermWindow = null;
let appProcRef = null;
let bossEnv = null;
/** Closes only the iTerm window this recorder opened (by its id), never anything else. */
function closeTerm() {
  if (!itermWindow || !/^\d+$/.test(itermWindow)) return;
  spawnSync('osascript', ['-e', `tell application "iTerm2" to close (window id ${itermWindow})`]);
  itermWindow = null;
}
function app(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? '' : JSON.stringify(body);
    const req = request({ host: '127.0.0.1', port: 8789, method, path, headers: { authorization: `Bearer ${token}`, 'content-length': String(Buffer.byteLength(data)), ...(data ? { 'content-type': 'application/json' } : {}) } }, (res) => {
      let t = '';
      res.on('data', (c) => (t += c));
      res.on('end', () => { let json; try { json = JSON.parse(t); } catch {} resolve({ status: res.statusCode, json }); });
    });
    req.on('error', reject);
    req.end(data);
  });
}
async function poll(fn, ms, label) {
  const t = Date.now();
  for (;;) {
    const v = await fn().catch(() => null);
    if (v) return v;
    if (Date.now() - t > ms) { mark(`TIMEOUT ${label}`); return null; }
    await sleep(300);
  }
}
const cards = async () => (await app('GET', '/feed')).json.cards;
const spoken = async () => (await app('GET', '/spoken')).json.spoken;

let k = 0;
async function say(text, voice = 'Samantha') {
  const name = `in${++k}`;
  const aiff = join(OUT, 'audio', `${name}.aiff`);
  const wav = join(OUT, 'audio', `${name}.wav`);
  execFileSync('say', ['-v', voice, '-o', aiff, text]);
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', aiff, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav]);
  const dur = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', wav], { encoding: 'utf8' }));
  // The "speaking" happens before the release: the clip plays, then the release sends it.
  const t = now();
  await app('POST', '/talk', { down: true }).catch(() => {}); // shows the recording state if a mic exists; harmless without
  await sleep(dur * 1000);
  await app('POST', '/talk', { down: false }).catch(() => {});
  const r = (await app('POST', '/inject', { wav_path: wav })).json;
  timeline.injects.push({ t, release: now(), wav, text, voice, dur, result: r });
  mark(`said: ${text} -> ${r?.text}`);
  return r;
}
const scene = (id, title) => { const s = { id, title, start: now() }; timeline.scenes.push(s); mark(`scene ${id}: ${title}`); return () => { s.end = now(); }; };
const lastSpokenAt = async () => { const sp = await spoken(); return sp.length ? new Date(sp.at(-1).at).getTime() : 0; };
async function waitSpoken(pred, ms, label) {
  return poll(async () => (await spoken()).find(pred), ms, label);
}

// ---------- run ----------
async function main() {
  seed();
  spawnSync('tmux', ['-L', SOCK, 'kill-server']);
  const home = makeHome(join(OUT, 'home'));
  token = home.token;
  await Promise.all([startWorker('payments', W.payments, { bossName: BOSS }), startWorker('site', W.site, { bossName: BOSS })]);
  const env = { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_TMUX_SOCKET: SOCK, BOSS_TMUX_SESSION: BOSS, BOSS_NAME: BOSS, BOSS_ALLOW: 'payments,site', BOSS_RADIO_DRY: '1' };
  // The worker block names the boss; lib.mjs primed workers for "bt-boss", so re-prime for this film's name.
  bossEnv = env;
  const up = spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), 'start'], { env, encoding: 'utf8' });
  if (up.status !== 0) throw new Error(`boss-up: ${up.stdout} ${up.stderr}`);
  const log = openSync(join(OUT, 'app.log'), 'w');
  const appProc = appProcRef = spawn(APP, [], { env: { ...process.env, BOSS_HOME: home.dir, BOSS_PORT: String(PORT), BOSS_DEBUG_CONTROL: '1', BOSS_PANEL_EXPANDED: '1', BOSS_NAME: BOSS, BOSS_SESSIONS_ONLY: 'payments,site', BOSS_NO_MIC: '1' }, stdio: ['ignore', log, log] });
  await poll(async () => { const s = (await app('GET', '/status')).json; return s?.boss_connected && s.sessions >= 2; }, 30_000, 'app ready');

  // A real iTerm window on the two workers, split top/bottom.
  itermWindow = execFileSync('osascript', ['-e', `tell application "iTerm2"
    set w to (create window with default profile command "/opt/homebrew/bin/tmux -L ${SOCK} attach -t payments")
    tell w to set bounds to {60, 60, 1260, 1060}
    tell current session of w
      set name to "payments"
      set s2 to (split horizontally with default profile command "/opt/homebrew/bin/tmux -L ${SOCK} attach -t site")
    end tell
    tell s2 to set name to "site"
    return id of w
  end tell`], { encoding: 'utf8' }).trim();
  await sleep(2500);
  const panelId = windowId('Boss', (w) => w[1] === '3');
  const termId = windowId('iTerm', (w) => w[1] === '0' && Number(w[2]) >= 1100 && Number(w[2]) <= 1300);
  if (!panelId || !termId) throw new Error(`windows not found: panel ${panelId} term ${termId}`);
  mark(`windows panel=${panelId} term=${termId}`);
  const loops = [captureLoop(panelId, join(OUT, 'panel')), captureLoop(termId, join(OUT, 'term'))];
  await sleep(3000);

  let end;
  // 1. Dispatch and report back.
  end = scene('dispatch', 'Dispatch: say the session name, then the instruction');
  await say('Payments, rename the fee calculator to pricing engine and run the tests.');
  await waitSpoken((s) => /payments/i.test(s.text) && s.priority !== 'question', 240_000, 'payments report');
  await sleep(4000); end();

  // 2. Russian.
  end = scene('russian', 'Russian works the same way');
  await say('Сайт, поменяй главный заголовок на: Деньги между командами за секунды. И отчитайся.', 'Milena');
  await waitSpoken((s) => /site/i.test(s.text) && /[а-яё]/i.test(s.text), 240_000, 'site ru report');
  await sleep(4000); end();

  // 3. Ambiguous: Boss asks back, answered by voice in the 6 s window.
  end = scene('ask', 'Not sure where it goes? Boss asks, you just answer');
  await sleep(1000);
  const before = (await spoken()).length;
  await say('Check the README for typos and fix them.');
  const q = await poll(async () => (await cards()).find((c) => c.kind === 'question' && !c.answered), 60_000, 'question');
  if (q) {
    await poll(async () => (await app('GET', '/status')).json.answer_window, 20_000, 'answer window');
    await say('Site.');
  }
  await waitSpoken((s, i) => /site/i.test(s.text) && s.priority !== 'question', 240_000, 'site readme report');
  await sleep(4000); end();
  void before;

  // 4. A worker asks Roman: tap a choice.
  end = scene('worker-question', 'A session needs a decision: it asks, you tap');
  await say('Site, ask me whether the highlighted pricing card should be blue or green, then apply my choice.');
  const wq = await poll(async () => (await cards()).find((c) => c.kind === 'question' && !c.answered && c.session === 'site'), 180_000, 'worker question');
  if (wq) {
    await sleep(8000); // the spoken question and the 6 s window pass
    const green = wq.choices.find((c) => /green/i.test(c)) ?? 'green';
    mark(`tap ${green}`);
    await app('POST', '/tap', { choice: green });
  }
  await waitSpoken((s) => /site/i.test(s.text) && /green|зел/i.test(s.text) && s.priority !== 'question', 240_000, 'green report');
  await sleep(4000); end();

  // 5. Status.
  end = scene('status', 'What is everyone doing?');
  await say('What is everyone doing?');
  await poll(async () => { const sp = await spoken(); const last = sp.at(-1); return last && new Date(last.at).getTime() > Date.now() - 15000 && /payments|site/i.test(last.text) ? last : null; }, 60_000, 'status answer');
  await sleep(7000); end();

  // 6. Scratch that.
  end = scene('scratch', 'Changed your mind? Say scratch that');
  await say('Payments, wait thirty seconds, then delete the README.');
  await poll(async () => (await cards()).find((c) => c.kind === 'youSaid' && c.status === 'delivered' && /README/i.test(c.text ?? '')), 60_000, 'delivered');
  await say('Scratch that.');
  await poll(async () => (await cards()).find((c) => c.kind === 'youSaid' && ['ignored', 'undone'].includes(c.status)), 60_000, 'ignored');
  await sleep(6000); end();

  // 7. Radio recap (dry: rendered, not sent).
  end = scene('radio', 'Leaving? Radio me: a spoken recap for the commute');
  await say('Radio me.');
  await poll(async () => (await cards()).find((c) => c.kind !== 'youSaid' && /Radio recap/i.test(c.text ?? '')), 120_000, 'radio ready');
  await sleep(3000); end();

  capturing.on = false;
  await Promise.all(loops);
  timeline.spoken = await spoken();
  timeline.cards = await cards();
  timeline.readme_exists = existsSync(join(W.payments, 'README.md'));
  timeline.files = {
    payments: spawnSync('ls', ['-R', W.payments], { encoding: 'utf8' }).stdout,
    site_title: (readFileSync(join(W.site, 'index.html'), 'utf8').match(/<h1>(.*?)<\/h1>/) ?? [])[1],
  };
  writeFileSync(join(OUT, 'timeline.json'), JSON.stringify(timeline, null, 2));
  mark('done');
  appProc.kill();
  spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), 'stop'], { env });
  closeTerm();
}

main().catch((e) => { console.error(e); capturing.on = false; closeTerm(); appProcRef?.kill(); if (bossEnv) spawnSync(process.execPath, [join(REPO, 'bin', 'boss-up.mjs'), 'stop'], { env: bossEnv }); spawnSync('tmux', ['-L', SOCK, 'kill-server']); writeFileSync(join(OUT, 'timeline.json'), JSON.stringify(timeline, null, 2)); process.exit(1); });
