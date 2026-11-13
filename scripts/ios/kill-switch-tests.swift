import Foundation

// Only OS Keychain and native-core services are replaced. Role mapping,
// erasure, paths, policy/key cleanup and the app's promotion sequence are the
// extracted production implementations.
var secrets: [String: String] = [:]
var failedWrites: Set<String> = []
var failedDeletes: Set<String> = []
func getItemString(forKey key: String) -> String? { secrets[key] }
func setItemString(_ value: String, forKey key: String) -> Bool {
    guard !failedWrites.contains(key) else { return false }
    secrets[key] = value
    return true
}
func deleteItem(forKey key: String) -> Bool {
    guard !failedDeletes.contains(key) else { return false }
    secrets[key] = nil
    return true
}
struct Log {
    func error(_ message: String) {}
    func debug(_ message: String) {}
}
let logger = Log()
enum DBContainer { case group, documents }
final class Default<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { value }
    func set(_ value: Value) { self.value = value }
}
let dbContainerGroupDefault = Default(DBContainer.group)
var testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
func getGroupContainerDirectory() -> URL { testDirectory.appendingPathComponent("group") }
func getDocumentsDirectory() -> URL { testDirectory.appendingPathComponent("documents") }
func getLegacyDatabasePath() -> URL { getDocumentsDirectory().appendingPathComponent("mobile_v1") }
func protectPrivateAppDataFromSystemBackup() -> Bool { true }

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard value() else { fatalError(message) }
}
func write(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
}
func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func database(_ scope: XauXatStorageScope) -> URL {
    URL(fileURLWithPath: getAppDatabasePath(scope).path + "_chat.db")
}
func populate(_ scope: XauXatStorageScope, name: String) throws {
    setXauXatStorageScope(scope)
    expect(kcDatabasePassword.set(name + "-database-key"), "fixture database key")
    try write("user:" + name, to: database(scope))
    try write("agent:" + name, to: URL(fileURLWithPath: getAppDatabasePath(scope).path + "_agent.db"))
    try write("wal:" + name, to: URL(fileURLWithPath: database(scope).path + "-wal"))
    try write("media:" + name, to: getAppFilesDirectory().appendingPathComponent("photo"))
    try write("expressions:" + name, to: getAppFilesDirectory().appendingPathComponent("expressions-7/library"))
    try write("wallpaper:" + name, to: getWallpaperDirectory().appendingPathComponent("wallpaper"))
    try write("invites:" + name, to: getAppDirectory(scope).appendingPathComponent("contact-invite-policies.recovery"))
    for base in ["conversationLocks", "hiddenChats", "protectedProfiles", "protectedProfilePasswords",
                 "contactInvitePolicies", "expiredContactInviteEnvelopes", "groupAccessPolicies", "oneTimeGroupInvites"] {
        expect(KeyChainItem(forKey: base + (scope == .decoy ? ".localProfile" : "")).set(name + ":" + base), "fixture policy")
    }
    for base in ["expressionLibrary", "codeLockedAttempts", "groupAccessAttempts", "groupAccessExpired"] {
        expect(KeyChainItem(forKey: base + (scope == .decoy ? ".localProfile.7" : ".primary.7")).set(name + ":" + base), "fixture dynamic secret")
    }
}
func setup(documents: Bool = false) throws {
    secrets = [:]; failedWrites = []; failedDeletes = []
    dbContainerGroupDefault.set(documents ? .documents : .group)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    setXauXatStorageScope(.primary)
    expect(kcAppPassword.set("111111"), "main PIN fixture")
    expect(kcDecoyPassword.set("222222"), "decoy PIN fixture")
    expect(kcSelfDestructPassword.set("333333"), "duress PIN fixture")
    try populate(.primary, name: "Main")
    try populate(.decoy, name: "Decoy")
    setXauXatStorageScope(.primary)
}
func newFixture(documents: Bool = false) throws {
    try? FileManager.default.removeItem(at: testDirectory)
    testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("xauxat-kill-tests-" + UUID().uuidString)
    try setup(documents: documents)
}
func assertPreserved(_ oldDecoyPath: URL) {
    expect(database(.primary) == oldDecoyPath, "promotion retains the actual decoy database")
    expect(read(oldDecoyPath) == "user:Decoy", "decoy profile survives")
    expect(read(URL(fileURLWithPath: oldDecoyPath.path + "-wal")) == "wal:Decoy", "decoy SQLite sidecars survive")
    expect(kcPrimaryDatabasePassword.get() == "Decoy-database-key", "primary opens with the decoy encryption key")
    setXauXatStorageScope(.primary)
    expect(read(getAppFilesDirectory().appendingPathComponent("photo")) == "media:Decoy", "attachments follow promotion")
    expect(read(getWallpaperDirectory().appendingPathComponent("wallpaper")) == "wallpaper:Decoy", "wallpapers follow promotion")
    expect(read(getAppDirectory().appendingPathComponent("contact-invite-policies.recovery")) == "invites:Decoy", "invite recovery stays with its database")
    for base in ["conversationLocks", "hiddenChats", "protectedProfiles", "protectedProfilePasswords",
                 "contactInvitePolicies", "expiredContactInviteEnvelopes", "groupAccessPolicies", "oneTimeGroupInvites"] {
        expect(KeyChainItem(forKey: base).get() == "Decoy:" + base, "promoted policy: " + base)
        expect(KeyChainItem(forKey: base + ".localProfile").get() == nil, "new decoy policy must be empty: " + base)
    }
    for base in ["expressionLibrary", "codeLockedAttempts", "groupAccessAttempts", "groupAccessExpired"] {
        expect(KeyChainItem(forKey: base + ".primary.7").get() == "Decoy:" + base, "promoted secret: " + base)
        expect(KeyChainItem(forKey: base + ".localProfile.7").get() == nil, "fresh secret namespace: " + base)
    }
    expect(kcAppPassword.get() == "333333", "duress PIN becomes the main PIN")
    expect(kcDecoyPassword.get() == "222222", "decoy PIN still selects the empty decoy")
    expect(kcSelfDestructPassword.get() == nil, "duress PIN is no longer armed")
}

