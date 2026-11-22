// boss-channel: the bridge between Boss.app (HTTP + SSE on 127.0.0.1) and the Boss Claude Code
// session (an MCP channel on stdio). It decides nothing about where words go; Boss does.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import type { Readable, Writable } from 'node:stream';
import { McpServer, ToolError } from './mcp.ts';
import { State, graduated, UNDO_WINDOW_MS, type BossEvent } from './state.ts';

export const MAX_BODY = 64 * 1024;
export const CONFIRM_WINDOW_MS = 2500;

export const instructionsFor = (allow: string, self = 'boss'): string => INSTRUCTIONS + `\nYou are the session named exactly "${self}". You may route to every other session whose name matches: ${allow}, including sessions whose names merely contain "boss" (such as boss-88).`;

export const INSTRUCTIONS = `Roman's words reach you as <channel source="boss-channel" kind="utterance" utterance_id="..." mode="..." lang="..."> events; the tag body is his transcript, verbatim.
kind="answer" carries his answer to a question you asked (question_id, about_id, session attributes). kind="undo" means "scratch that" for utterance_id.
Talk to Roman ONLY with the say and ask tools of this server; never reply in plain text. Before sending an utterance to a worker call route(); after SendMessage call routed().
Call state() whenever you need the allow-list, the last routes, or pending questions.`;

export type ChannelOpts = {
  home: string;
  port: number;
  input: Readable;
  output: Writable;
  allow?: string;
  /** This Boss session's own name: never a routing target. */
  selfName?: string;
  humor?: number;
  confirmWindowMs?: number;
  now?: () => number;
  version?: string;
};

