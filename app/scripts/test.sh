#!/bin/sh
# Runs the BossCore test suite with Swift Testing on a Command-Line-Tools-only Mac (no Xcode).
set -eu
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
# The CLT ships _Testing_Foundation without its module, so turn off the Testing+Foundation cross-import overlay.
exec swift test -Xswiftc -F"$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" "$@"
