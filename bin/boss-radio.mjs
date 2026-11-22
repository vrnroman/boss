#!/usr/bin/env node
// boss-radio: "radio me". Turns the recent reports and open questions into one spoken team-radio
// recap (Kokoro voice for English, macOS Milena for Russian, radio clicks between items) and sends
// it to Roman's Telegram as one audio file, for listening on the MRT. Only runs when he asks.
//
//   boss-radio.mjs [--hours N] [--dry]     --dry renders the file and sends nothing
// Env: BOSS_HOME (~/Boss), BOSS_TTS_URL (http://127.0.0.1:8792), BOSS_SOUNDS (dir with radio_*.wav),
//      BOSS_RADIO_DRY=1 (same as --dry), TELEGRAM_ENV (~/.claude/secrets/telegram.env)
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HOME = process.env.BOSS_HOME ?? join(homedir(), 'Boss');
const TTS = process.env.BOSS_TTS_URL ?? 'http://127.0.0.1:8792';
const HERE = dirname(fileURLToPath(import.meta.url));
const SOUNDS = process.env.BOSS_SOUNDS ?? [join(HOME, 'app', 'sounds'), join(HERE, '..', 'sounds')].find((d) => existsSync(join(d, 'radio_open.wav')));
const MAX_ITEMS = 8;

export const sgt = (d) => new Date(d.getTime() + 8 * 3600_000).toISOString().slice(11, 16) + ' SGT';
const isRu = (t) => /[а-яё]/i.test(t);

/** Picks what goes on air: reports since the cutoff (newest last, at most 8) and questions still open. */
export function pickItems(events, questions, sinceMs) {
  const reports = events
    .filter((e) => e.type === 'say' && e.data?.kind === 'report' && Date.parse(e.at) >= sinceMs)
    .map((e) => ({ kind: 'report', text: String(e.data.text), at: e.at, lang: e.data.lang }));
  const open = (questions ?? []).map((q) => ({ kind: 'question', text: `${q.session ? q.session + ' asks: ' : ''}${q.question}`, at: q.at, lang: q.lang }));
  return { reports: reports.slice(-MAX_ITEMS), questions: open.slice(0, 3), dropped: Math.max(0, reports.length - MAX_ITEMS) };
}

/** The spoken script, one segment per item, with an intro and an outro. */
export function script({ reports, questions, dropped }, now = new Date()) {
  const segs = [];
  const n = reports.length;
  const q = questions.length;
  segs.push({ text: `Boss radio, ${sgt(now).replace(' SGT', '')} Singapore time. ${n === 0 ? 'No new reports' : n === 1 ? 'One report' : `${n} reports`}${q ? `, ${q === 1 ? 'one question' : `${q} questions`} waiting for you` : ''}.`, lang: 'en' });
  for (const r of reports) segs.push({ text: r.text, lang: r.lang === 'ru' || isRu(r.text) ? 'ru' : 'en' });
  if (dropped) segs.push({ text: `And ${dropped} older ${dropped === 1 ? 'report' : 'reports'} in the panel.`, lang: 'en' });
  for (const x of questions) segs.push({ text: x.text, lang: x.lang === 'ru' || isRu(x.text) ? 'ru' : 'en' });
  segs.push({ text: 'Boss out.', lang: 'en' });
  return segs;
}

async function speakTo(seg, out) {
  if (seg.lang === 'en') {
    try {
      const r = await fetch(`${TTS}/speak`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: seg.text, lang: 'en' }), signal: AbortSignal.timeout(30_000) });
      if (r.ok) { writeFileSync(out, Buffer.from(await r.arrayBuffer())); return 'kokoro'; }
    } catch { /* fall through to the system voice */ }
  }
  const aiff = out.replace(/\.wav$/, '.aiff');
  execFileSync('say', ['-v', seg.lang === 'ru' ? 'Milena' : 'Samantha', '-o', aiff, seg.text]);
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-i', aiff, '-ar', '24000', '-ac', '1', out]);
  return 'system';
}

