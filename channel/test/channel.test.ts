import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { request } from 'node:http';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Harness } from './helpers.ts';
import { allowed, globMatch, normLinks } from '../src/channel.ts';
import { graduated } from '../src/state.ts';

describe('security gate', () => {
  const h = new Harness();
  before(() => h.start());
  after(() => h.stop());

  test('no token → 403, and nothing reaches Boss', async () => {
    await h.connect();
    const before = h.pushes().length;
    const r = await h.http('POST', '/utterance', { id: 'x1', text: 'rm -rf' }, { authorization: '' });
    assert.equal(r.status, 403);
    assert.equal(h.pushes().length, before);
  });

  test('wrong token → 403; right token → 200', async () => {
    assert.equal((await h.http('GET', '/health', undefined, { authorization: `Bearer ${'b'.repeat(64)}` })).status, 403);
    assert.equal((await h.http('GET', '/health', undefined, { authorization: 'Bearer short' })).status, 403);
    assert.equal((await h.get('/health')).status, 200);
  });

  test('browser requests (Origin header) are refused even with the token', async () => {
    const r = await h.http('GET', '/state', undefined, { origin: 'http://evil.example' });
    assert.equal(r.status, 403);
  });

  test('foreign Host header (DNS rebinding) is refused', async () => {
    const r = await h.http('GET', '/health', undefined, { host: 'evil.example:80' });
    assert.equal(r.status, 403);
  });

  test('non-JSON body → 415, oversized → 413, malformed → 400', async () => {
    assert.equal((await h.http('POST', '/utterance', 'id=1', { 'content-type': 'text/plain' })).status, 415);
    assert.equal((await h.http('POST', '/utterance', JSON.stringify({ id: 'big', text: 'x'.repeat(70_000) }))).status, 413);
    assert.equal((await h.http('POST', '/utterance', '{nope')).status, 400);
  });

  test('listens on loopback only', async () => {
    const os = await import('node:os');
    const lan = Object.values(os.networkInterfaces()).flat().find((i) => i && i.family === 'IPv4' && !i.internal);
    if (!lan) return; // no LAN interface on this machine
    const err = await new Promise<string>((resolve) => {
      const req = request({ host: lan.address, port: h.port, path: '/health', timeout: 1000 }, () => resolve('connected'));
      req.on('error', (e) => resolve((e as NodeJS.ErrnoException).code ?? 'error'));
      req.on('timeout', () => { req.destroy(); resolve('timeout'); });
      req.end();
    });
    assert.notEqual(err, 'connected');
  });
});

describe('MCP handshake', () => {
  const h = new Harness();
  before(() => h.start());
  after(() => h.stop());

  test('declares the channel capability and tools, negotiates a supported revision', async () => {
    const init = await h.connect();
    assert.deepEqual(init.result.capabilities.experimental, { 'claude/channel': {} });
    assert.ok(init.result.capabilities.tools);
    assert.equal(init.result.protocolVersion, '2025-11-25');
    assert.match(init.result.instructions, /say and ask/);
    const list = await h.rpc('tools/list');
    assert.deepEqual(list.result.tools.map((t: any) => t.name).sort(), ['ask', 'route', 'routed', 'say', 'state']);
  });

  test('never negotiates 2026-07-28 (not registered as a channel there)', async () => {
    const r = await h.rpc('initialize', { protocolVersion: '2026-07-28', capabilities: {} });
    assert.notEqual(r.result.protocolVersion, '2026-07-28');
  });

  test('unknown methods such as server/discover get -32601, ping answers', async () => {
    const r = await h.rpc('server/discover', {});
    assert.equal(r.error.code, -32601);
    assert.deepEqual((await h.rpc('ping')).result, {});
  });

  test('unknown tool is an error, a failing tool is isError not a crash', async () => {
    const r = await h.rpc('tools/call', { name: 'nope', arguments: {} });
    assert.ok(r.error);
    await assert.rejects(h.call('say', { text: '   ' }), /empty/);
    assert.equal((await h.get('/health')).status, 200);
  });

  test('health reports boss_connected only after initialized', async () => {
    const h2 = await new Harness().start();
    assert.equal((await h2.get('/health')).json.boss_connected, false);
    await h2.connect();
    assert.equal((await h2.get('/health')).json.boss_connected, true);
    await h2.stop();
  });
});

