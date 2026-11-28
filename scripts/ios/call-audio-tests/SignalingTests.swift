import Foundation

@main
enum SignalingTests {
    static func testCallKitTimeout() {
        let controller = Controller()
        let provider = CXProvider()
        let incoming = CXAnswerCallAction()
        controller.fulfillOnConnect = incoming
        controller.finishAnswer(for: UUID(), connected: true)
        controller.provider(provider, timedOutPerforming: CXAction())
        precondition(controller.canAnswer(incoming) && controller.callManager.ended.isEmpty)
        incoming.timeoutDate = Date.distantPast
        controller.finishAnswer(for: incoming.callUUID, connected: true)
        controller.provider(provider, timedOutPerforming: incoming)
        precondition(controller.fulfillOnConnect == nil && incoming.completions == 0)
        precondition(controller.callManager.ended == [incoming.callUUID.uuidString.lowercased()])

        for connected in [true, false] {
            let active = CXAnswerCallAction()
            controller.fulfillOnConnect = active
            controller.finishAnswer(for: active.callUUID, connected: connected)
            controller.finishAnswer(for: active.callUUID, connected: connected)
            precondition(active.completions == 1 && active.fulfilled == connected)
        }
        print("CallKit passed. Matching actions complete once, expired and unrelated actions remain untouched.")
    }

    static func main() async throws {
        try await verifyInvitations()
        try await verifyHeadlessCalls()
        await verifySuspendedAnswer()
        testCallKitTimeout()
        let old = IceCandidates()
        let current = IceCandidates()
        let client = Client()
        client.activeCall = Client.Call(iceCandidates: current)
        old.append(7)
        old.finish()
        await client.sendRemainingIceCandidates(old)
        precondition(client.sent.isEmpty, "An old SDP acknowledgement cannot start trickle on another call")
        current.append(9)
        current.finish()
        await client.sendRemainingIceCandidates(current)
        precondition(client.sent == ["[9]"])
        let ice = IceCandidates()
        ice.append(1)
        let start = ProcessInfo.processInfo.systemUptime
        let first = await ice.initial()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(first == [1] && elapsed < 0.5, "An available candidate must wake SDP immediately")

        ice.append(2)
        ice.append(3)
        let sender = Task {
            var received: [Int] = []
            await ice.sendRemaining { batch in
                received += batch
                if batch.contains(4) { ice.finish() }
            }
            return received
        }
        // Keep the peer alive beyond the former 12 s polling window.
        try await Task.sleep(nanoseconds: 12_500_000_000)
        ice.append(4)
        let deadline = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            ice.finish()
        }
        let remaining = await sender.value
        deadline.cancel()
        precondition(remaining == [2, 3, 4], "Send buffered and late candidates in order, exactly once")

        let slow = IceCandidates()
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        let empty = await slow.initial()
        let timeout = ProcessInfo.processInfo.systemUptime - timeoutStart
        precondition(empty.isEmpty && timeout >= 0.6 && timeout < 2, "Slow TURN gathering must release SDP")
        slow.finish()

        let ended = IceCandidates()
        let waiting = Task { await ended.initial() }
        ended.finish()
        let endedBatch = await waiting.value
        precondition(endedBatch.isEmpty)
        let complete = IceCandidates()
        complete.signal()
        let completeStart = ProcessInfo.processInfo.systemUptime
        let completeBatch = await complete.initial()
        precondition(completeBatch.isEmpty && ProcessInfo.processInfo.systemUptime - completeStart < 0.5)
        complete.finish()
        print(String(format: "ICE passed. Ready candidate %.1f ms, empty timeout %.1f ms, late candidate received after 12.5 s.", elapsed * 1000, timeout * 1000))
    }
}

final class CXProvider {}
class CXAction {
    let uuid = UUID()
    var timeoutDate = Date.distantFuture
    var completions = 0
    var fulfilled = false
    var isComplete: Bool { completions > 0 }
    func fulfill() { completions += 1; fulfilled = true }
    func fail() { completions += 1 }
}
final class CXAnswerCallAction: CXAction {
    let callUUID = UUID()
}
final class Manager {
    var ended: [String] = []
    func endCall(callUUID: String, completed: (Bool) -> Void) {
        ended.append(callUUID)
        completed(true)
    }
}


struct Message {
    enum Response { case ice(iceCandidates: String) }
    var corrId: Int?
    var resp: Response
    var command: Int?
}
func encodeJSON(_ batch: [Int]) -> String { String(describing: batch) }
func compressToBase64(input: String) -> String { input }

enum AppState { case active, activating, suspended, stopped }
final class AppChatState {
    static let shared = AppChatState()
    var value = AppState.suspended
}
private var storeOpen = false
private var torVerified = true
private var requiresPIN = false
enum SessionState {
    case running, suspended, stopped, unlockRequired, uninitialized
    var canRecover: Bool { self == .running || self == .suspended }
}
func xauXatStorageScope() -> Int { 0 }
func xauXatRecoverySessionState() -> SessionState {
    if requiresPIN { return .unlockRequired }
    if AppChatState.shared.value == .stopped { return .stopped }
    if !ChatModel.shared.chatInitialized { return .uninitialized }
    return AppChatState.shared.value == .active && storeOpen ? .running : .suspended
}
private var activations = 0
private var delayHandover = false
private var pendingHandover: (() -> Void)?
func isChatStoreOpen() -> Bool { storeOpen }
func isXauXatTorReady() -> Bool { torVerified }
func xauXatAppIsForeground() -> Bool { false }
func startChatAndActivate(ifAllowed: @escaping () -> Bool, _ finish: @escaping () -> Void) {
    activations += 1
    let activate = {
        if ifAllowed() { AppChatState.shared.value = .active; storeOpen = true }
        finish()
    }
    if delayHandover { pendingHandover = activate } else { activate() }
}

@MainActor
private func verifySuspendedAnswer() async {
    let controller = Controller()
    let action = CXAnswerCallAction()
    controller.fulfillOnConnect = action
    let resumed = await controller.waitUntilChatStarted(for: action)
    precondition(resumed && activations == 1 && storeOpen && controller.shouldSuspendChat)

    AppChatState.shared.value = .active
    storeOpen = false
    let reopened = await controller.waitUntilChatStarted(for: action)
    precondition(reopened && activations == 2 && storeOpen)

    AppChatState.shared.value = .stopped
    let stopped = await controller.waitUntilChatStarted(for: action)
    precondition(!stopped && activations == 2)

    AppChatState.shared.value = .suspended
    storeOpen = false
    for (initialized, verified, pin) in [(false, true, false), (true, false, false), (true, true, true)] {
        ChatModel.shared.chatInitialized = initialized
        torVerified = verified
        requiresPIN = pin
        action.timeoutDate = Date().addingTimeInterval(0.03)
        let allowed = await controller.waitUntilChatStarted(for: action)
        precondition(!allowed && !storeOpen && activations == 2)
    }
    torVerified = true
    requiresPIN = false
    action.timeoutDate = .distantFuture
    delayHandover = true
    let pending = Task { await controller.waitUntilChatStarted(for: action) }
    while pendingHandover == nil { await Task.yield() }
    controller.fulfillOnConnect = nil
    pendingHandover?()
    let cancelled = await pending.value
    precondition(!cancelled && !storeOpen && activations == 3)
    print("CallKit answer reactivates a suspended chat; stopped, locked startup, locked decoy profile, unavailable Tor and cancelled handover remain closed.")
}
