# Boss — macOS Onboarding and Security Review

**Document date:** 2026-11-26  
**Scope:** The current Phase 1 implementation in this repository.  
**Audience:** Desktop engineering, endpoint security, privacy, and application onboarding reviewers.

> This document describes the implementation, not every idea in `docs/SPEC.md`. In particular, the
> current build does **not** implement the specification's future screen/context capture, browser or
> Office-app automation, Accessibility API, Bonjour, or external-device features.

## Purpose and scope

Boss is a single-user macOS voice dispatcher for existing Claude Code sessions. It lets the user speak
an instruction, transcribes it locally, sends the text to a selected Claude Code worker session, and
speaks the worker's report or question back to the user. Boss does not replace Claude Code and does
not perform the worker's coding tasks itself.

The main security properties are:

- Installation is user-scoped and requires no administrator rights.
- Boss's own IPC listeners bind to `127.0.0.1` only.
- Raw microphone recordings and primary speech transcription remain on the Mac.
- Transcribed instructions and selected session context are processed by the existing Claude Code
  service configuration.
- Optional Telegram features can export report/question text and, on explicit request, a synthesized
  audio recap. These features need a separate data-sharing decision.
- The dispatcher Claude session is tool-restricted, but worker sessions retain their normal Claude
  Code permissions.

## How Boss works

1. **Intentional voice input.** The user presses the panel's Talk button, uses Left Option + Space,
   or optionally holds Right Option. Escape cancels an active recording.
2. **Local audio capture.** After microphone permission has been granted, the audio engine remains
   running to maintain a **300 ms in-memory pre-roll**, preventing clipped first words. It does not
   continuously transcribe or continuously write microphone audio to disk. An active utterance is
   currently capped at 180 seconds.
3. **Save before processing.** On completion, Boss writes the utterance as a WAV file plus JSON
   metadata under `~/Boss/outbox/` before transcription. This supports retry after a failure.
4. **Local transcription.** `whisper-server` transcribes the WAV on `127.0.0.1:8791`. An optional
   live target preview uses Apple Speech Recognition with `requiresOnDeviceRecognition = true`.
5. **Local dispatch.** Boss.app sends the transcript and live Claude session metadata over the
   token-protected loopback channel on `127.0.0.1:8788`. A dedicated Claude Code dispatcher chooses
   a worker, asks for clarification when needed, and relays the user's words through Claude Code's
   cross-session messaging.
6. **Worker execution.** The selected worker treats the relayed text as a user instruction. Its
   existing tool and permission rules still apply. Boss itself does not execute the requested work.
7. **Report and speech.** Workers return reports/questions to the dispatcher. The channel forwards
   them to Boss.app, which displays cards and uses local Kokoro TTS or macOS system voices.
8. **Session chat summaries.** When the session chat view is used, Boss can read recent local Claude
   transcript entries and invoke a separate tool-less `claude -p` summarizer. This sends the selected
   transcript excerpts to the configured Claude service and caches the resulting digest locally.

```text
Microphone
   │ raw audio stays on the Mac
   ▼
Boss.app ──► local outbox WAV + JSON ──► local whisper-server
   │
   │ transcript + routing metadata over authenticated loopback HTTP
   ▼
boss-channel ──► restricted Boss Claude Code dispatcher
   │                    │ text sent through the configured Claude service
   │                    ▼
   │             Claude Code cross-session messaging
   │                    ▼
   │              existing worker sessions
   ▼
Local display + local text-to-speech

Optional, separately controlled:
reports/questions ──► Telegram text when the user is away
recent reports/questions ──► synthesized Telegram audio after “radio me”
```

## Components and processes

| Component | Purpose | Execution and IPC |
| --- | --- | --- |
| `Boss.app` | Native SwiftUI/AppKit panel, microphone, hotkeys, outbox, local speech clients, chat view | User LaunchAgent; no Dock icon; normally no inbound listener |
| `boss-channel` | Authenticated bridge between the app and the dispatcher | Node 25+, started by Claude Code over stdio; HTTP/SSE on `127.0.0.1:8788` |
| Boss dispatcher | Routes text and relays reports/questions | Claude Code in a dedicated tmux session; no general shell/file/web tools |
| `boss-up` | Starts, checks, and restarts the dispatcher | Node supervisor under user launchd; performs a nightly restart |
| `whisper-server` | Local speech-to-text | Homebrew `whisper-cpp`; `127.0.0.1:8791` |
| Kokoro sidecar | Optional local English text-to-speech | Python virtual environment; `127.0.0.1:8792`; macOS voices are the fallback |
| Worker sessions | Perform the actual Claude Code tasks | Existing user sessions; normal Claude Code permissions |
| Chat summarizer | Summarizes recent session-chat entries | Short-lived `claude -p`; no tools, no MCP, no saved session |

