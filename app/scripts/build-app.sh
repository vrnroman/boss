#!/bin/sh
# Builds build/Boss.app without Xcode: swift build (release) + hand-assembled bundle + codesign.
# Signing identity: $BOSS_SIGN_ID (e.g. "Apple Development: …"), else ad-hoc ("-").
# Note: with ad-hoc signing every rebuild changes the code hash, so macOS asks for
# Microphone / Input Monitoring again. A stable BOSS_SIGN_ID keeps the grants.
set -eu
cd "$(dirname "$0")/.."
APP_DIR="$(pwd)"
OUT="$APP_DIR/build/Boss.app"
SOUNDS="$APP_DIR/Resources/sounds"

swift build -c release --product Boss
BIN="$(swift build -c release --show-bin-path)/Boss"

# Placeholder radio sounds (only when the real ones have not been dropped in yet).
mkdir -p "$SOUNDS"
tone() { # name, ffmpeg lavfi expression, duration
  [ -f "$SOUNDS/$1" ] && return 0
  if command -v ffmpeg >/dev/null 2>&1; then
    st=$(awk -v d="$3" 'BEGIN{printf "%.3f", d - 0.03}')
    ffmpeg -loglevel error -y -f lavfi -i "aevalsrc='$2':s=44100:d=$3" -af "afade=t=in:d=0.005,afade=t=out:st=$st:d=0.03,volume=0.5" -ac 1 -c:a pcm_s16le "$SOUNDS/$1"
  else
    echo "warning: ffmpeg missing, no placeholder for $1" >&2
  fi
}
tone radio_open.wav  "0.35*sin(2*PI*(880+1200*t)*t)*exp(-6*t)" 0.12
tone radio_close.wav "0.35*sin(2*PI*(1400-1600*t)*t)*exp(-6*t)" 0.12
tone sent.wav        "0.3*sin(2*PI*1320*t)*exp(-18*t)+0.2*sin(2*PI*1760*t)*exp(-14*t)" 0.18
tone report.wav      "0.3*sin(2*PI*660*t)*exp(-8*t)+0.25*sin(2*PI*990*t)*exp(-6*(t))*gte(t,0.09)" 0.35
tone question.wav    "0.3*sin(2*PI*784*t)*exp(-7*t)+0.3*sin(2*PI*1046*t)*exp(-7*(t-0.12))*gte(t,0.12)" 0.4
tone error.wav       "0.3*sin(2*PI*220*t)*exp(-5*t)+0.2*sin(2*PI*233*t)*exp(-5*t)" 0.3

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/sounds"
cp "$BIN" "$OUT/Contents/MacOS/Boss"
cp "$SOUNDS"/*.wav "$OUT/Contents/Resources/sounds/" 2>/dev/null || true
VERSION="${BOSS_VERSION:-0.1.0}"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Boss</string>
  <key>CFBundleIdentifier</key><string>${BOSS_BUNDLE_ID:-com.roman.boss.dev}</string>
  <key>CFBundleName</key><string>Boss</string>
  <key>CFBundleDisplayName</key><string>Boss</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Boss listens while you hold Right Option (or the Talk button) so it can send your words to the right Claude Code session. Audio stays on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Boss uses on-device speech recognition to preview which session you are talking to while you speak.</string>
  <key>NSAppleEventsUsageDescription</key><string>Boss brings the matching iTerm tab to the front when you tap Show session.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$OUT/Contents/PkgInfo"

ENT="$APP_DIR/build/Boss.entitlements"
cat > "$ENT" <<ENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENTS

SIGN_ID="${BOSS_SIGN_ID:--}"
codesign --force --options runtime --timestamp=none --entitlements "$ENT" --sign "$SIGN_ID" "$OUT"
codesign --verify --strict "$OUT"
echo "built $OUT (signed with: $SIGN_ID)"
