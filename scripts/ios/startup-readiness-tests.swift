import Foundation

// These adapters replace native/iOS services. All startup decisions, ordering
// and setup retry behavior are extracted from production by the test runner.
enum Phase { case active, inactive, background }
enum NotificationsMode { case off }
enum OnboardingStage { case step1_SimpleXInfo, step2_CreateProfile, step4_NetworkCommitments, onboardingComplete }
enum AppState { case active, suspended, stopped }
enum AuthMode { case passcode }
struct Migration { var startChat = true }
struct NetworkInfo { var online = true }
struct Profile { let displayName: String; let fullName: String }
struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
final class Setting<T> {
    var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { value }
    func set(_ value: T) { self.value = value }
}
final class Key {
    var value: String?
    var succeeds = true
    var writes = 0
    func get() -> String? { value }
    func set(_ value: String) -> Bool {
        writes += 1
        if succeeds { self.value = value }
        return succeeds
    }
}
let kcAppPassword = Key(), kcDatabasePassword = Key()
let privacyLocalAuthModeDefault = Setting(AuthMode.passcode)
let appLocalAuthEnabledGroupDefault = Setting(false)
let storeDBPassphraseGroupDefault = Setting(true)
let privacyDeliveryReceiptsSet = Setting(true)
let onboardingStageDefault = Setting(OnboardingStage.onboardingComplete)
let v3DBMigrationDefault = Setting(Migration())
let chatLastStartGroupDefault = Setting(Date.distantPast)
let DEFAULT_PRIVACY_SHOW_FILE_ENCRYPTION = "synthetic-file-encryption"
let DEFAULT_PERFORM_LA = "synthetic-auth"
let DEFAULT_LA_NOTICE_SHOWN = "synthetic-notice"
let DEFAULT_XAUXAT_EMPTY_SETUP = "synthetic-empty-setup"
struct Log { func debug(_ text: String) {} }
let logger = Log()
final class ChatModel {
    static let shared = ChatModel()
    var migrationState: Int?
    var chatInitialized = false, ctrlInitInProgress = false
    var v3DBMigration = Migration()
    var currentUser: Int?
    var networkInfo = NetworkInfo()
    var users: [Int] = []
    var onboardingStage: OnboardingStage?
    var savedToken: String?, tokenStatus: Int?, notificationServer: String?, deviceToken: String?
    var notificationMode = NotificationsMode.off
    var chatRunning: Bool?
    var setDeliveryReceipts = false, contentViewAccessAuthenticated = false
    func totalUnreadCountForAllUsers() -> Int { 0 }
}
final class AppChatState {
    static let shared = AppChatState()
    var value = AppState.suspended
    func set(_ value: AppState) { self.value = value }
}
final class AlertManager {
    static let shared = AlertManager()
    func showAlertMsg(title: String, message: String) {}
}
final class NtfManager {
    static let shared = NtfManager()
    func setNtfBadgeCount(_ count: Int) {}
}
final class ChatReceiver {
    static let shared = ChatReceiver()
    func start() {}
}
var databaseExists = false, alternatePIN = false, torReady = false
var localStarts: [Bool] = [], coreRunning = false, dataLoads = 0, coreStarts = 0
var profileCreates = 0, storeOpen = true, reopenSucceeds = true, activationSucceeds = true
var coreStartSucceeds = true
func hasDatabase() -> Bool { databaseExists }
func xauXatRequiresUnlockBeforeInitialization() -> Bool { alternatePIN }
func isXauXatTorReady() -> Bool { torReady }
func initializeChat(start: Bool, confirmStart: Bool, refreshInvitations: Bool) throws {
    localStarts.append(start)
    databaseExists = true
    ChatModel.shared.chatInitialized = true
    ChatModel.shared.onboardingStage = .step1_SimpleXInfo
}
func getNetCfg() -> Int { 0 }
func setNetworkConfig(_ config: Int) throws {}
func apiCheckChatRunning() throws -> Bool { coreRunning }
func listUsers() throws -> [Int] { [1] }
func getUserChatData() throws { dataLoads += 1 }
func refreshCallInvitations() async throws {}
func apiGetNtfToken() -> (String?, Int?, NotificationsMode, String?) { (nil, nil, .off, nil) }
func xauXatMigrateNotificationModeIntentIfNeeded(_ mode: NotificationsMode) {}
func apiStartChat() throws -> Bool {
    coreStarts += 1
    guard coreStartSucceeds else { throw RuntimeError("start failure") }
    coreRunning = true
    return true
}
func withAnimation(_ body: () -> Void) { body() }
func reconcileXauXatNotificationRegistration(token: String?) {}
func xauXatSetNotificationModeIntent(_ mode: NotificationsMode) {}
func apiCreateActiveUser(_ profile: Profile) throws -> Int {
    precondition(!UserDefaults.standard.bool(forKey: DEFAULT_XAUXAT_EMPTY_SETUP), "Clear empty-store eligibility before profile creation")
    profileCreates += 1
    return 1
}
func isChatStoreOpen() -> Bool { storeOpen }
func chatReopenStore() -> Bool { storeOpen = reopenSucceeds; return storeOpen }
func activateChat() -> Bool {
    if activationSucceeds { AppChatState.shared.set(.active) }
    return activationSucceeds
}
func responseError(_ error: Error) -> String { error.localizedDescription }

