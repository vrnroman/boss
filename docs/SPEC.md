# Boss — Voice Control for Claude Code on macOS (Build Spec)

Nov 22, 2026 · @Roman V

## Goal and principles

Boss lets Roman run many Claude Code sessions while talking to only one. He speaks to Boss from a small panel on his Mac. Boss sends each instruction to the right session, asks when unsure, and reports back out loud, with links, when work is done.

**The problem today:** five or six iTerm tabs, each needing typing, switching and reading. The heaviest input is feedback: a session builds a deck or a site, Roman clicks through it with many comments, and has to type them into the right tab.

**Principles** — every design choice below follows from these:

1. **One conversation.** Roman talks to and hears from Boss only. Workers never address him directly.
2. **Speak, don't type.** Every action has a voice path; the keyboard is optional.
3. **Listen, don't read.** Results come back as one to three spoken sentences plus tappable links. Terminals are for detail only.
4. **Context travels with the words.** During feedback, Boss knows which page, slide or file Roman was looking at, and which session built it.
5. **Ask, don't guess.** An unclear target gets one short question with choices, never a wrong delivery.
6. **Words go verbatim.** Boss forwards what Roman said; it does not rewrite instructions.
7. **Never lose a word.** Audio is saved locally before anything else happens; failures retry and stay visible.
8. **Local first.** Audio and transcription stay on the Mac; only text reaches Claude.
9. **Hardware-ready.** A physical button or stick is just another input to the same app.

**Not in v1:** replacing Claude Code's own UI, cloud or remote sessions, Windows or Linux, multiple users.

**Targets** (to verify in testing): under 3 seconds from end of speech to message landing in the worker; no lost utterances; after a week of use, most instructions routed without Boss needing to ask.

## User experience

Roman keeps one small panel on screen and one voice in his ear. These scenarios are the acceptance bar for the build.

**Start of day.** Boss.app starts at login, launches the Boss session in a hidden tmux pane and says: “Boss ready. Three sessions open: payments, gateway, titan-otc.” The panel sits top-right as a small pill.

**1. Dispatch.** Roman holds Right Option and says “Payments: rename the fee calculator to pricing engine and run the tests.” He releases. A two-second toast says “→ payments” with a soft click. He carries on with whatever he was doing.

**2. Report back.** Minutes later, a chime and Boss's voice: “Payments: renamed, all 248 tests pass. Pull request 482 is open.” A card appears in the feed with **Open PR** and **Show session** buttons; the second brings the payments iTerm tab to the front.

**3. Narrated feedback.** The `site` session built a landing page on `localhost:5173`. Roman opens it in Chrome and double-taps Right Option. The panel turns red: “Feedback · localhost:5173 → site · 00:12”. He scrolls, clicks between pages and talks for four minutes. The app notes which page he was on as he spoke and screenshots each page. He double-taps to stop. Boss: “Sent seven points across three pages to site.” Later: “Site fixed six. One question: which colour for the highlighted pricing card?” Decks work the same way: Keynote and PowerPoint report the current slide, an HTML deck reports its URL.

**4. Boss asks back.** “Run the linter.” Boss: “Payments or gateway?” The card shows two buttons, and the mic opens by itself for six seconds, so Roman just says “gateway”.

**5. New session.** “Start a session for the gold ledger repo.” Boss opens a new iTerm tab named `gold-ledger` in that folder and says so.

**6. Status.** “What is everyone doing?” Boss: “Payments is idle. Gateway has been running migrations for ten minutes. Site is waiting for your answer on colours.”

**7. Quiet.** In a meeting, Roman taps Mute. Reports pile up as cards, silently. Afterwards: “Catch me up”, and Boss reads a short digest.

**8. Correction.** “Scratch that” within a minute, or Undo on the card, tells the last target to ignore the last message.

## Architecture

Four pieces, each with one job: the app handles everything human (sound, screen, buttons); the channel server is a thin, local bridge; Boss decides where words go; workers do the work.

