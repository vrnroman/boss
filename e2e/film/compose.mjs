// Composes the presentation from a recording made by record.mjs.
//   node e2e/film/compose.mjs <recDir> <out.mp4>
// Layout: the real Boss panel (left) and the real iTerm window on the workers (right), captions on
// top, narration in the house voice. Waiting while a worker thinks plays at 4x with a visible badge;
// speaking, cards and Boss's answers play at 1x. Boss's answers are re-voiced from its speech log
// with the same local Kokoro voice the app uses (system audio cannot be recorded here).
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const REC = process.argv[2];
const OUTFILE = process.argv[3] ?? join(REC, 'presentation.mp4');
const W = join(REC, 'compose');
mkdirSync(join(W, 'voice'), { recursive: true });
mkdirSync(join(W, 'cards'), { recursive: true });
const tl = JSON.parse(readFileSync(join(REC, 'timeline.json'), 'utf8'));
// Test counts come from the gate's own log (written by the caller), never typed by hand.
const C = existsSync(join(REC, 'counts.json')) ? JSON.parse(readFileSync(join(REC, 'counts.json'), 'utf8')) : {};
const FPS = 10;
const FAST = 4;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const dur = (f) => Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f], { encoding: 'utf8' }));
const ff = (args) => execFileSync('ffmpeg', ['-loglevel', 'error', '-y', ...args], { stdio: ['ignore', 'ignore', 'inherit'] });

