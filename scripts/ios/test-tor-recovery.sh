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
"$temp/tor-recovery-tests"
swiftc -swift-version 5 -parse-as-library \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
  "$root/apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift" \
  "$tests/RecoveryTests.swift" -o "$temp/coordinated-recovery-tests"
"$temp/coordinated-recovery-tests"

# Compile and execute the real app activation/session-classification functions
# with an NSE callback that can be held across lifecycle/profile changes.
python3 - "$root" "$temp/Activation.swift" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
def function(path, name):
    source = (root / path).read_text(encoding="utf-8")
    start = source.index("func " + name + "(")
    opening = source.index("{", start)
    # The default callback contains a brace, so start from the function body.
    if name == "startChatAndActivate":
        opening = source.index("{\n", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

api = (root / "apps/ios/Shared/Model/SimpleXAPI.swift").read_text(encoding="utf-8")
context = api.split("context: {", 1)[1].split("ensureTor:", 1)[0]
active = context.split("active:", 1)[1]
assert "applicationState" in active and "scenePhaseActive" in active
assert "chatRunning" not in active and "AppChatState" not in active, "Foreground cannot depend on chat activation"
app = (root / "apps/ios/Shared/SimpleXApp.swift").read_text(encoding="utf-8")
appear = app.split(".onAppear()", 1)[1].split("// Spec: spec/architecture.md#scenePhaseHandling", 1)[0]
assert appear.index("NetworkObserver.shared.startMonitor()") < appear.index("startEmbeddedTor("), "Network monitoring must precede cold Tor bootstrap"
assert "startRetrying(whileAvailable:" in app, "Cold startup must retain its completion across transient failures"
assert "NetworkObserver.shared.updateCoreNetworkInfo()" in api, "New core must receive cached availability without restarting the monitor"
observer = (root / "apps/ios/Shared/Model/NetworkObserver.swift").read_text(encoding="utf-8")
assert "guard monitor == nil" in observer and "restartMonitor" not in api, "Opening the core must not synthesize another path change"
text = "import Foundation\n" + function("apps/ios/Shared/Model/SuspendChat.swift", "startChatAndActivate")
text += "\n@MainActor\n" + function("apps/ios/Shared/Model/SimpleXAPI.swift", "xauXatRecoverySessionState")
Path(sys.argv[2]).write_text(text, encoding="utf-8")
PY
swiftc -swift-version 5 -parse-as-library \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
  "$root/apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift" \
  "$temp/Activation.swift" "$tests/ActivationTests.swift" -o "$temp/activation-tests"
"$temp/activation-tests"
