#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
tests="$root/scripts/ios/tor-recovery-tests"
python3 "$root/scripts/ios/extract-lifecycle-tests.py" "$root" "$temp/Activation.swift"
swiftc -swift-version 5 -parse-as-library \
  "$temp/RecoveryTypes.swift" "$temp/Activation.swift" "$tests/ActivationTests.swift" \
  -o "$temp/activation-tests"
"$temp/activation-tests"
swiftc -swift-version 5 -parse-as-library \
  "$temp/InvitePolicy.swift" "$tests/InvitePolicyTests.swift" -o "$temp/invite-policy-tests"
"$temp/invite-policy-tests"