describe('utterance flow', () => {
  const h = new Harness();
  before(async () => { await h.start(); await h.connect(); });
  after(() => h.stop());

  test('an utterance becomes one channel event with clean meta, verbatim text', async () => {
    const text = 'Payments: rename the fee calculator to "pricing engine" & run the tests <now>.';
    const r = await h.post('/utterance', { id: 'u_1', text, mode: 'talk', lang: 'en' });
    assert.equal(r.status, 202);
    const m = await h.wait((x) => x.method === 'notifications/claude/channel' && x.params.meta.utterance_id === 'u_1');
    assert.equal(m.params.content, text);
    assert.deepEqual(m.params.meta, { kind: 'utterance', utterance_id: 'u_1', mode: 'talk', lang: 'en' });
  });

  test('a retried utterance (same id) is accepted but not delivered twice', async () => {
    await h.post('/utterance', { id: 'u_dup', text: 'run the linter', mode: 'talk' });
    const r = await h.post('/utterance', { id: 'u_dup', text: 'run the linter', mode: 'talk' });
    assert.equal(r.status, 202);
    assert.equal(r.json.duplicate, true);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(h.pushes().filter((m) => m.params.meta.utterance_id === 'u_dup').length, 1);
  });

  test('Russian text passes through untouched', async () => {
    const text = 'Гейтвей: запусти линтер и покажи ошибки.';
    await h.post('/utterance', { id: 'u_ru', text, lang: 'ru' });
    const m = await h.wait((x) => x.params?.meta?.utterance_id === 'u_ru');
    assert.equal(m.params.content, text);
    assert.equal(m.params.meta.lang, 'ru');
  });

  test('bad ids and empty text are refused', async () => {
    assert.equal((await h.post('/utterance', { id: 'a b', text: 'x' })).status, 400);
    assert.equal((await h.post('/utterance', { id: 'ok', text: '  ' })).status, 400);
  });

  test('boss offline → 503 and the id is not burned (a retry later is delivered)', async () => {
    const h2 = await new Harness().start();
    assert.equal((await h2.post('/utterance', { id: 'u_off', text: 'hello' })).status, 503);
    await h2.connect();
    assert.equal((await h2.post('/utterance', { id: 'u_off', text: 'hello' })).json.duplicate, false);
    await h2.wait((x) => x.params?.meta?.utterance_id === 'u_off');
    await h2.stop();
  });
});

describe('say / ask / answer over SSE', () => {
  const h = new Harness();
  before(async () => { await h.start(); await h.connect(); });
  after(() => h.stop());

  test('say reaches the app as an SSE event with only safe links', async () => {
    const s = h.sse(); await s.ready;
    await h.call('say', { text: 'payments: renamed, 248 tests pass.', links: ['https://github.com/x/pull/482', 'javascript:alert(1)', 'ftp://x'], session: 'payments', kind: 'report' });
    const e = await s.until((e) => e.event === 'say');
    assert.equal(e.data.text, 'payments: renamed, 248 tests pass.');
    assert.deepEqual(e.data.links, [{ title: 'https://github.com/x/pull/482', url: 'https://github.com/x/pull/482' }]);
    assert.equal(e.data.speak, true);
    assert.equal((await h.get('/state')).json.reports.payments.text, 'payments: renamed, 248 tests pass.');
    s.close();
  });

  test('ask → question card → answer goes back to Boss with the question context; a second answer is 404', async () => {
    const s = h.sse(); await s.ready;
    const { question_id } = await h.call('ask', { question: 'Payments or gateway?', choices: ['payments', 'gateway'], about_id: 'u_9' });
    const e = await s.until((e) => e.event === 'ask');
    assert.equal(e.data.question_id, question_id);
    assert.deepEqual(e.data.choices, ['payments', 'gateway']);
    assert.equal((await h.get('/state')).json.questions.length, 1);
    assert.equal((await h.post('/answer', { question_id, text: 'gateway' })).status, 202);
    const m = await h.wait((x) => x.params?.meta?.kind === 'answer');
    assert.equal(m.params.content, 'gateway');
    assert.equal(m.params.meta.about_id, 'u_9');
    assert.equal(m.params.meta.question_id, question_id);
    assert.equal(m.params.meta.original, undefined, 'u_9 was never spoken here, so no original');
    assert.equal((await h.get('/state')).json.questions.length, 0);
    assert.equal((await h.post('/answer', { question_id, text: 'payments' })).status, 404);
    s.close();
  });

  test('SSE replays missed events from Last-Event-ID, and not the older ones', async () => {
    await h.call('say', { text: 'one' });
    const st = (await h.get('/state')).json;
    const s1 = h.sse(); await s1.ready;
    await h.call('say', { text: 'two' });
    const two = await s1.until((e) => e.data.text === 'two');
    s1.close();
    await h.call('say', { text: 'three' });
    const s2 = h.sse('/events', { 'last-event-id': two.id }); await s2.ready;
    const three = await s2.until((e) => e.data.text === 'three');
    assert.ok(three);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(s2.events.filter((e) => e.data.text === 'two' || e.data.text === 'one').length, 0);
    s2.close();
    assert.ok(st);
  });

  test('a fresh SSE connection without Last-Event-ID gets only new events', async () => {
    await h.call('say', { text: 'old news' });
    const s = h.sse(); await s.ready;
    await new Promise((r) => setTimeout(r, 100));
    await h.call('say', { text: 'new news' });
    await s.until((e) => e.data.text === 'new news');
    assert.equal(s.events.filter((e) => e.data.text === 'old news').length, 0);
    s.close();
  });
});