@MainActor final class EmbeddedTorManager {
    static let shared = EmbeddedTorManager()
    var waiter: CheckedContinuation<UInt16, Error>?
    func ensureReady(maxAge: TimeInterval) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func resolve(_ success: Bool) {
        let pending = waiter!
        waiter = nil
        torReady = success
        if success { pending.resume(returning: 12345) }
        else { pending.resume(throwing: RuntimeError("route failure")) }
    }
}

@main @MainActor struct StartupTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Startup did not finish its expected transition")
    }
    static func reset() {
        databaseExists = false; alternatePIN = false; torReady = false
        localStarts = []; coreRunning = false; dataLoads = 0; coreStarts = 0
        profileCreates = 0; storeOpen = true; reopenSucceeds = true
        coreStartSucceeds = true; activationSucceeds = true
        kcAppPassword.value = nil; kcAppPassword.writes = 0; kcAppPassword.succeeds = true
        let m = ChatModel.shared
        m.chatInitialized = false; m.ctrlInitInProgress = false; m.migrationState = nil
        m.onboardingStage = nil; m.currentUser = nil; m.networkInfo.online = true
        m.chatRunning = nil; m.contentViewAccessAuthenticated = false
        AppChatState.shared.value = .suspended
        onboardingStageDefault.value = .onboardingComplete
        UserDefaults.standard.set(false, forKey: DEFAULT_XAUXAT_EMPTY_SETUP)
    }
    static func main() async throws {
        reset()
        let first = StartupHarness()
        first.initializeNewInstallation()
        expect(localStarts == [false], "Fresh setup opens only the local store before Tor")
        expect(UserDefaults.standard.bool(forKey: DEFAULT_XAUXAT_EMPTY_SETUP), "The known-empty setup marker survives relaunch")
        expect(ChatModel.shared.onboardingStage == .step1_SimpleXInfo && !torReady, "Onboarding is visible without a Tor route")
        expect(coreStarts == 0 && profileCreates == 0, "Showing setup creates no profile or network session")
        first.initializeNewInstallation()
        expect(localStarts.count == 1, "Appearance and foreground cannot initialize setup twice")
        reset()
        databaseExists = true
        onboardingStageDefault.value = .step1_SimpleXInfo
        UserDefaults.standard.set(true, forKey: DEFAULT_XAUXAT_EMPTY_SETUP)
        StartupHarness().initializeNewInstallation()
        expect(localStarts == [false] && !torReady, "Relaunching an unfinished empty database still shows setup before Tor")
        reset()
        databaseExists = true
        onboardingStageDefault.value = .step1_SimpleXInfo
        StartupHarness().initializeNewInstallation()
        expect(localStarts.isEmpty, "An unfinished profile without an empty-store marker still waits for Tor")
        reset()
        databaseExists = true
        UserDefaults.standard.set(true, forKey: DEFAULT_XAUXAT_EMPTY_SETUP)
        StartupHarness().initializeNewInstallation()
        expect(localStarts.isEmpty, "A stale empty-store marker cannot open a completed profile before Tor")
        for blocker in 0..<7 {
            reset()
            let launch = StartupHarness()
            switch blocker {
            case 0: databaseExists = true
            case 1: alternatePIN = true
            case 2: launch.scenePhase = .background
            case 3: launch.scenePhase = .inactive
            case 4: ChatModel.shared.ctrlInitInProgress = true
            case 5: ChatModel.shared.migrationState = 1
            default: AppChatState.shared.value = .stopped
            }
            launch.initializeNewInstallation()
            expect(localStarts.isEmpty, "Existing, protected, inactive or migrating stores keep their startup boundary")
        }

        reset(); torReady = true; coreRunning = true
        try startChat(refreshInvitations: false)
        expect(ChatModel.shared.onboardingStage == .onboardingComplete, "An already running core still prepares its first screen")
        expect(dataLoads == 1 && coreStarts == 0, "The first screen loads local data without restarting a running core")
        try startChat(refreshInvitations: false)
        expect(dataLoads == 1 && coreStarts == 0, "A prepared running screen is preserved")
        reset(); torReady = true; coreRunning = true
        onboardingStageDefault.value = .step1_SimpleXInfo
        try startChat(refreshInvitations: false)
        expect(ChatModel.shared.onboardingStage == .step4_NetworkCommitments, "An unfinished profile retains its setup screen")
        reset()
        do { try startChat(); fatalError("Unverified Tor must not start chat") }
        catch { expect(coreStarts == 0 && dataLoads == 0, "Chat stays blocked before verified Tor") }

        reset()
        let setup = SetupHarness()
        UserDefaults.standard.set(true, forKey: DEFAULT_XAUXAT_EMPTY_SETUP)
        setup.finishOnboarding()
        await until { EmbeddedTorManager.shared.waiter != nil }
        expect(setup.isCompleting && profileCreates == 0 && kcAppPassword.writes == 0, "Finish waits for Tor before profile/PIN changes")
        setup.finishOnboarding()
        EmbeddedTorManager.shared.resolve(false)
        await until { !setup.isCompleting }
        expect(setup.errorMessage != nil && profileCreates == 0, "Route failure shows an error and permits retry")
        expect(UserDefaults.standard.bool(forKey: DEFAULT_XAUXAT_EMPTY_SETUP), "Route failure preserves empty setup for the next launch")
        setup.finishOnboarding()
        await until { EmbeddedTorManager.shared.waiter != nil }
        storeOpen = false
        EmbeddedTorManager.shared.resolve(true)
        await until { !setup.isCompleting }
        expect(storeOpen && setup.completions == 1 && profileCreates == 1, "Retry reopens the setup store after backgrounding")
        expect(kcAppPassword.value == "123456" && AppChatState.shared.value == .active, "Setup saves the PIN and activates the profile after Tor")

        for failure in 0..<5 {
            reset()
            let setup = SetupHarness()
            setup.finishOnboarding()
            await until { EmbeddedTorManager.shared.waiter != nil }
            switch failure {
            case 0: setup.scenePhase = .background
            case 1: setup.scenePhase = .inactive
            case 2: ChatModel.shared.networkInfo.online = false
            case 3: storeOpen = false; reopenSucceeds = false
            default: activationSucceeds = false
            }
            EmbeddedTorManager.shared.resolve(true)
            await until { !setup.isCompleting }
            expect(setup.errorMessage != nil && setup.completions == 0 && kcAppPassword.writes == 0, "Unavailable setup cannot save a PIN or complete")
            if failure < 4 { expect(profileCreates == 0, "Unavailable foreground/store creates no profile") }
        }

        reset()
        let retry = SetupHarness()
        coreStartSucceeds = false
        retry.finishOnboarding()
        await until { EmbeddedTorManager.shared.waiter != nil }
        EmbeddedTorManager.shared.resolve(true)
        await until { !retry.isCompleting }
        expect(retry.profileCreated && profileCreates == 1 && retry.completions == 0, "A failed native start retains the newly created profile")
        coreStartSucceeds = true
        retry.finishOnboarding()
        await until { EmbeddedTorManager.shared.waiter != nil }
        EmbeddedTorManager.shared.resolve(true)
        await until { !retry.isCompleting }
        expect(profileCreates == 1 && coreStarts == 2 && retry.completions == 1, "Retry starts the same profile without creating a duplicate")
        print("\(checks) production startup/setup readiness checks passed.")
    }
}
