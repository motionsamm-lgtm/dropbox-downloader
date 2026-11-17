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
app="$staging/Dropbox Downloader.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp Sources/*.mjs Sources/interface.html "$app/Contents/Resources/"
/usr/bin/xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -O Sources/main.swift \
    -o "$app/Contents/MacOS/DropboxDownloader"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
mkdir -p build
if [[ -e 'build/Dropbox Downloader.app' ]]; then
    printf '%s\n' 'Move the previous app out of the build folder, then run the build again.' >&2
    exit 1
fi
mv "$app" 'build/Dropbox Downloader.app'
printf '\nBuilt %s/build/Dropbox Downloader.app\n' "$PWD"
