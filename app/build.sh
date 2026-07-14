#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
cp menubar-mark.png "$APP/Contents/Resources/"
cp menubar-mark-alert.png "$APP/Contents/Resources/"
cp menubar-mark-100.png "$APP/Contents/Resources/"

swiftc -parse-as-library -o "$APP/Contents/MacOS/ClaudeUsage" \
    App.swift \
    -framework SwiftUI -framework AppKit \
    -target arm64-apple-macos13.0

chmod 755 "$APP/Contents/MacOS/ClaudeUsage"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built: $APP"
open "$APP"
