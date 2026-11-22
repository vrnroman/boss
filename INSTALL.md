# Installing Boss on a Mac

No admin rights needed. Everything goes into your home folder.

## Needs
- macOS 14+ on Apple Silicon
- Homebrew (https://brew.sh); it brings Apple's Command Line Tools (Swift) with it
- Claude Code, installed and signed in (`claude --version`)

## Install
```sh
git clone https://github.com/vrnroman/boss.git ~/code/boss
cd ~/code/boss
sh install/install.sh
sh install/doctor.sh
```
`install.sh` installs any missing Homebrew tools (node, tmux, whisper-cpp, ffmpeg), downloads the
1.6 GB speech model, builds and signs Boss.app with a local certificate (so macOS keeps its
permissions across updates), starts the background jobs, and adds the worker block to
`~/.claude/CLAUDE.md` (backed up; `uninstall.sh` restores it byte for byte).

Office network blocks Hugging Face? Copy `~/Boss/models/ggml-large-v3-turbo.bin` from another Mac
into the same path first; the installer then skips the download.

## First use (by hand, once)
1. Click the ring in the menu bar, then **Talk** (or press **Left Option + Space**). macOS asks for
   the microphone: **Allow**. No admin password is needed for this.
2. Optional, at home: hold **Right Option** to talk. That needs System Settings > Privacy &
   Security > **Input Monitoring** > Boss on (on office Macs this may need an admin; use
   Left Option + Space instead).

## Talking
- Hold a talk key and release to send, or tap once to start and tap again to send. **Esc** cancels.
- "reelshow, run the tests" sends to a session by name. "What is everyone doing?" gives a status.
  "Rename guard to picket" sets a nickname. "Radio me" sends a spoken recap to Telegram.
- The language switch (**EN | RU**) in the panel picks what you speak.

## When something is wrong
`sh install/doctor.sh` checks every piece and says what to fix. The one thing it cannot fix: if your
Claude account belongs to a Team or Enterprise organization, an owner must enable **Channels**
(claude.ai admin > Claude Code > Channels); without it the Boss session cannot receive your words.

## Update / remove
```sh
cd ~/code/boss && git pull && sh install/install.sh     # update
sh install/uninstall.sh                                  # remove (add --purge to delete ~/Boss too)
```
