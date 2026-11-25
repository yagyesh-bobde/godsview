#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
case "$#" in
    0) configuration=release ;;
    1) [[ "$1" == "--debug" ]] || exit 2; configuration=debug ;;
    *) exit 2 ;;
esac
swift build -c "$configuration" --product GodsView
bin_dir=$(swift build -c "$configuration" --show-bin-path)
mkdir -p dist
stage=$(mktemp -d dist/.package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/GodsView.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/GodsView" "$app/Contents/MacOS/GodsView"
install -m 644 scripts/Info.plist "$app/Contents/Info.plist"
icon="$app/Contents/Resources/GodsView.icns"
cached_icon=".build/dev/GodsView.icns"
if [[ "$configuration" == debug ]]; then
    plutil -insert GodsViewDevelopmentBuild -string "$(uuidgen)" "$app/Contents/Info.plist"
fi
if [[ "$configuration" == debug && "$cached_icon" -nt scripts/make-icon.swift ]]; then
    cp "$cached_icon" "$icon"
else
    mkdir "$stage/GodsView.iconset"
    swift scripts/make-icon.swift "$stage/GodsView.iconset"
    iconutil -c icns "$stage/GodsView.iconset" -o "$icon"
    if [[ "$configuration" == debug ]]; then
        mkdir -p .build/dev
        cp "$icon" "$cached_icon"
    fi
fi
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

# Install the fully signed bundle in one step, including when the previous build is running.
swift -e '
import Foundation
let source = CommandLine.arguments[1], destination = CommandLine.arguments[2]
let flags = FileManager.default.fileExists(atPath: destination) ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
guard renamex_np(source, destination, flags) == 0 else { perror("Install GodsView.app"); exit(1) }
' "$app" dist/GodsView.app
echo "Built dist/GodsView.app"
