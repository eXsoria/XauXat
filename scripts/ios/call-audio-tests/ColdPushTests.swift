import Foundation

private var events: [String] = []
private var pin = false
private var routeReady = true
private var scope = 0
private var verified: CheckedContinuation<Void, Never>?

final class UIApplication { typealias LaunchOptionsKey = String }
final class AppDelegate {
    func removeStaleXauXatProtectedFiles() {}
    func removePasscodesIfReinstalled() {}
    func prepareForLaunch() {}
    func deleteOldChatArchive() {}
}
enum PKPushType { case voIP }
final class PKPushRegistry {
    weak var delegate: CallController?
    var desiredPushTypes: Set<PKPushType> = [] {
        didSet { if delegate != nil && desiredPushTypes.contains(.voIP) { events.append("registered") } }
    }
}
struct PKPushPayload { let dictionaryPayload: [String: Any] }
enum CallMediaType: String { case audio }
final class CXEndCallAction {
    let callUUID: UUID
    private(set) var fulfilled = false
    init(_ uuid: UUID) { callUUID = uuid }
    func fulfill() { fulfilled = true }
    func fail() { fulfilled = false }
}
final class Manager {
    func endCall(callUUID: String, completed: (Bool) -> Void) { completed(false) }
}
final class CXProvider {
    func setDelegate(_ delegate: CallController, queue: DispatchQueue?) {}
    func reportNewIncomingCall(with uuid: UUID, update: String, completion: @escaping (Error?) -> Void) {
        events.append("reported")
        completion(nil)
    }
}
struct Invitation { let callUUID: String }
struct User { let userId: Int }
final class ChatModel {
    static let shared = ChatModel()
    var callInvitations: [String: Invitation] = [:]
    var currentUser: User?
    var chatInitialized = false
    var ctrlInitInProgress = false
    var migrationState: Int?
    var chatRunning: Bool?
}
enum State { case active, suspended, stopped }
final class AppChatState { static let shared = AppChatState(); var value = State.suspended }
enum Recovery { case unlockRequired, available }
func xauXatStorageScope() -> Int { scope }
func xauXatStoragePromotionPending() -> Bool { false }
func xauXatRecoverySessionState() -> Recovery { .available }
func xauXatRequiresUnlockBeforeInitialization() -> Bool { pin }
func isXauXatTorReady() -> Bool { routeReady }
func xauXatAppIsForeground() -> Bool { false }
struct Default {
    var inactive = true
    var startChat = true
    func get() -> Self { self }
}
let v3DBMigrationDefault = Default()
var nseStateGroupDefault = Default()
let nseSuspendTimeout: TimeInterval = 5
private var onSuspend: ((Bool) -> Void)?
func waitNSESuspended(timeout: TimeInterval, suspended: @escaping (Bool) -> Void) {
    events.append("handover")
    onSuspend = suspended
}
final class EmbeddedTorManager {
    static let shared = EmbeddedTorManager()
    @MainActor func readyBefore(_ deadline: TimeInterval, maxAge: TimeInterval) async throws -> UInt16 {
        events.append("tor")
        await withCheckedContinuation { verified = $0 }
        return 12345
    }
}
func initializeChat(start: Bool, refreshInvitations: Bool) throws {
    precondition(start && !refreshInvitations && routeReady)
    events.append("core")
    ChatModel.shared.chatInitialized = true
    ChatModel.shared.currentUser = User(userId: 1)
    ChatModel.shared.chatRunning = true
}
func applyXauXatRecoveryConfiguration() throws -> Bool { events.append("configure"); return false }
func startChatAndActivate(ifAllowed: () -> Bool, _ finish: () -> Void) {
    if ifAllowed() { events.append("activate") }
    finish()
}
final class Answer { let callUUID = UUID(); func fulfill() {}; func fail() {} }
extension CallController {
    func suspendOnEndCall() {}
    var fulfillOnConnect: Answer? { get { nil } set {} }
    func canAnswer(_ answer: Answer) -> Bool { false }
    func cxCallUpdate(_ contact: String, _ name: String, _ media: CallMediaType) -> String { "call" }
    func reportExpiredCall(update: String, _ complete: () -> Void) { events.append("expired"); complete() }
    func reportExpiredCall(payload: PKPushPayload, _ complete: () -> Void) { events.append("expired"); complete() }
    static func alreadyReported(_ error: Error) -> Bool { false }
}

@main enum ColdPushTests {
    @MainActor static func main() async throws {
        _ = AppDelegate().application(UIApplication(), didFinishLaunchingWithOptions: nil)
        precondition(events == ["registered"])
        let controller = CallController.shared
        func push(_ age: TimeInterval = 0) -> UUID {
            events = []
            let uuid = UUID()
            let fields: [String: Any] = ["contactId": "1", "displayName": "Call", "callUUID": uuid.uuidString,
                                          "media": "audio", "callTs": Date().timeIntervalSince1970 - age]
            controller.pushRegistry(controller.registry, didReceiveIncomingPushWith: PKPushPayload(dictionaryPayload: fields), for: .voIP) {
                events.append("completed")
            }
            return uuid
        }
        _ = push(181)
        precondition(events == ["expired", "completed"])
        pin = true
        _ = push()
        await Task.yield()
        precondition(events == ["reported", "completed"])
        pin = false
        for scenario in ["cancel", "stop", "lock", "scope", "no-route", "expiry", "cancel-handover", "ready"] {
            AppChatState.shared.value = .suspended
            pin = false
            routeReady = true
            nseStateGroupDefault.inactive = scenario != "cancel-handover"
            let uuid = push(scenario == "expiry" ? 179.85 : 0)
            precondition(events == ["reported", "completed"])
            while verified == nil { await Task.yield() }
            switch scenario {
            case "cancel":
                let end = CXEndCallAction(uuid)
                controller.provider(controller.provider, perform: end)
                precondition(end.fulfilled)
            case "stop": AppChatState.shared.value = .stopped
            case "lock": pin = true
            case "scope": scope += 1
            case "no-route": routeReady = false
            case "expiry": try await Task.sleep(nanoseconds: 200_000_000)
            default: break
            }
            verified?.resume()
            verified = nil
            if scenario == "cancel-handover" {
                while onSuspend == nil { await Task.yield() }
                controller.finishAnswer(for: uuid, connected: false)
                nseStateGroupDefault.inactive = true
                onSuspend?(true)
                onSuspend = nil
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            let steps = ["reported", "completed", "tor"] + (scenario == "ready" ? ["core", "activate"] : [])
                + (scenario == "cancel-handover" ? ["handover"] : [])
            precondition(events == steps, "\(scenario) \(events)")
        }
        print("Cold push passed: launch registration, immediate report/completion, verified host Tor before core, cancellation, expiry, stop and identity gates.")
    }
}
