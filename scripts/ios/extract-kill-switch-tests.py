"""Compile the production storage/promotion decisions with injectable OS services."""
from pathlib import Path
import re
import sys

root, destination = map(Path, sys.argv[1:])
keychain = (root / "apps/ios/SimpleXChat/KeyChain.swift").read_text()
files = (root / "apps/ios/SimpleXChat/FileUtils.swift").read_text()
auth = (root / "apps/ios/Shared/Views/LocalAuth/LocalAuthView.swift").read_text()
auth_utils = (root / "apps/ios/Shared/Views/Helpers/LocalAuthenticationUtils.swift").read_text()
api = (root / "apps/ios/SimpleXChat/API.swift").read_text()
nse = (root / "apps/ios/SimpleX NSE/NotificationService.swift").read_text()


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


parts = ["import Foundation\n"]
parts.append("@MainActor\n" + declaration(auth_utils, "func xauXatPrepareLocalStorageChange("))
parts.append(declaration(auth_utils, "func xauXatClearDuressSettings("))
parts.append("var chatControllerDatabasePath: String?\n"
             + declaration(api, "public func chatControllerMatchesCurrentStorage("))
parts.append(declaration(api, "public func chatReopenStore("))
parts.append("final class NSEHarness {\n" + declaration(nse, "func startChat()") + "\n}")
parts.append(keychain[keychain.index("private let DATABASE_PASSWORD_ITEM"):
                      keychain.index("private var kcConversationLocks")])
parts.append(declaration(keychain, "public struct KeyChainItem"))
parts.append(declaration(keychain, "private func expressionLibraryKeyName"))
for marker in [
    "public func xauXatRemoveExpressionLibraryKey(",
    "public func xauXatRemoveConversationLocks(", "public func xauXatRemoveHiddenChats(",
    "public func xauXatRemoveProtectedProfiles(", "public func xauXatRemoveProtectedProfilePasswords(",
    "private func contactInvitePolicyRecoveryURL(", "public func xauXatRemoveContactInvitePolicies(",
    "public func xauXatRemoveGroupAccessPolicies(", "public func xauXatRemoveOneTimeGroupInvites(",
]:
    parts.append(declaration(keychain, marker))
for name in ("CHAT_DB", "AGENT_DB", "CHAT_DB_BAK", "AGENT_DB_BAK", "DECOY_STORAGE_DIRECTORY", "DB_FILE_PREFIX"):
    parts.append(re.search(r"^(?:private )?let " + name + r"[^\n]+", files, re.M).group())
for marker in [
    "func getAppDirectory(", "public func getAppDatabasePath(",
    "public func hasLegacyDatabase(", "public func hasDatabase(", "public func hasDecoyDatabase(",
    "public func destroyXauXatStorage(", "func hasDatabaseAtPath(",
    "public func getTempFilesDirectory(", "public func getMigrationTempFilesDirectory(",
    "public func getAppFilesDirectory(", "public func getWallpaperDirectory(",
    "private func removeExpressionLibraryKeys(", "public func deleteDecoyStorage(",
    "public func prepareXauXatStorageScope(",
]:
    parts.append(declaration(files, marker))

# Keep UI sequencing in the test too: fresh decoy creation must precede opening
# the promoted main, failures must complete once, and settings must switch off.
methods = [declaration(auth, marker).replace("private func", "func", 1) for marker in [
    "private func promoteDecoyAndRestart(", "private func closeLocalProfile(",
    "private func initializeLocalProfile(", "private func clearVisibleChatData(",
]]
parts.append("@MainActor final class PromotionHarness {\n"
             "let m = ChatModel.shared\n"
             'let authRequest = LocalAuthRequest(password: kcAppPassword.get() ?? "111111")\n'
             + "\n".join(methods)
             + "\n" + declaration(auth, "private var configuredPasscodes:").replace("private var", "var", 1) + "\n}")
destination.write_text("\n\n".join(parts) + "\n")
