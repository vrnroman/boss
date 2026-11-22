# Boss: one voice to rule them all

Talk to one assistant; it puts your words, verbatim, into the right Claude Code session and reads
the results back to you. Phase 1 of `docs/SPEC.md` (milestones M1 + M2).

```
 Boss.app (menu-bar pill, hold-to-talk, Kokoro/Milena voice, radio sounds)
   │  local audio → whisper.cpp large-v3-turbo (127.0.0.1:8791)
   │  HTTP + SSE, bearer token (127.0.0.1:8788)
 boss-channel (Node, zero dependencies, MCP channel on stdio)
   │
 Boss session (Claude Code, Haiku, hidden tmux pane, no shell/edit/write tools)
   │  Claude Code cross-session messaging (SendMessage / REPORT / QUESTION)
 your sessions in iTerm (worker block in ~/.claude/CLAUDE.md)
```

## Use
- Talk with **Right Option** (home: hold it), **Left Option + Space** (office: no permissions needed) or the panel's **Talk** button. Hold and release to send, or tap once to start and tap again to send. Esc cancels.
  Release sends. English and Russian both work.
- Name the session first for a direct send. Without a name Boss infers the session and gives you
  2.5 s to cancel ("→ site (docs topic)"); a session that was right 10 times in a row skips that
  window ("routed blind 14/15" in the pill).
- Reports come back spoken, with link cards. Questions come with buttons, and the mic opens for 6 s
  so you can just answer.
- "scratch that" (or Undo) cancels the last message. "What is everyone doing?" gives a status.
  "Radio me" sends a spoken recap of recent reports to your Telegram.
- Away from the Mac for 10+ minutes: reports and questions also go to Telegram as text.

## Install / redeploy / remove
```sh
sh install/install.sh          # idempotent; also the redeploy
sh install/uninstall.sh        # puts ~/.claude/CLAUDE.md and settings.json back
```
First use: macOS asks for the Microphone. For the Right Option hotkey, allow Boss in
System Settings → Privacy & Security → Input Monitoring (the panel button works without it).

## Test
```sh
sh scripts/test.sh             # unit, typecheck, installer round trip, dependency audit, secret scan
sh scripts/test.sh --e2e       # plus real end-to-end runs against throwaway Claude Code sessions
```

## Security
No Docker image is shipped: Boss needs the Mac itself (mic, hotkey, iTerm, Claude Code sockets).
Everything listens on 127.0.0.1 only and refuses browser requests. The channel and app need a
32-byte token (`~/Boss/token`, mode 600). The channel has zero runtime npm dependencies; the
voice sidecar's Python lockfile passes pip-audit. The Boss session cannot run shell commands,
edit files or fetch the web, and can route only to sessions on its allow list.
