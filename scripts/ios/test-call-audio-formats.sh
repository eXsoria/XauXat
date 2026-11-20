#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

# Use real AVAudioEngine nodes. The Stealth menu fixture substitutes the
# RTCAudioDevice and therefore cannot catch invalid microphone bus access.
python3 "$root/scripts/ios/call-audio-tests/make-test.py" "$root" "$temp"
swiftc "$temp/Current.swift" -o "$temp/current"
"$temp/current"
swiftc "$temp/InvalidBus.swift" -o "$temp/invalid-bus"
if "$temp/invalid-bus" >"$temp/invalid-bus.log" 2>&1; then
  echo 'Audio format regression accepted a nonexistent microphone bus' >&2
  exit 1
fi
grep -q 'Invalid microphone output bus 1' "$temp/invalid-bus.log"
echo 'Call audio format queries and invalid-bus negative control passed.'
