#!/usr/bin/env node
// boss-up: starts and keeps the Boss Claude Code session alive in a hidden tmux pane.
//
//   boss-up start     start Boss if it is not healthy (idempotent), wait until the channel is connected
//   boss-up stop      stop the Boss pane
//   boss-up restart   stop, then start
//   boss-up status    print {tmux, channel} as JSON
//   boss-up keep      supervise forever: restart when unhealthy, and every night at 04:00 local time
//
// Env: BOSS_HOME (~/Boss), BOSS_PORT (8788), BOSS_TMUX_SOCKET (boss), BOSS_TMUX_SESSION (boss),
//      BOSS_NAME (boss), BOSS_MODEL (haiku), BOSS_ALLOW (*), BOSS_CLAUDE (claude), BOSS_EXTRA_ARGS.
// Startup screens (trust folder, new MCP server, development-channels warning) are answered by
// reading the pane and picking the safe option by its text; an unknown screen is reported, never guessed.
import { execFileSync, spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const env = process.env;
const HOME = env.BOSS_HOME ?? join(homedir(), 'Boss');
const PORT = Number(env.BOSS_PORT ?? 8788);
const SOCK = env.BOSS_TMUX_SOCKET ?? 'boss';
const SESS = env.BOSS_TMUX_SESSION ?? 'boss';
const NAME = env.BOSS_NAME ?? 'boss';
const MODEL = env.BOSS_MODEL ?? 'haiku';
const CLAUDE = env.BOSS_CLAUDE ?? 'claude';
const TMUX = existsSync('/opt/homebrew/bin/tmux') ? '/opt/homebrew/bin/tmux' : 'tmux';
const WORKDIR = env.BOSS_WORKDIR ?? join(HOME, 'boss');

// Each known screen: a marker that identifies it, and the option to choose (matched by text).
export const SCREENS = [
  { id: 'trust', marker: /trust this folder/i, choose: /Yes, I trust this folder/i },
  { id: 'mcp', marker: /New MCP server found/i, choose: /^\s*(?:❯\s*)?(?:\d+\.\s*)?Use this MCP server\s*$/i },
  { id: 'devchannels', marker: /Loading development channels/i, choose: /I am using this for local development/i },
  { id: 'automode', marker: /Teach auto mode/i, choose: /Not now/i },
];

export function log(event, fields = {}) {
  try {
    mkdirSync(join(HOME, 'logs'), { recursive: true });
    appendFileSync(join(HOME, 'logs', 'boss-up.log'), JSON.stringify({ at: new Date().toISOString(), event, ...fields }) + '\n');
  } catch { /* never break on logging */ }
}

function tmux(...args) {
  return spawnSync(TMUX, ['-L', SOCK, ...args], { encoding: 'utf8' });
}

export function paneText() {
  const r = tmux('capture-pane', '-p', '-t', SESS);
  return r.status === 0 ? r.stdout : null;
}

export function hasSession() {
  return tmux('has-session', '-t', SESS).status === 0;
}

/**
 * Given a pane and a wanted option, returns the keys that move the ❯ cursor onto it and press Enter.
 * Menu options are the lines between the marker and "Enter to confirm"; the cursor line starts with ❯.
 */
export function keysFor(text, choose) {
  const lines = text.split('\n');
  const end = lines.findIndex((l) => /Enter to confirm/i.test(l));
  const scope = end > 0 ? lines.slice(0, end) : lines;
  const options = [];
  for (let i = 0; i < scope.length; i++) {
    const l = scope[i];
    if (/^\s*(❯\s*)?(\d+\.\s+)?\S/.test(l) && (/^\s{2,}/.test(l) || /❯/.test(l))) options.push({ i, line: l, cursor: /❯/.test(l) });
  }
  // Options are the trailing contiguous block of indented lines that contains the cursor.
  const cur = options.findIndex((o) => o.cursor);
  if (cur < 0) return null;
  let lo = cur, hi = cur;
  while (lo > 0 && options[lo - 1].i === options[lo].i - 1) lo--;
  while (hi < options.length - 1 && options[hi + 1].i === options[hi].i + 1) hi++;
  const block = options.slice(lo, hi + 1);
  const want = block.findIndex((o) => choose.test(o.line.replace(/❯/, ' ')));
  if (want < 0) return null;
  const delta = want - (cur - lo);
  const keys = [];
  for (let k = 0; k < Math.abs(delta); k++) keys.push(delta > 0 ? 'Down' : 'Up');
  keys.push('Enter');
  return keys;
}

function token() {
  try { return readFileSync(join(HOME, 'token'), 'utf8').trim(); } catch { return ''; }
}

export async function health() {
  try {
    const r = await fetch(`http://127.0.0.1:${PORT}/health`, { headers: { authorization: `Bearer ${token()}` }, signal: AbortSignal.timeout(2000) });
    if (!r.ok) return { ok: false, status: r.status };
    return await r.json();
  } catch (e) {
    return { ok: false, error: String(e.cause?.code ?? e.message) };
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function launchCommand() {
  const extra = env.BOSS_EXTRA_ARGS ? ` ${env.BOSS_EXTRA_ARGS}` : '';
  const vars = ['BOSS_ALLOW', 'BOSS_HUMOR', 'BOSS_CONFIRM_MS']
    .filter((k) => env[k] !== undefined).map((k) => `${k}=${shq(env[k])}`).join(' ');
  return `env ${vars} BOSS_HOME=${shq(HOME)} BOSS_PORT=${PORT} BOSS_NAME=${shq(NAME)} ${shq(CLAUDE)} --name ${shq(NAME)} --model ${shq(MODEL)} --effort low --setting-sources project,local --settings ${shq(JSON.stringify({ crossSessionInbound: 'accept', autoMemoryEnabled: false }))} --system-prompt-file ${shq(join(WORKDIR, 'BOSS_PROMPT.md'))} --dangerously-load-development-channels server:boss-channel${extra}`;
}

function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

export async function start({ timeoutMs = 90_000 } = {}) {
  const h = await health();
  if (hasSession() && h.boss_connected) {
    log('start_noop', { reason: 'already healthy' });
    return { ok: true, already: true };
  }
  if (hasSession()) stop('unhealthy before start');
  if (!existsSync(WORKDIR)) throw new Error(`Boss home ${WORKDIR} is missing; run install/install.sh`);
  const t0 = Date.now();
  const r = tmux('new-session', '-d', '-s', SESS, '-x', '200', '-y', '50', '-c', WORKDIR, launchCommand());
  if (r.status !== 0) throw new Error(`tmux new-session failed: ${r.stderr}`);
  log('launched', { cmd: launchCommand() });
  const answered = new Set();
  while (Date.now() - t0 < timeoutMs) {
    await sleep(700);
    if (!hasSession()) {
      log('start_failed', { reason: 'pane exited' });
      return { ok: false, error: 'the Boss pane exited during start' };
    }
    const text = paneText() ?? '';
    const screen = SCREENS.find((s) => s.marker.test(text));
    if (screen) {
      const keys = keysFor(text, screen.choose);
      if (!keys) {
        log('start_unknown_menu', { screen: screen.id, tail: text.slice(-600) });
        continue;
      }
      tmux('send-keys', '-t', SESS, ...keys);
      answered.add(screen.id);
      log('answered', { screen: screen.id, keys });
      await sleep(900);
      continue;
    }
    const hh = await health();
    if (hh.boss_connected) {
      log('started', { ms: Date.now() - t0, answered: [...answered] });
      return { ok: true, ms: Date.now() - t0, answered: [...answered] };
    }
  }
  const tail = (paneText() ?? '').trim().split('\n').slice(-12).join('\n');
  log('start_timeout', { tail });
  return { ok: false, error: 'Boss did not connect in time', tail };
}

export function stop(reason = 'requested') {
  const had = hasSession();
  if (had) tmux('kill-session', '-t', SESS);
  log('stopped', { reason, had });
  return { ok: true, had };
}

export async function status() {
  return { tmux: hasSession(), channel: await health(), session: SESS, socket: SOCK };
}

async function keep() {
  let bad = 0;
  let lastNight = '';
  for (;;) {
    const now = new Date();
    const day = now.toDateString();
    if (now.getHours() === 4 && lastNight !== day) {
      lastNight = day;
      log('nightly_restart', {});
      stop('nightly');
      await start().catch((e) => log('start_error', { error: e.message }));
    }
    const h = await health();
    const alive = hasSession();
    if (alive && h.boss_connected) bad = 0;
    else bad++;
    if (bad >= 3) {
      log('unhealthy', { alive, health: h });
      const r = await start().catch((e) => ({ ok: false, error: e.message }));
      log('restart_result', r);
      bad = 0;
    }
    await sleep(10_000);
  }
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('boss-up')) {
  const cmd = process.argv[2] ?? 'status';
  const run = {
    start: () => start(),
    stop: () => stop(),
    restart: async () => { stop('restart'); return start(); },
    status: () => status(),
    keep: () => keep(),
  }[cmd];
  if (!run) {
    console.error('usage: boss-up start|stop|restart|status|keep');
    process.exit(2);
  }
  Promise.resolve(run()).then((r) => {
    if (r !== undefined) console.log(JSON.stringify(r));
    process.exit(r && r.ok === false ? 1 : 0);
  }, (e) => {
    console.error(`boss-up: ${e.message}`);
    log('error', { cmd, error: e.message });
    process.exit(1);
  });
}
