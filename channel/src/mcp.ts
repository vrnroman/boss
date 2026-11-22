// A minimal MCP server over stdio (newline-delimited JSON-RPC 2.0), enough for a Claude Code
// channel: initialize, tools/list, tools/call, ping, and pushed notifications. No SDK, no deps.
import type { Readable, Writable } from 'node:stream';

export type Tool = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  handler: (args: Record<string, unknown>) => Promise<unknown> | unknown;
};

// Newest first. 2026-07-28 is deliberately absent: a server on that revision is not registered
// as a channel by the v2 MCP client runtime (channels-reference).
export const SUPPORTED = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

export class ToolError extends Error {}

export class McpServer {
  out: Writable;
  tools = new Map<string, Tool>();
  instructions: string;
  initialized = false;
  onInitialized: () => void = () => {};
  onClose: () => void = () => {};
  log: (s: string) => void;
  buf = '';

  constructor(opts: { input: Readable; output: Writable; instructions: string; log?: (s: string) => void }) {
    this.out = opts.output;
    this.instructions = opts.instructions;
    this.log = opts.log ?? (() => {});
    opts.input.setEncoding('utf8');
    opts.input.on('data', (chunk: string) => this.feed(chunk));
    opts.input.on('end', () => this.onClose());
  }

  addTool(t: Tool): void {
    this.tools.set(t.name, t);
  }

  write(msg: unknown): void {
    this.out.write(JSON.stringify(msg) + '\n');
  }

  notify(method: string, params: unknown): void {
    this.write({ jsonrpc: '2.0', method, params });
  }

  feed(chunk: string): void {
    this.buf += chunk;
    let i: number;
    while ((i = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, i).trim();
      this.buf = this.buf.slice(i + 1);
      if (line) void this.handle(line);
    }
  }

  async handle(line: string): Promise<void> {
    let msg: { id?: string | number; method?: string; params?: Record<string, unknown> };
    try {
      msg = JSON.parse(line);
    } catch {
      this.write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
      return;
    }
    const { id, method, params = {} } = msg;
    if (!method) return; // a response to something we never send
    const isRequest = id !== undefined && id !== null;
    try {
      if (method === 'initialize') {
        const asked = String(params.protocolVersion ?? '');
        const protocolVersion = SUPPORTED.includes(asked) ? asked : SUPPORTED[0];
        this.write({
          jsonrpc: '2.0', id,
          result: {
            protocolVersion,
            capabilities: { tools: {}, experimental: { 'claude/channel': {} } },
            serverInfo: { name: 'boss-channel', version: '1.0.0' },
            instructions: this.instructions,
          },
        });
        return;
      }
      if (method === 'notifications/initialized') {
        this.initialized = true;
        this.onInitialized();
        return;
      }
      if (!isRequest) return; // other notifications (cancelled, etc.) need no answer
      if (method === 'ping') return this.write({ jsonrpc: '2.0', id, result: {} });
      if (method === 'tools/list') {
        const tools = [...this.tools.values()].map(({ name, description, inputSchema }) => ({ name, description, inputSchema }));
        return this.write({ jsonrpc: '2.0', id, result: { tools } });
      }
      if (method === 'tools/call') {
        const name = String(params.name ?? '');
        const tool = this.tools.get(name);
        if (!tool) return this.write({ jsonrpc: '2.0', id, error: { code: -32602, message: `unknown tool ${name}` } });
        try {
          const r = await tool.handler((params.arguments as Record<string, unknown>) ?? {});
          return this.write({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: typeof r === 'string' ? r : JSON.stringify(r) }] } });
        } catch (err) {
          const m = err instanceof Error ? err.message : String(err);
          this.log(`tool ${name} failed: ${m}`);
          return this.write({ jsonrpc: '2.0', id, result: { isError: true, content: [{ type: 'text', text: m }] } });
        }
      }
      this.write({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } });
    } catch (err) {
      if (isRequest) this.write({ jsonrpc: '2.0', id, error: { code: -32603, message: String(err) } });
    }
  }
}
