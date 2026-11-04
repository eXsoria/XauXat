import Foundation

typealias Recovery = XauXatConnectionRecoveryManager
enum StorageScope { case primary, decoy }
var storageScope = StorageScope.primary
func xauXatStorageScope() -> StorageScope { storageScope }
func xauXatRequiresUnlockBeforeInitialization() -> Bool { kcDecoyPassword.get() != nil }
var initializations = 0
func initChatAndMigrate() { initializations += 1; ChatModel.shared.chatInitialized = true }

@MainActor final class PostAuthFixture {
    var events: [String] = []
    var reconnects = 0
    var failRoutes = 0
    var holdRoute = false
    var held: CheckedContinuation<Void, Never>?
    lazy var manager = Recovery(dependencies: .init(
        context: {
            .init(userId: ChatModel.shared.currentUser?.userId,
                  online: ChatModel.shared.networkInfo.online,
                  active: xauXatAppIsForeground(), alternateStore: storageScope == .decoy)
        },
        ensureTor: { _ in
            self.events.append("tor")
            if self.holdRoute { await withCheckedContinuation { self.held = $0 } }
            if self.failRoutes > 0 { self.failRoutes -= 1; throw TestFailure() }
            torReady = true
            return .init(port: 19050, replaced: false)
        },
        invalidateTor: { torReady = false },
        applyTor: { self.events.append("config"); return false },
        failedRelays: { [:] },
        reconnect: { _ in self.events.append("reconnect"); self.reconnects += 1 },
        sessionState: { xauXatRecoverySessionState() },
        resumeChat: { isCurrent in
            self.events.append("resume")
            await withCheckedContinuation { continuation in
                startChatAndActivate(ifAllowed: { isCurrent() && isXauXatTorReady() }) { continuation.resume() }
            }
        },
        retryJitter: { 1 },
        sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) }
    ))
}
@MainActor var postAuthFixture: PostAuthFixture!
@MainActor extension XauXatConnectionRecoveryManager {
    static var shared: XauXatConnectionRecoveryManager { postAuthFixture.manager }
}

@main @MainActor struct PostAuthTests {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("Post-authentication recovery did not finish")
    }
    static func reset() -> PostAuthFixture {
        controllerAvailable = true; ChatModel.ok = true; torReady = false
        reopenSucceeds = true; commandSucceeds = true; setChatStoreOpen(false)
        UIApplication.shared.applicationState = .active; AppSheetState.shared.scenePhaseActive = true
        let m = ChatModel.shared
        m.currentUser = .init(userId: 1); m.chatInitialized = true
        m.chatRunning = true; m.ctrlInitInProgress = false; m.contentViewAccessAuthenticated = false
        m.networkInfo.online = true
        kcDecoyPassword.value = "TEST_PIN"; storageScope = .primary
        nseStateGroupDefault.value = .suspended; setAppState(.suspended)
        activations = 0; ChatReceiver.shared.starts = 0; nseWaiter = nil; initializations = 0
        let f = PostAuthFixture(); postAuthFixture = f
        return f
    }
    static func main() async throws {
        let f = reset()
        require(recoverXauXatSessionAfterAuthentication() == nil, "No route/store operation may run before the PIN authorizes the selected store")
        require(f.events.isEmpty && activations == 0 && !isChatStoreOpen(), "A locked suspended store must remain closed")
        AuthSuccessHarness().complete()
        try await until { f.reconnects == 1 && isChatStoreOpen() }
        require(ChatModel.shared.contentViewAccessAuthenticated && xauXatRecoverySessionState() == .running,
                "The real same-store authentication callback must leave a usable running session")
        require(f.events == ["tor", "config", "resume", "reconnect"], "PIN success must verify/apply Tor before native resume/reconnect")
        require(activations == 1 && ChatReceiver.shared.starts == 1 && initializations == 0,
                "Same-store unlock reuses the controller/profile without another initialization")
        require(storageScope == .primary && ChatModel.shared.currentUser?.userId == 1, "Unlock recovery cannot switch profile or store")
        f.manager.pause()

        for change in 0..<8 {
            let f = reset()
            ChatModel.shared.contentViewAccessAuthenticated = true
            let task = recoverXauXatSessionAfterAuthentication()
            require(task != nil, "An authorized existing suspended session is eligible for recovery")
            switch change {
            case 0: ChatModel.shared.currentUser = .init(userId: 2)
            case 1: storageScope = .decoy
            case 2: ChatModel.shared.contentViewAccessAuthenticated = false
            case 3: UIApplication.shared.applicationState = .background
            case 4: AppSheetState.shared.scenePhaseActive = false
            case 5: AppChatState.shared.set(.stopped)
            case 6: controllerAvailable = false
            default: ChatModel.shared.networkInfo.online = false
            }
            await task?.value
            require(f.events.isEmpty && activations == 0 && !isChatStoreOpen(),
                    "Queued post-auth work cannot cross identity, store, lifecycle, session or network gates")
            f.manager.pause()
        }

        for change in 0..<5 {
            let f = reset()
            f.holdRoute = true; ChatModel.shared.contentViewAccessAuthenticated = true
            let task = recoverXauXatSessionAfterAuthentication()
            try await until { f.held != nil }
            switch change {
            case 0: ChatModel.shared.currentUser = .init(userId: 2)
            case 1: storageScope = .decoy
            case 2: ChatModel.shared.contentViewAccessAuthenticated = false
            case 3: UIApplication.shared.applicationState = .background; f.manager.pause()
            default: AppSheetState.shared.scenePhaseActive = false
            }
            f.held!.resume()
            await task?.value
            require(f.events == ["tor"] && activations == 0 && !isChatStoreOpen(),
                    "A late verified route cannot reopen a stale or re-locked store")
            f.manager.pause()
        }

        let retry = reset()
        retry.failRoutes = 1; ChatModel.shared.contentViewAccessAuthenticated = true
        await recoverXauXatSessionAfterAuthentication()?.value
        try await until { retry.reconnects == 1 }
        require(retry.events == ["tor", "tor", "config", "resume", "reconnect"] && activations == 1,
                "A transient post-unlock route failure must retain incoming-only retry demand")
        retry.manager.pause()

        let cold = reset()
        controllerAvailable = false; ChatModel.shared.chatInitialized = false
        AuthSuccessHarness().complete()
        require(initializations == 1 && cold.events.isEmpty, "Deferred cold initialization remains separate from resuming an existing controller")
        cold.manager.pause()
        print("Production post-authentication recovery checks passed: \(checks)")
    }
}
