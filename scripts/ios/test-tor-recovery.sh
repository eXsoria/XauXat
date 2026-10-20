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
text += "\n" + function("apps/ios/Shared/Model/SuspendChat.swift", "activateChat")
text += "\n" + function("apps/ios/Shared/Model/SimpleXAPI.swift", "apiActivateChat")
for name in ["chatCloseStore", "chatReopenStore", "isChatStoreOpen", "setChatStoreOpen"]:
    text += "\n" + function("apps/ios/SimpleXChat/API.swift", name)
text += "\n@MainActor\n" + function("apps/ios/Shared/Model/SimpleXAPI.swift", "xauXatRecoverySessionState")
text += "\n@MainActor\n" + function("apps/ios/Shared/Model/SimpleXAPI.swift", "xauXatRequireInviteSession")
Path(sys.argv[2]).write_text(text, encoding="utf-8")

keychain = (root / "apps/ios/SimpleXChat/KeyChain.swift").read_text(encoding="utf-8")
start = keychain.index("public enum XauXatContactInviteState:")
policy = "import Foundation\n" + keychain[start:keychain.index("private var kcContactInvitePolicies:", start)]
policy += "\nprivate var kcContactInvitePolicies: KeyChainItem { xauXatStorageScope() == .decoy ? kcDecoyContactInvitePolicies : kcPrimaryContactInvitePolicies }\n"
for name in ["xauXatRemoveContactInvitePolicies", "readXauXatContactInvitePolicies", "writeXauXatContactInvitePolicies", "xauXatSaveContactInvitePolicy", "xauXatObserveContactInvitePolicy", "xauXatSetContactInviteState", "xauXatContactInvitePolicies"]:
    policy += "\n" + function("apps/ios/SimpleXChat/KeyChain.swift", name)
Path(sys.argv[2]).with_name("InvitePolicy.swift").write_text(policy, encoding="utf-8")

initialization = function("apps/ios/SimpleXChat/API.swift", "chatMigrateInit")
assert initialization.index("xauXatRemoveContactInvitePolicies") < initialization.index("chat_migrate_init_key"), "Clear stale policies before a fresh database reuses connection IDs"
assert "!FileManager.default.fileExists(atPath: dbPath + CHAT_DB)" in initialization, "Existing databases retain their invite policies"
assert "return (false, .errorKeychain)" in initialization, "Failed Keychain cleanup must block fresh database initialization"
revoke = function("apps/ios/Shared/Views/ChatList/ChatListNavLink.swift", "revokeXauXatContactInvite")
assert revoke.index("xauXatRequireInviteSession") < revoke.index("xauXatSetContactInviteState"), "An unavailable store cannot tombstone an invite on a tap"
create = function("apps/ios/Shared/Model/SimpleXAPI.swift", "apiAddContact")
assert create.index("xauXatRequireInviteSession") < create.index("chatApiSendCmdWithRetry"), "Never submit invite creation against a suspended store"
assert "guard xauXatSaveContactInvitePolicy" in create, "Every newly allocated native invite, including Free, must replace stale ID policies"
PY
swiftc -swift-version 5 -parse-as-library \
  "$root/apps/ios/Shared/Model/XauXatOutboundDeliveryPolicy.swift" \
  "$root/apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift" \
  "$temp/Activation.swift" "$tests/ActivationTests.swift" -o "$temp/activation-tests"
"$temp/activation-tests"
swiftc -swift-version 5 -parse-as-library \
  "$temp/InvitePolicy.swift" "$tests/InvitePolicyTests.swift" -o "$temp/invite-policy-tests"
"$temp/invite-policy-tests"
