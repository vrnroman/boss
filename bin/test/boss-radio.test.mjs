import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { pickItems, script, sendAllowed, speakable } from '../boss-radio.mjs';
import { homedir, userInfo } from 'node:os';

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

test('a test, demo or sandbox can never send to Telegram, even without --dry', () => {
  const real = join(userInfo().homedir, 'Boss');
  assert.equal(sendAllowed({}, real), true);
  assert.equal(sendAllowed({ BOSS_RADIO_DRY: '1' }, real), false);
  assert.equal(sendAllowed({ BOSS_NO_TELEGRAM: '1' }, real), false);
  assert.equal(sendAllowed({ BOSS_DEBUG_CONTROL: '1' }, real), false);
  assert.equal(sendAllowed({}, '/tmp/boss-sandbox/Boss'), false);
});

test('without --dry, a sandbox home still does not send', () => {
  const home = mkdtempSync(join(tmpdir(), 'boss-radio-nodry-'));
  mkdirSync(join(home, 'state'));
  writeFileSync(join(home, 'state', 'events.jsonl'), '');
  const env = { ...process.env, BOSS_HOME: home, TELEGRAM_ENV: '/nonexistent' };
  delete env.BOSS_RADIO_DRY;
  const r = JSON.parse(execFileSync(process.execPath, [join(import.meta.dirname, '..', 'boss-radio.mjs')], { env, encoding: 'utf8' }).trim());
  assert.equal(r.sent, false);
});

test('recap text is read without quote marks (the Russian voice says "backslash" for « »)', () => {
  assert.equal(speakable('site: заголовок «Деньги за секунды»'), 'site: заголовок Деньги за секунды');
  assert.equal(speakable('a \\ “b”'), 'a b');
});
