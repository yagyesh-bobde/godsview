#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product GodsView
bin_dir=$(swift build -c release --show-bin-path)
app="dist/GodsView.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/GodsView" "$app/Contents/MacOS/GodsView"
install -m 644 scripts/Info.plist "$app/Contents/Info.plist"
icon_tmp=$(mktemp -d)
trap 'rm -rf "$icon_tmp"' EXIT
mkdir "$icon_tmp/GodsView.iconset"
swift scripts/make-icon.swift "$icon_tmp/GodsView.iconset"
iconutil -c icns "$icon_tmp/GodsView.iconset" -o "$app/Contents/Resources/GodsView.icns"
codesign --force --sign - "$app"
echo "Built $app"
