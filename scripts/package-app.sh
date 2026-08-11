#!/bin/zsh
set -euo pipefail

swift build --configuration release
app_path="dist/Blink.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp .build/release/Blink "$app_path/Contents/MacOS/Blink"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
