#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
app="/Applications/Claude Sessions.app"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 "$here/scripts/render_icon.py" "$work/icon.iconset"
iconutil -c icns "$work/icon.iconset" -o "$work/AppIcon.icns"

swift build -c release --package-path "$here"
binary="$(swift build -c release --package-path "$here" --show-bin-path)/ClaudeSessions"

mkdir -p "$work/bundle/Contents/MacOS" "$work/bundle/Contents/Resources"
cp "$here/Bundle/Info.plist" "$work/bundle/Contents/Info.plist"
cp "$work/AppIcon.icns" "$work/bundle/Contents/Resources/"
cp "$binary" "$work/bundle/Contents/MacOS/ClaudeSessions"

rm -rf "$app"
cp -R "$work/bundle" "$app"
codesign --force --sign - "$app" 2>/dev/null
touch "$app"
echo "  installed: $app"