&#91;embedded content: Boss architecture · app, channel, Boss session, workers\]

| Component | Built with | Runs as |
| --- | --- | --- |
| Boss.app | Swift, SwiftUI + AppKit, WhisperKit | Menu-bar app, login item |
| `boss-channel` | Bun, TypeScript, MCP SDK | Started by Claude Code inside the Boss session |
| Boss session | Claude Code, `CLAUDE.md` + settings in `~/Boss/boss` | Hidden tmux pane, launched by the app |
| Workers | Claude Code, launched with `bw` | Roman's iTerm tabs |
| State | JSON files in `~/Boss/state/` | Shared by app and channel |

Nothing listens beyond `127.0.0.1` except the optional device port (see Device protocol). Worker-to-Boss messages travel over Claude Code's local per-session sockets, not through any server.

## The Mac app

Boss.app is a native menu-bar app (SwiftUI + AppKit, macOS 14+, Apple Silicon) with one floating panel. The panel never steals keyboard focus, so it can stay up while Roman works in any other app.

**Surfaces**

- **Menu-bar icon:** grey idle, blue listening, red hands-free or feedback, green speaking, amber “waiting on you”, a warning badge when Boss is offline.
- **Panel:** a non-activating, always-on-top `NSPanel` on all Spaces, draggable, two sizes. **Pill:** state dot, target lock if set, last route (“→ payments”), counts (“2 working · 1 waiting on you”). **Expanded:** the buttons and the feed.
- **Buttons:** Talk (press and hold), Hands-free (toggle), Feedback (toggle, captures what is on screen), Lock target (session picker), Repeat, Mute.
- **Recording overlay:** next to the panel, a level meter, a timer, and the hint “release to send” or “double-tap to stop”.

**Feed cards**, newest first:

| Card | Shows | Actions |
| --- | --- | --- |
| You said | Transcript, target chip, status: saved → sent → delivered, or failed | Undo, Resend, Edit and resend |
| Report | Session, the spoken summary, links | Open each link, Show session, Reply by voice |
| Question | Boss's question, choices as buttons | Tap a choice, or just answer: the mic opens for 6 seconds |
| Feedback batch | Pages or slides, point count, thumbnails | Open batch file, Show session |
| System | Errors and recoveries | Retry, Restart Boss |

**Default controls** (all rebindable in Settings):

| Gesture | Action |
| --- | --- |
| Hold Right Option | Push-to-talk; release sends |
| Double-tap Right Option | Hands-free on; double-tap again sends |
| Double-tap Right Command | Feedback mode on or off |
| Esc while recording | Cancel; nothing is sent |
| ⌃⌥R | Repeat last spoken answer |
| ⌃⌥M | Mute or unmute speech |
| ⌃⌥L | Lock or unlock a target session |

Modifier keys are read with a `CGEventTap` on `flagsChanged`. A press over 300 ms is a hold; two taps within 350 ms are a double-tap. A single click during a hands-free recording is ignored.

**Target lock.** “Talk to site” or ⌃⌥L pins every utterance to one session until “unlock”. The pill shows the lock. Boss still forwards, but skips the routing decision. This is the mode for long feedback bursts.

**Sounds:** short and quiet, each one distinct — start, stop, sent, report, question, error. All can be turned off.

**Failure behaviour.** Every recording is written to `~/Boss/outbox/` before transcription. If Boss is offline, the pill says so with a Restart button, and queued messages send automatically when it returns.

**First run.** A checklist that verifies or requests: Microphone, Input Monitoring and Accessibility (hotkeys), Screen Recording (feedback screenshots), Automation for iTerm, Chrome, Safari, Keynote and PowerPoint, Claude Code version, and `tmux` and `bun` installed. It ends with a test: “Say hello to Boss.”

## Feedback mode

Feedback mode is hands-free recording plus a record of what was on screen while Roman spoke. Each comment arrives at the right session tagged with its page or slide and a screenshot.

