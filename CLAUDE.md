# Boss repo: notes for Claude

## Installing Boss on this Mac (when the user asks to install or set up Boss)
Follow INSTALL.md exactly:
1. `sh install/install.sh` (no sudo, ever; it installs missing Homebrew tools itself).
2. `sh install/doctor.sh` and fix whatever it lists as FIX, re-running the installer when it says so.
3. Tell the user the two manual steps: Allow the microphone on the first Talk, and (optional, home)
   Input Monitoring for Right Option. Office Macs: Left Option + Space needs no permission.
If doctor reports the Boss session is not running and the screen mentions channels, explain that a
Team/Enterprise Claude org must enable Channels; do not try to work around it.
Never run anything with sudo, never edit system files, never delete ~/Boss or ~/.claude content.

## Working on the code
- Tests: `sh scripts/test.sh` (fast gate); `sh scripts/test.sh --e2e` drives real Claude Code
  sessions and plays speech through the speakers (ask before running it if someone may be asleep).
- Tests must never touch the real Boss: own BOSS_HOME, tmux socket, port; Telegram never from tests.
- Spec: docs/SPEC.md. Interfaces: docs/CONTRACT.md.