// ---------- voices ----------
const backself = JSON.parse(readFileSync(join(homedir(), '.backself', 'config.json'), 'utf8'));
async function narrate(text, file) {
  if (existsSync(file)) return dur(file);
  try {
    const r = await fetch(`${backself.url}/api/v1/voice`, { method: 'POST', headers: { authorization: `Bearer ${backself.token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ text, voice: 'Kore', style: 'warm, confident product-film narrator, natural pace, never salesy' }), signal: AbortSignal.timeout(150_000) });
    if (!r.ok) throw new Error(`voice ${r.status}`);
    const raw = file.replace(/\.wav$/, '.raw');
    writeFileSync(raw, Buffer.from(await r.arrayBuffer()));
    ff(['-i', raw, '-ar', '24000', '-ac', '1', file]);
  } catch (e) {
    console.error(`narration fell back to Kokoro: ${e.message}`);
    await kokoro(text, file, 'bf_emma');
  }
  return dur(file);
}
async function kokoro(text, file, voice = 'af_heart') {
  if (existsSync(file)) return dur(file);
  // Same voices as the app: Kokoro for English, Milena for Russian.
  const lang = /[а-яё]/i.test(text) ? 'ru' : 'en';
  const r = await fetch('http://127.0.0.1:8792/speak', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text, lang, voice }) });
  if (r.status === 422 || !r.ok) {
    const aiff = file.replace(/\.wav$/, '.aiff');
    execFileSync('say', ['-v', /[а-яё]/i.test(text) ? 'Milena' : 'Samantha', '-o', aiff, text.replace(/[«»„“”\\]/g, '')]);
    ff(['-i', aiff, '-ar', '24000', '-ac', '1', file]);
  } else {
    writeFileSync(file, Buffer.from(await r.arrayBuffer()));
  }
  return dur(file);
}

// ---------- cards (HTML -> PNG with headless Chrome) ----------
const CSS = `body{margin:0;width:1920px;height:1080px;background:#0e1116;color:#e8eaed;font-family:-apple-system,"SF Pro Display",Helvetica,sans-serif;display:flex;flex-direction:column;justify-content:center;padding:0 160px;box-sizing:border-box}
.k{color:#8ab4f8;font-size:30px;letter-spacing:3px;text-transform:uppercase;margin-bottom:24px}h1{font-size:84px;margin:0 0 28px;font-weight:700;line-height:1.05}
p,li{font-size:38px;line-height:1.45;color:#c4c7cc;margin:0}ul{margin:18px 0 0;padding-left:40px}.g{color:#81c995}.a{color:#fdd663}.m{font-family:Menlo,monospace;font-size:30px;color:#9aa0a6}
.row{display:flex;gap:28px;margin-top:34px}.box{flex:1;background:#171b22;border:1px solid #2d333b;border-radius:18px;padding:26px 28px}.box b{display:block;font-size:34px;color:#e8eaed;margin-bottom:8px}.box span{font-size:27px;color:#9aa0a6;line-height:1.4}
.arrow{font-size:40px;color:#5f6368;align-self:center}`;
function card(name, html) {
  const f = join(W, 'cards', `${name}.html`);
  writeFileSync(f, `<!doctype html><meta charset="utf-8"><style>${CSS}</style><body>${html}</body>`);
  const png = join(W, 'cards', `${name}.png`);
  execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', `--screenshot=${png}`, '--window-size=1920,1080', `file://${f}`], { stdio: 'ignore' });
  return png;
}

// ---------- the cut: map recording time to output time ----------
function framesOf(dir) {
  return readdirSync(join(REC, dir)).filter((f) => f.endsWith('.png')).map((f) => ({ t: Number(f.slice(0, -4)), f: join(REC, dir, f) })).sort((a, b) => a.t - b.t);
}
const panel = framesOf('panel');

// ---------- terminal frames: real tmux pane text (with colours) rendered as an iTerm-like window ----------
const PAL = ['#1e1e1e', '#e06c75', '#98c379', '#e5c07b', '#61afef', '#c678dd', '#56b6c2', '#dcdfe4', '#5c6370', '#ef7b85', '#a7d68a', '#f0cf8a', '#7cc0f7', '#d797ea', '#6fd0dc', '#ffffff'];
function xterm256(n) {
  if (n < 16) return PAL[n];
  if (n >= 232) { const v = 8 + (n - 232) * 10; return `rgb(${v},${v},${v})`; }
  n -= 16; const c = [Math.floor(n / 36), Math.floor(n / 6) % 6, n % 6].map((x) => (x ? x * 40 + 55 : 0));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}
const esc = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
export function ansiToHtml(text) {
  let fg = null, bg = null, bold = false, dim = false, out = '';
  const parts = text.split(/(\x1b\[[0-9;]*m)/);
  for (const p of parts) {
    const m = /^\x1b\[([0-9;]*)m$/.exec(p);
    if (!m) {
      if (!p) continue;
      const st = [fg && `color:${fg}`, bg && `background:${bg}`, bold && 'font-weight:700', dim && 'opacity:.6'].filter(Boolean).join(';');
      out += st ? `<span style="${st}">${esc(p)}</span>` : esc(p);
      continue;
    }
    const codes = (m[1] || '0').split(';').map(Number);
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      if (c === 0) { fg = bg = null; bold = dim = false; }
      else if (c === 1) bold = true; else if (c === 2) dim = true; else if (c === 22) bold = dim = false;
      else if (c >= 30 && c <= 37) fg = PAL[c - 30]; else if (c >= 90 && c <= 97) fg = PAL[c - 82];
      else if (c >= 40 && c <= 47) bg = PAL[c - 40]; else if (c >= 100 && c <= 107) bg = PAL[c - 92];
      else if (c === 39) fg = null; else if (c === 49) bg = null;
      else if ((c === 38 || c === 48) && codes[i + 1] === 5) { const v = xterm256(codes[i + 2]); if (c === 38) fg = v; else bg = v; i += 2; }
      else if ((c === 38 || c === 48) && codes[i + 1] === 2) { const v = `rgb(${codes[i + 2]},${codes[i + 3]},${codes[i + 4]})`; if (c === 38) fg = v; else bg = v; i += 4; }
    }
  }
  return out;
}
function lastLines(pane, n = 22) {
  const lines = pane.replace(/\s+$/, '').split('\n');
  return lines.slice(-n).join('\n');
}
const TERM_CSS = `body{margin:0;background:#0e1116}.win{width:1180px;height:960px;background:#1b1d22;border-radius:12px;overflow:hidden;border:1px solid #30343c;font-family:Menlo,monospace}
.bar{height:34px;background:#2a2d33;display:flex;align-items:center;padding:0 14px;gap:8px}.dot{width:12px;height:12px;border-radius:6px}.ttl{color:#9aa0a6;font:13px -apple-system,sans-serif;margin-left:12px}
.pane{height:461px;box-sizing:border-box;padding:6px 12px;border-bottom:1px solid #30343c;position:relative}.lab{position:absolute;right:12px;top:6px;color:#61afef;font:600 13px -apple-system,sans-serif}
pre{margin:0;color:#dcdfe4;font-size:15.5px;line-height:19.5px;white-space:pre;overflow:hidden}.box{height:445px;display:flex;flex-direction:column;justify-content:flex-end;overflow:hidden}`;
function renderTermFrames() {
  const dir = join(REC, 'term');
  const outDir = join(W, 'term');
  mkdirSync(outDir, { recursive: true });
  const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort();
  const byContent = new Map();
  const frames = [];
  for (const f of files) {
    const panes = JSON.parse(readFileSync(join(dir, f), 'utf8'));
    const key = panes.map((p) => lastLines(p)).join('\u0000');
    let png = byContent.get(key);
    if (!png) {
      png = join(outDir, `${f.slice(0, -5)}.png`);
      const html = join(outDir, `${f.slice(0, -5)}.html`);
      writeFileSync(html, `<!doctype html><meta charset="utf-8"><style>${TERM_CSS}</style><div class="win"><div class="bar"><span class="dot" style="background:#ff5f57"></span><span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span><span class="ttl">iTerm · tmux · two Claude Code workers</span></div>` +
        ['payments', 'site'].map((n, i) => `<div class="pane"><span class="lab">${n}</span><div class="box"><pre>${ansiToHtml(lastLines(panes[i] ?? ''))}</pre></div></div>`).join('') + '</div>');
      execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', `--screenshot=${png}`, '--window-size=1180,960', '--force-device-scale-factor=1', `file://${html}`], { stdio: 'ignore' });
      byContent.set(key, png);
    }
    frames.push({ t: Number(f.slice(0, -5)), f: png });
  }
  console.log(`terminal frames: ${files.length}, rendered ${byContent.size} unique`);
  return frames;
}
const term = existsSync(join(REC, 'term')) && readdirSync(join(REC, 'term')).some((f) => f.endsWith('.json')) ? renderTermFrames() : framesOf('term');

/** Normal-speed windows: around each spoken input and each Boss answer. Everything else in a scene is fast. */
function normalWindows(scene, answers) {
  const wins = [];
  for (const i of tl.injects) if (i.t >= scene.start && i.t <= scene.end) wins.push([i.t - 600, i.release + 3500]);
  for (const a of answers) if (a.rt >= scene.start && a.rt <= scene.end) wins.push([a.rt - 1200, a.rt + a.d * 1000 + 1200]);
  for (const m of tl.marks) if (m.t >= scene.start && m.t <= scene.end && /^tap /.test(m.label)) wins.push([m.t - 1500, m.t + 2500]);
  wins.sort((x, y) => x[0] - y[0]);
  const merged = [];
  for (const w of wins) {
    const a = Math.max(w[0], scene.start), b = Math.min(w[1], scene.end);
    if (b <= a) continue;
    if (merged.length && a <= merged.at(-1)[1]) merged.at(-1)[1] = Math.max(merged.at(-1)[1], b);
    else merged.push([a, b]);
  }
  const segs = [];
  let cur = scene.start;
  for (const [a, b] of merged) {
    if (a > cur) segs.push({ a: cur, b: a, speed: FAST });
    segs.push({ a, b, speed: 1 });
    cur = b;
  }
  if (scene.end > cur) segs.push({ a: cur, b: scene.end, speed: FAST });
  return segs;
}

const frameAt = (frames, t) => { let lo = 0, hi = frames.length - 1, best = frames[0]; while (lo <= hi) { const m = (lo + hi) >> 1; if (frames[m].t <= t) { best = frames[m]; lo = m + 1; } else hi = m - 1; } return best; };
const assTime = (s) => { const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = (s % 60).toFixed(2).padStart(5, '0'); return `${h}:${String(m).padStart(2, '0')}:${sec}`; };
const assEsc = (t) => t.replace(/\{/g, '(').replace(/\}/g, ')').replace(/\n/g, '\\N');

// ---------- script ----------
const NARR = {
  intro: 'This is Boss. You run five or six Claude Code sessions at once. Instead of typing into each tab, you talk to one assistant, and it puts your words into the right session.',
  arch: 'Everything runs on the Mac. Whisper turns speech into text locally. A small Claude session, Boss, decides where the words go and passes them on verbatim. Workers report back, and Boss reads the result to you.',
  dispatch: 'Say the session name, then the instruction. The words land in that session, it does the work, and the report comes back as one spoken line.',
  russian: 'Russian works the same way: Russian speech in, Russian report out.',
  ask: 'No session named, and two could fit. Boss does not guess. It asks, and the microphone opens for six seconds so you can just answer.',
  'worker-question': 'When a session needs a decision, the question comes to you as a card with buttons. Tap, or answer by voice.',
  status: 'Ask what everyone is doing, and Boss answers from the live session list, without disturbing anyone.',
  scratch: 'Changed your mind? Say scratch that. The session is told to drop the last instruction.',
  radio: 'Leaving the office? Say radio me, and a spoken recap of the reports goes to your phone for the commute. In this demo it is rendered, not sent.',
  tests: 'And the testing. Every flow you just saw is also an automated end to end test against real Claude sessions, including a real microphone in the room. Plus more than two hundred unit tests, and a dependency audit with zero known vulnerabilities.',
  close: 'What stayed synthetic: the commands were spoken by the Mac voice and fed in after the microphone. The display was asleep, so the panel is drawn from the app itself and the terminals from the real session text, not filmed off the screen. Boss, the workers and every answer were real.',
};

async function main() {
  // Boss answers, re-voiced.
  const answers = [];
  let n = 0;
  for (const s of tl.spoken ?? []) {
    const rt = new Date(s.at).getTime() - tl.t0;
    const f = join(W, 'voice', `boss${n++}.wav`);
    const d = await kokoro(s.text, f);
    answers.push({ rt, d, f, text: s.text, question: s.priority === 'question' });
  }
  // Narration.
  const narr = {};
  for (const [k, t] of Object.entries(NARR)) narr[k] = { text: t, f: join(W, 'voice', `n-${k}.wav`), d: await narrate(t, join(W, 'voice', `n-${k}.wav`)) };

  // Cards.
  const cards = {
    intro: card('intro', `<div class="k">Boss · phase 1</div><h1>One voice for all your<br>Claude Code sessions</h1><p>Hold a key, say “payments: run the tests”, keep working.<br>Boss puts the words in the right session and reads back the result.</p>`),
    arch: card('arch', `<div class="k">How it works</div><h1>Everything on the Mac</h1><div class="row">
      <div class="box"><b>Boss.app</b><span>menu-bar panel, hold-to-talk, local whisper large-v3-turbo, Kokoro voice</span></div><div class="arrow">→</div>
      <div class="box"><b>boss-channel</b><span>127.0.0.1 only, token, zero npm dependencies</span></div><div class="arrow">→</div>
      <div class="box"><b>Boss (Haiku)</b><span>routes verbatim, cannot run shell or edit files</span></div><div class="arrow">→</div>
      <div class="box"><b>Your sessions</b><span>Claude Code messaging; REPORT and QUESTION back</span></div></div>`),
    tests: card('tests', `<div class="k">Testing</div><h1>Tested end to end, for real</h1><ul>
      <li><span class="g">${C.e2e ?? '?'}</span> end-to-end scenarios against real Claude Code sessions, incl. a real microphone in the room</li>
      <li><span class="g">${C.swift ?? '?'}</span> Swift tests · <span class="g">${C.channel ?? '?'}</span> channel tests · <span class="g">${C.other ?? '?'}</span> supervisor, installer, voice tests</li>
      <li>Typecheck, installer round trip that restores your config byte for byte</li>
      <li>npm audit and pip-audit: <span class="g">0</span> known vulnerabilities · no Docker image to scan</li></ul>`),
    close: card('close', `<div class="k">What stayed synthetic</div><h1>Real product, synthetic voice in</h1><ul>
      <li>Commands were spoken by macOS <span class="m">say</span> and fed in after the mic</li>
      <li>Boss's answers re-voiced from its speech log with the app's voices (Kokoro, Milena)</li>
      <li>Display asleep: the panel is the app's real view rendered offscreen, the terminals are the real session text redrawn</li>
      <li>The real mic path is tested separately: speakers → webcam mic → whisper, ${C.micAccuracy ?? '?'} word accuracy</li>
      <li class="a">Still to check with you: the Right Option hotkey (needs Input Monitoring)</li></ul>`),
  };

  // Build the output timeline.
  const out = []; // {kind:'card'|'scene', ...}
  out.push({ kind: 'card', png: cards.intro, narr: narr.intro });
  out.push({ kind: 'card', png: cards.arch, narr: narr.arch });
  for (const sc of tl.scenes) out.push({ kind: 'scene', sc, narr: narr[sc.id], segs: normalWindows(sc, answers) });
  out.push({ kind: 'card', png: cards.tests, narr: narr.tests });
  out.push({ kind: 'card', png: cards.close, narr: narr.close });

  const panelList = [];
  const termList = [];
  const audio = []; // {f, at}
  const subs = [];
  let T = 0;
  const step = 1 / FPS;
  const pushFrame = (p, q, d) => { panelList.push({ f: p, d }); termList.push({ f: q, d }); };
  const blank = card('blank', '');
  let busyUntil = 0;
  const audioEnd = () => Math.max(busyUntil, ...audio.map((x) => x.at + (x.d ?? 0)));
  for (const item of out) {
    // Never start a narration over Boss still talking: hold the last frame until the audio ends.
    const quietAt = audioEnd();
    if (quietAt > T && panelList.length) {
      const last = { p: panelList.at(-1).f, q: termList.at(-1).f };
      pushFrame(last.p, last.q, quietAt - T + 0.4);
      T = quietAt + 0.4;
    }
    if (item.kind === 'card') {
      const d = item.narr.d + 1.2;
      pushFrame(item.png, item.png, d);
      audio.push({ f: item.narr.f, at: T + 0.4, d: item.narr.d });
      subs.push({ a: T + 0.4, b: T + 0.4 + item.narr.d, text: item.narr.text, style: 'Cap' });
      item.at = T; item.d = d;
      T += d;
      continue;
    }
    const { sc, segs } = item;
    item.at = T;
    // Hold the scene's first frame while the narration plays.
    const hold = (item.narr?.d ?? 0) + 0.6;
    pushFrame(frameAt(panel, sc.start).f, frameAt(term, sc.start).f, hold);
    if (item.narr) { audio.push({ f: item.narr.f, at: T + 0.2, d: item.narr.d }); subs.push({ a: T + 0.2, b: T + 0.2 + item.narr.d, text: item.narr.text, style: 'Cap' }); }
    subs.push({ a: T, b: T + hold, text: sc.title, style: 'Title' });
    T += hold;
    const sceneStart = T;
    for (const s of segs) {
      const outLen = (s.b - s.a) / 1000 / s.speed;
      if (outLen < step) continue;
      if (s.speed > 1) subs.push({ a: T, b: T + outLen, text: `▶▶ ${s.speed}×  waiting for the session`, style: 'Fast' });
      for (let o = 0; o < outLen; o += step) {
        const rt = s.a + o * 1000 * s.speed;
        pushFrame(frameAt(panel, rt).f, frameAt(term, rt).f, Math.min(step, outLen - o));
      }
      if (s.speed === 1) {
        for (const i of tl.injects) if (i.t >= s.a - 1 && i.t < s.b) {
          audio.push({ f: i.wav, at: T + (i.t - s.a) / 1000, d: i.dur });
          subs.push({ a: T + (i.t - s.a) / 1000, b: T + (i.t - s.a) / 1000 + i.dur, text: `🎙  “${i.text}”`, style: 'You' });
        }
        for (const an of answers) if (an.rt >= s.a && an.rt < s.b) {
          audio.push({ f: join(REC, '..', '..', '..', 'sounds', 'radio_open.wav'), at: T + (an.rt - s.a) / 1000 - 0.2 });
          audio.push({ f: an.f, at: T + (an.rt - s.a) / 1000, d: an.d });
          subs.push({ a: T + (an.rt - s.a) / 1000, b: T + (an.rt - s.a) / 1000 + an.d, text: `🔊  ${an.text}`, style: 'Boss' });
        }
      }
      T += outLen;
    }
    subs.push({ a: sceneStart, b: T, text: sc.title, style: 'Title' });
    item.d = T - item.at;
  }
  void blank;
  console.log(`output length ${T.toFixed(1)} s`);

  // Concat lists.
  const writeList = (list, name) => {
    const f = join(W, `${name}.ffconcat`);
    const lines = ['ffconcat version 1.0'];
    for (const x of list) lines.push(`file '${x.f.replace(/'/g, "'\\''")}'`, `duration ${x.d.toFixed(3)}`);
    lines.push(`file '${list.at(-1).f.replace(/'/g, "'\\''")}'`);
    writeFileSync(f, lines.join('\n'));
    return f;
  };
  const pl = writeList(panelList, 'panel');
  const tlist = writeList(termList, 'term');

  // Captions: this ffmpeg has no libass/freetype, so each caption state is a transparent PNG
  // rendered by Chrome, played as one more concat stream over the video.
  const CAP_CSS = `html,body{margin:0;width:1920px;height:1080px;background:transparent;font-family:-apple-system,"SF Pro Display",Helvetica,sans-serif}
  .title{position:absolute;left:70px;top:26px;color:#8ab4f8;font-size:40px;font-weight:700}
  .fast{position:absolute;right:64px;top:30px;color:#c4c7cc;font-size:28px;background:rgba(16,17,22,.85);padding:6px 16px;border-radius:10px}
  .bottom{position:absolute;left:0;right:0;bottom:30px;display:flex;flex-direction:column;align-items:center;gap:12px}
  .line{max-width:1640px;font-size:34px;line-height:1.3;padding:10px 22px;border-radius:12px;background:rgba(16,17,22,.88);text-align:center}
  .Cap{color:#e8eaed}.You{color:#fdd663;font-weight:600}.Boss{color:#81c995;font-weight:600}`;
  const cuts = [...new Set(subs.flatMap((x) => [x.a, x.b]).concat([0, T]))].filter((x) => x >= 0 && x <= T).sort((a, b) => a - b);
  const capDir = join(W, 'caps');
  mkdirSync(capDir, { recursive: true });
  const capList = [];
  const rendered = new Map();
  for (let i = 0; i < cuts.length - 1; i++) {
    const a = cuts[i], b = cuts[i + 1];
    if (b - a < 0.02) continue;
    const mid = (a + b) / 2;
    const act = subs.filter((x) => x.a <= mid && x.b > mid);
    const title = act.find((x) => x.style === 'Title');
    const fast = act.find((x) => x.style === 'Fast');
    const lines = ['You', 'Boss', 'Cap'].flatMap((st) => act.filter((x) => x.style === st));
    const html = `<!doctype html><meta charset="utf-8"><style>${CAP_CSS}</style><body>` +
      (title ? `<div class="title">${esc(title.text)}</div>` : '') + (fast ? `<div class="fast">${esc(fast.text)}</div>` : '') +
      `<div class="bottom">${lines.map((x) => `<div class="line ${x.style}">${esc(x.text)}</div>`).join('')}</div></body>`;
    let png = rendered.get(html);
    if (!png) {
      png = join(capDir, `cap${rendered.size}.png`);
      const hf = png.replace(/\.png$/, '.html');
      writeFileSync(hf, html);
      execFileSync(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--default-background-color=00000000', `--screenshot=${png}`, '--window-size=1920,1080', '--force-device-scale-factor=1', `file://${hf}`], { stdio: 'ignore' });
      rendered.set(html, png);
    }
    capList.push({ f: png, d: b - a });
  }
  const cl = writeList(capList, 'caps');
  console.log(`captions: ${rendered.size} states`);

  // Video: background, panel left, terminal right; cards are full-frame in both streams, so scale them alike.
  const video = join(W, 'video.mp4');
  ff(['-f', 'lavfi', '-i', `color=c=0x0e1116:s=1920x1080:r=${FPS}:d=${T.toFixed(2)}`,
    '-f', 'concat', '-safe', '0', '-i', pl, '-f', 'concat', '-safe', '0', '-i', tlist, '-f', 'concat', '-safe', '0', '-i', cl,
    '-filter_complex',
    `[1:v]scale=w='if(gte(iw,1900),1920,-2)':h='if(gte(iw,1900),1080,900)',setsar=1,fps=${FPS}[p];` +
    `[2:v]scale=w='if(gte(iw,1900),1920,1180)':h='if(gte(iw,1900),1080,-2)',setsar=1,fps=${FPS}[t];` +
    `[0:v][t]overlay=x='if(gte(overlay_w,1900),0,670)':y='if(gte(overlay_w,1900),0,96)':shortest=1[bt];` +
    `[bt][p]overlay=x='if(gte(overlay_w,1900),0,70)':y='if(gte(overlay_w,1900),0,96)':shortest=1[v0];` +
    `[3:v]format=rgba,fps=${FPS}[c];[v0][c]overlay=0:0:shortest=1[v]`,
    '-map', '[v]', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'medium', '-crf', '20', '-r', '30', video]);

  // Audio: every clip at its time.
  const audioFile = join(W, 'audio.m4a');
  const ins = audio.flatMap((a) => ['-i', a.f]);
  const parts = audio.map((a, i) => `[${i}:a]aresample=48000,aformat=channel_layouts=stereo,adelay=${Math.max(0, Math.round(a.at * 1000))}|${Math.max(0, Math.round(a.at * 1000))}[a${i}]`).join(';');
  ff([...ins, '-filter_complex', `${parts};${audio.map((_, i) => `[a${i}]`).join('')}amix=inputs=${audio.length}:normalize=0:dropout_transition=0,apad,atrim=0:${T.toFixed(2)}[out]`, '-map', '[out]', '-c:a', 'aac', '-b:a', '160k', audioFile]);
  ff(['-i', video, '-i', audioFile, '-c:v', 'copy', '-c:a', 'copy', '-shortest', '-movflags', '+faststart', OUTFILE]);
  writeFileSync(join(W, 'cut.json'), JSON.stringify({ length_s: T, items: out.map((o) => ({ kind: o.kind, id: o.sc?.id, at: o.at, d: o.d, segs: o.segs })) }, null, 2));
  console.log(`wrote ${OUTFILE} (${dur(OUTFILE).toFixed(1)} s)`);
}

main().catch((e) => { console.error(e); process.exit(1); });