**What the app captures**, sampled every second while recording:

| Front app | Captured | How |
| --- | --- | --- |
| Chrome, Arc, Brave, Edge | Active tab URL and title | AppleScript (`URL of active tab of front window`) |
| Safari | Front document URL and title | AppleScript |
| Keynote | File path and current slide number | AppleScript |
| PowerPoint | File path and current slide | AppleScript (verify on install) |
| Preview, PDF viewers | File path and page, parsed from the window title | Accessibility API |
| Any other app | App name, window title, selected text | Accessibility API |

**Segments.** A new context segment starts whenever the URL, slide or file changes. The app screenshots the front window (ScreenCaptureKit) at each new segment. A single tap of Right Command during feedback takes an extra screenshot (“this one”). Transcription returns timestamped sentences; each sentence is assigned to the segment that was on screen when it started.

**The batch.** On stop, the app writes `~/Boss/feedback/<time>-<target>.md` and passes its path to Boss:

```markdown
# Feedback for site · 2026-11-22 10:45 · 4 min 12 s
## http://localhost:5173/  (screenshot: shots/01.png)
- [00:05] The hero title is too long, make it one line.
## http://localhost:5173/pricing  (screenshot: shots/02.png)
- [01:12] The middle card should be highlighted.
```

Sentences are kept as spoken; only filler words (“um”, “uh”) are removed.

**Finding the session that built it**, in this order:

1. Target lock, if set, or a spoken target at the start (“this is for gateway”).
2. **Artifact registry**: workers register what they produce (URL prefix, file path, deck name); see Worker sessions.
3. **Local port lookup**: for `localhost:<port>`, run `lsof -nP -iTCP:<port> -sTCP:LISTEN` to get the process, then its working folder, then the session whose folder contains it.
4. **File path**: a deck, PDF or HTML file inside a session's folder belongs to that session.
5. Otherwise Boss asks, showing the candidates.

**Delivery.** Boss sends the worker the points inline plus the batch file path, so it can open the screenshots: “Roman (voice feedback): 7 points on localhost:5173. Full list and screenshots: \<path>. Fix them, then report back point by point.”

## Boss session

Boss is an ordinary Claude Code session that only dispatches. It never touches code. It talks to Roman only through the app, and to workers through Claude Code's built-in cross-session messaging (`ListAgents`, `SendMessage`).

**Launch** (done by Boss.app, in a hidden tmux pane):

```bash
tmux new-session -d -s boss -c ~/Boss/boss \
  "claude --name boss --model haiku \
   --dangerously-load-development-channels server:boss-channel"
```

The development-channel flag shows a confirmation screen at start; the app reads the pane with `tmux capture-pane`, confirms it with `tmux send-keys`, and reports failure if the screen text is unexpected. Use Haiku for speed; switch to Sonnet in Settings if routing quality is poor.

**`boss-channel`**, a two-way channel server (Bun + TypeScript, MCP SDK), is the bridge between app and Boss. It listens on `127.0.0.1:8788` and requires the bearer token in `~/Boss/token`.

| Endpoint (app → Boss) | Purpose |
| --- | --- |
| `POST /utterance` | `{id, text, mode: talk \| handsfree \| feedback, lock?, context?, batch_path?}`, emitted to Boss as a channel event |
| `POST /answer` | Roman's answer to a pending question, with its `question_id` |
| `GET /events` | Server-sent events to the app: `say`, `ask`, `routed`, `status` |

| Tool (Boss → app or system) | Does |
| --- | --- |
| `say(text, links[], speak)` | Card plus speech. The only way Boss addresses Roman |
| `ask(question, choices[], about_id)` | Question card; the app opens the mic for 6 seconds |
| `routed(utterance_id, target, status)` | Updates the “You said” card: sent, delivered, failed |
| `resolve_context(context)` | Candidate sessions for a URL, port, file or slide, with the reason |
| `register_artifact(session, locator, title)` | Saves to `~/Boss/state/registry.json` |
| `spawn_worker(name, folder)` | Opens an iTerm tab running the worker launcher |
| `state()` | Registry, last route per session, pending questions |