describe('route, confirm window, trust graduation', () => {
  const h = new Harness();
  before(async () => { await h.start({ BOSS_CONFIRM_MS: '300', BOSS_ALLOW: 'bt-*,payments' }); await h.connect(); });
  after(() => h.stop());

  test('explicit route sends at once, no confirm event', async () => {
    const s = h.sse(); await s.ready;
    const t0 = Date.now();
    const r = await h.call('route', { utterance_id: 'u1', target: 'payments', explicit: true, reason: 'named' });
    assert.equal(r.decision, 'send');
    assert.ok(Date.now() - t0 < 250);
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(s.events.filter((e) => e.event === 'confirm').length, 0);
    s.close();
  });

  test('inferred route opens a confirm window, then sends', async () => {
    const s = h.sse(); await s.ready;
    const p = h.call('route', { utterance_id: 'u2', target: 'bt-alpha', explicit: false, reason: 'topic: tests' });
    const c = await s.until((e) => e.event === 'confirm');
    assert.equal(c.data.target, 'bt-alpha');
    assert.equal(c.data.window_ms, 300);
    assert.equal((await p).decision, 'send');
    s.close();
  });

  test('cancel inside the window → cancelled, counts a miss; cancel after → 404', async () => {
    const s = h.sse(); await s.ready;
    const p = h.call('route', { utterance_id: 'u3', target: 'bt-alpha', explicit: false, reason: 'guess' });
    const c = await s.until((e) => e.event === 'confirm' && e.data.utterance_id === 'u3');
    assert.equal((await h.post('/cancel_route', { route_id: c.data.route_id })).status, 200);
    assert.equal((await p).decision, 'cancelled');
    assert.equal((await h.get('/state')).json.ledger['bt-alpha'].misses, 1);
    assert.equal((await h.post('/cancel_route', { route_id: c.data.route_id })).status, 404);
    s.close();
  });

  test('targets outside the allow list (and boss itself) are refused', async () => {
    await assert.rejects(h.call('route', { utterance_id: 'u4', target: 'reelshow-9d', explicit: true }), /not allowed/);
    const h2 = await new Harness().start();
    await h2.connect();
    await assert.rejects(h2.call('route', { utterance_id: 'u5', target: 'boss', explicit: true }), /not allowed/);
    await h2.stop();
  });

  test('blind sends count; an undo within 60 s turns one into a miss', async () => {
    await h.call('route', { utterance_id: 'u6', target: 'bt-beta', explicit: false });
    await h.call('routed', { utterance_id: 'u6', target: 'bt-beta', status: 'sent' });
    await h.call('routed', { utterance_id: 'u6', target: 'bt-beta', status: 'delivered' }); // same route, not counted twice
    assert.deepEqual((await h.get('/state')).json.ledger['bt-beta'], { blind: 1, misses: 0, graduated: false });
    const r = await h.post('/undo', { utterance_id: 'u6' });
    assert.equal(r.json.target, 'bt-beta');
    const m = await h.wait((x) => x.params?.meta?.kind === 'undo');
    assert.equal(m.params.meta.session, 'bt-beta');
    assert.deepEqual((await h.get('/state')).json.ledger['bt-beta'], { blind: 0, misses: 1, graduated: false });
  });

  test('routed without a prior route() (the explicit fast path) still records the route, so undo finds it', async () => {
    await h.call('routed', { utterance_id: 'fast1', target: 'bt-delta', status: 'sent' });
    const st = (await h.get('/state')).json;
    const r = st.routes.find((x: any) => x.utterance_id === 'fast1');
    assert.equal(r.explicit, true);
    assert.ok(r.sent_at);
    assert.equal(st.ledger['bt-delta'], undefined);
    assert.equal((await h.post('/undo', { utterance_id: 'fast1' })).json.target, 'bt-delta');
  });

  test('explicit sends never count as blind', async () => {
    await h.call('route', { utterance_id: 'u7', target: 'payments', explicit: true });
    await h.call('routed', { utterance_id: 'u7', target: 'payments', status: 'sent' });
    assert.equal((await h.get('/state')).json.ledger.payments, undefined);
  });

  test('after 10 clean blind sends the target graduates and skips the confirm window', async () => {
    for (let i = 0; i < 10; i++) {
      await h.call('route', { utterance_id: `g${i}`, target: 'bt-gamma', explicit: false });
      await h.call('routed', { utterance_id: `g${i}`, target: 'bt-gamma', status: 'sent' });
    }
    assert.equal((await h.get('/state')).json.ledger['bt-gamma'].graduated, true);
    const s = h.sse(); await s.ready;
    const r = await h.call('route', { utterance_id: 'g10', target: 'bt-gamma', explicit: false });
    assert.equal(r.trusted, true);
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(s.events.filter((e) => e.event === 'confirm').length, 0);
    s.close();
  });
});

