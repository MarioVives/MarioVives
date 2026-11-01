#!/bin/bash
# Compile ClaudeTokens.app (aucun Xcode requis : les Command Line Tools suffisent).
# Usage : ./build.sh            -> build/ClaudeTokens.app
#         ./build.sh --install  -> copie aussi l'app dans ~/Applications et la lance
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeTokens.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compilation..."
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  ClaudeTokens.swift \
  -o "$APP/Contents/MacOS/ClaudeTokens"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "OK : $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x ClaudeTokens 2>/dev/null || true
  rm -rf "$HOME/Applications/ClaudeTokens.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/ClaudeTokens.app"
  echo "Installée et lancée : ~/Applications/ClaudeTokens.app"
fi