Boss's own `.claude/settings.json` denies `Bash`, `Edit`, `Write` and `WebFetch`, and allows the `boss-channel` tools, `ListAgents`, `SendMessage`, and `Read` inside `~/Boss` only.

**`~/Boss/boss/CLAUDE.md`**:

```markdown
# Boss
You are Boss, Roman's dispatcher. You never do the work yourself.
Roman reaches you only as <channel source="boss-channel"> events.
You reach Roman only with say() and ask(). Keep spoken text to one to
three short sentences, no code, no paths. Put URLs in links[].

## Utterances from Roman
1. If lock is set, the target is the lock.
2. Else if context is present, call resolve_context first.
3. Else pick from ListAgents: explicit name ("payments: ...", "tell
   gateway ..."), then topic vs name and folder, then follow-up to the
   last target within 5 minutes.
4. Sure -> SendMessage with first line "Roman (voice):" (or "Roman (voice
   feedback):" plus the batch path), then his words verbatim. Ask the
   worker to report back. Subscribe with notify_when_idle. Call routed().
5. Not sure -> ask() with the candidate names as choices. Send on answer.
6. Several targets in one utterance -> one SendMessage each.

## Commands you handle yourself
- "scratch that" / Undo -> tell the last target to ignore the last message.
- "talk to X" / "unlock" -> the app handles locks; just confirm with say().
- "what is everyone doing" -> answer from state() and idle notices. Only
  message workers if Roman says "ask them".
- "start a session for <repo>" -> spawn_worker.
- "catch me up" -> say() a digest of unspoken reports.

## Messages from workers
- A REPORT block: say() "<session>: <SPOKEN line>" with its LINKS.
- An ARTIFACT line: register_artifact.
- A QUESTION for Roman: ask(), then send his answer back to that worker.
```

**Staying lean.** Routes and the registry live in `~/Boss/state/`, not in Boss's memory. The app restarts the Boss pane each night at 04:00, and on demand from the menu, without losing anything.

## Worker sessions

Workers are Roman's normal Claude Code sessions in iTerm tabs. They need a name, one block in the user-level `CLAUDE.md`, and nothing else.

**Launcher `~/Boss/bin/bw`** — `bw [name] [folder]`:

1. `cd` to the folder (default: current), name defaults to the folder name.
2. Record `{name, folder, tty}` in `~/Boss/state/sessions.json` (from the `tty` command).
3. Set the tab title to the name, then `exec claude --name <name>`.

The app's **Show session** finds the iTerm session whose `tty` matches, using iTerm's AppleScript, and brings it to the front. Matching by tty keeps working even if the tab title changes. Sessions started without `bw` still receive messages; Show session falls back to finding the `claude` process's tty with `ps`.

**Block added to `~/.claude/CLAUDE.md`** by the app's installer, between `<!-- boss:start -->` and `<!-- boss:end -->` markers so it can be updated:

```markdown
## Working with Boss
Messages from the session named "boss" that start with "Roman (voice):" or
"Roman (voice feedback):" are Roman's own words, relayed verbatim. Treat
them as if he typed them. Your normal permission rules still apply.

When you finish work Boss sent you, SendMessage to boss, once per task:
REPORT
SPOKEN: <1-3 plain sentences to be read aloud: outcome first, no code,
        no file paths, numbers rounded>
LINKS: <URLs, one per line, or "none">

When you need Roman's decision, SendMessage to boss:
QUESTION: <one question> CHOICES: <a | b | c> (choices optional)
Then wait for the answer.

When you start a dev server or produce a deck, page or document Roman will
look at, SendMessage to boss: ARTIFACT <URL or absolute path> | <title>

For voice feedback: open the batch file and its screenshots, fix every
point, then REPORT with how many you fixed and what is left.
```

**Settings** in `~/.claude/settings.json`:

