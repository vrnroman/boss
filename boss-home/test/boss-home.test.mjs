import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

const HOME = join(import.meta.dirname, '..');
const settings = JSON.parse(readFileSync(join(HOME, '.claude', 'settings.json'), 'utf8'));
const LOGHOME = (await import('node:fs')).mkdtempSync(join((await import('node:os')).tmpdir(), 'guard-test-'));
const guard = (input, env = {}) => execFileSync(process.execPath, [join(HOME, '.claude', 'guard-send.mjs')], { input: JSON.stringify(input), env: { ...process.env, BOSS_HOME: LOGHOME, ...env }, encoding: 'utf8' });
const denied = (out) => out.trim() !== '' && JSON.parse(out).hookSpecificOutput.permissionDecision === 'deny';

test('every tool the channel offers is allowed for Boss (a missing one is silently denied in dontAsk mode)', async () => {
  const src = readFileSync(join(HOME, '..', 'channel', 'src', 'channel.ts'), 'utf8');
  const tools = [...src.matchAll(/name: '([a-z_]+)',\n\s+description:/g)].map((m) => m[1]);
  assert.ok(tools.length >= 6, tools.join(','));
  for (const t of tools) assert.ok(settings.permissions.allow.includes(`mcp__boss-channel__${t}`), `mcp__boss-channel__${t} allowed`);
});

test('Boss cannot run shell, edit, write or fetch', () => {
  for (const t of ['Bash', 'Edit', 'Write', 'WebFetch', 'WebSearch']) assert.ok(settings.permissions.deny.includes(t), t);
  assert.equal(settings.permissions.defaultMode, 'dontAsk');
});

test('SendMessage guard: allowed targets pass, everything else is denied', () => {
  const env = { BOSS_ALLOW: 'bt-*,payments', BOSS_NAME: 'bt-boss' };
  assert.equal(guard({ tool_name: 'SendMessage', tool_input: { to: 'bt-alpha', message: 'x' } }, env), '');
  assert.equal(guard({ tool_name: 'SendMessage', tool_input: { to: '@payments [ab12cd]' } }, env), '');
  assert.ok(denied(guard({ tool_name: 'SendMessage', tool_input: { to: 'reelshow-9d' } }, env)));
  assert.ok(denied(guard({ tool_name: 'SendMessage', tool_input: { to: 'bt-boss' } }, env)));
  assert.ok(denied(guard({ tool_name: 'SendMessage', tool_input: { to: 'boss' } }, env)));
  assert.ok(denied(guard({ tool_name: 'SendMessage', tool_input: {} }, env)));
  assert.equal(guard({ tool_name: 'SendMessage', tool_input: { to: 'anything' } }, { BOSS_ALLOW: '*', BOSS_NAME: 'boss' }), '');
});

test('the guard is wired as a PreToolUse hook on SendMessage', () => {
  const h = settings.hooks.PreToolUse.find((x) => x.matcher === 'SendMessage');
  assert.match(h.hooks[0].command, /guard-send\.mjs/);
});
