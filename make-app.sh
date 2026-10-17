#!/bin/bash
# Builds Quicky.app (release), signs it, and optionally relaunches it.
#   ./make-app.sh               build/Quicky.app
#   ./make-app.sh run           ... and (re)launch, logs to build/quicky.log
#   ./make-app.sh verify        build/verify/Quicky.app, compiled with QUICKY_VERIFY
#   ./make-app.sh verify run    ... and (re)launch, logs to build/verify/quicky.log
set -euo pipefail
cd "$(dirname "$0")"

OUT=build
FLAGS=()
if [[ "${1:-}" == "verify" ]]; then
  OUT=build/verify
  # Its own scratch path, so switching between release and verify doesn't rebuild everything.
  FLAGS=(--scratch-path .build/verify -Xswiftc -DQUICKY_VERIFY)
  shift
fi

swift build -c release --product QuickyApp ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/QuickyApp"

# The executable is "Quicky" inside the bundle; the SwiftPM product stays QuickyApp because "Quicky"
# and the "quicky" CLI collide on case-insensitive APFS.
APP="$OUT/Quicky.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/Quicky"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

# A stable signing identity keeps macOS privacy grants (Accessibility, Screen Recording, Input
# Monitoring) across rebuilds. Ad-hoc signing works too, but you'll re-grant after every build.
IDENTITY="${ASSISTANT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "signed $APP with: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "run" ]]; then
  pkill -x Quicky 2>/dev/null || true
  sleep 0.3
  # Launch through LaunchServices so macOS attributes privacy prompts to the app, not the terminal.
  open --stdout "$PWD/$OUT/quicky.log" --stderr "$PWD/$OUT/quicky.log" "$APP"
  echo "running, logs: $OUT/quicky.log"
fi
