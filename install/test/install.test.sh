#!/bin/sh
# Installer round trip in a sandbox: install (no app, launchd plists written but not loaded) then
# uninstall, and check the Claude config comes back byte for byte.
set -eu
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
export BOSS_HOME="$T/Boss" CLAUDE_DIR="$T/.claude" LAUNCH_DIR="$T/LaunchAgents" APP_DIR="$T/Applications" BOSS_NO_RESTART=1
mkdir -p "$BOSS_HOME/models" "$BOSS_HOME/tts" "$CLAUDE_DIR"
for f in ggml-large-v3-turbo.bin ggml-silero-v5.1.2.bin; do ln -s "$HOME/Boss/models/$f" "$BOSS_HOME/models/$f"; done
for f in kokoro-v1.0.onnx voices-v1.0.bin venv; do ln -s "$HOME/Boss/tts/$f" "$BOSS_HOME/tts/$f"; done
printf '# Mine\n\nKeep this.\n' > "$CLAUDE_DIR/CLAUDE.md"
printf '{\n  "theme": "light"\n}\n' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/CLAUDE.md" "$T/md.orig"; cp "$CLAUDE_DIR/settings.json" "$T/st.orig"

# launchctl must not be called in the sandbox: shadow it.
mkdir -p "$T/shim"; printf '#!/bin/sh\necho "launchctl $*" >> "%s/launchctl.calls"\n[ "$1" = print ] && exit 1\nexit 0\n' "$T" > "$T/shim/launchctl"; chmod +x "$T/shim/launchctl"
PATH="$T/shim:$PATH" sh "$REPO/install/install.sh" --no-app > "$T/install.out"
PATH="$T/shim:$PATH" sh "$REPO/install/install.sh" --no-app > /dev/null   # idempotent second run

fail() { echo "FAIL: $*"; exit 1; }
[ "$(stat -f %Lp "$BOSS_HOME/token")" = 600 ] || fail "token mode"
[ "$(stat -f %Lp "$BOSS_HOME")" = 700 ] || fail "home mode"
grep -q "boss:start" "$CLAUDE_DIR/CLAUDE.md" || fail "block missing"
[ "$(grep -c 'boss:start' "$CLAUDE_DIR/CLAUDE.md")" = 1 ] || fail "block duplicated"
grep -q '"Roman (voice):"' "$CLAUDE_DIR/CLAUDE.md" || fail "block content"
grep -q '"boss"' "$CLAUDE_DIR/CLAUDE.md" || fail "boss name filled in"
grep -q '__BOSS__' "$CLAUDE_DIR/CLAUDE.md" && fail "placeholder left"
grep -q '"crossSessionInbound": "accept"' "$CLAUDE_DIR/settings.json" || fail "setting"
 [ -x "$BOSS_HOME/bin/boss-radio.mjs" ] || fail "radio script"
[ -s "$BOSS_HOME/boss/.claude/guard-send.mjs" ] || fail "send guard"
[ -s "$BOSS_HOME/app/sounds/radio_open.wav" ] || fail "radio sounds"
grep -q "$BOSS_HOME/app/channel/src/server.ts" "$BOSS_HOME/boss/.mcp.json" || fail "mcp path"
grep -q "__" "$BOSS_HOME/boss/.mcp.json" && fail "mcp placeholder left"
for l in whisper tts up; do plutil -lint "$LAUNCH_DIR/com.roman.boss.$l.plist" >/dev/null || fail "plist $l"; done
grep -q "127.0.0.1" "$LAUNCH_DIR/com.roman.boss.whisper.plist" || fail "whisper must bind loopback"
grep -q "bootstrap" "$T/launchctl.calls" || fail "launchctl not called"
# The sandbox's supervisor must not address the real Boss's tmux socket.
BOSS_HOME="$BOSS_HOME" BOSS_PORT=1 node "$BOSS_HOME/bin/boss-up.mjs" status | grep -q '"socket":"boss-' || fail "sandbox shares the real tmux socket"

PATH="$T/shim:$PATH" sh "$REPO/install/uninstall.sh" > /dev/null
cmp -s "$CLAUDE_DIR/CLAUDE.md" "$T/md.orig" || fail "CLAUDE.md not restored byte for byte"
cmp -s "$CLAUDE_DIR/settings.json" "$T/st.orig" || fail "settings.json not restored byte for byte"
[ -f "$LAUNCH_DIR/com.roman.boss.up.plist" ] && fail "plist left behind"
rm -rf "$T"
echo "install round trip: ok"
