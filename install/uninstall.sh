#!/bin/sh
# Boss uninstaller: stops everything, puts ~/.claude/CLAUDE.md and settings.json back.
#   sh install/uninstall.sh [--purge]    (--purge also deletes ~/Boss: models, outbox, logs, token)
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BOSS_HOME="${BOSS_HOME:-$HOME/Boss}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
LAUNCH_DIR="${LAUNCH_DIR:-$HOME/Library/LaunchAgents}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"

for l in com.roman.boss.app com.roman.boss.up com.roman.boss.tts com.roman.boss.whisper; do
  launchctl bootout "gui/$(id -u)/$l" 2>/dev/null || true
  rm -f "$LAUNCH_DIR/$l.plist"
done
BOSS_HOME="$BOSS_HOME" "$NODE" "$REPO/bin/boss-up.mjs" stop >/dev/null 2>&1 || true
"$NODE" "$REPO/install/edit-config.mjs" revert "$CLAUDE_DIR" "$BOSS_HOME"
rm -rf "$APP_DIR/Boss.app"
if [ "${1:-}" = "--purge" ]; then
  KC="$BOSS_HOME/signing/boss-signing.keychain-db"
  [ -f "$KC" ] && security delete-keychain "$KC" 2>/dev/null || true
  rm -rf "$BOSS_HOME"
fi
echo "boss-uninstall: done"
