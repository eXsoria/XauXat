#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
manager="$repo_root/apps/ios/SimpleX NSE/NSEEmbeddedTorManager.swift"
service="$repo_root/apps/ios/SimpleX NSE/NotificationService.swift"
network="$repo_root/apps/ios/SimpleXChat/AppGroup.swift"
podfile="$repo_root/apps/ios/Podfile"

require_text() {
  local file=$1
  local text=$2
  if ! grep -Fq -- "$text" "$file"; then
    echo "Missing NSE Tor policy invariant in $file: $text" >&2
    exit 1
  fi
}

require_text "$podfile" "target 'SimpleX NSE' do"
require_text "$podfile" "pod 'Tor/CTor-NoLZMA', '409.11.2'"
require_text "$manager" '"--SocksPort", "127.0.0.1:auto"'
require_text "$manager" 'case .stopped, .ready, .failed:'
require_text "$manager" 'if authenticated, let controller, controller.isConnected'
require_text "$manager" 'control.addObserver(forCircuitEstablished:'
require_text "$service" 'socksProxy: "127.0.0.1:1"'
require_text "$service" 'NSEEmbeddedTorManager.shared.start'
require_text "$network" 'managed.socksMode = .always'
require_text "$network" 'managed.hostMode = .onionHost'

closed_line=$(grep -nF 'networkConfig = xauXatManagedTorConfig(getNetCfg(), socksProxy: "127.0.0.1:1")' "$service" | head -1 | cut -d: -f1)
start_line=$(grep -nF 'NSEEmbeddedTorManager.shared.start' "$service" | head -1 | cut -d: -f1)
receive_line=$(grep -nF 'self.receiveNtfMessages(request)' "$service" | head -1 | cut -d: -f1)

if (( closed_line >= start_line || start_line >= receive_line )); then
  echo "NSE Tor startup ordering is no longer fail closed." >&2
  exit 1
fi

if grep -Eq '^[[:space:]]*logger\..*(displayName|contact\.id|msgId|entityId|nonce|encNtfInfo)' "$service"; then
  echo "A notification extension log includes sensitive or stable identifiers." >&2
  exit 1
fi

echo "NSE Tor policy invariants verified."
