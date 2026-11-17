#!/bin/bash
set -euo pipefail
archive="$1"
version="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' \
  https://github.com/motionsamm-lgtm/dropbox-downloader/releases/download/gob-v1.0.0/GOB-Mac-Intel.zip -o "$work/old.zip"
printf '%s  %s\n' d027945d0560325848713c368be30a24b92374c1214c3e9b3a7698b793fc416c "$work/old.zip" | shasum -a 256 -c -
ditto -x -k "$work/old.zip" "$work/old"
app="$work/old/GOB for Mac/GOB.app"
test -f "$app/Contents/Resources/install-update.sh"
history="$HOME/Library/Application Support/Dropbox Downloader Mac"
mkdir -p "$history"
printf 'keep my saved history' > "$history/ci-upgrade-sentinel.txt"
before="$(shasum -a 256 "$history/ci-upgrade-sentinel.txt")"
# Run the actual 1.0.0 installer helper after the old UI has exited.
bash "$app/Contents/Resources/install-update.sh" "$archive" "$app" 999999
actual=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
test "$actual" = "$version"
codesign --verify --strict --deep "$app"
test "$(shasum -a 256 "$history/ci-upgrade-sentinel.txt")" = "$before"
# The new GUI has no active downloads on this isolated test machine.
pkill -f "$app/Contents/MacOS/DropboxDownloader" || true
printf '%s\n' 'PASS: actual 1.0.0 Mac replacement helper, bundle version/signature and preserved history.'
