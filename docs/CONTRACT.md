# Boss phase 1: interface contract

Phase 1 = spec milestones M1 + M2, plus the approved touches (Kokoro voice, Russian
first-class, radio sounds, Telegram text fallback, trust graduation, timing tower,
live target chip, dry humour line). Every piece builds against this file.

## Processes and ports (all bind 127.0.0.1 only)

| Piece | Where | Port | Started by |
|---|---|---|---|
| Boss.app (Swift, SwiftPM) | `app/` → `build/Boss.app` | 8789 (debug control, only when `BOSS_DEBUG_CONTROL=1` or defaults `debugControl=YES`) | login item |
| boss-channel (Node 25 TS, zero deps) | `channel/` | 8788 (`BOSS_PORT`) | Claude Code, as the Boss session's MCP server |
| Boss session (Claude Code, Haiku) | `~/Boss/boss` (copied from `boss-home/`) | none | `bin/boss-up` (launchd job), tmux socket `-L boss`, session `boss` |
| whisper-server (whisper.cpp) | brew | 8791 | launchd `com.boss.whisper` |
| Kokoro TTS sidecar (python) | `tts/` | 8792 | launchd `com.boss.tts` |

Runtime home `~/Boss` (`BOSS_HOME` overrides; tests use a temp dir):
`token` (mode 600, 32 random bytes hex), `state/` (channel state JSON), `outbox/`
(WAV + JSON per utterance, written BEFORE transcription), `logs/`, `models/`, `boss/`.

## Channel HTTP API (app → channel)

Every request needs `Authorization: Bearer <token>` (else 403 `{error}`). A request with an
`Origin` header, or a `Host` that is not `127.0.0.1:<port>`/`localhost:<port>`, is 403.
Bodies are JSON (`content-type: application/json`), max 64 KB.

- `GET /health` → `{ok:true, boss_connected:bool, version, uptime_s}`. `boss_connected` is true
  once Claude Code finished MCP `initialize` on stdio.
- `POST /utterance` `{id, text, mode:"talk"|"handsfree"|"feedback", lang?:"en"|"ru", lock?, context?}`
  → `202 {ok:true, id, duplicate:bool}`. Idempotent by `id` (outbox retries are safe). Emits a
  channel notification to Boss. If Boss is not connected → `503 {error:"boss offline"}` and the app
  keeps the utterance queued.
- `POST /answer` `{question_id, text}` → `202`. Emits a channel event `kind=answer`.
- `POST /undo` `{utterance_id}` → `202`. Emits `kind=undo` ("scratch that").
- `POST /cancel_route` `{route_id}` → `{ok}`. Cancels a pending confirm window (trust graduation).
- `GET /state` → `{routes:[...last 50], questions:[pending], reports:{<session>: {text, at}},
  ledger:{<session>: {blind:int, misses:int, graduated:bool}}, settings:{humor, allow}}`.
- `GET /events` → Server-Sent Events. Each event: `id: <seq>\nevent: <type>\ndata: <json>\n\n`.
  Supports `Last-Event-ID` header or `?since=<seq>` replay from a ring buffer (last 500, persisted
  to `state/events.jsonl`). Comment keepalive `: ping` every 15 s. Types:
  - `say` `{id, text, links:[{title,url}], speak:bool, session?, lang?, kind:"report"|"info"|"status"}`
  - `ask` `{question_id, question, choices:[string], about_id?, session?, lang?}`
  - `routed` `{utterance_id, target, status:"sent"|"delivered"|"failed"|"asking"|"ignored", note?}`
  - `confirm` `{route_id, utterance_id, target, reason, window_ms}` (an inferred, not-yet-trusted route;
    the app shows "→ target" with a countdown and a Cancel button)
  - `boss` `{connected:bool}`

## Channel MCP side (Claude Code ↔ channel, stdio JSON-RPC)

- Answers `initialize` with `capabilities: {tools:{}, experimental:{"claude/channel":{}}}`,
  `serverInfo {name:"boss-channel"}`, and `instructions` (how events look, which tools to use).
  Negotiates protocol `2025-11-25` or older (never `2026-07-28`). Unknown requests (e.g.
  `server/discover`) get JSON-RPC error `-32601`.
- Event push: `notifications/claude/channel` `{content, meta}`. Meta keys `[A-Za-z0-9_]` only:
  `kind` (utterance|answer|undo), `utterance_id`, `mode`, `lang`, `lock`, `question_id`, `about_id`,
  `session`.
- Tools:
  - `say({text, links?, speak?=true, session?, lang?, kind?})`
  - `ask({question, choices?, about_id?, session?, lang?})` → returns `question_id`
  - `route({utterance_id, target, explicit:bool, reason})` → BLOCKS until decided, returns
    `{decision:"send"|"cancelled", route_id}`. explicit (named/locked) or graduated targets return
    `send` at once; otherwise emits `confirm` and waits `window_ms` (2500) for a cancel.
  - `routed({utterance_id, target, status, note?})` (after SendMessage)
  - `state()` → same as `GET /state` plus `allow` (glob of names Boss may route to; `*` in prod,
    `bt-*` in tests) and `utterances` (last 20).
- Trust graduation: per target, `blind` counts inferred routes that were sent and not undone within
  60 s; `misses` counts cancels and undos. `graduated = blind >= 10 && misses*10 <= blind`.

## Worker ↔ Boss (Claude Code cross-session messages)

Boss session name is exactly `boss`. Workers get the block in `install/worker-block.md`
(between `<!-- boss:start -->` / `<!-- boss:end -->` in `~/.claude/CLAUDE.md`). Formats:
```
REPORT
SPOKEN: <1-3 plain sentences>
LINKS: <urls, one per line, or none>

QUESTION: <one question> CHOICES: <a | b | c>
```

## App

- Sessions view (the timing tower): live sessions from `~/.claude/sessions/*.json` (pid alive,
  `kind == interactive`, skip `boss`), merged with `GET /state`: waiting-on-you (pending question for
  that session) on top in amber with wait time and the question; then busy with the last report's
  short text; then idle greyed. Rows show name, cwd basename, status, "routed blind b/(b+m)".
- Outbox: `~/Boss/outbox/<id>.wav` + `<id>.json` `{id, created_at, state:"saved"|"transcribed"|"sent"|"failed", text?, lang?}`
  written before transcription; unsent items retry every 5 s and on `boss connected`.
- Transcription: `POST http://127.0.0.1:8791/inference` multipart `file`, `response_format=verbose_json`,
  `language=auto` (or locked), `prompt=<vocabulary: live session names, words list>`. Drop empty /
  known hallucinations ("Thank you.", "Продолжение следует...", etc.) and recordings under 0.3 s or
  below the RMS floor.
- Speech out: Kokoro `POST http://127.0.0.1:8792/speak {text, lang}` → `audio/wav`; Russian, or
  Kokoro down → `AVSpeechSynthesizer` (Milena for ru, best installed en voice). Queue; questions jump
  ahead; paused while recording. Radio sound set on by default (toggle).
- Debug control (8789, token-guarded, off by default): `POST /inject {wav_path}` runs the full path
  as if spoken; `GET /feed` returns cards; `GET /sessions`; `POST /talk {down:bool}`;
  `POST /tap {choice}` answers the newest question card; `GET /spoken` lists texts spoken.
