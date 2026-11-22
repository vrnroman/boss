// E2E helpers: an isolated Boss home, throwaway worker sessions in a private tmux socket, and a
// client that talks to the channel like Boss.app does. Nothing here touches the user's own sessions:
// test sessions are named bt-*, the test Boss is "bt-boss", and the channel's allow list is "bt-*".
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { request } from 'node:http';

export const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
export const TMUX = existsSync('/opt/homebrew/bin/tmux') ? '/opt/homebrew/bin/tmux' : 'tmux';
export const SOCK = process.env.E2E_SOCK ?? 'bt';
export const BOSS_NAME = 'bt-boss';
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const sgt = (d = new Date()) => new Date(d.getTime() + 8 * 3600_000).toISOString().slice(11, 19) + ' SGT';

export function tmux(...args) {
  return spawnSync(TMUX, ['-L', SOCK, ...args], { encoding: 'utf8' });
}

export function pane(name) {
  const r = tmux('capture-pane', '-p', '-J', '-S', '-200', '-t', name);
  return r.status === 0 ? r.stdout : '';
}

/** Builds an isolated Boss home: token, state, and boss/ from boss-home with paths filled in. */
export function makeHome(dir) {
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(join(dir, 'state'), { recursive: true });
  writeFileSync(join(dir, 'token'), randomBytes(32).toString('hex') + '\n', { mode: 0o600 });
  cpSync(join(REPO, 'boss-home'), join(dir, 'boss'), { recursive: true });
  const mcp = join(dir, 'boss', '.mcp.json');
  writeFileSync(mcp, readFileSync(mcp, 'utf8').replace('__NODE__', process.execPath).replace('__BOSS_CHANNEL__', join(REPO, 'channel', 'src', 'server.ts')));
  return { dir, token: readFileSync(join(dir, 'token'), 'utf8').trim() };
}

export function workerBlock(bossName = BOSS_NAME) {
  return readFileSync(join(REPO, 'install', 'worker-block.md'), 'utf8').replaceAll('__BOSS__', bossName);
}

const WORKER_SCREENS = [
  { marker: /trust this folder/i, choose: /Yes, I trust this folder/i },
  { marker: /Bypass Permissions mode/i, choose: /Yes, I accept/i },
  { marker: /Teach auto mode/i, choose: /Not now/i },
];

export async function answerScreens(name, screens, readyRe, timeoutMs = 60_000) {
  const { keysFor } = await import(join(REPO, 'bin', 'boss-up.mjs'));
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    await sleep(700);
    const text = pane(name);
    const s = screens.find((x) => x.marker.test(text));
    if (s) {
      const keys = keysFor(text, s.choose);
      if (keys) { tmux('send-keys', '-t', name, ...keys); await sleep(900); continue; }
    }
    if (readyRe.test(text)) return true;
  }
  throw new Error(`${name} did not become ready:\n${pane(name).split('\n').slice(-15).join('\n')}`);
}