describe('persistence and logs', () => {
  test('state and event history survive a restart; seq keeps climbing', async () => {
    const h = await new Harness().start();
    await h.connect();
    await h.call('say', { text: 'before restart', session: 'bt-a', kind: 'report' });
    await h.call('ask', { question: 'keep this?', session: 'bt-a' });
    const seq1 = Math.max(...(await h.get('/state')).json.routes.map(() => 0), 0);
    await h.stop();
    const h2 = await new Harness(h.home).start();
    const st = (await h2.get('/state')).json;
    assert.equal(st.reports['bt-a'].text, 'before restart');
    assert.equal(st.questions.length, 1);
    await h2.connect();
    const s = h2.sse('/events?since=0'); await s.ready;
    const e = await s.until((e) => e.data.text === 'before restart');
    assert.ok(Number(e.id) >= 1);
    await h2.call('say', { text: 'after' });
    const after = await s.until((e) => e.data.text === 'after');
    assert.ok(Number(after.id) > Number(e.id));
    s.close();
    await h2.stop();
    assert.equal(seq1, 0);
  });

  test('structured log lines are written and contain no transcript text', async () => {
    const h = await new Harness().start();
    await h.connect();
    await h.post('/utterance', { id: 'u_log', text: 'secret project titan', mode: 'talk' });
    await h.wait((x) => x.params?.meta?.utterance_id === 'u_log');
    const log = readFileSync(join(h.home, 'logs', 'channel.log'), 'utf8');
    assert.match(log, /"event":"utterance"/);
    assert.doesNotMatch(log, /secret project titan/);
    await h.stop();
  });

  test('the server exits when Claude Code closes stdin', async () => {
    const h = await new Harness().start();
    await h.connect();
    const exited = new Promise((r) => h.child.once('exit', (code) => r(code)));
    h.child.stdin!.end();
    assert.equal(await exited, 0);
  });
});

