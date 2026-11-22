// Channel state: events ring (SSE replay), routes, pending questions, reports, trust ledger.
// Everything that matters survives a restart: it is persisted under <home>/state/.
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';

export type BossEvent = { seq: number; type: string; data: Record<string, unknown>; at: string };
export type Route = { route_id: string; utterance_id: string; target: string; explicit: boolean; reason: string; decision?: string; status?: string; at: string; sent_at?: number };
export type Question = { question_id: string; question: string; choices: string[]; about_id?: string; session?: string; lang?: string; at: string };
export type Ledger = Record<string, { blind: number; misses: number }>;
export type Utterance = { id: string; text: string; mode: string; lang?: string; lock?: string; at: string };

export const RING = 500;
export const UNDO_WINDOW_MS = 60_000;

export function newId(prefix: string): string {
  return `${prefix}_${randomBytes(4).toString('hex')}`;
}

export function graduated(e: { blind: number; misses: number } | undefined): boolean {
  if (!e) return false;
  return e.blind >= 10 && e.misses * 10 <= e.blind;
}

/** Trust ledger by action class (v1), read by other systems from state/trust-ledger.v1.json. */
export type ClassLedger = {
  route_explicit: { sent: number; undone: number };
  route_inferred: { proposed: number; auto: number; sent: number; cancelled: number; undone: number };
  routing_question: { asked: number; answered: number };
  worker_question: { asked: number; answered: number };
  report: { spoken: number };
};
export const emptyClasses = (): ClassLedger => ({
  route_explicit: { sent: 0, undone: 0 },
  route_inferred: { proposed: 0, auto: 0, sent: 0, cancelled: 0, undone: 0 },
  routing_question: { asked: 0, answered: 0 },
  worker_question: { asked: 0, answered: 0 },
  report: { spoken: 0 },
});

/** A nickname Roman gave a session. Claude Code names cannot be renamed from outside, and derived
 * names change on restart, so a nickname follows the session's name and, failing that, its folder. */
export type Nickname = { nickname: string; name: string; cwd: string; at: string };

type Persisted = { seq: number; routes: Route[]; questions: Question[]; reports: Record<string, { text: string; at: string }>; ledger: Ledger; utterances: Utterance[]; seen: string[]; classes?: ClassLedger; nicknames?: Nickname[] };

export class State {
  dir: string;
  now: () => number;
  seq = 0;
  events: BossEvent[] = [];
  routes: Route[] = [];
  questions: Question[] = [];
  reports: Record<string, { text: string; at: string }> = {};
  ledger: Ledger = {};
  classes: ClassLedger = emptyClasses();
  nicknames: Nickname[] = [];
  utterances: Utterance[] = [];
  seen = new Set<string>();
  listeners = new Set<(e: BossEvent) => void>();

  constructor(home: string, now: () => number = Date.now) {
    this.dir = join(home, 'state');
    this.now = now;
    mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    this.load();
  }

  iso(): string {
    return new Date(this.now()).toISOString();
  }

  load(): void {
    const f = join(this.dir, 'channel.json');
    if (existsSync(f)) {
      try {
        const p = JSON.parse(readFileSync(f, 'utf8')) as Persisted;
        this.seq = p.seq ?? 0;
        this.routes = p.routes ?? [];
        this.questions = p.questions ?? [];
        this.reports = p.reports ?? {};
        this.ledger = p.ledger ?? {};
        this.utterances = p.utterances ?? [];
        this.seen = new Set(p.seen ?? []);
        this.classes = { ...emptyClasses(), ...(p.classes ?? {}) };
        this.nicknames = p.nicknames ?? [];
      } catch { /* a corrupt file starts fresh; events.jsonl still holds the history */ }
    }
    const ev = join(this.dir, 'events.jsonl');
    if (existsSync(ev)) {
      const lines = readFileSync(ev, 'utf8').trim().split('\n').filter(Boolean).slice(-RING);
      for (const l of lines) {
        try { this.events.push(JSON.parse(l)); } catch { /* skip a torn line */ }
      }
      const last = this.events.at(-1);
      if (last && last.seq > this.seq) this.seq = last.seq;
    }
  }

