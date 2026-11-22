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
  const r = await fetch('http://127.0.0.1:8792/speak', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text, lang: 'en', voice }) });
  if (r.status === 422 || !r.ok) {
    const aiff = file.replace(/\.wav$/, '.aiff');
    execFileSync('say', ['-v', /[а-яё]/i.test(text) ? 'Milena' : 'Samantha', '-o', aiff, text]);
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
const term = framesOf('term');

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
  radio: 'Leaving the office? Say radio me, and a spoken recap of the reports goes to your phone for the commute.',
  tests: 'And the testing. Every flow you just saw is also an automated end to end test against real Claude sessions, including a real microphone in the room. Plus more than two hundred unit tests, and a dependency audit with zero known vulnerabilities.',
  close: 'What stayed synthetic in this film: the commands were spoken by the Mac voice and fed in after the microphone, so the recording is clean. The microphone path itself is tested separately, through the speakers and the webcam mic. Everything else was the real product.',
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
      <li>Boss's answers re-voiced from its speech log, same Kokoro voice</li>
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
  for (const item of out) {
    if (item.kind === 'card') {
      const d = item.narr.d + 1.2;
      pushFrame(item.png, item.png, d);
      audio.push({ f: item.narr.f, at: T + 0.4 });
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
    if (item.narr) { audio.push({ f: item.narr.f, at: T + 0.2 }); subs.push({ a: T + 0.2, b: T + 0.2 + item.narr.d, text: item.narr.text, style: 'Cap' }); }
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
          audio.push({ f: i.wav, at: T + (i.t - s.a) / 1000 });
          subs.push({ a: T + (i.t - s.a) / 1000, b: T + (i.t - s.a) / 1000 + i.dur, text: `🎙  “${i.text}”`, style: 'You' });
        }
        for (const an of answers) if (an.rt >= s.a && an.rt < s.b) {
          audio.push({ f: join(REC, '..', '..', '..', 'sounds', 'radio_open.wav'), at: T + (an.rt - s.a) / 1000 - 0.2 });
          audio.push({ f: an.f, at: T + (an.rt - s.a) / 1000 });
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

  // Subtitles (ASS).
  const ass = [`[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding`,
    'Style: Title,Helvetica Neue,40,&H00F8B48A,&H00FFFFFF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,0,0,7,64,64,28,1',
    'Style: Cap,Helvetica Neue,34,&H00EDEAE8,&H00FFFFFF,&H00161110,&HB0161110,0,0,0,0,100,100,0,0,3,14,0,2,120,120,36,1',
    'Style: You,Helvetica Neue,36,&H0063D6FD,&H00FFFFFF,&H00161110,&HB0161110,1,0,0,0,100,100,0,0,3,12,0,2,120,120,110,1',
    'Style: Boss,Helvetica Neue,36,&H0081C995,&H00FFFFFF,&H00161110,&HB0161110,1,0,0,0,100,100,0,0,3,12,0,2,120,120,110,1',
    'Style: Fast,Helvetica Neue,30,&H00C4C7CC,&H00FFFFFF,&H00161110,&HC0161110,0,0,0,0,100,100,0,0,3,10,0,9,64,64,28,1',
    '\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text'];
  for (const s of subs) ass.push(`Dialogue: 0,${assTime(s.a)},${assTime(s.b)},${s.style},,0,0,0,,${assEsc(s.text)}`);
  const assFile = join(W, 'subs.ass');
  writeFileSync(assFile, ass.join('\n'));

  // Video: background, panel left, terminal right; cards are full-frame in both streams, so scale them alike.
  const video = join(W, 'video.mp4');
  ff(['-f', 'lavfi', '-i', `color=c=0x0e1116:s=1920x1080:r=${FPS}:d=${T.toFixed(2)}`,
    '-f', 'concat', '-safe', '0', '-i', pl, '-f', 'concat', '-safe', '0', '-i', tlist,
    '-filter_complex',
    `[1:v]scale=w='if(gte(iw,1900),1920,-2)':h='if(gte(iw,1900),1080,900)',setsar=1,fps=${FPS}[p];` +
    `[2:v]scale=w='if(gte(iw,1900),1920,1180)':h='if(gte(iw,1900),1080,-2)',setsar=1,fps=${FPS}[t];` +
    `[0:v][t]overlay=x='if(gte(overlay_w,1900),0,670)':y='if(gte(overlay_w,1900),0,96)':shortest=1[bt];` +
    `[bt][p]overlay=x='if(gte(overlay_w,1900),0,70)':y='if(gte(overlay_w,1900),0,96)':shortest=1[v0];` +
    `[v0]subtitles='${assFile}'[v]`,
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