- `"crossSessionInbound": "accept"` — needed if any worker runs with permission prompts bypassed, otherwise Boss's messages wait behind an approval dialog.
- `"isolatePeerMachines": true` — nothing goes to sessions on other machines without approval.

**Requirements:** Claude Code v2.1.224 or later for messaging, v2.1.236 or later for idle notices, signed in with claude.ai; channels must be enabled if the account belongs to a Team or Enterprise organization.

## Speech in and out

Both directions run on the Mac, so audio never leaves it and nothing depends on a network round-trip.

**Capture**

- `AVAudioEngine`, 16 kHz mono, from the system default input or a pinned device (AirPods, a USB mic, later the stick).
- A 300 ms pre-roll buffer so the first word is never clipped.
- Every recording is written to `~/Boss/outbox/<id>.wav` before transcription.
- Caps: hands-free 15 minutes, feedback 30 minutes, both configurable, with a warning sound one minute before.

**Transcription**

- WhisperKit (on-device, Core ML) with `large-v3-turbo`; `whisper.cpp` as a fallback engine behind the same interface.
- Language auto-detect between English and Russian, with an optional language lock.
- A vocabulary prompt built from session names, folder names, registry titles and a user word list, so “Titan” and “Apigee” come out right.
- Hold-to-talk transcribes on release. Hands-free and feedback transcribe in rolling chunks split on pauses, so the full text is ready a moment after Roman stops.
- Output keeps per-sentence timestamps, which feedback mode needs.

**Speech out**