  save(): void {
    const p: Persisted = { seq: this.seq, routes: this.routes.slice(-50), questions: this.questions, reports: this.reports, ledger: this.ledger, utterances: this.utterances.slice(-20), seen: [...this.seen].slice(-1000), classes: this.classes, nicknames: this.nicknames };
    const f = join(this.dir, 'channel.json');
    writeFileSync(`${f}.tmp`, JSON.stringify(p), { mode: 0o600 });
    renameSync(`${f}.tmp`, f);
    const t = join(this.dir, 'trust-ledger.v1.json');
    writeFileSync(`${t}.tmp`, JSON.stringify(this.classLedgerView(), null, 2), { mode: 0o600 });
    renameSync(`${t}.tmp`, t);
  }

  /** Bumps one counter of one action class and persists. */
  bump<K extends keyof ClassLedger>(cls: K, field: keyof ClassLedger[K]): void {
    (this.classes[cls] as Record<string, number>)[field as string] += 1;
    this.save();
  }

  classLedgerView(): { version: 1; updated_at: string; classes: ClassLedger; by_session: Record<string, { blind: number; misses: number; graduated: boolean }> } {
    return { version: 1, updated_at: this.iso(), classes: this.classes, by_session: this.ledgerView() };
  }

  emit(type: string, data: Record<string, unknown>): BossEvent {
    const e: BossEvent = { seq: ++this.seq, type, data, at: this.iso() };
    this.events.push(e);
    if (this.events.length > RING) this.events.splice(0, this.events.length - RING);
    appendFileSync(join(this.dir, 'events.jsonl'), JSON.stringify(e) + '\n', { mode: 0o600 });
    this.save();
    for (const l of this.listeners) l(e);
    return e;
  }

  since(seq: number): BossEvent[] {
    return this.events.filter((e) => e.seq > seq);
  }

  /** Returns false when this utterance id was already accepted (outbox retry). */
  acceptUtterance(u: Utterance): boolean {
    if (this.seen.has(u.id)) return false;
    this.seen.add(u.id);
    this.utterances.push(u);
    if (this.utterances.length > 20) this.utterances.splice(0, this.utterances.length - 20);
    this.save();
    return true;
  }

  addQuestion(q: Omit<Question, 'question_id' | 'at'>): Question {
    const full: Question = { ...q, question_id: newId('q'), at: this.iso() };
    this.questions.push(full);
    this.save();
    return full;
  }

  takeQuestion(id: string): Question | undefined {
    const i = this.questions.findIndex((q) => q.question_id === id);
    if (i < 0) return undefined;
    const [q] = this.questions.splice(i, 1);
    this.save();
    return q;
  }

  addRoute(r: Omit<Route, 'route_id' | 'at'>): Route {
    const full: Route = { ...r, route_id: newId('r'), at: this.iso() };
    this.routes.push(full);
    if (this.routes.length > 50) this.routes.splice(0, this.routes.length - 50);
    this.save();
    return full;
  }

  entry(target: string): { blind: number; misses: number } {
    return (this.ledger[target] ??= { blind: 0, misses: 0 });
  }

  /** An inferred route that went out counts as blind; an undo within the window turns it into a miss. */
  countBlind(target: string): void {
    this.entry(target).blind += 1;
    this.save();
  }

  countMiss(target: string, wasBlind: boolean): void {
    const e = this.entry(target);
    if (wasBlind && e.blind > 0) e.blind -= 1;
    e.misses += 1;
    this.save();
  }

  setReport(session: string, text: string): void {
    this.reports[session] = { text, at: this.iso() };
    this.save();
  }

  ledgerView(): Record<string, { blind: number; misses: number; graduated: boolean }> {
    const out: Record<string, { blind: number; misses: number; graduated: boolean }> = {};
    for (const [k, v] of Object.entries(this.ledger)) out[k] = { ...v, graduated: graduated(v) };
    return out;
  }
}
