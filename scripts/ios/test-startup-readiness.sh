#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
python3 "$root/scripts/ios/extract-startup-tests.py" "$root" "$temp/Production.swift"
swiftc -swift-version 5 -parse-as-library "$temp/Production.swift" \
  "$root/scripts/ios/startup-readiness-tests.swift" -o "$temp/startup-tests"
"$temp/startup-tests"