## macOS permissions

| Permission | Requirement | Why Boss uses it | Behavior if denied / reviewer notes |
| --- | --- | --- | --- |
| **Microphone** | Required for voice operation | Captures Talk utterances and the 300 ms pre-roll | Voice capture cannot work without it. After approval, the audio engine runs while Boss.app is running; only the rolling pre-roll is kept outside an active recording. |
| **Speech Recognition** | Optional; live preview is enabled by default | Shows a partial, on-device transcript to preview the likely target session | Requested on the first recording with live preview enabled. Denying it disables only the preview. Recognition is explicitly constrained to on-device recognition and is skipped if unavailable. |
| **Input Monitoring** | Optional | A listen-only `CGEventTap` detects Right Option and Escape for the alternative push-to-talk gesture | Boss attempts to register this hotkey at launch and may prompt. Deny it to use Left Option + Space or the Talk button; neither requires Input Monitoring or Accessibility. |
| **Automation / Apple Events for iTerm2** | Optional | “Show session” selects the matching iTerm tab, or activates iTerm | Requested only when the AppleScript path is used. Dispatch and voice operation do not depend on it. |

**No other sensitive macOS permissions are used by the current implementation.** Specifically, it
does not request Accessibility, Screen Recording, Camera, Location, Contacts, Calendars, Photos,
Full Disk Access, Bluetooth, or Local Network permission. It installs no system extension, kernel
extension, privileged helper, or root LaunchDaemon.

### Signing and entitlements

- The app declares microphone, speech-recognition, and Apple Events usage strings.
- It is built with the hardened runtime and audio-input/automation entitlements. It is **not** built
  with the App Sandbox entitlement.
- The basic build uses ad-hoc signing. The normal installer creates a separate, user-owned,
  self-signed local code-signing keychain so permission grants remain stable across rebuilds.
- The app is **not Apple Developer ID signed or notarized** in the current installer. Desktop
  engineering should decide whether enterprise signing/notarization is required for approval.

## Data and network flows

### Runtime external services

| Destination | When | Data sent | Notes |
| --- | --- | --- | --- |
| **Claude service configured for Claude Code** | Dispatch, worker operation, and optional chat summarization | Transcribed instructions; worker prompts/replies; session names, working-folder context and status; up to two recent user-prompt excerpts per candidate session for routing; selected recent chat content for digests | Uses the existing signed-in Claude Code configuration and organization settings. Boss adds no separate Anthropic credential or endpoint. Raw microphone WAV files are not sent. Exact hosts/proxy behavior should be taken from the approved Claude Code deployment. |
| **`api.telegram.org`** | Optional text fallback, and explicit “radio me” command | Away fallback: report/question text and links. Radio: a generated M4A recap of recent reports/open questions and a caption | Text fallback is enabled by default but only acts when configured and after at least 10 minutes of keyboard/mouse inactivity. Radio runs only on explicit request. Radio audio is synthesized speech, not the original microphone recording. Both features use the user's separately configured Telegram bot/chat credentials. |
| **User-selected links** | When the user opens a report link | Determined by the destination and browser | Boss asks macOS to open the URL; it does not fetch the link itself. |

Boss includes no analytics, advertising, crash-reporting SDK, custom telemetry service, or automatic
update service.

### Install/update-time downloads

These downloads do not intentionally include user content:

| Source | Content |
| --- | --- |
| Homebrew | `node`, `tmux`, `whisper-cpp`, `ffmpeg`, and their dependencies |
| `huggingface.co` | Whisper `large-v3-turbo` model (approximately 1.6 GB) and Silero VAD model |
| `github.com` | Kokoro ONNX model and voice data; initial source clone if obtained from GitHub |
| Python package indexes used by `pip` | Pinned Kokoro sidecar dependencies from `tts/requirements.lock` |

An office network can pre-stage the Whisper model to skip its Hugging Face download. Equivalent
controlled hosting/pre-staging decisions may also be needed for the other dependencies and models.

### Loopback listeners

| Port | Service | Controls |
| --- | --- | --- |
| `127.0.0.1:8788` | Boss channel HTTP + SSE | Required bearer token; rejects browser `Origin` requests and unexpected `Host` headers; JSON body limit 64 KB |
| `127.0.0.1:8789` | Debug control | **Off by default**; when explicitly enabled, uses the same bearer token and loopback-only binding |
| `127.0.0.1:8791` | Whisper transcription | Loopback-only; no application bearer token |
| `127.0.0.1:8792` | Kokoro TTS | Loopback-only; rejects browser `Origin` requests and unexpected `Host` headers; no application bearer token |

