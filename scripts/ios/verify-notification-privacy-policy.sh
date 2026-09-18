#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
app_group="$repo_root/apps/ios/SimpleXChat/AppGroup.swift"
notifications="$repo_root/apps/ios/SimpleXChat/Notifications.swift"
service="$repo_root/apps/ios/SimpleX NSE/NotificationService.swift"

require_text() {
  local file=$1
  local text=$2
  if ! grep -Fq -- "$text" "$file"; then
    echo "Missing notification privacy invariant in $file: $text" >&2
    exit 1
  fi
}

require_text "$app_group" 'public let xauXatNtfPreviewMode: NotificationPreviewMode = .hidden'
require_text "$notifications" 'let previewMode = xauXatNtfPreviewMode'
require_text "$service" 'guard !notification.xauXatShouldSuppress else { return nil }'
require_text "$service" '"displayName": NSLocalizedString("XauXat call", comment: "private callkit banner")'

if grep -Eq '"displayName":[[:space:]]*.*contact\.(displayName|chatViewName)' "$service"; then
  echo "CallKit display name contains a contact name." >&2
  exit 1
fi

echo "Notification privacy policy invariants verified."
