import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { pickItems, script } from '../boss-radio.mjs';

const now = new Date('2026-11-22T10:40:00Z'); // 18:40 SGT
const ev = (at, kind, text, lang) => ({ type: 'say', at, data: { kind, text, lang } });

test('picks only reports since the cutoff, newest last, at most 8, plus open questions', () => {
  const events = [ev('2026-11-22T01:00:00Z', 'report', 'old'), ev('2026-11-22T09:00:00Z', 'info', 'not a report'),
    ...Array.from({ length: 10 }, (_, i) => ev(`2026-11-22T09:${10 + i}:00Z`, 'report', `r${i}`))];
  const r = pickItems(events, [{ question: 'Merge or hold?', session: 'payments', at: 'x' }], Date.parse('2026-11-22T08:00:00Z'));
  assert.equal(r.reports.length, 8);
  assert.equal(r.reports.at(-1).text, 'r9');
  assert.equal(r.dropped, 2);
  assert.equal(r.questions[0].text, 'payments asks: Merge or hold?');
  assert.ok(!r.reports.some((x) => x.text === 'old' || x.text === 'not a report'));
});

test('the script opens with SGT time and counts, keeps Russian items Russian, closes with "Boss out."', () => {
  const s = script({ reports: [{ text: 'payments: green, 248 tests pass.' }, { text: 'site: готово, три правки.', lang: 'ru' }], questions: [{ text: 'site asks: which colour?' }], dropped: 0 }, now);
  assert.equal(s[0].text, 'Boss radio, 18:40 Singapore time. 2 reports, one question waiting for you.');
  assert.equal(s[2].lang, 'ru');
  assert.equal(s.at(-1).text, 'Boss out.');
  assert.equal(script({ reports: [], questions: [], dropped: 0 }, now)[0].text, 'Boss radio, 18:40 Singapore time. No new reports.');
});

test('dry run renders a real audio file with the radio sounds and sends nothing', async () => {
  const home = mkdtempSync(join(tmpdir(), 'boss-radio-'));
  mkdirSync(join(home, 'state'));
  writeFileSync(join(home, 'state', 'events.jsonl'), [ev(new Date().toISOString(), 'report', 'bt-alpha: green, file created.')].map((e) => JSON.stringify(e)).join('\n') + '\n');
  const out = execFileSync(process.execPath, [join(import.meta.dirname, '..', 'boss-radio.mjs'), '--dry'], { env: { ...process.env, BOSS_HOME: home, TELEGRAM_ENV: '/nonexistent' }, encoding: 'utf8' });
  const r = JSON.parse(out.trim());
  assert.equal(r.sent, false);
  assert.equal(r.reports, 1);
  assert.ok(existsSync(r.path));
  assert.ok(r.seconds > 3 && r.seconds < 60, `${r.seconds} s`);
  assert.ok(!existsSync(join(home, 'state', 'radio-last.json')), 'a dry run does not move the cutoff');
});
