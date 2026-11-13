#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
python3 "$root/scripts/ios/extract-kill-switch-tests.py" "$root" "$temp/Production.swift"
swiftc -swift-version 5 -parse-as-library "$temp/Production.swift" \
  "$root/scripts/ios/kill-switch-tests.swift" -o "$temp/kill-switch-tests"
"$temp/kill-switch-tests"
