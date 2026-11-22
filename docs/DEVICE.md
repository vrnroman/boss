# Boss Device — Market Check and Hardware Path

Nov 22, 2026 · @Roman V

## Does it exist?

Not as one product. Both halves exist and are moving fast: desk keypads built for coding agents, and wearable press-to-talk buttons. Nothing found combines a device you carry and talk into, feedback on where your words went, and routing across many agent sessions.

| Product | What it is | Price | Closest to the idea in | Missing |
| --- | --- | --- | --- | --- |
| [OpenAI Codex Micro](https://www.axios.com/2026/07/15/openai-keyboard-codex-agents) | Desk keypad for Codex agents, with Work Louder | Limited edition | Push-to-talk key, shows agent status | Desk-bound; Codex only |
| [Logitech MX Keypad](https://www.yankodesign.com/2026/09/08/the-100-keypad-that-puts-each-ai-coding-tool-behind-its-own-button/) | Keys for Copilot, Claude Code, VS Code, IntelliJ | $99.99 | Built for AI-coding workflows | No voice; not portable |
| [VibeKeys Max](https://www.hackster.io/wushize03/building-a-wireless-control-surface-for-claude-code-codex-987634) | Open-source wireless console | Maker project | Voice input and a live status screen for Claude Code and Codex | Desk console; approve/reject, not routing |
| [Vibe Desktop Buddy](https://claude-desktop-buddy.com/) | Bluetooth desk pet for the Claude desktop app | $110 pre-order | Physical approve/deny | No voice input |
| [Pebble Index 01](https://techcrunch.com/2025/12/09/pebbles-founder-introduces-a-75-ai-smart-ring-for-recording-brief-notes-with-a-press-of-a-button) | Ring: one button, mic, Bluetooth | $75 | Press-and-talk, open-source app, webhook | No screen or speaker; built for notes |
| [Sandbar Stream Ring](https://techcrunch.com/2025/11/05/former-meta-employees-launch-a-ring-to-take-voice-notes-and-control-music/) | Ring for voice notes and an AI chatbot | $249–$299 + $10/month | Whisper-level capture | Closed; personal-assistant focus |
| [Button Computer](https://www.startuphub.ai/ai-news/claudes-corner/2026/claudes-corner-button-computer-yc-w2026) (YC W2026) | Clip-on press-to-talk AI device | $179 | The form factor | General assistant, not agents |
| [Omi](https://omi.me) | Open-source AI necklace | $69.99 | Programmable button, speaker, webhooks | Conversation-memory focus |

**Verdict:** the hardware alone is not new or defensible — OpenAI and Logitech already sell agent-control hardware, and voice rings ship at $75. The open space is the software: routing between sessions, narrated feedback with screen context, spoken reports. The device is the hook; Boss is the product.

## The opportunity

The buyer is the developer or tech lead running several coding agents at once. In 2026 that audience became real enough for OpenAI and Logitech to ship hardware for it, and makers are building Bluetooth companions for Claude Code.

**Positioning:** a remote control for your agents that goes where you go. Talk from the sofa or while walking; hear when work is done; give feedback on what an agent built just by looking at it and speaking. Multi-vendor (Claude Code first, Codex next) widens the market and lowers dependence on one platform.

**Risks to weigh before spending on hardware:**

- **Platform risk.** Claude Code already has voice dictation, cross-session messaging and an agent view. Anthropic or OpenAI could ship voice routing natively; the value then moves to the device and to working across vendors.
- **“My phone already does this.”** iPhones and watches have action buttons and mics, and AirPods have both. The device must be clearly faster and nicer than those.
- **Small niche, hard business.** Hardware margins, inventory, returns and support, for a narrow group of power users at first.
- **Regulated offices.** Many banks restrict recording devices. Local-only processing, a physical mic-off switch and a live-mic light are requirements, not features.
- **Your employment terms.** Check SGX's outside-activity and IP clauses before starting a company or publishing code built on work time or equipment.

**Recommendation:** software first. Build Boss, use it daily with off-the-shelf devices, put it in the hands of 20–50 other heavy agent users, and commit to custom hardware only if they keep using it after a month.

## Path A: better-looking devices to use now

Two consumer devices look far better than a dev board and are open enough to feed Boss today. Both talk to a phone app, which forwards to a webhook, so Boss.app needs a webhook input that the phone can reach (for example over Tailscale).

| Device | Look and feel | Talks back | How it reaches Boss | Catch | Price |
| --- | --- | --- | --- | --- | --- |
| [Omi necklace](https://omi.me) | Coin-sized pendant | Yes: speaker | Open-source app; [real-time transcript and raw-audio webhooks](https://docs.omi.me/doc/developer/apps/Integrations) | Built around always-on capture; test that press-to-talk alone works for you | $69.99 |
| [Pebble Index 01](https://ndocs.repebble.com/index-mcp-instructions) | Stainless-steel ring, thumb button | LED only | Open-source Pebble app, one webhook per ring | Records only while held, so no hands-free mode; non-rechargeable battery, replaced by mail | $75 |
| [M5StickS3](https://docs.m5stack.com/en/core/StickS3) | Plain dev-kit stick | Yes: speaker and screen | Boss Device Protocol directly over Wi-Fi | Looks like a dev board | about £20 |
| iPhone or Watch Action button | Already in your pocket | Yes | A Shortcut posts dictated text to the webhook | Phone has to be in hand | Free |

**Pick:** Omi if you want answers spoken from the device itself; Index 01 if you want the most discreet trigger and are happy to hear answers through AirPods. Either one is also a useful competitor teardown for Path B.

## Path B: what our own device would be

A pocketable stick or clip that does three things well: hear a whisper, show where it went, and say what came back. It talks straight to the Mac, with no phone in between. All figures below are design targets, not quotes.

| Area | MVP target | Why |
| --- | --- | --- |
| Buttons | One large main button (hold, double, triple), one side button | The whole Boss grammar, usable without looking |
| Microphone | Two MEMS mics with beamforming and noise suppression | Quiet speech at arm's length, open-plan offices |
| Status | Small round display, or an LED ring if cost forces it | “→ payments”, timer, waiting-on-you |
| Sound | Small speaker plus a haptic motor | Spoken answers; a buzz to confirm without sound |
| Radio | Bluetooth LE to the Mac, Wi-Fi for range at home | No phone in the loop |
| Chip | ESP32-S3 (BLE + Wi-Fi, audio front end) for v1; nRF5340 if battery life wins over Wi-Fi | Mature, cheap, huge maker ecosystem |
| Battery | A full workday of push-to-talk use, USB-C, magnetic clip | Charge once a night |
| Privacy | Physical mic-off switch, light whenever the mic is live, no cloud | Needed for banks and regulated offices |
| Firmware | Boss Device Protocol v1, signed over-the-air updates | Same protocol as the reference stick |

**Start from what exists.** The open-source [xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) firmware (MIT licence) already runs voice devices on 70+ ESP32 boards, many of them made by Shenzhen companies. Choosing one of those board designs as the base, and swapping its cloud link for the Boss protocol, cuts design time and gives a factory something it has already built.

## Path B: building it with a Shenzhen partner

Spend on hardware in steps, each one unlocked by a gate, so a weak signal stops the spending early.

&#91;embedded content: Path to a manufactured device · 5 phases, 4 gates\]

**Contract points that protect you with an ODM:**

- You own the firmware, the Boss protocol, the industrial design and the tooling (the moulds), in writing.
- The ODM hands over PCB design files and the bill of materials at each build, not only at the end.
- Pay in stages tied to EVT, DVT and PVT sign-off.
- Use an independent inspection firm, or a sourcing agent you trust, for each production batch.
- Visit the factory before tooling is cut; Shenzhen is a short flight from Singapore.

## Next steps

- [ ] Check SGX's outside-activity and IP terms before building anything you might sell.
- [ ] Build Boss M1–M3 from the build spec and use it daily for two weeks.
- [ ] Order an Omi and a Pebble Index 01; connect them through the webhook input and compare them with the M5StickS3.
- [ ] Write a one-page pitch and recruit 20 heavy Claude Code or Codex users to try Boss.
- [ ] Only if they keep using it: commission a works-like prototype on an existing xiaozhi-class ESP32 board.

## Sources

- [Axios: Codex Micro is a physical keyboard for AI agents](https://www.axios.com/2026/07/15/openai-keyboard-codex-agents)
- [Yanko Design: Logitech MX Keypad](https://www.yankodesign.com/2026/09/08/the-100-keypad-that-puts-each-ai-coding-tool-behind-its-own-button/)
- [Hackster: VibeKeys Max](https://www.hackster.io/wushize03/building-a-wireless-control-surface-for-claude-code-codex-987634)
- [Vibe Desktop Buddy](https://claude-desktop-buddy.com/)
- [TechCrunch: Pebble Index 01](https://techcrunch.com/2025/12/09/pebbles-founder-introduces-a-75-ai-smart-ring-for-recording-brief-notes-with-a-press-of-a-button) · [Index developer page](https://ndocs.repebble.com/index-mcp-instructions)
- [TechCrunch: Sandbar Stream Ring](https://techcrunch.com/2025/11/05/former-meta-employees-launch-a-ring-to-take-voice-notes-and-control-music/)
- [StartupHub: Button Computer](https://www.startuphub.ai/ai-news/claudes-corner/2026/claudes-corner-button-computer-yc-w2026)
- [Omi](https://omi.me) · [Omi integration docs](https://docs.omi.me/doc/developer/apps/Integrations)
- [M5Stack StickS3 docs](https://docs.m5stack.com/en/core/StickS3)
- [xiaozhi-esp32 on GitHub](https://github.com/78/xiaozhi-esp32)
