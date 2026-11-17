#!/bin/bash
set -euo pipefail
archive="$1"
target="$2"
old_pid="$3"
parent="$(dirname "$target")"
work="$(mktemp -d "$parent/.gob-update.XXXXXXXX")"
backup="$work/previous.app"
trap 'rm -rf "$work"' EXIT
fail() {
  /usr/bin/osascript -e 'display alert "GOB update could not finish" message "The existing app was kept. Move GOB to a folder you can write to and try again."' || true
}
if ! /usr/bin/ditto -x -k "$archive" "$work/unpacked"; then fail; exit 1; fi
candidate="$work/unpacked/GOB for Mac/GOB.app"
if ! /usr/bin/codesign --verify --strict --deep "$candidate"; then fail; exit 1; fi
for ((waited=0; waited<120; waited++)); do
  if ! kill -0 "$old_pid" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$old_pid" 2>/dev/null; then fail; exit 1; fi
if ! mv "$target" "$backup"; then fail; exit 1; fi
if ! mv "$candidate" "$target"; then mv "$backup" "$target"; fail; exit 1; fi
if ! /usr/bin/open "$target"; then
  mv "$target" "$work/failed.app"
  mv "$backup" "$target"
  fail
  exit 1
fi
