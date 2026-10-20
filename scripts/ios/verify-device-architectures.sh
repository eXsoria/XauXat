#!/usr/bin/env bash
set -euo pipefail
app_path=${1:?Usage: verify-device-architectures.sh /path/to/App.app}
test -d "$app_path"
platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app_path/Info.plist")
if [[ "$platform" != iPhoneOS ]]; then
  echo "Expected an iPhoneOS device app, got $platform" >&2
  exit 1
fi
bundles=("$app_path")
for bundle in "$app_path"/PlugIns/*.appex "$app_path"/Frameworks/*.framework; do
  if [[ -d "$bundle" ]]; then bundles+=("$bundle"); fi
done
for bundle in "${bundles[@]}"; do
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")
  test -n "$executable"
  [[ "$executable" != */* ]]
  test -f "$bundle/$executable"
  xcrun lipo -verify_arch arm64 "$bundle/$executable"
done
echo "Verified ARM64 device binaries in ${#bundles[@]} app, extension and framework bundles."