describe('pure helpers', () => {
  test('glob / allow', () => {
    assert.ok(globMatch('bt-*', 'bt-alpha'));
    assert.ok(!globMatch('bt-*', 'xbt-alpha'));
    assert.ok(globMatch('*', 'anything'));
    assert.ok(allowed('bt-*, payments', 'payments'));
    assert.ok(!allowed('bt-*', 'payments'));
    assert.ok(!globMatch('a.b', 'aXb'));
  });
  test('links', () => {
    assert.deepEqual(normLinks([{ title: 'PR', url: 'https://x/1' }, 'file:///Users/r/deck.key', 'data:text/html,x']), [
      { title: 'PR', url: 'https://x/1' }, { title: 'file:///Users/r/deck.key', url: 'file:///Users/r/deck.key' }]);
    assert.deepEqual(normLinks('https://x'), []);
  });
  test('graduation threshold', () => {
    assert.equal(graduated({ blind: 9, misses: 0 }), false);
    assert.equal(graduated({ blind: 10, misses: 0 }), true);
    assert.equal(graduated({ blind: 10, misses: 1 }), true);
    assert.equal(graduated({ blind: 10, misses: 2 }), false);
    assert.equal(graduated(undefined), false);
  });
});

describe('answers carry the original words', () => {
  test('an answer to a routing question includes the original utterance text', async () => {
    const h = await new Harness().start();
    await h.connect();
    await h.post('/utterance', { id: 'orig1', text: 'run the linter please' });
    const { question_id } = await h.call('ask', { question: 'Alpha or beta?', choices: ['alpha', 'beta'], about_id: 'orig1' });
    await h.post('/answer', { question_id, text: 'beta' });
    const m = await h.wait((x) => x.params?.meta?.kind === 'answer');
    assert.equal(m.params.meta.original, 'run the linter please');
    await h.stop();
  });
});

describe('warm-up', () => {
  test('one warm-up event is pushed after Boss connects (unless disabled)', async () => {
    const h = await new Harness().start({ BOSS_WARMUP: '1' });
    await h.connect();
    const m = await h.wait((x) => x.params?.meta?.kind === 'warmup', 4000);
    assert.equal(m.params.meta.kind, 'warmup');
    await h.stop();
  });
});

describe('routing context', () => {
  test('live sessions from the app are filtered by the allow list and summarised in meta; last target has an age', async () => {
    const h = await new Harness().start({ BOSS_ALLOW: 'bt-*' });
    await h.connect();
    await h.call('route', { utterance_id: 'p1', target: 'bt-alpha', explicit: true });
    await h.call('routed', { utterance_id: 'p1', target: 'bt-alpha', status: 'sent' });
    await h.post('/utterance', { id: 'ctx1', text: 'run it', sessions: [
      { name: 'bt-alpha', cwd: '/x/alpha-calc', status: 'idle' }, { name: 'reelshow-9d', cwd: '/x/reelshow', status: 'busy' }, { name: 'boss', cwd: '/x', status: 'idle' }] });
    const m = await h.wait((x) => x.params?.meta?.utterance_id === 'ctx1');
    assert.equal(m.params.meta.sessions, 'bt-alpha (alpha-calc, idle)');
    assert.doesNotMatch(m.params.meta.sessions, /reelshow|boss/);
    assert.equal(m.params.meta.last_target, 'bt-alpha');
    assert.match(m.params.meta.last_target_age_s, /^\d+$/);
    await h.post('/utterance', { id: 'ctx2', text: 'x', sessions: [{ name: 'reelshow-9d', cwd: '/r', status: 'idle' }] });
    assert.equal((await h.wait((x) => x.params?.meta?.utterance_id === 'ctx2')).params.meta.sessions, 'none');
    await h.stop();
  });
  test('Boss never routes to itself, under any name', async () => {
    const h = await new Harness().start({ BOSS_ALLOW: 'bt-*', BOSS_NAME: 'bt-boss' });
    await h.connect();
    await assert.rejects(h.call('route', { utterance_id: 's1', target: 'bt-boss', explicit: true }), /not allowed/);
    await h.post('/utterance', { id: 'self1', text: 'x', sessions: [{ name: 'bt-boss', cwd: '/b', status: 'idle' }, { name: 'bt-a', cwd: '/a', status: 'idle' }] });
    assert.equal((await h.wait((x) => x.params?.meta?.utterance_id === 'self1')).params.meta.sessions, 'bt-a (a, idle)');
    await h.stop();
  });

  test('the allow list is part of the instructions Boss gets', async () => {
    const h = await new Harness().start({ BOSS_ALLOW: 'bt-*' });
    const init = await h.connect();
    assert.match(init.result.instructions, /match: bt-\*/);
    await h.stop();
  });
});
