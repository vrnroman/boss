#!/bin/sh
# Boss installer. Idempotent: run it again after a change to redeploy.
#   sh install/install.sh [--no-launchd] [--no-app] [--no-config]
# Env: BOSS_HOME (~/Boss), CLAUDE_DIR (~/.claude), LAUNCH_DIR (~/Library/LaunchAgents), APP_DIR (~/Applications)
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BOSS_HOME="${BOSS_HOME:-$HOME/Boss}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
LAUNCH_DIR="${LAUNCH_DIR:-$HOME/Library/LaunchAgents}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"
LAUNCHD=1; APP=1; CONFIG=1
for a in "$@"; do
  case "$a" in
    --no-launchd) LAUNCHD=0 ;;
    --no-app) APP=0 ;;
    --no-config) CONFIG=0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "boss-install: $*"; }
fail() { printf '%s\n' "boss-install: $*" >&2; exit 1; }

# ---------- preflight ----------
"$NODE" -e 'const [a]=process.versions.node.split(".").map(Number); process.exit(a>=25?0:1)' || fail "node 25+ is required (found $("$NODE" -v))"
command -v tmux >/dev/null 2>&1 || [ -x /opt/homebrew/bin/tmux ] || fail "tmux is required (brew install tmux)"
CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
[ -x "$CLAUDE_BIN" ] || fail "Claude Code (claude) is required"
CV="$("$CLAUDE_BIN" --version 2>/dev/null | awk '{print $1}')"
"$NODE" -e 'const v=process.argv[1].split(".").map(Number), m=[2,1,236]; for (let i=0;i<3;i++){ if((v[i]||0)>m[i]) process.exit(0); if((v[i]||0)<m[i]) process.exit(1);} process.exit(0)' "$CV" \
  || fail "Claude Code 2.1.236+ is required for messaging and idle notices (found $CV)"
WHISPER="$(command -v whisper-server || echo /opt/homebrew/bin/whisper-server)"
[ -x "$WHISPER" ] || fail "whisper.cpp is required (brew install whisper-cpp)"

