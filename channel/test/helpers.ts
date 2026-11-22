// Test harness: runs the real server.ts as a child process, plays Claude Code on its stdio,
// and talks HTTP to it like Boss.app does.
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:net';
import { request } from 'node:http';

export async function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => resolve(p));
    });
  });
}

export type Msg = { jsonrpc: string; id?: number | string; method?: string; params?: any; result?: any; error?: any };

export class Harness {
  child!: ChildProcess;
  home: string;
  port = 0;
  token = 'a'.repeat(64);
  msgs: Msg[] = [];
  waiters: { pred: (m: Msg) => boolean; resolve: (m: Msg) => void }[] = [];
  nextId = 1;
  buf = '';
  stderr = '';

  constructor(home?: string) {
    this.home = home ?? mkdtempSync(join(tmpdir(), 'boss-ch-'));
  }

  async start(env: Record<string, string> = {}): Promise<this> {
    this.port = await freePort();
    writeFileSync(join(this.home, 'token'), this.token + '\n', { mode: 0o600 });
    this.child = spawn(process.execPath, [new URL('../src/server.ts', import.meta.url).pathname], {
      env: { ...process.env, BOSS_WARMUP: '0', BOSS_HOME: this.home, BOSS_PORT: String(this.port), ...env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child.stdout!.setEncoding('utf8');
    this.child.stdout!.on('data', (d: string) => {
      this.buf += d;
      let i;
      while ((i = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, i);
        this.buf = this.buf.slice(i + 1);
        if (!line.trim()) continue;
        const m = JSON.parse(line) as Msg;
        this.msgs.push(m);
        for (const w of [...this.waiters]) if (w.pred(m)) { this.waiters.splice(this.waiters.indexOf(w), 1); w.resolve(m); }
      }
    });
    this.child.stderr!.on('data', (d) => (this.stderr += d));
    for (let i = 0; i < 100; i++) {
      try { await this.get('/health'); return this; } catch { await new Promise((r) => setTimeout(r, 50)); }
    }
    throw new Error(`server did not start: ${this.stderr}`);
  }

  wait(pred: (m: Msg) => boolean, ms = 3000): Promise<Msg> {
    const found = this.msgs.find(pred);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('timeout waiting for stdio message')), ms);
      this.waiters.push({ pred, resolve: (m) => { clearTimeout(t); resolve(m); } });
    });
  }

  rpc(method: string, params: unknown = {}): Promise<Msg> {
    const id = this.nextId++;
    this.child.stdin!.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    return this.wait((m) => m.id === id);
  }

  notifyIn(method: string, params: unknown = {}): void {
    this.child.stdin!.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
  }

  async connect(): Promise<Msg> {
    const init = await this.rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'claude-code', version: '2.1.330' } });
    this.notifyIn('notifications/initialized');
    await new Promise((r) => setTimeout(r, 30));
    return init;
  }

  async call(name: string, args: Record<string, unknown> = {}): Promise<any> {
    const r = await this.rpc('tools/call', { name, arguments: args });
    if (r.error) throw new Error(r.error.message);
    const text = r.result.content[0].text;
    if (r.result.isError) throw new Error(text);
    try { return JSON.parse(text); } catch { return text; }
  }

  pushes(): Msg[] {
    return this.msgs.filter((m) => m.method === 'notifications/claude/channel');
  }

  http(method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<{ status: number; json: any; text: string }> {
    return new Promise((resolve, reject) => {
      const data = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
      const req = request({ host: '127.0.0.1', port: this.port, method, path, headers: {
        authorization: `Bearer ${this.token}`, ...(data !== undefined ? { 'content-type': 'application/json' } : {}), ...headers } }, (res) => {
        let t = '';
        res.on('data', (c) => (t += c));
        res.on('end', () => { let json; try { json = JSON.parse(t); } catch { json = undefined; } resolve({ status: res.statusCode!, json, text: t }); });
      });
      req.on('error', reject);
      if (data !== undefined) req.write(data);
      req.end();
    });
  }

  get(path: string) { return this.http('GET', path); }
  post(path: string, body: unknown) { return this.http('POST', path, body); }

  /** Opens an SSE stream and collects parsed events. */
  /** Opens an SSE stream; await `ready` before triggering events. */
  sse(path = '/events', headers: Record<string, string> = {}): { ready: Promise<void>; events: { id: string; event: string; data: any }[]; close: () => void; until: (pred: (e: any) => boolean, ms?: number) => Promise<any> } {
    let markReady: () => void = () => {};
    const ready = new Promise<void>((r) => (markReady = r));
    const events: { id: string; event: string; data: any }[] = [];
    let buf = '';
    const waiters: { pred: (e: any) => boolean; resolve: (e: any) => void }[] = [];
    const req = request({ host: '127.0.0.1', port: this.port, method: 'GET', path, headers: { authorization: `Bearer ${this.token}`, ...headers } }, (res) => {
      res.setEncoding('utf8');
      res.on('data', (c: string) => {
        if (buf === '' && c.startsWith(': boss-channel')) markReady();
        buf += c;
        let i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const block = buf.slice(0, i);
          buf = buf.slice(i + 2);
          const e: any = {};
          for (const line of block.split('\n')) {
            if (line.startsWith(':')) continue;
            const [k, ...v] = line.split(': ');
            e[k] = v.join(': ');
          }
          if (!e.event) continue;
          const ev = { id: e.id, event: e.event, data: JSON.parse(e.data) };
          events.push(ev);
          for (const w of [...waiters]) if (w.pred(ev)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(ev); }
        }
      });
    });
    req.on('error', () => {});
    req.end();
    return {
      ready,
      events,
      close: () => req.destroy(),
      until: (pred, ms = 3000) => {
        const f = events.find(pred);
        if (f) return Promise.resolve(f);
        return new Promise((resolve, reject) => {
          const t = setTimeout(() => reject(new Error('timeout waiting for SSE event')), ms);
          waiters.push({ pred, resolve: (e) => { clearTimeout(t); resolve(e); } });
        });
      },
    };
  }

  async stop(): Promise<void> {
    if (!this.child || this.child.exitCode !== null) return;
    const done = new Promise((r) => this.child.once('exit', r));
    this.child.stdin!.end();
    await Promise.race([done, new Promise((r) => setTimeout(r, 2000))]);
    if (this.child.exitCode === null) this.child.kill('SIGKILL');
  }
}
