#!/usr/bin/env node
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
// PreToolUse guard for the Boss session: SendMessage may only reach sessions on the allow list
// (BOSS_ALLOW, globs, comma-separated) and never Boss itself. The prompt asks for the same; this
// makes it hard, so a confused model can never message a session it was not allowed to.
let raw = '';
process.stdin.on('data', (d) => (raw += d));
process.stdin.on('end', () => {
  let input = {};
  try { input = JSON.parse(raw); } catch { /* malformed: deny below */ }
  const ti = input.tool_input ?? {};
  const target = String(ti.to ?? ti.target ?? ti.recipient ?? '').trim().replace(/^@/, '').replace(/\s*\[[^\]]*\]$/, '');
  const allow = (process.env.BOSS_ALLOW ?? '*').split(',').map((s) => s.trim()).filter(Boolean);
  const self = process.env.BOSS_NAME ?? 'boss';
  const glob = (g, n) => new RegExp('^' + g.split('*').map((p) => p.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$', 'i').test(n);
  const ok = target && target !== 'boss' && target !== self && allow.some((g) => glob(g, target));
  try {
    const { appendFileSync, mkdirSync } = require('node:fs');
    const dir = `${process.env.BOSS_HOME ?? `${process.env.HOME}/Boss`}/logs`;
    mkdirSync(dir, { recursive: true });
    appendFileSync(`${dir}/guard.log`, JSON.stringify({ at: new Date().toISOString(), target, decision: ok ? 'allow' : 'deny' }) + '\n');
  } catch { /* logging never blocks the decision */ }
  if (ok) process.exit(0);
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
    permissionDecisionReason: `Boss may only message sessions matching ${allow.join(', ')} (not "${target || '?'}"). Ask Roman instead.` } }));
  process.exit(0);
});
