#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
tests="$root/scripts/ios/tor-recovery-tests"
manager=apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift
python3 "$root/scripts/ios/extract-lifecycle-tests.py" "$root" "$temp/Activation.swift"

compile_recovery() {
  swiftc -swift-version 5 -parse-as-library \
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
swiftc -swift-version 5 -parse-as-library \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" "$root/$manager" \
  "$temp/PostAuth.swift" "$temp/PostAuthAdapters.swift" "$tests/PostAuthTests.swift" -o "$temp/post-auth"
"$temp/post-auth"
swiftc -swift-version 5 -parse-as-library \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" "$root/$manager" \
  "$temp/Activation.swift" "$tests/ActivationTests.swift" -o "$temp/activation"
"$temp/activation"
