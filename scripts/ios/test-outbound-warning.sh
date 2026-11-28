#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
api="$root/apps/ios/Shared/Model/SimpleXAPI.swift"
{
  echo 'import Foundation'
  sed -n '/^final class OutboundDeliveryManager {/,/^}/p' "$api" | sed '/logger\./d'
  echo 'func handle(_ id: Int64, _ status: Status) {'
  sed -n '/case let \.chatItemsStatusesUpdated(user, chatItems):/,/case let \.chatItemUpdated(user, aChatItem):/p' "$api" |
    sed -n '/switch cItem.meta.itemStatus {/,/^            }/p' |
    sed 's/cItem.meta.itemStatus/status/; s/itemId: cItem.id/itemId: id/'
  echo '}'
} > "$temp/OutboundDelivery.swift"
swiftc -swift-version 5 -parse-as-library -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$temp/modules}" \
  "$temp/OutboundDelivery.swift" "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
  "$root/scripts/ios/tor-recovery-tests/OutboundWarningTests.swift" -o "$temp/test"
"$temp/test"
