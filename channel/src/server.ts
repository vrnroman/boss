// Entry point: Claude Code starts this as the Boss session's MCP server (see boss-home/.mcp.json).
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Channel } from './channel.ts';

const home = process.env.BOSS_HOME ?? join(homedir(), 'Boss');
const ch = new Channel({
  home,
  port: Number(process.env.BOSS_PORT ?? 8788),
  input: process.stdin,
  output: process.stdout,
  allow: process.env.BOSS_ALLOW ?? '*',
  selfName: process.env.BOSS_NAME ?? 'boss',
  humor: Number(process.env.BOSS_HUMOR ?? 1),
  confirmWindowMs: process.env.BOSS_CONFIRM_MS ? Number(process.env.BOSS_CONFIRM_MS) : undefined,
});
ch.mcp.onClose = () => {
  ch.log('stdin_closed', {});
  ch.close();
  process.exit(0);
};
ch.listen().catch((err) => {
  ch.log('listen_failed', { error: String(err) });
  process.stderr.write(`boss-channel: cannot listen on ${ch.opts.port}: ${err}\n`);
  process.exit(1);
});