// Native/UI service adapters for the actual LocalAuthView promotion methods.
enum LAResult { case success, failed(authError: String?) }
struct LocalAuthRequest { let password: String; var selfDestruct = true }
struct RuntimeError: Error { let description: String; init(_ value: String) { description = value } }
struct Profile { let displayName: String; let fullName: String }
struct User { let name: String }
enum DBStatus { case ok, errorKeychain }
enum OnboardingStage { case onboardingComplete }
let onboardingStageDefault = Default(OnboardingStage.onboardingComplete)
let DEFAULT_LA_SELF_DESTRUCT = "localAuthenticationSelfDestruct"
let DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME = "localAuthenticationSelfDestructDisplayName"
let DEFAULT_LA_DURESS_SCOPE = "localAuthenticationDuressScope"
let DEFAULT_LA_DECOY_DISPLAY_NAME = "localAuthenticationLocalProfileDisplayName"
final class ChatState { func clear() {} }
final class ItemsModel {
    static let shared = ItemsModel()
    var reversedChatItems: [String] = []
    let chatState = ChatState()
}
final class ChatModel {
    static let shared = ChatModel()
    var ctrlInitInProgress = false, chatInitialized = true, chatDbChanged = false
    var chatRunning: Bool? = true
    var currentUser: User? = User(name: "Main")
    var chatId: String? = "old-chat"
    var users: [User] = []
    var secondaryIM: ItemsModel?
    var chatDbStatus = DBStatus.ok
    var onboardingStage = OnboardingStage.onboardingComplete
    func updateChats(_ chats: [String]) {}
}
enum AppState { case active, activating }
enum NSEState {
    case created, starting, active, suspending, suspended
    var inactive: Bool { self == .created || self == .suspended }
}
typealias DBMigrationResult = DBStatus
let startLock = DispatchSemaphore(value: 1)
final class NSEChatState {
    static let shared = NSEChatState()
    var value = NSEState.suspended
    func set(_ state: NSEState) { value = state }
}
func applyCurrentNSEConfig() -> Bool { true }
func doStartChat() -> DBMigrationResult? {
    chatControllerDatabasePath = getAppDatabasePath().path
    NSEChatState.shared.set(.active)
    return .ok
}
func activateChat() -> DBMigrationResult? { chatReopenStore() ? .ok : nil }
func hasChatCtrl() -> Bool { chatControllerDatabasePath != nil }
func getChatCtrl() -> Int { 0 }
func fromCString(_ value: String) -> String { value }
func chat_reopen_store(_ controller: Int) -> String { "" }
func setChatStoreOpen(_ value: Bool) { storeOpen = value }
let nseStateGroupDefault = Default(NSEState.created)
let nseSuspendTimeout: TimeInterval = 5
var suspensionSucceeds = true
func waitNSESuspended(timeout: TimeInterval, suspended: @escaping (Bool) -> Void) {
    if suspensionSucceeds { nseStateGroupDefault.set(.suspended) }
    suspended(suspensionSucceeds)
}
final class AppChatState {
    static let shared = AppChatState()
    func set(_ state: AppState) {}
}
final class XauXatPINAttemptStore {
    static let shared = XauXatPINAttemptStore()
    func reset() {}
}
final class NtfManager {
    static let shared = NtfManager()
    func removeAllNotifications() async {}
}
var storeOpen = true
var initializedPaths: [URL] = []
var createdPaths: [URL] = []
var failNewDecoy = false
func isChatStoreOpen() -> Bool { storeOpen }
func chatCloseStore() { storeOpen = false }
func resetChatCtrl() { storeOpen = false; chatControllerDatabasePath = nil }
func stopChatAsync() async throws { ChatModel.shared.chatRunning = false }
func initializeChat(start: Bool) throws {
    expect(!start, "preparation must not start a network session")
    if failNewDecoy && xauXatStorageScope() == .decoy && !hasDatabase() { throw RuntimeError("injected native failure") }
    let path = database(xauXatStorageScope())
    initializedPaths.append(path)
    if !hasDatabase() {
        guard kcDatabasePassword.set("generated-" + UUID().uuidString) else { throw RuntimeError("key failure") }
        try write("empty", to: path)
        try write("agent-empty", to: URL(fileURLWithPath: getAppDatabasePath().path + "_agent.db"))
    }
    let value = read(path) ?? ""
    ChatModel.shared.currentUser = value.hasPrefix("user:") ? User(name: String(value.dropFirst(5))) : nil
    ChatModel.shared.chatInitialized = true
    ChatModel.shared.chatDbStatus = .ok
    chatControllerDatabasePath = getAppDatabasePath().path
    storeOpen = true
}
func apiCreateActiveUser(_ profile: Profile, pastTimestamp: Bool) throws -> User {
    let path = database(xauXatStorageScope())
    createdPaths.append(path)
    try write("user:" + profile.displayName, to: path)
    return User(name: profile.displayName)
}
func startChat() throws { ChatModel.shared.chatRunning = true }