Loopback HTTP is not TLS-encrypted because it does not leave the machine. These listeners are not
intended to be reachable from other hosts. The threat boundary still includes other processes running
as the same macOS user: such a process may be able to read the user's token or call the unauthenticated
loopback speech services.

## Local files, credentials, and subprocesses

### Files and configuration

| Location | Use |
| --- | --- |
| `~/Boss/` | Main runtime directory, created mode `700`; models, app support, state, logs, outbox, digests, radio audio, backups, and signing material |
| `~/Boss/token` | Random 32-byte hex bearer token, mode `600` |
| `~/Boss/outbox/` | Raw utterance WAV files and transcript/status JSON |
| `~/Boss/state/` | Channel state, recent routes/utterances, questions, reports, append-only event history, trust ledger, and cached chat digests |
| `~/Boss/radio/` | Generated Telegram-radio audio files |
| `~/Boss/logs/` | Supervisor, channel, app, Telegram, and guard logs |
| `~/Boss/signing/` | Separate local signing keychain and its generated password file |
| `~/Applications/Boss.app` | Installed app bundle |
| `~/Library/LaunchAgents/com.roman.boss.*.plist` | User agents for the app, supervisor, Whisper, and optional Kokoro TTS |
| `~/.claude/CLAUDE.md` | Reversible Boss worker-instruction block between marked comments |
| `~/.claude/settings.json` | Sets `crossSessionInbound` to `accept`; original values/files are backed up before the first change |
| macOS `UserDefaults` | App preferences such as voice, language, live preview, Telegram fallback, and debug control |

Boss also **reads**:

- `~/.claude/sessions/*.json` to enumerate live sessions;
- recent entries in `~/.claude/projects/.../*.jsonl` for routing context and the chat view;
- process/TTY information to locate sessions;
- the separately configured Telegram environment/script only when the corresponding Telegram feature
  is used.

The installer does not read or replace Claude's existing account credentials. Boss invokes the
already signed-in `claude` executable.

### Retention

- Sent and unsent outbox WAV/JSON files currently have **no automatic post-delivery cleanup** in the
  reviewed source.
- `~/Boss/state/events.jsonl` is append-only on disk. Although replay memory is bounded, the file
  itself is not automatically rotated by the current implementation.
- Reports, questions, digests, generated radio files, and logs can also persist under `~/Boss/`.
- Uninstall without `--purge` deliberately preserves this directory. `sh install/uninstall.sh --purge`
  deletes it, including recordings, transcripts, logs, models, token, and local signing keychain.

A retention/deletion policy should therefore be part of office approval, especially if voice commands
or reports may contain confidential project information.

### Subprocesses

Boss starts or invokes existing local executables including `node`, `tmux`, `claude`,
`whisper-server`, Python, `ffmpeg`/`ffprobe`, `ps`, macOS `say`, and the optional Telegram script.
The installer also uses standard `codesign`, `security`, and `launchctl` tools without sudo.

## Third-party software and services

- **Apple platforms:** macOS 14+ on Apple Silicon; Swift/Command Line Tools; AVFoundation, Speech,
  AppKit, CoreGraphics, and Network frameworks.
- **Claude Code:** version 2.1.236 or newer, already installed and signed in. Team/Enterprise accounts
  may require an organization owner to enable Channels.
- **Node:** 25 or newer. The channel has zero runtime npm dependencies; TypeScript and Node types are
  development dependencies.
- **Swift:** no third-party Swift Package dependencies.
- **Python:** Kokoro sidecar packages are pinned in `tts/requirements.lock`.
- **Homebrew tools:** `node`, `tmux`, `whisper-cpp`, and `ffmpeg`.
- **Models:** Whisper large-v3-turbo, Silero VAD, Kokoro ONNX, and Kokoro voice data.
- **Optional integrations:** iTerm2 for “Show session” and a user-provided Telegram bot/script.

No Docker image, privileged daemon, or bundled browser is used.

## Security boundaries and user controls

- The dispatcher's settings allow only its channel tools, `ListAgents`, and `SendMessage`; shell,
  file read/write/edit, web, agent, skill, and workflow tools are denied.
- A `PreToolUse` guard enforces the dispatcher's session allow-list. The current default is
  `BOSS_ALLOW=*`, meaning every other eligible local Claude session; deployments can restrict it.
- Worker sessions are **not** sandboxed by Boss. Relayed voice text is treated like a typed user
  instruction, and the worker's normal permissions apply.
- Explicitly addressed/locked routes send immediately. Inferred routes normally provide a 2.5-second
  cancellation window; frequently successful routes can graduate to immediate dispatch. Escape
  cancels recording, and Undo/“scratch that” supports correction after delivery.