/** Renders the segments with radio clicks between them into one AAC file; returns {path, seconds}. */
export async function render(segs, dir) {
  mkdirSync(dir, { recursive: true });
  const parts = [];
  const voices = [];
  for (let i = 0; i < segs.length; i++) {
    if (SOUNDS) parts.push(join(SOUNDS, 'radio_open.wav'));
    const f = join(dir, `seg${i}.wav`);
    voices.push(await speakTo(segs[i], f));
    parts.push(f);
    if (SOUNDS) parts.push(join(SOUNDS, 'radio_close.wav'));
  }
  const inputs = parts.flatMap((p) => ['-i', p]);
  const norm = parts.map((_, i) => `[${i}:a]aresample=24000,aformat=channel_layouts=mono[a${i}]`).join(';');
  const cat = parts.map((_, i) => `[a${i}]`).join('') + `concat=n=${parts.length}:v=0:a=1[out]`;
  const out = join(dir, `boss-radio-${Date.now()}.m4a`);
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', ...inputs, '-filter_complex', `${norm};${cat}`, '-map', '[out]', '-c:a', 'aac', '-b:a', '64k', out]);
  const seconds = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out], { encoding: 'utf8' }).trim());
  for (let i = 0; i < segs.length; i++) rmSync(join(dir, `seg${i}.wav`), { force: true }), rmSync(join(dir, `seg${i}.aiff`), { force: true });
  return { path: out, seconds, voices };
}

function sendTelegram(path, caption) {
  const envFile = process.env.TELEGRAM_ENV ?? join(homedir(), '.claude', 'secrets', 'telegram.env');
  const env = Object.fromEntries(readFileSync(envFile, 'utf8').split('\n').map((l) => /^\s*(?:export\s+)?([A-Z_]+)=["']?([^"'\n]*)["']?/.exec(l)).filter(Boolean).map((m) => [m[1], m[2]]));
  if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) throw new Error('telegram.env has no token or chat id');
  const r = spawnSync('curl', ['-sS', '--max-time', '60', '--form-string', `chat_id=${env.TELEGRAM_CHAT_ID}`, '--form-string', `caption=${caption}`,
    '--form-string', 'title=Boss radio', '-F', `audio=@${path};type=audio/mp4`, `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendAudio`], { encoding: 'utf8' });
  const j = JSON.parse(r.stdout || '{}');
  if (!j.ok) throw new Error(`telegram refused: ${(r.stdout || r.stderr).slice(0, 200)}`);
}

/** Telegram only from the real install (same rule as the app): never from a test, demo or sandbox. */
export function sendAllowed(env = process.env, home = HOME) {
  if (env.BOSS_RADIO_DRY === '1' || env.BOSS_NO_TELEGRAM === '1' || env.BOSS_DEBUG_CONTROL === '1') return false;
  return resolve(home) === resolve(join(homedir(), 'Boss'));
}

export async function radio({ hours, dry = !sendAllowed(), now = new Date() } = {}) {
  if (!sendAllowed()) dry = true;
  const st = join(HOME, 'state');
  const lastFile = join(st, 'radio-last.json');
  const last = existsSync(lastFile) ? Date.parse(JSON.parse(readFileSync(lastFile, 'utf8')).at) : 0;
  const since = hours ? now.getTime() - hours * 3600_000 : Math.max(last, now.getTime() - 8 * 3600_000);
  const evFile = join(st, 'events.jsonl');
  const events = existsSync(evFile) ? readFileSync(evFile, 'utf8').trim().split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean) : [];
  const chFile = join(st, 'channel.json');
  const questions = existsSync(chFile) ? JSON.parse(readFileSync(chFile, 'utf8')).questions ?? [] : [];
  const items = pickItems(events, questions, since);
  const segs = script(items, now);
  const out = await render(segs, join(HOME, 'radio'));
  const caption = `Boss radio, ${sgt(now)}: ${items.reports.length} reports, ${items.questions.length} questions`;
  if (!dry) {
    sendTelegram(out.path, caption);
    writeFileSync(lastFile, JSON.stringify({ at: now.toISOString() }));
  }
  return { ok: true, sent: !dry, reports: items.reports.length, questions: items.questions.length, seconds: Math.round(out.seconds), path: out.path, voices: out.voices };
}

if (process.argv[1]?.endsWith('boss-radio.mjs')) {
  const args = process.argv.slice(2);
  const hi = args.indexOf('--hours');
  radio({ hours: hi >= 0 ? Number(args[hi + 1]) : undefined, dry: args.includes('--dry') || !sendAllowed() })
    .then((r) => console.log(JSON.stringify(r)), (e) => { console.error(`boss-radio: ${e.message}`); process.exit(1); });
}
