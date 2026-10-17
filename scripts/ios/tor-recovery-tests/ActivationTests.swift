import Foundation

// Minimal app collaborators for the actual production activation functions.
// The NSE waiter is held so lifecycle changes can happen before its callback.
enum AppState { case active, activating, bgRefresh, suspending, suspended, stopped }
enum NSEState {
    case active, suspended
    var inactive: Bool { self == .suspended }
}
final class NSESetting {
    var value: NSEState = .suspended
    func get() -> NSEState { value }
    func set(_ value: NSEState) { self.value = value }
}
let nseStateGroupDefault = NSESetting()
let nseSuspendTimeout: TimeInterval = 5
final class AppChatState {
    static let shared = AppChatState()
    var value: AppState = .suspended
}
func setAppState(_ state: AppState) { AppChatState.shared.value = state }
final class ChatModel {
    static let shared = ChatModel()
    var chatRunning: Bool? = true
    var ctrlInitInProgress = false
    var contentViewAccessAuthenticated = true
}
final class ChatReceiver {
    static let shared = ChatReceiver()
    var starts = 0
    func start() { starts += 1 }
}
final class Key {
    var value: String?
    func get() -> String? { value }
}
let kcDecoyPassword = Key()
var controllerAvailable = true
func hasChatCtrl() -> Bool { controllerAvailable }
var activations = 0
func activateChat() { activations += 1; setAppState(.active) }
var nseWaiter: ((Bool) -> Void)?
func waitNSESuspended(timeout: TimeInterval, suspended: @escaping (Bool) -> Void) { nseWaiter = suspended }
struct Logger { func debug(_ value: String) {} }
let logger = Logger()

@main @MainActor struct ActivationTests {
    static var checks = 0
    static func require(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError(message) }
    }
    static func reset() {
        controllerAvailable = true
        ChatModel.shared.chatRunning = true
        ChatModel.shared.ctrlInitInProgress = false
        ChatModel.shared.contentViewAccessAuthenticated = true
        kcDecoyPassword.value = nil
        nseStateGroupDefault.value = .suspended
        setAppState(.suspended)
        activations = 0
        ChatReceiver.shared.starts = 0
        nseWaiter = nil
    }
    static func main() {
        reset()
        require(xauXatRecoverySessionState() == .suspended, "A foreground app may have a resumable suspended core")
        setAppState(.active)
        require(xauXatRecoverySessionState() == .running, "A running core must be distinguishable from foreground availability")
        setAppState(.stopped)
        require(xauXatRecoverySessionState() == .stopped, "An intentionally stopped chat must not auto-start")
        reset()
        controllerAvailable = false
        require(xauXatRecoverySessionState() == .uninitialized, "A missing controller cannot be activated")
        controllerAvailable = true
        ChatModel.shared.ctrlInitInProgress = true
        require(xauXatRecoverySessionState() == .uninitialized, "Opening a store must not race recovery")
        reset()
        kcDecoyPassword.value = "TEST_PIN"
        ChatModel.shared.contentViewAccessAuthenticated = false
        require(xauXatRecoverySessionState() == .unlockRequired, "Decoy store selection must still wait for unlock")

        reset()
        var completions = 0
        startChatAndActivate(ifAllowed: { false }) { completions += 1 }
        require(activations == 0 && ChatReceiver.shared.starts == 0 && completions == 1, "An invalid operation must not start the receiver and must finish its waiter")
        reset()
        completions = 0
        startChatAndActivate(ifAllowed: { true }) { completions += 1 }
        require(activations == 1 && completions == 1, "A verified current operation should activate normally")

        // These invalidations reach the production helper through its supplied
        // current-operation guard; coordinator tests exercise the real epoch,
        // foreground, network and selected-profile comparisons.
        for invalidate in 0..<4 {
            reset()
            nseStateGroupDefault.value = .active
            completions = 0
            var current = true
            startChatAndActivate(ifAllowed: {
                current && xauXatRecoverySessionState() == .suspended
            }) { completions += 1 }
            require(activations == 0 && nseWaiter != nil, "Activation must wait for the active extension")
            switch invalidate {
            case 0: current = false
            case 1: setAppState(.suspended)
            case 2: setAppState(.stopped)
            default:
                kcDecoyPassword.value = "TEST_PIN"
                ChatModel.shared.contentViewAccessAuthenticated = false
            }
            nseWaiter!(false)
            require(activations == 0 && completions == 1, "A late NSE callback cannot activate a stale, stopped or protected session and cannot strand its waiter")
            require(nseStateGroupDefault.value == .active, "A stale NSE timeout must not rewrite the newer extension state")
        }
        reset()
        nseStateGroupDefault.value = .active
        completions = 0
        startChatAndActivate(ifAllowed: { true }) { completions += 1 }
        nseWaiter!(true)
        require(activations == 1 && completions == 1, "A current NSE callback must activate exactly once")
        reset()
        nseStateGroupDefault.value = .active
        completions = 0
        startChatAndActivate(ifAllowed: { true }) { completions += 1 }
        nseWaiter!(false)
        require(activations == 1 && completions == 1 && nseStateGroupDefault.value == .suspended, "A current NSE timeout must retain the existing bounded activation fallback")
        // A duplicate callback must neither resume a checked continuation twice
        // nor mistake a newer activation for its own operation.
        setAppState(.activating)
        nseStateGroupDefault.value = .active
        nseWaiter!(false)
        require(activations == 1 && completions == 1 && nseStateGroupDefault.value == .active, "Completed activation callbacks must be idempotent and leave newer NSE state alone")
        print("Production activation regression checks passed: \(checks)")
    }
}
