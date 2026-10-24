#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
python3 "$root/scripts/ios/extract-message-history-tests.py" "$root" "$temp/History.swift"
swiftc -swift-version 5 -parse-as-library "$temp/History.swift" \
  "$root/scripts/ios/message-history-tests/Tests.swift" -o "$temp/message-history-tests"
"$temp/message-history-tests"
