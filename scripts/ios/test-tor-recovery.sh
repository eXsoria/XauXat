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
  "$root/apps/ios/Shared/Model/EmbeddedTorManager.swift" \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
  "$root/apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift" "$tests/Tests.swift" \
  -o "$temp/tor-recovery-tests"
for run in {1..10}; do
  echo "Tor recovery repeat $run/10"
  "$temp/tor-recovery-tests"
done
swiftc -swift-version 5 -parse-as-library \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
  "$root/apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift" \
  "$tests/RecoveryTests.swift" -o "$temp/coordinated-recovery-tests"
"$temp/coordinated-recovery-tests"

# Compile and execute the real app activation/session-classification functions
# with an NSE callback that can be held across lifecycle/profile changes.
python3 "$root/scripts/ios/extract-lifecycle-tests.py" "$root" "$temp/Activation.swift"
swiftc -swift-version 5 -parse-as-library \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
  "$root/apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift" \
  "$temp/Activation.swift" "$tests/ActivationTests.swift" -o "$temp/activation-tests"
"$temp/activation-tests"
swiftc -swift-version 5 -parse-as-library \
  "$temp/InvitePolicy.swift" "$tests/InvitePolicyTests.swift" -o "$temp/invite-policy-tests"
"$temp/invite-policy-tests"