/** Starts a throwaway worker session `name` in `folder`, primed with the worker block. */
export async function startWorker(name, folder, { model = 'haiku' } = {}) {
  mkdirSync(folder, { recursive: true });
  tmux('kill-session', '-t', name);
  const settings = JSON.stringify({ skipDangerousModePermissionPrompt: true, crossSessionInbound: 'accept', autoMemoryEnabled: false });
  const cmd = ['claude', '--name', name, '--model', model, '--effort', 'low', '--dangerously-skip-permissions',
    '--setting-sources', 'project,local', '--settings', settings, '--append-system-prompt', workerBlock()]
    .map((a) => `'${a.replace(/'/g, `'\\''`)}'`).join(' ');
  const r = tmux('new-session', '-d', '-s', name, '-x', '200', '-y', '50', '-c', folder, cmd);
  if (r.status !== 0) throw new Error(r.stderr);
  await answerScreens(name, WORKER_SCREENS, /❯\s*$|❯ Try|bypass permissions on/m);
  return name;
}

export function killAll() {
  tmux('kill-server');
}

export class Client {
  constructor(port, token) {
    this.port = port;
    this.token = token;
    this.events = [];
    this.waiters = [];
  }

  http(method, path, body) {
    return new Promise((resolve, reject) => {
      const data = body === undefined ? undefined : JSON.stringify(body);
      const req = request({ host: '127.0.0.1', port: this.port, method, path, headers: {
        authorization: `Bearer ${this.token}`, ...(data ? { 'content-type': 'application/json' } : {}) } }, (res) => {
        let t = '';
        res.on('data', (c) => (t += c));
        res.on('end', () => { let json; try { json = JSON.parse(t); } catch {} resolve({ status: res.statusCode, json }); });
      });
      req.on('error', reject);
      if (data) req.write(data);
      req.end();
    });
  }

  listen() {
    return new Promise((ready) => {
      let buf = '';
      this.req = request({ host: '127.0.0.1', port: this.port, path: '/events', headers: { authorization: `Bearer ${this.token}` } }, (res) => {
        res.setEncoding('utf8');
        res.on('data', (c) => {
          if (buf === '' && c.startsWith(': boss-channel')) ready();
          buf += c;
          let i;
          while ((i = buf.indexOf('\n\n')) >= 0) {
            const block = buf.slice(0, i);
            buf = buf.slice(i + 2);
            const e = {};
            for (const line of block.split('\n')) {
              if (line.startsWith(':')) continue;
              const k = line.slice(0, line.indexOf(': '));
              e[k] = line.slice(line.indexOf(': ') + 2);
            }
            if (!e.event) continue;
            const ev = { event: e.event, data: JSON.parse(e.data), t: Date.now() };
            this.events.push(ev);
            if (process.env.E2E_VERBOSE) console.log(`  [${sgt()}] ${ev.event} ${JSON.stringify(ev.data).slice(0, 200)}`);
            for (const w of [...this.waiters]) if (w.pred(ev)) { this.waiters.splice(this.waiters.indexOf(w), 1); w.resolve(ev); }
          }
        });
      });
      this.req.on('error', () => {});
      this.req.end();
    });
  }

  until(pred, ms = 60_000, label = 'event') {
    const f = this.events.find(pred);
    if (f) return Promise.resolve(f);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timeout (${ms} ms) waiting for ${label}`)), ms);
      this.waiters.push({ pred, resolve: (e) => { clearTimeout(t); resolve(e); } });
    });
  }

  close() { this.req?.destroy(); }
}

/** Live Claude Code sessions as the app sends them: [{name, cwd, status}] (pid alive, interactive). */
export function liveSessions(filter = /^bt-/) {
  const dir = join(process.env.HOME, '.claude', 'sessions');
  const out = [];
  for (const f of (spawnSync('ls', [dir], { encoding: 'utf8' }).stdout || '').split('\n').filter((x) => x.endsWith('.json'))) {
    try {
      const s = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      try { process.kill(s.pid, 0); } catch { continue; }
      if (s.kind !== 'interactive' || !s.name || !filter.test(s.name) || s.name === BOSS_NAME) continue;
      out.push({ name: s.name, cwd: s.cwd, status: s.status });
    } catch { /* torn file */ }
  }
  return out;
}

/** Everything a session's transcript holds as text (to check words arrived verbatim). */
export function transcript(name) {
  const dir = join(process.env.HOME, '.claude', 'sessions');
  for (const f of (spawnSync('ls', [dir], { encoding: 'utf8' }).stdout || '').split('\n').filter((x) => x.endsWith('.json'))) {
    try {
      const s = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      if (s.name !== name) continue;
      try { process.kill(s.pid, 0); } catch { continue; }
      const p = join(process.env.HOME, '.claude', 'projects', s.cwd.replace(/[^A-Za-z0-9]/g, '-'), `${s.sessionId}.jsonl`);
      return existsSync(p) ? readFileSync(p, 'utf8') : '';
    } catch { /* keep looking */ }
  }
  return '';
}

/** Removes the Claude Code project folders that test sessions under `root` created. */
export function cleanProjects(root) {
  const base = join(process.env.HOME, '.claude', 'projects');
  const keys = [root, root.replace(/^\/var\//, '/private/var/')].map((r) => r.replace(/[^A-Za-z0-9]/g, '-'));
  for (const d of (spawnSync('ls', [base], { encoding: 'utf8' }).stdout || '').split('\n')) {
    if (d && keys.some((k) => d.startsWith(k))) rmSync(join(base, d), { recursive: true, force: true });
  }
}
