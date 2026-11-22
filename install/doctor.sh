#!/bin/sh
# Boss doctor: checks every piece of an install and says what to do about anything wrong.
#   sh install/doctor.sh
BOSS_HOME="${BOSS_HOME:-$HOME/Boss}"
ok=0; bad=0
pass() { printf '  ok    %s\n' "$*"; ok=$((ok+1)); }
warn() { printf '  FIX   %s\n' "$*"; bad=$((bad+1)); }
echo "Boss doctor ($(date '+%Y-%m-%d %H:%M'))"

command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] && pass "Claude Code $(claude --version 2>/dev/null | awk '{print $1}')" || warn "Claude Code not found: install it and sign in (claude)"
[ -s "$BOSS_HOME/token" ] && pass "Boss home $BOSS_HOME" || warn "not installed: run sh install/install.sh"
[ -s "$BOSS_HOME/models/ggml-large-v3-turbo.bin" ] && pass "speech model present" || warn "speech model missing: copy ggml-large-v3-turbo.bin into $BOSS_HOME/models/ (or let install.sh download it)"

for l in whisper tts up app; do
  launchctl print "gui/$(id -u)/com.roman.boss.$l" >/dev/null 2>&1 && pass "background job $l loaded" || { [ "$l" = tts ] && echo "  info  voice sidecar not loaded (macOS voices are used instead)" || warn "background job $l not loaded: run sh install/install.sh"; }
done

curl -s -m 3 127.0.0.1:8791/ -o /dev/null && pass "speech-to-text (whisper) answering" || warn "whisper not answering: tail $BOSS_HOME/logs/com.roman.boss.whisper.err"
H="$(curl -s -m 3 -H "Authorization: Bearer $(cat "$BOSS_HOME/token" 2>/dev/null)" 127.0.0.1:8788/health)"
case "$H" in
  *'"boss_connected":true'*) pass "Boss session connected to its channel" ;;
  *'"ok":true'*) warn "channel up but Boss not connected yet: wait 30 s and run again" ;;
  *)
    warn "Boss session not running. Last supervisor lines:"
    tail -4 "$BOSS_HOME/logs/boss-up.log" 2>/dev/null | sed 's/^/          /'
    if tmux -L boss capture-pane -p -t boss 2>/dev/null | grep -qi "channel"; then
      echo "          If the screen mentions channels being disabled: your Claude organization must enable"
      echo "          Channels (claude.ai admin > Claude Code > Channels), or use a personal Claude plan."
    fi ;;
esac

pgrep -f "Applications/Boss.app/Contents/MacOS/Boss" >/dev/null && pass "Boss.app running (ring in the menu bar)" || warn "Boss.app not running: open ~/Applications/Boss.app"
codesign -d --entitlements - "$HOME/Applications/Boss.app" 2>/dev/null | grep -q audio-input && pass "app may use the microphone (entitlement present)" || warn "app is missing the microphone entitlement: run sh install/install.sh"
grep -q "boss:start" "$HOME/.claude/CLAUDE.md" 2>/dev/null && pass "sessions know how to report back to Boss" || warn "worker block missing from ~/.claude/CLAUDE.md: run sh install/install.sh"

echo
echo "  To finish by hand: click the ring > Talk (or Left Option + Space) and Allow the microphone."
echo "  At home, hold Right Option (needs Input Monitoring in System Settings > Privacy & Security)."
echo
[ "$bad" = 0 ] && echo "All good ($ok checks)." || echo "$bad thing(s) to fix, $ok fine."
[ "$bad" = 0 ]
