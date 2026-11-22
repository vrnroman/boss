#!/usr/bin/env node
// Reversible edits to the user's Claude Code config, with a record of what was there before.
//
//   edit-config.mjs apply   <claudeDir> <bossHome> <blockFile>
//   edit-config.mjs revert  <claudeDir> <bossHome>
//
// apply: puts the worker block between <!-- boss:start --> / <!-- boss:end --> in CLAUDE.md
// (replacing an older block, or appending), and sets "crossSessionInbound": "accept" in
// settings.json. Before the first change it saves exact copies under <bossHome>/backups/ and
// writes <bossHome>/install-state.json. revert: puts both files back byte for byte when they were
// not changed since, or removes only Boss's own edits when they were.
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const START = '<!-- boss:start -->';
const END = '<!-- boss:end -->';

function atomicWrite(file, text) {
  writeFileSync(`${file}.boss-tmp`, text);
  renameSync(`${file}.boss-tmp`, file);
}

export function withBlock(md, block) {
  const b = block.trim();
  const i = md.indexOf(START);
  const j = md.indexOf(END);
  if (i >= 0 && j > i) return md.slice(0, i) + b + md.slice(j + END.length);
  const sep = md === '' ? '' : md.endsWith('\n\n') ? '' : md.endsWith('\n') ? '\n' : '\n\n';
  return md + sep + b + '\n';
}

export function withoutBlock(md) {
  const i = md.indexOf(START);
  const j = md.indexOf(END);
  if (i < 0 || j < i) return md;
  let before = md.slice(0, i);
  let after = md.slice(j + END.length);
  if (after.startsWith('\n')) after = after.slice(1);
  if (after === '' && before.endsWith('\n\n')) before = before.slice(0, -1);
  return before + after;
}

export function apply(claudeDir, bossHome, blockFile) {
  const md = join(claudeDir, 'CLAUDE.md');
  const st = join(claudeDir, 'settings.json');
  const stateFile = join(bossHome, 'install-state.json');
  const backups = join(bossHome, 'backups');
  mkdirSync(backups, { recursive: true });
  const prev = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : null;
  const state = prev ?? { at: new Date().toISOString(), claudeMd: {}, settings: {} };

  // CLAUDE.md
  const mdBefore = existsSync(md) ? readFileSync(md, 'utf8') : null;
  if (!prev) {
    state.claudeMd.existed = mdBefore !== null;
    if (mdBefore !== null) copyFileSync(md, join(backups, 'CLAUDE.md.orig'));
  }
  const mdAfter = withBlock(mdBefore ?? '', readFileSync(blockFile, 'utf8'));
  mkdirSync(claudeDir, { recursive: true });
  atomicWrite(md, mdAfter);
  state.claudeMd.written = mdAfter;

  // settings.json
  const stBefore = existsSync(st) ? readFileSync(st, 'utf8') : null;
  let settings = {};
  if (stBefore !== null) {
    try { settings = JSON.parse(stBefore); } catch { throw new Error(`${st} is not valid JSON; not touching it`); }
  }
  if (!prev) {
    state.settings.existed = stBefore !== null;
    state.settings.hadKey = Object.hasOwn(settings, 'crossSessionInbound');
    state.settings.oldValue = settings.crossSessionInbound;
    if (stBefore !== null) copyFileSync(st, join(backups, 'settings.json.orig'));
  }
  if (settings.crossSessionInbound !== 'accept') {
    settings.crossSessionInbound = 'accept';
    const stAfter = JSON.stringify(settings, null, 2) + '\n';
    atomicWrite(st, stAfter);
    state.settings.written = stAfter;
  } else {
    state.settings.written = stBefore;
  }
  writeFileSync(stateFile, JSON.stringify(state, null, 2));
  return state;
}

export function revert(claudeDir, bossHome) {
  const md = join(claudeDir, 'CLAUDE.md');
  const st = join(claudeDir, 'settings.json');
  const stateFile = join(bossHome, 'install-state.json');
  const backups = join(bossHome, 'backups');
  if (!existsSync(stateFile)) return { reverted: false, reason: 'no install state' };
  const state = JSON.parse(readFileSync(stateFile, 'utf8'));
  const out = {};

  const mdNow = existsSync(md) ? readFileSync(md, 'utf8') : null;
  if (mdNow !== null && mdNow === state.claudeMd.written) {
    // Untouched since install: exact restore.
    if (state.claudeMd.existed) { copyFileSync(join(backups, 'CLAUDE.md.orig'), md); out.claudeMd = 'restored'; }
    else { unlinkSync(md); out.claudeMd = 'removed'; }
  } else if (mdNow !== null) {
    atomicWrite(md, withoutBlock(mdNow));
    out.claudeMd = 'block removed (file changed since install)';
  }

  const stNow = existsSync(st) ? readFileSync(st, 'utf8') : null;
  if (stNow !== null && stNow === state.settings.written) {
    if (state.settings.existed) { copyFileSync(join(backups, 'settings.json.orig'), st); out.settings = 'restored'; }
    else { unlinkSync(st); out.settings = 'removed'; }
  } else if (stNow !== null) {
    const s = JSON.parse(stNow);
    if (state.settings.hadKey) s.crossSessionInbound = state.settings.oldValue;
    else delete s.crossSessionInbound;
    atomicWrite(st, JSON.stringify(s, null, 2) + '\n');
    out.settings = 'key reverted (file changed since install)';
  }
  unlinkSync(stateFile);
  return { reverted: true, ...out };
}

if (process.argv[1]?.endsWith('edit-config.mjs')) {
  const [cmd, claudeDir, bossHome, blockFile] = process.argv.slice(2);
  try {
    const r = cmd === 'apply' ? apply(claudeDir, bossHome, blockFile) : cmd === 'revert' ? revert(claudeDir, bossHome) : null;
    if (!r) { console.error('usage: edit-config.mjs apply|revert <claudeDir> <bossHome> [blockFile]'); process.exit(2); }
    console.log(JSON.stringify(cmd === 'apply' ? { applied: true } : r));
  } catch (e) {
    console.error(`edit-config: ${e.message}`);
    process.exit(1);
  }
}
