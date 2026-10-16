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

# Check the foreground delegate itself: local messages and generic NSE fallbacks
# must use the same silent policy without relying on cached app/chat state.
python3 - "$repo_root/apps/ios/Shared/Model/NtfManager.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("willPresent notification: UNNotification,")
end = source.index("    // Spec:", start)
body = source[start:end]
assert "handler([])" in body, "Foreground notifications must be silent."
assert "presentationOptions(" not in body, "Conditional foreground banners must not return."
assert "applicationState" not in body, "Use the system foreground callback, not a racing state read."
print("Foreground local/push notification presentation guard verified.")
PY