export function globMatch(glob: string, name: string): boolean {
  const re = new RegExp('^' + glob.split('*').map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$', 'i');
  return re.test(name);
}

export function allowed(allow: string, name: string): boolean {
  return allow.split(',').map((s) => s.trim()).filter(Boolean).some((g) => globMatch(g, name));
}

export function normLinks(raw: unknown): { title: string; url: string }[] {
  if (!Array.isArray(raw)) return [];
  const out: { title: string; url: string }[] = [];
  for (const l of raw) {
    const url = typeof l === 'string' ? l : typeof l === 'object' && l ? String((l as Record<string, unknown>).url ?? '') : '';
    const title = typeof l === 'object' && l && (l as Record<string, unknown>).title ? String((l as Record<string, unknown>).title) : url;
    if (/^(https?:\/\/|file:\/\/\/)/i.test(url.trim())) out.push({ title: title.trim().slice(0, 200), url: url.trim() });
  }
  return out.slice(0, 10);
}

function str(v: unknown, max = 4000): string {
  return typeof v === 'string' ? v.slice(0, max) : v === undefined || v === null ? '' : String(v).slice(0, max);
}

export function readToken(home: string): string {
  return readFileSync(join(home, 'token'), 'utf8').trim();
}

export class Channel {
  opts: ChannelOpts;
  state: State;
  mcp: McpServer;
  http: Server;
  token: string;
  allow: string;
  selfName: string;
  humor: number;
  confirmWindowMs: number;
  started = Date.now();
  pending = new Map<string, (decision: 'send' | 'cancelled') => void>();
  sse = new Set<ServerResponse>();
  logFile: string;

  constructor(opts: ChannelOpts) {
    this.opts = opts;
    this.state = new State(opts.home, opts.now);
    this.token = readToken(opts.home);
    this.allow = opts.allow ?? '*';
    this.selfName = opts.selfName ?? 'boss';
    this.humor = opts.humor ?? 1;
    this.confirmWindowMs = opts.confirmWindowMs ?? CONFIRM_WINDOW_MS;
    mkdirSync(join(opts.home, 'logs'), { recursive: true });
    this.logFile = join(opts.home, 'logs', 'channel.log');
    this.mcp = new McpServer({ input: opts.input, output: opts.output, instructions: instructionsFor(opts.allow ?? '*', opts.selfName ?? 'boss'), log: (s) => this.log('mcp', { msg: s }) });
    this.mcp.onInitialized = () => {
      this.log('boss_connected', {});
      this.state.emit('boss', { connected: true });
      // One throwaway turn so the first real utterance does not pay the cold prompt cache.
      if (process.env.BOSS_WARMUP !== '0') setTimeout(() => this.push('warm-up: do nothing', { kind: 'warmup' }), 1500).unref();
    };
    this.registerTools();
    this.http = createServer((req, res) => void this.route(req, res));
    this.state.listeners.add((e) => this.broadcast(e));
  }

  log(event: string, fields: Record<string, unknown>): void {
    try {
      appendFileSync(this.logFile, JSON.stringify({ at: new Date().toISOString(), event, ...fields }) + '\n');
    } catch { /* logging never breaks the bridge */ }
  }

  listen(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.http.once('error', reject);
      this.http.listen(this.opts.port, '127.0.0.1', () => {
        this.log('listening', { port: this.opts.port });
        resolve();
      });
    });
  }

  close(): void {
    for (const r of this.sse) r.end();
    this.http.close();
  }

  push(content: string, meta: Record<string, string | undefined>): void {
    const clean: Record<string, string> = {};
    for (const [k, v] of Object.entries(meta)) if (v !== undefined && v !== '' && /^[A-Za-z0-9_]+$/.test(k)) clean[k] = String(v);
    this.mcp.notify('notifications/claude/channel', { content, meta: clean });
    this.log('push', { meta: clean, chars: content.length });
  }

  /**
   * Routing context that saves Boss a tool round trip per utterance: the live sessions it may route
   * to (sent by the app, filtered by the allow list) and the last target with its age.
   */
  routingContext(raw: unknown): Record<string, string | undefined> {
    const list = Array.isArray(raw) ? raw : [];
    if (list.length) {
      this.lastSessions = list.map((x) => (typeof x === 'object' && x ? (x as Record<string, unknown>) : {}))
        .map((x) => ({ name: str(x.name, 60).trim(), cwd: str(x.cwd, 300) }))
        .filter((x) => x.name && !this.isSelf(x.name) && allowed(this.allow, x.name));
    }
    const live = list
      .map((x) => (typeof x === 'object' && x ? (x as Record<string, unknown>) : {}))
      .map((x) => ({ name: str(x.name, 60).trim(), cwd: str(x.cwd, 300), status: str(x.status, 20) }))
      .filter((x) => x.name && !this.isSelf(x.name) && allowed(this.allow, x.name))
      .slice(0, 30)
      .map((x) => {
        const nick = this.nicknamesBySession()[x.name];
        return `${nick ? `${nick} = ` : ''}${x.name} (${x.cwd.split('/').filter(Boolean).pop() ?? '-'}, ${x.status || '?'})`;
      });
    const last = [...this.state.routes].reverse().find((r) => r.sent_at);
    const age = last?.sent_at ? Math.round((this.state.now() - last.sent_at) / 1000) : undefined;
    return {
      sessions: list.length ? (live.join('; ') || 'none') : undefined,
      last_target: last?.target,
      last_target_age_s: age === undefined ? undefined : String(age),
    };
  }

  radioRunning = false;
  /** The live sessions the app sent with the last utterance (or GET /state?sessions=): [{name, cwd}]. */
  lastSessions: { name: string; cwd: string }[] = [];

  static cleanNickname(n: string): string {
    return n.toLowerCase().replace(/[^a-z0-9а-яё _-]/gi, '').trim().replace(/\s+/g, '-').slice(0, 40);
  }

  /** nickname -> the live session it means now: same name first, else the one live session in the same folder. */
  resolveNicknames(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const n of this.state.nicknames) {
      const byName = this.lastSessions.find((x) => x.name === n.name);
      const byCwd = this.lastSessions.filter((x) => x.cwd && x.cwd === n.cwd);
      const hit = byName ?? (byCwd.length === 1 ? byCwd[0] : undefined);
      if (hit) out[n.nickname] = hit.name;
    }
    return out;
  }

  /** session name -> nickname, for the panel. */
  nicknamesBySession(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [nick, name] of Object.entries(this.resolveNicknames())) out[name] = nick;
    return out;
  }

  /** A routing question's choices must be session names: map folder names (a real Haiku slip) to them. */
  normalizeChoices(choices: string[]): string[] {
    if (!this.lastSessions.length) return choices;
    const base = (p: string) => (p.split('/').filter(Boolean).pop() ?? '').toLowerCase();
    const out: string[] = [];
    for (const c of choices) {
      const l = c.toLowerCase();
      const viaNick = this.resolveNicknames()[Channel.cleanNickname(c)];
      const hit = this.lastSessions.find((x) => x.name.toLowerCase() === l)
        ?? (viaNick ? this.lastSessions.find((x) => x.name === viaNick) : undefined)
        ?? this.lastSessions.find((x) => base(x.cwd) === l)
        ?? this.lastSessions.find((x) => base(x.cwd).includes(l) || l.includes(base(x.cwd)));
      const v = hit ? hit.name : c;
      if (!out.includes(v)) out.push(v);
    }
    return out;
  }

  /** Runs bin/boss-radio.mjs (or BOSS_RADIO_CMD in tests) and reports the outcome as a panel card. */
  startRadio(hours?: number): string {
    if (this.radioRunning) return 'a radio recap is already being made';
    const here = fileURLToPath(new URL('.', import.meta.url));
    const script = process.env.BOSS_RADIO_CMD ?? [join(here, '..', '..', 'bin', 'boss-radio.mjs'), join(here, '..', '..', '..', 'bin', 'boss-radio.mjs')].find((p) => existsSync(p));
    if (!script) throw new ToolError('boss-radio is not installed');
    this.radioRunning = true;
    const args = [script, ...(hours ? ['--hours', String(hours)] : [])];
    const child = spawn(process.execPath, args, { env: { ...process.env, BOSS_HOME: this.opts.home }, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('close', (code) => {
      this.radioRunning = false;
      let r: { sent?: boolean; reports?: number; seconds?: number } = {};
      try { r = JSON.parse(out.trim().split('\n').pop() ?? '{}'); } catch { /* reported below */ }
      this.log('radio', { code, reports: r.reports, seconds: r.seconds, sent: r.sent, error: code ? err.slice(0, 200) : undefined });
      const text = code === 0
        ? (r.sent ? `Radio recap sent to your phone: ${r.reports ?? 0} reports, ${r.seconds ?? 0} seconds.` : `Radio recap ready (${r.seconds ?? 0} s), not sent.`)
        : 'Radio recap failed. The reports are still in the panel.';
      this.state.emit('say', { id: `say_${this.state.seq + 1}`, text, links: [], speak: code !== 0, kind: 'info' });
    });
    return 'making the radio recap now; the panel confirms when it is sent';
  }

  isSelf(name: string): boolean {
    return name === 'boss' || name === this.selfName;
  }

  stateView(): Record<string, unknown> {
    return {
      routes: this.state.routes.slice(-50),
      questions: this.state.questions,
      reports: this.state.reports,
      ledger: this.state.ledgerView(),
      settings: { humor: this.humor, allow: this.allow },
      nicknames: this.nicknamesBySession(),
    };
  }

  registerTools(): void {
    const s = this.state;
    this.mcp.addTool({
      name: 'say',
      description: 'Speak to Roman: a card in his panel plus speech (1-3 short sentences, no code, no paths). Put URLs in links. kind=report for a worker REPORT, status for status answers, info otherwise.',
      inputSchema: { type: 'object', properties: {
        text: { type: 'string' }, links: { type: 'array', items: { type: 'string' } }, speak: { type: 'boolean' },
        session: { type: 'string', description: 'the worker this is about, if any' }, lang: { type: 'string', enum: ['en', 'ru'] },
        kind: { type: 'string', enum: ['report', 'status', 'info'] } }, required: ['text'] },
      handler: (a) => {
        const text = str(a.text, 1200).trim();
        if (!text) throw new ToolError('text is empty');
        const kind = ['report', 'status', 'info'].includes(str(a.kind)) ? str(a.kind) : 'info';
        const session = str(a.session, 100) || undefined;
        if (session && kind === 'report') { s.setReport(session, text); s.bump('report', 'spoken'); }
        const e = s.emit('say', { id: `say_${s.seq + 1}`, text, links: normLinks(a.links), speak: a.speak !== false, session, lang: str(a.lang) === 'ru' ? 'ru' : str(a.lang) === 'en' ? 'en' : undefined, kind });
        return `said (event ${e.seq})`;
      },
    });
    this.mcp.addTool({
      name: 'ask',
      description: 'Ask Roman one short question; choices become buttons and his mic opens for 6 s. His answer comes back as a kind="answer" event with this question_id. about_id = the utterance_id the question is about (routing questions), session = the worker that asked (worker questions).',
      inputSchema: { type: 'object', properties: {
        question: { type: 'string' }, choices: { type: 'array', items: { type: 'string' } }, about_id: { type: 'string' },
        session: { type: 'string' }, lang: { type: 'string', enum: ['en', 'ru'] } }, required: ['question'] },
      handler: (a) => {
        const question = str(a.question, 600).trim();
        if (!question) throw new ToolError('question is empty');
        let choices = Array.isArray(a.choices) ? a.choices.map((c) => str(c, 80).trim()).filter(Boolean).slice(0, 6) : [];
        if (a.about_id) choices = this.normalizeChoices(choices);
        const q = s.addQuestion({ question, choices, about_id: str(a.about_id, 80) || undefined, session: str(a.session, 100) || undefined, lang: str(a.lang) || undefined });
        s.bump(q.about_id ? 'routing_question' : 'worker_question', 'asked');
        s.emit('ask', { question_id: q.question_id, question, choices, about_id: q.about_id, session: q.session, lang: q.lang });
        return JSON.stringify({ question_id: q.question_id });
      },
    });
    this.mcp.addTool({
      name: 'route',
      description: 'Call BEFORE SendMessage for every utterance you deliver. explicit=true when Roman named the target or a lock is set. Returns {decision:"send"|"cancelled"}. Only send when decision is send; on cancelled, ask() Roman which session instead.',
      inputSchema: { type: 'object', properties: {
        utterance_id: { type: 'string' }, target: { type: 'string' }, explicit: { type: 'boolean' }, reason: { type: 'string' } },
        required: ['utterance_id', 'target', 'explicit'] },
      handler: async (a) => {
        const target = str(a.target, 100).trim();
        const utterance_id = str(a.utterance_id, 80);
        if (!target) throw new ToolError('target is empty');
        if (!allowed(this.allow, target) || this.isSelf(target)) throw new ToolError(`target "${target}" is not allowed (allow: ${this.allow})`);
        const explicit = a.explicit === true;
        const r = s.addRoute({ utterance_id, target, explicit, reason: str(a.reason, 200) });
        const trusted = explicit || graduated(s.ledger[target]);
        if (!explicit) s.bump('route_inferred', trusted ? 'auto' : 'proposed');
        let decision: 'send' | 'cancelled' = 'send';
        if (!trusted) {
          s.emit('confirm', { route_id: r.route_id, utterance_id, target, reason: r.reason, window_ms: this.confirmWindowMs });
          decision = await new Promise<'send' | 'cancelled'>((resolve) => {
            const t = setTimeout(() => { this.pending.delete(r.route_id); resolve('send'); }, this.confirmWindowMs);
            this.pending.set(r.route_id, (d) => { clearTimeout(t); this.pending.delete(r.route_id); resolve(d); });
          });
        }
        r.decision = decision;
        s.save();
        this.log('route', { utterance_id, target, explicit, trusted, decision });
        return JSON.stringify({ decision, route_id: r.route_id, trusted });
      },
    });
    this.mcp.addTool({
      name: 'routed',
      description: 'Report delivery of an utterance after SendMessage: status sent|delivered|failed|ignored (ignored = after an undo).',
      inputSchema: { type: 'object', properties: {
        utterance_id: { type: 'string' }, target: { type: 'string' }, status: { type: 'string', enum: ['sent', 'delivered', 'failed', 'ignored', 'asking'] }, note: { type: 'string' } },
        required: ['utterance_id', 'target', 'status'] },
      handler: (a) => {
        const utterance_id = str(a.utterance_id, 80);
        const target = str(a.target, 100);
        const status = ['sent', 'delivered', 'failed', 'ignored', 'asking'].includes(str(a.status)) ? str(a.status) : 'sent';
        let r = [...s.routes].reverse().find((x) => x.utterance_id === utterance_id && x.target === target);
        // The explicit path skips route() (one model turn saved), so the first delivery report creates the record.
        if (!r && (status === 'sent' || status === 'delivered')) r = s.addRoute({ utterance_id, target, explicit: true, reason: 'explicit (no route call)' });
        if (r && (status === 'sent' || status === 'delivered') && !r.sent_at) {
          r.sent_at = s.now();
          r.status = status;
          if (!r.explicit) { s.countBlind(target); s.bump('route_inferred', 'sent'); }
          else s.bump('route_explicit', 'sent');
        }
        s.emit('routed', { utterance_id, target, status, note: str(a.note, 300) || undefined });
        return 'ok';
      },
    });
    this.mcp.addTool({
      name: 'nickname',
      description: 'Roman renamed a session ("rename reelshow-9d to reels", "call guard-29 guard"): save nickname for that session. Address it by its real name in SendMessage; Roman may now say the nickname. Empty nickname removes it.',
      inputSchema: { type: 'object', properties: { session: { type: 'string', description: 'real session name, or its current nickname' }, nickname: { type: 'string' } }, required: ['session', 'nickname'] },
      handler: (a) => {
        const raw = str(a.session, 100).trim();
        const name = this.resolveNicknames()[Channel.cleanNickname(raw)] ?? raw;
        const live = this.lastSessions.find((x) => x.name === name);
        if (!live) throw new ToolError(`no live session named "${raw}"`);
        const nick = Channel.cleanNickname(str(a.nickname, 60));
        s.nicknames = s.nicknames.filter((n) => n.name !== name && n.nickname !== nick);
        if (nick) s.nicknames.push({ nickname: nick, name, cwd: live.cwd, at: s.iso() });
        s.save();
        s.emit('nicknames', { nicknames: this.nicknamesBySession() });
        this.log('nickname', { name, nickname: nick || null });
        return JSON.stringify({ ok: true, session: name, nickname: nick || null });
      },
    });
    this.mcp.addTool({
      name: 'radio',
      description: 'Roman said "radio me": render a spoken team-radio recap of recent reports and open questions and send it to his phone (Telegram audio). Runs in the background; the panel confirms when it is sent. hours = how far back (optional).',
      inputSchema: { type: 'object', properties: { hours: { type: 'number' } } },
      handler: (a) => this.startRadio(typeof a.hours === 'number' && a.hours > 0 ? Math.min(a.hours, 48) : undefined),
    });
    this.mcp.addTool({
      name: 'state',
      description: 'Boss state: allow (glob of session names you may route to), last routes, pending questions, last report per session, trust ledger, humor level, recent utterances.',
      inputSchema: { type: 'object', properties: {} },
      handler: () => JSON.stringify({ ...this.stateView(), allow: this.allow, humor: this.humor, utterances: s.utterances.slice(-20) }),
    });
  }

  // ---------- HTTP ----------

  authorized(req: IncomingMessage): string | null {
    const host = String(req.headers.host ?? '');
    const port = this.opts.port;
    if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) return 'bad host';
    if (req.headers.origin !== undefined) return 'browser requests are refused';
    const h = String(req.headers.authorization ?? '');
    const m = /^Bearer\s+(\S+)$/.exec(h);
    if (!m) return 'missing token';
    const a = Buffer.from(m[1]);
    const b = Buffer.from(this.token);
    if (a.length !== b.length || !timingSafeEqual(a, b)) return 'bad token';
    return null;
  }

  async body(req: IncomingMessage): Promise<Record<string, unknown>> {
    if (!/^application\/json\b/i.test(String(req.headers['content-type'] ?? ''))) throw Object.assign(new Error('content-type must be application/json'), { status: 415 });
    let size = 0;
    const chunks: Buffer[] = [];
    for await (const c of req) {
      size += (c as Buffer).length;
      if (size > MAX_BODY) throw Object.assign(new Error('body too large'), { status: 413 });
      chunks.push(c as Buffer);
    }
    try {
      const v = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error();
      return v;
    } catch {
      throw Object.assign(new Error('invalid JSON'), { status: 400 });
    }
  }

  send(res: ServerResponse, status: number, obj: unknown): void {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(obj));
  }

  broadcast(e: BossEvent): void {
    const frame = `id: ${e.seq}\nevent: ${e.type}\ndata: ${JSON.stringify({ ...e.data, seq: e.seq, at: e.at })}\n\n`;
    for (const r of this.sse) r.write(frame);
  }

  async route(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const deny = this.authorized(req);
    if (deny) {
      this.log('http_denied', { reason: deny, method: req.method, url: req.url });
      return this.send(res, 403, { error: deny });
    }
    const url = new URL(req.url ?? '/', `http://127.0.0.1:${this.opts.port}`);
    const key = `${req.method} ${url.pathname}`;
    const s = this.state;
    try {
      switch (key) {
        case 'GET /health':
          return this.send(res, 200, { ok: true, boss_connected: this.mcp.initialized, version: this.opts.version ?? '1.0.0', uptime_s: Math.round((Date.now() - this.started) / 1000) });
        case 'GET /state': {
          const q = url.searchParams.get('sessions');
          if (q) {
            try { this.routingContext(JSON.parse(q)); } catch { /* ignore a malformed list */ }
          }
          return this.send(res, 200, this.stateView());
        }
        case 'GET /ledger':
          return this.send(res, 200, s.classLedgerView());
        case 'GET /events': {
          const since = Number(req.headers['last-event-id'] ?? url.searchParams.get('since') ?? s.seq);
          res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
          res.write(`: boss-channel\n\n`);
          for (const e of s.since(Number.isFinite(since) ? since : s.seq)) res.write(`id: ${e.seq}\nevent: ${e.type}\ndata: ${JSON.stringify({ ...e.data, seq: e.seq, at: e.at })}\n\n`);
          this.sse.add(res);
          const ping = setInterval(() => res.write(': ping\n\n'), 15_000);
          req.on('close', () => { clearInterval(ping); this.sse.delete(res); });
          return;
        }
        case 'POST /utterance': {
          const b = await this.body(req);
          const id = str(b.id, 80).trim();
          const text = str(b.text, 20_000).trim();
          if (!/^[A-Za-z0-9_-]{1,80}$/.test(id)) return this.send(res, 400, { error: 'id must be [A-Za-z0-9_-]{1,80}' });
          if (!text) return this.send(res, 400, { error: 'text is empty' });
          const mode = ['talk', 'handsfree', 'feedback'].includes(str(b.mode)) ? str(b.mode) : 'talk';
          if (!this.mcp.initialized) return this.send(res, 503, { error: 'boss offline' });
          const lang = str(b.lang) === 'ru' ? 'ru' : str(b.lang) === 'en' ? 'en' : undefined;
          const lock = str(b.lock, 100) || undefined;
          const fresh = s.acceptUtterance({ id, text, mode, lang, lock, at: s.iso() });
          if (fresh) this.push(text, { kind: 'utterance', utterance_id: id, mode, lang, lock, ...this.routingContext(b.sessions) });
          this.log('utterance', { id, duplicate: !fresh, chars: text.length, mode, lang });
          return this.send(res, 202, { ok: true, id, duplicate: !fresh });
        }
        case 'POST /answer': {
          const b = await this.body(req);
          const text = str(b.text, 4000).trim();
          if (!text) return this.send(res, 400, { error: 'text is empty' });
          if (!this.mcp.initialized) return this.send(res, 503, { error: 'boss offline' });
          const q = s.takeQuestion(str(b.question_id, 80));
          if (!q) return this.send(res, 404, { error: 'no such pending question' });
          s.bump(q.about_id ? 'routing_question' : 'worker_question', 'answered');
          const original = q.about_id ? s.utterances.find((u) => u.id === q.about_id)?.text : undefined;
          this.push(text, { kind: 'answer', question_id: q.question_id, about_id: q.about_id, session: q.session, question: q.question.slice(0, 300), original: original?.slice(0, 4000) });
          return this.send(res, 202, { ok: true });
        }
        case 'POST /undo': {
          const b = await this.body(req);
          const utterance_id = str(b.utterance_id, 80);
          if (!this.mcp.initialized) return this.send(res, 503, { error: 'boss offline' });
          const r = [...s.routes].reverse().find((x) => x.utterance_id === utterance_id && x.sent_at);
          if (r && s.now() - (r.sent_at ?? 0) <= UNDO_WINDOW_MS) {
            s.countMiss(r.target, !r.explicit);
            s.bump(r.explicit ? 'route_explicit' : 'route_inferred', 'undone');
          }
          this.push(`scratch that (undo utterance ${utterance_id})`, { kind: 'undo', utterance_id, session: r?.target });
          return this.send(res, 202, { ok: true, target: r?.target ?? null });
        }
        case 'POST /cancel_route': {
          const b = await this.body(req);
          const route_id = str(b.route_id, 80);
          const resolve = this.pending.get(route_id);
          if (!resolve) return this.send(res, 404, { error: 'no pending route (window already closed?)' });
          const r = s.routes.find((x) => x.route_id === route_id);
          if (r) s.countMiss(r.target, false);
          s.bump('route_inferred', 'cancelled');
          resolve('cancelled');
          return this.send(res, 200, { ok: true });
        }
        default:
          return this.send(res, 404, { error: 'not found' });
      }
    } catch (err) {
      const status = (err as { status?: number }).status ?? 500;
      this.log('http_error', { key, status, error: String((err as Error).message) });
      if (!res.headersSent) this.send(res, status, { error: (err as Error).message });
    }
  }
}
