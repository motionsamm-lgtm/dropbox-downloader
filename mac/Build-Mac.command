#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'Build this package on a Mac.' >&2
    exit 1
fi
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    printf '%s\n' 'Run xcode-select --install in Terminal first.' >&2
    exit 1
fi

staging="$(mktemp -d "$PWD/.mac-build.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/GOB.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp Sources/*.mjs Sources/interface.html Sources/install-update.sh "$app/Contents/Resources/"
/usr/bin/xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -O Sources/main.swift \
    -o "$app/Contents/MacOS/DropboxDownloader"
mkdir -p "$staging/GOB.iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" ../assets/GOB.png --out "$staging/GOB.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" ../assets/GOB.png --out "$staging/GOB.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$staging/GOB.iconset" -o "$app/Contents/Resources/GOB.icns"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
mkdir -p build
if [[ -e 'build/GOB.app' ]]; then
    printf '%s\n' 'Move the previous app out of the build folder, then run the build again.' >&2
    exit 1
fi
mv "$app" 'build/GOB.app'
printf '\nBuilt %s/build/GOB.app\n' "$PWD"