- The channel authenticates requests and uses idempotent utterance IDs for safe retries.
- Debug control is disabled by default.
- “Telegram when away” can be toggled in the app. “Radio me” is a separate, explicit action. For an
  office pilot, Telegram export should be disabled unless explicitly approved.
- The user can mute speech, quit the app, unload its user LaunchAgents, and run the uninstaller.

## Installation and removal

Installation is performed with:

```sh
sh install/install.sh
sh install/doctor.sh
```

It installs missing user-level Homebrew dependencies, downloads models, builds/signs the app, writes
user LaunchAgents, updates the reversible Claude configuration, and starts the components. No sudo or
administrator password is used. Re-running the installer is the update/redeploy path.

Removal is:

```sh
sh install/uninstall.sh
```

This stops the Boss components, removes the LaunchAgents and app bundle, stops the dispatcher tmux
session, and restores/removes Boss's Claude configuration edits. It does not remove Homebrew tools,
the source checkout, or Claude Code's pre-existing session transcripts.

To remove all Boss runtime data as well:

```sh
sh install/uninstall.sh --purge
```

## Approval checklist

- [ ] Confirm that the organization's approved Claude Code account, service endpoints, and data terms
      cover voice-transcribed instructions, routing context, worker replies, and chat-digest excerpts.
- [ ] For Team/Enterprise Claude accounts, confirm that Channels is enabled by an organization owner.
- [ ] Decide whether Telegram text/audio export is prohibited, disabled for the pilot, or explicitly
      approved. Do not treat local-only speech processing as meaning that all features are local-only.
- [ ] Set an approved retention/deletion policy for outbox recordings/transcripts, event history,
      reports, digests, radio files, and logs.
- [ ] Decide whether the current self-signed/not-notarized, non-sandboxed app is acceptable, or require
      enterprise/Developer ID signing, notarization, and additional hardening.
- [ ] Approve or pre-stage Homebrew, Python, Hugging Face, and GitHub dependencies and models.
- [ ] Restrict `BOSS_ALLOW` if the dispatcher must not reach every eligible local Claude session.
- [ ] For a minimal-permission pilot, use Left Option + Space, decline Input Monitoring, and enable
      Speech Recognition or iTerm Automation only if their optional features are needed.
- [ ] Keep debug control and Telegram export off unless separately approved.
- [ ] Run `sh scripts/test.sh` and `sh install/doctor.sh`; record the tested commit and dependency
      lockfiles. The fast gate covers unit/integration tests, typechecking, installer round-trip,
      npm audit, and a secret scan. Python `pip-audit` runs when `PIP_AUDIT` is supplied; real
      microphone/E2E tests are a separate opt-in gate.

## Source references

The primary implementation evidence for this document is:

- `app/scripts/build-app.sh:41-79` — bundle metadata, permission descriptions, entitlements, signing.
- `app/Sources/BossApp/AudioCapture.swift:51-56,71-127` — continuous pre-roll engine and microphone permission.
- `app/Sources/BossCore/Audio.swift:3-65` — 300 ms ring buffer and recording limit.
- `app/Sources/BossApp/LivePreview.swift:5-49` — optional, explicitly on-device Speech Recognition.
- `app/Sources/BossApp/Hotkey.swift:6-35` — listen-only Input Monitoring event tap.
- `app/Sources/BossApp/OptionSpaceHotkey.swift:5-8` — permission-free office hotkey.
- `app/Sources/BossApp/Integrations.swift:7-41` — iTerm AppleScript and activation.
- `app/Sources/BossCore/Outbox.swift:46-110` — local WAV/JSON outbox and retry states.
- `app/Sources/BossCore/Transcriber.swift:74-117` — loopback Whisper transcription.
- `app/Sources/BossCore/SessionDigest.swift:176-218,233-279` — digest content and tool-less Claude subprocess.
- `app/Sources/BossCore/Away.swift:3-17,28-97` — inactivity threshold and Telegram text fallback.
- `bin/boss-radio.mjs:1-8,24-43,85-120` — explicit Telegram audio recap.
- `channel/src/channel.ts:131-197` — routing context and recent-prompt excerpts.
- `channel/src/state.ts:73-140` — persisted state and event history.
- `boss-home/.claude/settings.json:1-49` and `boss-home/.claude/guard-send.mjs:4-27` — dispatcher restrictions.
- `install/install.sh:51-177` — files, models, signing, configuration, LaunchAgents, and loopback services.
- `install/edit-config.mjs:43-119` — backup, application, and reversal of Claude configuration edits.
- `install/uninstall.sh:1-24` — standard and purge removal behavior.
- `docs/CONTRACT.md` — current Phase 1 ports, APIs, storage, and behavior.
- `docs/SPEC.md` — product direction; future features are not evidence of current permission use.
