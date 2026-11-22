import { test } from 'node:test';
import assert from 'node:assert/strict';
import { keysFor, SCREENS, launchCommand } from '../boss-up.mjs';

const trust = `────────────
 Accessing workspace:

 /Users/x/Boss/boss

 Quick safety check: Is this a project you created or one you trust?

 Claude Code'll be able to read, edit, and execute files here.

 ❯ No, exit
   Yes, I trust this folder

 Enter to confirm · Esc to cancel`;

const mcp = `  New MCP server found in this project: boss-channel

  MCP servers may execute code or access system resources.

    Use this MCP server
    Use this and all future MCP servers in this project
  ❯ Continue without using this MCP server

  Enter to confirm · Esc to cancel`;

const dev = `  WARNING: Loading development channels

  --dangerously-load-development-channels is for local channel development only.

  Channels: server:boss-channel

  ❯ 1. I am using this for local development
    2. Exit

  Enter to confirm · Esc to cancel`;

const screen = (t) => SCREENS.find((s) => s.marker.test(t));

test('trust screen: moves down onto "Yes, I trust this folder"', () => {
  assert.equal(screen(trust).id, 'trust');
  assert.deepEqual(keysFor(trust, screen(trust).choose), ['Down', 'Enter']);
});

test('mcp screen: moves up twice onto "Use this MCP server", not the "all future" option', () => {
  assert.equal(screen(mcp).id, 'mcp');
  assert.deepEqual(keysFor(mcp, screen(mcp).choose), ['Up', 'Up', 'Enter']);
});

test('dev channels warning: cursor already on the right option, just Enter (never Exit)', () => {
  assert.equal(screen(dev).id, 'devchannels');
  assert.deepEqual(keysFor(dev, screen(dev).choose), ['Enter']);
});

test('dev channels warning with cursor on Exit moves up', () => {
  const t = dev.replace('❯ 1. I am', '  1. I am').replace('    2. Exit', '  ❯ 2. Exit');
  assert.deepEqual(keysFor(t, screen(t).choose), ['Up', 'Enter']);
});

test('an unknown menu returns null instead of guessing', () => {
  assert.equal(keysFor(' ❯ Delete everything\n   Keep\n Enter to confirm', /Something else/), null);
  assert.equal(keysFor('no menu here', /x/), null);
});

test('a normal idle Claude screen is not mistaken for a startup screen', () => {
  const idle = '❯ Try "edit <filepath> to…"\n  ⏵⏵ auto mode on (shift+tab to cycle)';
  assert.equal(screen(idle), undefined);
});

test('launch command pins the name, model, channel and project-only settings', () => {
  const c = launchCommand();
  assert.match(c, /--name 'boss'/);
  assert.match(c, /--model 'haiku'/);
  assert.match(c, /--setting-sources project,local/);
  assert.match(c, /--dangerously-load-development-channels server:boss-channel/);
  assert.doesNotMatch(c, /dangerously-skip-permissions/);
});