# ---------- ~/Boss ----------
mkdir -p "$BOSS_HOME"/state "$BOSS_HOME"/outbox "$BOSS_HOME"/logs "$BOSS_HOME"/models "$BOSS_HOME"/app "$BOSS_HOME"/bin "$BOSS_HOME"/tts
chmod 700 "$BOSS_HOME"
if [ ! -s "$BOSS_HOME/token" ]; then
  ( umask 077; "$NODE" -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex")+"\n")' > "$BOSS_HOME/token" )
  say "new token in $BOSS_HOME/token"
fi
chmod 600 "$BOSS_HOME/token"

MODEL="$BOSS_HOME/models/ggml-large-v3-turbo.bin"
VAD="$BOSS_HOME/models/ggml-silero-v5.1.2.bin"
if [ ! -s "$MODEL" ]; then
  say "downloading whisper large-v3-turbo (1.6 GB)"
  curl -fsSL -o "$MODEL.part" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin && mv "$MODEL.part" "$MODEL"
fi
[ -s "$VAD" ] || curl -fsSL -o "$VAD" https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

# Kokoro voice (local, English). Optional: without it the app uses the macOS voices.
TTS_OK=0
if [ ! -x "$BOSS_HOME/tts/venv/bin/python" ]; then
  python3 -m venv "$BOSS_HOME/tts/venv" && "$BOSS_HOME/tts/venv/bin/pip" install -q -r "$REPO/tts/requirements.lock" || say "kokoro venv failed; the app will use macOS voices"
fi
[ -s "$BOSS_HOME/tts/kokoro-v1.0.onnx" ] || curl -fsSL -o "$BOSS_HOME/tts/kokoro-v1.0.onnx" https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx || true
[ -s "$BOSS_HOME/tts/voices-v1.0.bin" ] || curl -fsSL -o "$BOSS_HOME/tts/voices-v1.0.bin" https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin || true
[ -x "$BOSS_HOME/tts/venv/bin/python" ] && [ -s "$BOSS_HOME/tts/kokoro-v1.0.onnx" ] && TTS_OK=1
cp "$REPO/tts/kokoro_server.py" "$BOSS_HOME/tts/kokoro_server.py"

# Channel, supervisor, launcher.
rm -rf "$BOSS_HOME/app/channel"
mkdir -p "$BOSS_HOME/app/channel"
cp -R "$REPO/channel/src" "$REPO/channel/package.json" "$BOSS_HOME/app/channel/"
cp "$REPO/bin/boss-up.mjs" "$REPO/bin/boss-radio.mjs" "$REPO/bin/bw" "$BOSS_HOME/bin/"
chmod +x "$BOSS_HOME/bin/boss-up.mjs" "$BOSS_HOME/bin/boss-radio.mjs" "$BOSS_HOME/bin/bw"
mkdir -p "$BOSS_HOME/app/sounds"
cp "$REPO"/sounds/*.wav "$BOSS_HOME/app/sounds/"

# Boss session home.
mkdir -p "$BOSS_HOME/boss/.claude"
cp "$REPO/boss-home/BOSS_PROMPT.md" "$BOSS_HOME/boss/BOSS_PROMPT.md"
cp "$REPO/boss-home/.claude/settings.json" "$REPO/boss-home/.claude/guard-send.mjs" "$BOSS_HOME/boss/.claude/"
sed -e "s#__NODE__#$NODE#" -e "s#__BOSS_CHANNEL__#$BOSS_HOME/app/channel/src/server.ts#" "$REPO/boss-home/.mcp.json" > "$BOSS_HOME/boss/.mcp.json"

# ---------- Claude Code config (reversible, backed up) ----------
if [ "$CONFIG" = 1 ]; then
  sed "s#__BOSS__#boss#g" "$REPO/install/worker-block.md" > "$BOSS_HOME/worker-block.md"
  "$NODE" "$REPO/install/edit-config.mjs" apply "$CLAUDE_DIR" "$BOSS_HOME" "$BOSS_HOME/worker-block.md" >/dev/null
  say "worker block in $CLAUDE_DIR/CLAUDE.md, crossSessionInbound=accept in settings.json (backups in $BOSS_HOME/backups)"
fi

# ---------- the app ----------
if [ "$APP" = 1 ]; then
  sh "$REPO/app/scripts/build-app.sh" >/dev/null
  mkdir -p "$APP_DIR"
  rm -rf "$APP_DIR/Boss.app"
  cp -R "$REPO/app/build/Boss.app" "$APP_DIR/Boss.app"
  KC="$BOSS_HOME/signing/boss-signing.keychain-db"
  if [ -f "$KC" ]; then
    security unlock-keychain -p "$(cat "$BOSS_HOME/signing/keychain.pass")" "$KC"
    ID="$(security find-identity -p codesigning "$KC" | awk '/1\)/{print $2; exit}')"
    ENT="$REPO/app/Boss.entitlements"
    if [ -f "$ENT" ]; then codesign -f -s "$ID" --keychain "$KC" --entitlements "$ENT" -o runtime "$APP_DIR/Boss.app" 2>/dev/null
    else codesign -f -s "$ID" --keychain "$KC" -o runtime "$APP_DIR/Boss.app" 2>/dev/null; fi
    say "Boss.app signed with the local identity (permission grants survive rebuilds)"
  fi
fi

# ---------- launchd ----------
plist() { # label, program args (one per line), keepalive(true/false)
  label="$1"; args="$2"; keep="$3"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n'
    printf '<key>Label</key><string>%s</string>\n<key>ProgramArguments</key><array>\n' "$label"
    printf '%s\n' "$args" | while IFS= read -r a; do [ -n "$a" ] && printf '<string>%s</string>\n' "$a"; done
    if [ "$keep" = crash ]; then keepxml='<dict><key>SuccessfulExit</key><false/></dict>'; else keepxml="<$keep/>"; fi
    printf '</array>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key>%s\n' "$keepxml"
    printf '<key>EnvironmentVariables</key><dict><key>PATH</key><string>%s</string><key>BOSS_HOME</key><string>%s</string></dict>\n' "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$BOSS_HOME"
    printf '<key>StandardOutPath</key><string>%s/logs/%s.out</string><key>StandardErrorPath</key><string>%s/logs/%s.err</string>\n' "$BOSS_HOME" "$label" "$BOSS_HOME" "$label"
    printf '<key>ProcessType</key><string>Interactive</string>\n</dict></plist>\n'
  } > "$LAUNCH_DIR/$label.plist"
}
if [ "$LAUNCHD" = 1 ]; then
  mkdir -p "$LAUNCH_DIR"
  plist com.roman.boss.whisper "$WHISPER
-m
$MODEL
--host
127.0.0.1
--port
8791
-l
auto
-fa
-bs
1
-bo
1
--no-fallback" true
  [ "$TTS_OK" = 1 ] && plist com.roman.boss.tts "$BOSS_HOME/tts/venv/bin/python
$BOSS_HOME/tts/kokoro_server.py
--models
$BOSS_HOME/tts
--port
8792" true
  plist com.roman.boss.up "$NODE
$BOSS_HOME/bin/boss-up.mjs
keep" true
  [ "$APP" = 1 ] && plist com.roman.boss.app "$APP_DIR/Boss.app/Contents/MacOS/Boss" crash
  for l in com.roman.boss.whisper com.roman.boss.tts com.roman.boss.up com.roman.boss.app; do
    [ -f "$LAUNCH_DIR/$l.plist" ] || continue
    launchctl bootout "gui/$(id -u)/$l" 2>/dev/null || true
    # bootout is asynchronous: wait until the old job is really gone before loading the new one.
    i=0; while launchctl print "gui/$(id -u)/$l" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_DIR/$l.plist" || { sleep 1; launchctl bootstrap "gui/$(id -u)" "$LAUNCH_DIR/$l.plist"; }
  done
  say "launch agents loaded (whisper, tts, boss supervisor, app)"
  # A redeploy must run the new channel and prompt: restart the Boss pane (the supervisor keeps it up).
  if [ -z "${BOSS_NO_RESTART:-}" ]; then
    BOSS_HOME="$BOSS_HOME" "$NODE" "$BOSS_HOME/bin/boss-up.mjs" restart >/dev/null 2>&1 && say "Boss session restarted on the new code" || say "Boss session will be started by the supervisor"
  fi
fi
say "done"
