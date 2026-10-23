#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
for tool in flutter go rustup pod xcodegen; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
flutter pub get
bash tool/build_ios_core.sh "${1:-iphoneos}"
touch ios/Flutter/Generated.xcconfig
cd ios
xcodegen generate
cd ..
flutter build ios --config-only --no-codesign
cd ios
xcodegen generate
pod install
