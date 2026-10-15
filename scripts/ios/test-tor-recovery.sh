#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
tests="$root/scripts/ios/tor-recovery-tests"
swiftc -swift-version 5 -emit-library -emit-module -module-name SimpleXChat \
  "$tests/SimpleXStub.swift" -emit-module-path "$temp/SimpleXChat.swiftmodule" -o "$temp/libSimpleXChat.dylib"
swiftc -swift-version 5 -emit-library -emit-module -module-name Tor \
  "$tests/TorStub.swift" -emit-module-path "$temp/Tor.swiftmodule" -o "$temp/libTor.dylib"
swiftc -swift-version 5 -parse-as-library -I "$temp" -L "$temp" -lTor -lSimpleXChat \
  -Xlinker -rpath -Xlinker "$temp" "$tests/AppAdapters.swift" \
  "$root/apps/ios/Shared/Model/EmbeddedTorManager.swift" "$tests/Tests.swift" \
  -o "$temp/tor-recovery-tests"
"$temp/tor-recovery-tests"
