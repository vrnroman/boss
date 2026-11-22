import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { apply, revert, withBlock, withoutBlock } from '../edit-config.mjs';

const BLOCK = join(import.meta.dirname, '..', 'worker-block.md');
function fixture({ md, settings } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'boss-cfg-'));
  const claude = join(root, '.claude');
  const boss = join(root, 'Boss');
  const fs = { claude, boss };
  if (md !== undefined) { require_mkdir(claude); writeFileSync(join(claude, 'CLAUDE.md'), md); }
  if (settings !== undefined) { require_mkdir(claude); writeFileSync(join(claude, 'settings.json'), settings); }
  return fs;
}
function require_mkdir(d) { mkdirSync(d, { recursive: true }); }

const MD = '# Global instructions\n\nShip without asking.\n';
const SETTINGS = '{\n  "permissions": {\n    "defaultMode": "auto"\n  },\n  "theme": "light"\n}\n';

test('apply adds the block and the setting; revert restores both byte for byte', () => {
  const f = fixture({ md: MD, settings: SETTINGS });
  apply(f.claude, f.boss, BLOCK);
  const md = readFileSync(join(f.claude, 'CLAUDE.md'), 'utf8');
  assert.ok(md.startsWith(MD));
  assert.match(md, /<!-- boss:start -->[\s\S]*Working with Boss[\s\S]*<!-- boss:end -->/);
  const s = JSON.parse(readFileSync(join(f.claude, 'settings.json'), 'utf8'));
  assert.equal(s.crossSessionInbound, 'accept');
  assert.equal(s.theme, 'light');
  assert.deepEqual(s.permissions, { defaultMode: 'auto' });
  const r = revert(f.claude, f.boss);
  assert.equal(r.claudeMd, 'restored');
  assert.equal(readFileSync(join(f.claude, 'CLAUDE.md'), 'utf8'), MD);
  assert.equal(readFileSync(join(f.claude, 'settings.json'), 'utf8'), SETTINGS);
});

test('apply twice is idempotent: one block, and revert still restores the original', () => {
  const f = fixture({ md: MD, settings: SETTINGS });
  apply(f.claude, f.boss, BLOCK);
  apply(f.claude, f.boss, BLOCK);
  const md = readFileSync(join(f.claude, 'CLAUDE.md'), 'utf8');
  assert.equal(md.split('<!-- boss:start -->').length, 2);
  revert(f.claude, f.boss);
  assert.equal(readFileSync(join(f.claude, 'CLAUDE.md'), 'utf8'), MD);
  assert.equal(readFileSync(join(f.claude, 'settings.json'), 'utf8'), SETTINGS);
});

test('user edits after install survive revert: only Boss\'s block and key go', () => {
  const f = fixture({ md: MD, settings: SETTINGS });
  apply(f.claude, f.boss, BLOCK);
  const md = readFileSync(join(f.claude, 'CLAUDE.md'), 'utf8');
  writeFileSync(join(f.claude, 'CLAUDE.md'), md + '\n## Added later\nKeep me.\n');
  const s = JSON.parse(readFileSync(join(f.claude, 'settings.json'), 'utf8'));
  s.model = 'opus';
  writeFileSync(join(f.claude, 'settings.json'), JSON.stringify(s, null, 2) + '\n');
  revert(f.claude, f.boss);
  const after = readFileSync(join(f.claude, 'CLAUDE.md'), 'utf8');
  assert.doesNotMatch(after, /boss:start/);
  assert.match(after, /Keep me\./);
  assert.match(after, /Ship without asking/);
  const s2 = JSON.parse(readFileSync(join(f.claude, 'settings.json'), 'utf8'));
  assert.equal(s2.model, 'opus');
  assert.equal(s2.crossSessionInbound, undefined);
});

test('a pre-existing crossSessionInbound value comes back on revert', () => {
  const f = fixture({ md: MD, settings: '{\n  "crossSessionInbound": "hold"\n}\n' });
  apply(f.claude, f.boss, BLOCK);
  assert.equal(JSON.parse(readFileSync(join(f.claude, 'settings.json'), 'utf8')).crossSessionInbound, 'accept');
  const s = JSON.parse(readFileSync(join(f.claude, 'settings.json'), 'utf8'));
  s.extra = 1;
  writeFileSync(join(f.claude, 'settings.json'), JSON.stringify(s));
  revert(f.claude, f.boss);
  assert.equal(JSON.parse(readFileSync(join(f.claude, 'settings.json'), 'utf8')).crossSessionInbound, 'hold');
});

test('missing files are created and removed again', () => {
  const f = fixture();
  apply(f.claude, f.boss, BLOCK);
  assert.ok(existsSync(join(f.claude, 'CLAUDE.md')));
  revert(f.claude, f.boss);
  assert.ok(!existsSync(join(f.claude, 'CLAUDE.md')));
  assert.ok(!existsSync(join(f.claude, 'settings.json')));
});

test('invalid settings.json is never touched', () => {
  const f = fixture({ md: MD, settings: '{ broken' });
  assert.throws(() => apply(f.claude, f.boss, BLOCK), /not valid JSON/);
  assert.equal(readFileSync(join(f.claude, 'settings.json'), 'utf8'), '{ broken');
});

test('block helpers', () => {
  assert.equal(withoutBlock(withBlock(MD, '<!-- boss:start -->\nX\n<!-- boss:end -->')), MD);
  assert.equal(withoutBlock('no block'), 'no block');
  assert.equal(withBlock('a\n<!-- boss:start -->old<!-- boss:end -->\nb\n', '<!-- boss:start -->new<!-- boss:end -->'), 'a\n<!-- boss:start -->new<!-- boss:end -->\nb\n');
});