@main struct KillSwitchTests {
    @MainActor static func main() async throws {
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        for documents in [false, true] {
            try newFixture(documents: documents)
            let oldMain = database(.primary), oldDecoy = database(.decoy)
            chatControllerDatabasePath = getAppDatabasePath(.primary).path
            expect(chatControllerMatchesCurrentStorage(), "controller originally matches main")
            let unrelated = getAppDirectory(.primary).appendingPathComponent("shared-extension-state")
            try write("preserve", to: unrelated)
            expect(xauXatPromoteDecoyStorage(appPIN: "333333", decoyPIN: "222222"), "promotion succeeds")
            assertPreserved(oldDecoy)
            expect(!chatControllerMatchesCurrentStorage(), "surviving extension controller no longer matches promoted main")
            expect(!chatReopenStore(), "old native controller cannot reopen erased main")
            NSEChatState.shared.set(.suspended)
            expect(NSEHarness().startChat() == .ok, "notification extension recreates its controller")
            expect(chatControllerMatchesCurrentStorage(), "notification extension now uses promoted main")
            expect(!FileManager.default.fileExists(atPath: oldMain.path), "old main database deleted")
            expect(!FileManager.default.fileExists(atPath: oldMain.path + "-wal"), "old main WAL deleted")
            expect(secrets["databasePassword"] == nil, "old main encryption key erased")
            expect(secrets["expressionLibrary.primary.7"] == nil, "old expression key erased")
            expect(read(unrelated) == "preserve", "shared extension state not deleted")
            expect(!hasDecoyDatabase(), "replacement starts empty")
            expect(hasLegacyDatabase() == documents, "document-container promotion survives next launch selection")
            expect(!xauXatStoragePromotionPending(), "completed journal removed")
            expect(xauXatResumeStoragePromotion(), "restart is idempotent")
            assertPreserved(oldDecoy)
            // A second independently armed promotion must work on UUID slots.
            try populate(.decoy, name: "NextDecoy")
            let secondDecoy = database(.decoy)
            expect(kcSelfDestructPassword.set("444444"), "rearming is explicit")
            expect(xauXatPromoteDecoyStorage(appPIN: "444444", decoyPIN: "222222"), "repeat promotion succeeds")
            expect(database(.primary) == secondDecoy, "second decoy becomes primary")
            expect(read(secondDecoy) == "user:NextDecoy", "second promotion preserves data")
            expect(read(oldDecoy) == nil, "previous primary removed after rearming")
            expect(kcPrimaryDatabasePassword.get() == "NextDecoy-database-key", "second key follows role")
            expect(!hasDecoyDatabase(), "second replacement is empty")
            setXauXatStorageScope(.primary)
            deleteDecoyStorage()
            expect(read(secondDecoy) != nil, "removing the empty decoy preserves promoted main")
        }

        try newFixture()
        let main = database(.primary), decoy = database(.decoy)
        failedDeletes = ["databasePassword"]
        expect(!xauXatPromoteDecoyStorage(appPIN: "333333", decoyPIN: "222222"), "erase failure reported")
        expect(read(main) == "user:Main", "key deletion failure cannot delete original files")
        expect(read(decoy) == "user:Decoy", "failed erase cannot touch decoy")
        expect(xauXatStoragePromotionPending(), "failed operation retained for resumption")
        failedDeletes = []
        expect(xauXatResumeStoragePromotion(), "restart completes failed erase")
        assertPreserved(decoy)

        try newFixture()
        let commitDecoy = database(.decoy)
        failedWrites = ["localProfileStorageRoles"]
        expect(!xauXatPromoteDecoyStorage(appPIN: "333333", decoyPIN: "222222"), "mapping commit failure reported")
        expect(read(commitDecoy) == "user:Decoy", "commit failure retains source files")
        failedWrites = []
        expect(xauXatResumeStoragePromotion(), "restart recovers interrupted role commit")
        assertPreserved(commitDecoy)

        try newFixture(documents: true)
        failedWrites = ["localProfileStorageRoles"]
        expect(!xauXatPromoteDecoyStorage(appPIN: "333333", decoyPIN: "222222"), "legacy role commit interrupted")
        expect(hasLegacyDatabase(), "interrupted document-container promotion must not switch to group")
        failedWrites = []
        expect(xauXatResumeStoragePromotion(), "legacy promotion resumes at its original container")
        expect(hasDatabase(), "legacy promoted database stays reachable")

        try newFixture()
        let cleanupDecoy = database(.decoy)
        failedDeletes = ["localProfileStoragePromotion"]
        expect(!xauXatPromoteDecoyStorage(appPIN: "333333", decoyPIN: "222222"), "journal cleanup failure reported")
        failedDeletes = []
        expect(xauXatResumeStoragePromotion(), "already committed journal resumes")
        assertPreserved(cleanupDecoy)

        try newFixture()
        failedWrites = ["localProfileStoragePromotion"]
        expect(!xauXatPromoteDecoyStorage(appPIN: "333333", decoyPIN: "222222"), "journal persistence failure reported")
        expect(read(database(.primary)) == "user:Main", "no erasure before durable journal")
        expect(kcAppPassword.get() == "111111", "no credential change before commit")
        failedWrites = []
        expect(!xauXatPromoteDecoyStorage(appPIN: "222222", decoyPIN: "222222"), "PIN collision refused")
        try FileManager.default.removeItem(at: database(.decoy))
        expect(!xauXatPromoteDecoyStorage(appPIN: "333333", decoyPIN: "222222"), "incomplete source database refused")
        expect(read(database(.primary)) == "user:Main", "missing source cannot erase primary")

        for injectedFailure in [false, true] {
            try newFixture()
            let source = database(.decoy)
            initializedPaths = []; createdPaths = []; failNewDecoy = injectedFailure
            ChatModel.shared.chatInitialized = true
            ChatModel.shared.chatRunning = true
            ChatModel.shared.currentUser = User(name: "Main")
            storeOpen = true
            nseStateGroupDefault.set(.active)
            UserDefaults.standard.set(true, forKey: DEFAULT_LA_SELF_DESTRUCT)
            var completions = 0
            let result = await withCheckedContinuation { continuation in
                PromotionHarness().promoteDecoyAndRestart("333333") { result in
                    completions += 1
                    continuation.resume(returning: result)
                }
            }
            expect(completions == 1, "unlock completes exactly once")
            expect(nseStateGroupDefault.get().inactive, "notification controller suspended before destructive changes")
            expect(!UserDefaults.standard.bool(forKey: DEFAULT_LA_SELF_DESTRUCT), "settings switch is off")
            expect(kcSelfDestructPassword.get() == nil, "kill switch PIN cannot retrigger")
            let unlock = PromotionHarness()
            expect(unlock.configuredPasscodes.contains("333333"), "used duress PIN is now accepted as main PIN")
            expect(!unlock.configuredPasscodes.contains("111111"), "erased main PIN no longer unlocks either environment")
            expect(!ChatModel.shared.chatDbChanged, "UI change indicator cleared")
            expect(xauXatStorageScope() == .primary, "success and failure return to primary role")
            expect(read(source) == "user:Decoy", "native flow preserves existing decoy")
            if injectedFailure {
                if case .success = result { fatalError("native creation failure cannot authenticate") }
                expect(ChatModel.shared.currentUser == nil, "failed decoy creation never exposes a wrong user")
                expect(!ChatModel.shared.chatInitialized, "failed initialization is closed")
            } else {
                if case .failed = result { fatalError("normal promotion must authenticate") }
                expect(ChatModel.shared.currentUser?.name == "Decoy", "opens existing promoted profile")
                expect(createdPaths == [database(.decoy)], "only the fresh decoy profile is created")
                expect(read(database(.decoy)) == "user:Alex", "empty decoy ordinary profile created eagerly")
                expect(kcDecoyDatabasePassword.get() != nil, "fresh decoy encryption key exists")
                expect(kcDecoyDatabasePassword.get() != kcPrimaryDatabasePassword.get(), "decoy has a separate key")
            }
        }
        // Compatibility: an old duress configuration may predate decoy setup.
        try newFixture()
        expect(kcDecoyPassword.remove(), "remove legacy missing decoy PIN")
        expect(destroyXauXatStorage(.decoy), "remove legacy absent decoy storage")
        initializedPaths = []; createdPaths = []; failNewDecoy = false
        nseStateGroupDefault.set(.created)
        let compatibility = await withCheckedContinuation { continuation in
            PromotionHarness().promoteDecoyAndRestart("333333") { continuation.resume(returning: $0) }
        }
        if case .failed = compatibility { fatalError("legacy setup without decoy must migrate") }
        expect(kcAppPassword.get() == "333333", "legacy duress PIN becomes main")
        expect(kcDecoyPassword.get() == "111111", "legacy main PIN selects empty decoy")
        expect(createdPaths.count == 2, "legacy flow creates source decoy before erasure and then a new decoy")
        expect(ChatModel.shared.currentUser?.name == "Alex", "legacy replacement opens an ordinary main")
        expect(kcSelfDestructPassword.set("555555"), "simulate stale disabled duress secret")
        let disabled = PromotionHarness()
        expect(!disabled.configuredPasscodes.contains("555555"), "disabled kill switch never accepts a stale duress PIN")

        try newFixture()
        nseStateGroupDefault.set(.active)
        suspensionSucceeds = false
        failNewDecoy = false
        let notQuiesced = await withCheckedContinuation { continuation in
            PromotionHarness().promoteDecoyAndRestart("333333") { continuation.resume(returning: $0) }
        }
        if case .success = notQuiesced { fatalError("active extension cannot permit erasure") }
        expect(read(database(.primary)) == "user:Main", "extension suspension failure preserves original")
        expect(kcAppPassword.get() == "111111", "failed suspension cannot change PINs")
        expect(!xauXatStoragePromotionPending(), "failed suspension cannot start a journal")
        for key in [DEFAULT_LA_SELF_DESTRUCT, DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME, DEFAULT_LA_DURESS_SCOPE] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        print("\(checks) production kill-switch storage and unlock checks passed.")
    }
}
