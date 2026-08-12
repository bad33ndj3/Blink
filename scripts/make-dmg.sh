#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

zsh scripts/package-app.sh

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Blink.app/Contents/Info.plist)
dmg_path="dist/Blink-${version}.dmg"
staging="dist/.dmg-staging"

rm -rf "$staging" "$dmg_path"
mkdir -p "$staging"
cp -R dist/Blink.app "$staging/Blink.app"
ln -s /Applications "$staging/Applications"

hdiutil create -volname "Blink" -srcfolder "$staging" -ov -format UDZO "$dmg_path"
rm -rf "$staging"

echo "Created $dmg_path"