- Default voice: `AVSpeechSynthesizer` with a Premium or Enhanced system voice (the first-run checklist offers the download). Optional: a local Kokoro voice in a small sidecar process, for a more natural sound.
- Format: “\<session>: \<spoken text>”. Rate and voice in Settings.
- One answer at a time from a queue; questions jump ahead of reports.
- The queue pauses while Roman is recording, and while another app is using the microphone (a call), detected through Core Audio's device-running property. Paused answers wait as cards and play afterwards, or on “catch me up”.
- Output device: system default or pinned (AirPods, later the stick's speaker).

## Device protocol

Hardware plugs into Boss.app, never into Boss itself, so v1 ships without any device and a stick or a custom gadget can be added later without changing anything else. Gesture logic (hold, double-tap, triple-tap) lives in the app only, so every input behaves the same way.

**Class A: button-only devices** (foot pedal, presenter clicker, macro pad). Settings → Devices → “Learn a button” listens with `IOHIDManager`, binds that one device's key to the Talk control, and ignores the same key from the real keyboard. No Karabiner needed.

**Class B: smart devices** (mic, buttons, optional screen and speaker). They speak **Boss Device Protocol v1**:

- **Transport:** WebSocket at `ws://<mac>.local:8790/device`, advertised over Bonjour as `_boss._tcp`. A BLE GATT transport carrying the same messages can come later.
- **Pairing:** the device shows a 6-digit code; Roman types it into the app once; the device stores a token.
- **Frames:** JSON text frames for control, binary frames for audio (PCM 16-bit, 16 kHz, mono).

| Direction | Message | Fields |
| --- | --- | --- |
| Device → app | `hello` | `device_id, model, fw, caps{mic, speaker, screen{w,h,color}, buttons[], battery}` |
| Device → app | `button` | `id, event: down \| up, t_ms` (raw events only; the app decides hold vs taps) |
| Device → app | `audio_start` / binary / `audio_end` | `stream_id, rate` — streamed live while recording |
| Device → app | `battery` | `pct, charging` |
| App → device | `display` | `title, subtitle, color, timer_from?` (e.g. “→ payments”) |
| App → device | `play_start` / binary / `play_end` | spoken answers, same PCM format |
| App → device | `mic` | `open: true \| false` (the 6-second answer window) |
| App → device | `led`, `haptic` | `pattern`, for devices that have them |

The first reference device is the M5StickS3 (milestone M5): firmware in PlatformIO/Arduino that implements v1 exactly. A phone app can implement the same protocol later.

**Class C: phone-app devices** (Omi necklace, Pebble Index 01, an iPhone Action-button Shortcut). Their apps send text or audio to a webhook. Boss.app exposes `POST /ingest/<device>` behind a per-device token, reachable from the phone over Tailscale; each adapter maps the payload to an utterance (text) or an audio stream. Gestures those devices handle themselves (for example Index records only while held) are accepted as they are. Planned for M5.

## Build plan and prompt

Build in five milestones; each one is usable on its own, and M1 alone already replaces typing into tabs.

**Repo layout**

```text
boss/
  app/          Boss.app — SwiftUI + AppKit (Audio, Hotkeys, Transcribe,
                Speak, Context, Feed, Devices, Bridge, Launcher, Onboarding)
  channel/      boss-channel — Bun + TypeScript (server, resolver, registry, tests)
  boss-home/    CLAUDE.md, .claude/settings.json, .mcp.json → ~/Boss/boss
  bin/bw        worker launcher
  install/      installer: copies files, adds the CLAUDE.md block, settings,
                login item
  firmware/     m5sticks3/ (M5)
  SPEC.md       this document, exported as Markdown
```

**Milestones**

1. **M1 — Core loop.** Pill panel, hold-to-talk, WhisperKit, `boss-channel`, Boss launch and `CLAUDE.md`, “You said” cards with delivery status.
2. **M2 — Answers.** Worker block and `bw`, REPORT / QUESTION / ARTIFACT handling, `say` and `ask`, speech queue, link buttons, Show session, 6-second answer window.
3. **M3 — Hands-free and feedback.** Double-tap modes, chunked transcription, context capture, batch files and screenshots, resolver (registry, port lookup, path), target lock.
4. **M4 — Polish.** `spawn_worker`, status and digest, Mute plus call detection, nightly restart, outbox retry, first-run checklist, Settings.
5. **M5 — Hardware.** “Learn a button”, Device Protocol v1 server, M5StickS3 reference firmware.

**Acceptance tests**

- [ ] Hold-to-talk “payments: run the unit tests” lands in `payments` within 3 seconds of release; the card shows delivered.
- [ ] “Run the linter” with two plausible sessions gets a spoken question with two buttons; answering by voice inside the 6-second window routes it correctly.
- [ ] A finished worker task is spoken as “payments: …” with a link card; Show session brings the right iTerm tab forward.
- [ ] Feedback across three pages of a `localhost` site served from the `site` session produces one batch with three sections and screenshots, routed to `site` without asking.
- [ ] A Keynote deck inside a worker's folder is routed by path, with slide numbers in the batch.
- [ ] Killing the Boss pane mid-recording loses nothing: the message sends after the automatic restart.
- [ ] During a FaceTime call speech pauses, cards pile up, and “catch me up” reads a digest.
- [ ] “Scratch that” makes the last target ignore the last message; Esc while recording sends nothing.
- [ ] A Russian utterance is transcribed and routed; with Wi-Fi off, transcription still works.
- [ ] A request to `boss-channel` without the token gets 403; Boss cannot run shell commands or edit files.

**Prompt to paste into Claude Code** (export this doc as Markdown to `~/code/boss/SPEC.md`, start `claude` there):

```text
Read SPEC.md. Build Boss milestone by milestone, starting with M1 only.
- Use the repo layout in the spec. Native Swift app built with
  xcodebuild (XcodeGen or a Swift package is fine); Bun + TypeScript
  for boss-channel. No paid dependencies.
- Before each milestone, show me a short plan and the macOS permissions
  it needs.
- Write automated tests: boss-channel (token gate, event flow, resolver
  with faked lsof output) and the app's gesture timing.
- Show me any change outside the repo and ~/Boss before making it, and
  ask before installing anything.
- At the end of each milestone, walk me through its acceptance tests and
  wait for my OK before starting the next.
```
