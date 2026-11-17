#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'This release build requires a macOS runner.' >&2
  exit 1
fi
case "$(uname -m)" in
  arm64) arch=arm64; label=Apple-Silicon ;;
  x86_64) arch=x64; label=Intel ;;
  *) printf '%s\n' 'Unsupported build architecture.' >&2; exit 1 ;;
esac

aria_version=1.37.0
aria_checksum=60a420ad7085eb616cb6e2bdf0a7206d68ff3d37fb5a956dc44242eb2f79b66b
node_version=22.23.4
node_name="node-v${node_version}-darwin-${arch}"
node_base="https://nodejs.org/download/release/v${node_version}"
aria_archive="aria2-${aria_version}.tar.xz"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
export MACOSX_DEPLOYMENT_TARGET=14.0

download() { /usr/bin/curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' "$@"; }
download "$node_base/$node_name.tar.gz" -o "$workspace/$node_name.tar.gz"
download "$node_base/SHASUMS256.txt" -o "$workspace/node-checksums.txt"
(
  cd "$workspace"
  awk -v file="$node_name.tar.gz" '$2 == file { print; count++ } END { if (count != 1) exit 1 }' node-checksums.txt > node-selected.sha
  /usr/bin/shasum -a 256 -c node-selected.sha
  /usr/bin/tar -xzf "$node_name.tar.gz" "$node_name/bin/node" "$node_name/LICENSE"
)
download "https://github.com/aria2/aria2/releases/download/release-$aria_version/$aria_archive" -o "$workspace/$aria_archive"
(
  cd "$workspace"
  printf '%s  %s\n' "$aria_checksum" "$aria_archive" | /usr/bin/shasum -a 256 -c -
  /usr/bin/tar -xf "$aria_archive"
  cd "aria2-$aria_version"
  mkdir "$workspace/no-pkg-config"
  PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$workspace/no-pkg-config" \
    ./configure --with-appletls --disable-bittorrent --disable-metalink --disable-nls \
      --without-openssl --without-gnutls --without-libnettle --without-libgcrypt \
      --without-libssh2 --without-libcares --without-sqlite3 --without-libxml2 --without-libexpat
  /usr/bin/make -j"$(/usr/sbin/sysctl -n hw.ncpu)"
)

bash Build-Mac.command
app="$PWD/build/Dropbox Downloader.app"
bin="$app/Contents/MacOS"
resources="$app/Contents/Resources"
cp "$workspace/$node_name/bin/node" "$bin/node"
cp "$workspace/aria2-$aria_version/src/aria2c" "$bin/aria2c"
mkdir -p "$resources/ThirdParty"
cp "$workspace/$node_name/LICENSE" "$resources/ThirdParty/Node-LICENSE.txt"
cp "$workspace/aria2-$aria_version/COPYING" "$resources/ThirdParty/aria2-COPYING.txt"

# Reject binaries that depend on libraries from the build runner.
for binary in "$bin/node" "$bin/aria2c"; do
  /usr/bin/otool -L "$binary" | awk 'NR > 1 && $1 !~ /^\/(usr\/lib|System\/Library)\// { print; bad=1 } END { exit bad }'
  /usr/bin/codesign --force --sign - "$binary"
done
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict --deep "$app"

"$bin/node" --version
"$bin/node" --test Tests/engine.test.mjs
"$bin/aria2c" --version
mkdir -p "$workspace/smoke"
printf 'original' > "$workspace/smoke/existing"
printf 'verified' > "$workspace/smoke/partial"
if "$bin/DropboxDownloader" --publish "$workspace/smoke/partial" "$workspace/smoke/existing"; then
  echo 'Publication test unexpectedly replaced an existing file.' >&2
  exit 1
fi
"$bin/DropboxDownloader" --publish "$workspace/smoke/partial" "$workspace/smoke/saved"
test "$(cat "$workspace/smoke/saved")" = verified

"$bin/aria2c" --no-conf=true --check-certificate=true --max-tries=2 --timeout=25 \
  --dir="$workspace/smoke" --out=checksums.txt "$node_base/SHASUMS256.txt"
cmp "$workspace/smoke/checksums.txt" "$workspace/node-checksums.txt"
printf '' | "$bin/node" "$resources/backend.mjs" "$workspace/smoke/history" "$bin/DropboxDownloader" "$workspace/smoke" > "$workspace/smoke/worker.jsonl"
grep -F '"available":true' "$workspace/smoke/worker.jsonl"

package="$workspace/Dropbox Downloader for Mac"
mkdir -p "$package/ThirdParty" dist
mv "$app" "$package/"
cp OPEN-MAC-APP.txt "$package/"
cp "$workspace/$aria_archive" "$package/ThirdParty/"
cp Scripts/package-mac.sh "$package/ThirdParty/aria2-build-recipe.sh"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package" "dist/Dropbox-Downloader-Mac-$label.zip"
/usr/bin/unzip -tq "dist/Dropbox-Downloader-Mac-$label.zip"
