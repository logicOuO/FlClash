#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:-iphoneos}"
case "$platform" in
  iphoneos) arch=arm64; triple=arm64-apple-ios15.0 ;;
  iphonesimulator) arch=arm64; triple=arm64-apple-ios15.0-simulator ;;
  *) echo "Expected iphoneos or iphonesimulator" >&2; exit 1 ;;
esac
sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
out="$root/libclash/ios/$platform"
mkdir -p "$out"
python3 "$root/tool/ios_go_overlay.py" "$root" "$out"
export GOOS=ios GOARCH="$arch" CGO_ENABLED=1
export CC="$(xcrun --sdk "$platform" --find clang)"
export CGO_CFLAGS="-target $triple -isysroot $sdk -fapplication-extension"
export CGO_LDFLAGS="-target $triple -isysroot $sdk -fapplication-extension -lresolv"
cd "$root/core"
go build -overlay "$out/overlay.json" -trimpath -tags with_gvisor -buildmode=c-archive -ldflags '-s -w' -o "$out/libclash.a" .
