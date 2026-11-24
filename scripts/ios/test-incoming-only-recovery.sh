#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
tests="$root/scripts/ios/tor-recovery-tests"
manager=apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift
python3 "$root/scripts/ios/extract-lifecycle-tests.py" "$root" "$temp/Activation.swift"
swift_flags=()
if [[ $(uname -s) == Linux ]]; then
  # These tests exercise the real coordinator and app callbacks, not Combine
  # delivery. Supply only its two storage declarations on non-Apple runners.
  cat > "$temp/Combine.swift" <<'SWIFT'
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
SWIFT
  swiftc -emit-library -emit-module -module-name Combine "$temp/Combine.swift" \
    -emit-module-path "$temp/Combine.swiftmodule" -o "$temp/libCombine.so"
  swift_flags=(-I "$temp" -L "$temp" -lCombine -Xlinker -rpath -Xlinker "$temp")
fi

compile_recovery() {
  swiftc -swift-version 5 -parse-as-library "${swift_flags[@]}" \
    "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
    "$1" "$temp/SubscriptionEvents.swift" "$tests/RecoveryTests.swift" -o "$2"
}

# Execute the new scenarios against the actual pre-change coordinator too.
# A generic compile failure or unrelated crash is not a baseline reproduction.
if [[ -n ${INCOMING_RECOVERY_BASE_SHA:-} ]]; then
  git -C "$root" show "$INCOMING_RECOVERY_BASE_SHA:$manager" > "$temp/Baseline.swift"
  compile_recovery "$temp/Baseline.swift" "$temp/baseline"
  set +e
  XAUXAT_INCOMING_ONLY_REGRESSIONS=1 "$temp/baseline" > "$temp/baseline.log" 2>&1
  baseline_status=$?
  set -e
  if [[ $baseline_status -eq 0 ]] || ! grep -Fq 'Incoming-only global recovery stalled without an outbound message' "$temp/baseline.log"; then
    cat "$temp/baseline.log"
    echo 'Expected incoming-only baseline regression was not reproduced' >&2
    exit 1
  fi
  echo 'Baseline reproduced: incoming recovery stopped after global acknowledgement with no outbound message.'
fi

compile_recovery "$root/$manager" "$temp/recovery"
"$temp/recovery"
swiftc -swift-version 5 -parse-as-library "${swift_flags[@]}" \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" "$root/$manager" \
  "$temp/PostAuth.swift" "$temp/PostAuthAdapters.swift" "$tests/PostAuthTests.swift" -o "$temp/post-auth"
"$temp/post-auth"
swiftc -swift-version 5 -parse-as-library "${swift_flags[@]}" \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" "$root/$manager" \
  "$temp/Activation.swift" "$tests/ActivationTests.swift" -o "$temp/activation"
"$temp/activation"
