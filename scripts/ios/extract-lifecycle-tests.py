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
resume = function("apps/ios/Shared/SimpleXApp.swift", "resumeChatAfterTor")
configuration_failure = resume.split('logger.error("XauXat could not apply', 1)[1].split("let userId", 1)[0]
assert "sessionUnavailable()" in configuration_failure, "Foreground configuration failure needs an incoming-only retry"
assert "guard xauXatRecoverySessionState() == .running else" in resume, "Foreground activation must confirm the store-backed session"
activation_failure = resume.split("guard xauXatRecoverySessionState() == .running else", 1)[1].split("guard isXauXatTorReady()", 1)[0]
assert "sessionUnavailable()" in activation_failure, "Foreground activation failure cannot rely on an outbox to retry"
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
for name in ["connectViaLink", "saveXauXatIncomingInvitePolicy"]:
    policy += "\n" + function("apps/ios/Shared/Views/NewChat/NewChatView.swift", name)
for name in ["apiConnect", "apiConnectPreparedContact", "saveFreshXauXatContactInvitePolicy", "expirePendingXauXatContactInvites"]:
    policy += "\n" + function("apps/ios/Shared/Model/SimpleXAPI.swift", name)
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

# These exact production enums let the store/policy tests run independently of
# Apple's Combine framework on Linux as well as in the full macOS suite.
recovery = (root / "apps/ios/Shared/Model/XauXatConnectionRecoveryManager.swift").read_text(encoding="utf-8")
types = "import Foundation\nfinal class XauXatConnectionRecoveryManager {\n"
for name in ["SessionState", "Blocker", "RecoveryError"]:
    start = recovery.index("enum " + name + ":")
    opening = recovery.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (recovery[end] == "{") - (recovery[end] == "}")
        end += 1
    types += recovery[start:end] + "\n"
types += "}\n"
Path(sys.argv[2]).with_name("RecoveryTypes.swift").write_text(types, encoding="utf-8")
