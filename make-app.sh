#!/bin/bash
# Builds build/Assistant.app (release), signs it, and optionally launches it.
#   ./make-app.sh          build + sign
#   ./make-app.sh run      build + sign + (re)launch, logs to build/assistant.log
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Assistant"

APP=build/Assistant.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/Assistant"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

# A stable signing identity keeps macOS privacy grants (Accessibility, Screen Recording, Input
# Monitoring) across rebuilds. Ad-hoc signing works too, but you'll re-grant after every build.
IDENTITY="${ASSISTANT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "signed with: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "run" ]]; then
  pkill -x Assistant 2>/dev/null || true
  sleep 0.3
  # Launch through LaunchServices so macOS attributes privacy prompts to the app, not the terminal.
  open --stdout "$PWD/build/assistant.log" --stderr "$PWD/build/assistant.log" "$APP"
  echo "running, logs: build/assistant.log"
fi
