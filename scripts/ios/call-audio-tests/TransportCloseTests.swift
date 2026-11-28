import Foundation

enum State { case connected, ended }
final class Call {
  let callUUID: String?
  let usesCallKit: Bool
  var callState: State = .connected
  let contact = 1
  init(_ native: Bool = true) {
    usesCallKit = native
    callUUID = native ? UUID().uuidString.lowercased() : nil
  }
  func finishWebRTC() {}
}
struct Invitation { let callUUID: String? }
func justRefreshCallInvitations() async throws {}
struct AVAudioSession { static func sharedInstance() -> Self { Self() } }
struct WebRTCClient {
  static func callKitAudioChanged(_ s: AVAudioSession, active: Bool) -> Bool { true }
}
final class ChatModel {
  static let shared = ChatModel()
  var callInvitations: [String: Invitation] = [:]
  var activeCall: Call?
  var showCallView = true
  var activeCallViewIsCollapsed = false
}
final class CXEndCallAction {
  let callUUID: UUID
  var resolution: String?
  init(call: UUID) { callUUID = call }
  func fulfill() { resolution = "fulfilled" }
  func fail() { resolution = "failed" }
}
final class CXStartCallAction {
  let callUUID: UUID
  init(_ id: UUID) { callUUID = id }
  func fulfill() {}
  func fail() {}
}
final class CXProvider {
  var ended: [UUID] = []
  enum Reason { case failed }
  func reportOutgoingCall(with id: UUID, startedConnectingAt: Date?) {}
  func reportCall(with id: UUID, endedAt: Date?, reason: Reason) { ended.append(id) }
}
final class CXAnswerCallAction {
  let callUUID: UUID
  init(_ uuid: UUID) { callUUID = uuid }
  func fulfill() {}
  func fail() {}
}
enum XauXatCallTiming { static func mark(_ s: String) {} }
// All work is driven by the test on the main actor. No sleeps or deadlines.
private var pendingOperations: [@MainActor () async -> Void] = []
func enqueue(_ operation: @escaping @MainActor () async -> Void) {
  pendingOperations.append(operation)
}
@MainActor func runOperations() async {
  while !pendingOperations.isEmpty {
    let next = pendingOperations.removeFirst()
    await next()
  }
}
enum Signals { static var count = 0 }
func apiEndCall(_ contact: Int) async throws { Signals.count += 1 }
final class CallManager {
  var answered = 0
  func startOutgoingCall(callUUID: String) -> Bool {
    ChatModel.shared.activeCall?.callUUID == callUUID
  }
  func answerIncomingCall(callUUID: String) -> Bool {
    answered += 1
    return ChatModel.shared.activeCall?.callUUID == callUUID
  }
  func getCallInvitation(_ id: String) -> Invitation? { nil }
  func endCall(invitation: Invitation, completed: () -> Void) { completed() }
  /* CALL_MANAGER */
}
final class CallController {
  static let shared = CallController()
  static func useCallKit() -> Bool { true }
  let provider = CXProvider()
  var queued: [CXEndCallAction] = []
  var lastNativeCallUUID: UUID?
  let callManager = CallManager()
  var pendingPushes: [UUID: Date] = [:]
  var fulfillOnConnect: CXAnswerCallAction?
  func canAnswer(_ action: CXAnswerCallAction) -> Bool { fulfillOnConnect === action }
  func waitUntilChatStarted(for action: CXAnswerCallAction) async -> Bool { true }
  func suspendOnEndCall() {}
  func requestTransaction(with action: CXEndCallAction) { queued.append(action) }
  /* CALL_CONTROLLER */
}
func closed(_ call: Call) {
  let m = ChatModel.shared
  guard m.activeCall === call else { return }
  let state = (connectionState: "closed", unused: false)
  /* RTC_CLOSED */
}
@main struct TransportCloseTests {
  @MainActor static func main() async {
    let controller = CallController.shared
    let model = ChatModel.shared
    var failures = 0
    func check(_ flag: Bool, _ label: String) {
      print("\(flag ? "PASS" : "FAIL") \(label)")
      if !flag { failures += 1 }
    }
    func start(_ call: Call) {
      model.activeCall = call
      if let id = call.callUUID.flatMap(UUID.init(uuidString:)) {
        controller.provider(controller.provider, perform: CXStartCallAction(id))
      }
    }
    func deliverNativeRequests() -> [String] {
      let actions = controller.queued
      controller.queued.removeAll()
      for action in actions {
        controller.provider(controller.provider, perform: action)
      }
      return actions.map { $0.resolution ?? "missing" }
    }

    let native = Call()
    start(native)
    let nativeID = UUID(uuidString: native.callUUID!)!
    closed(native)
    let actions = deliverNativeRequests()
    await runOperations()
    check(
      actions == ["fulfilled"] || controller.provider.ended == [nativeID],
      "native close acknowledged for exact owned UUID")
    check(Signals.count == 1, "native close signalled to core once")
    let countAfterNative = Signals.count
    closed(native)
    let fallback = Call(false)
    start(fallback)
    closed(fallback)
    _ = deliverNativeRequests()
    await runOperations()
    check(
      Signals.count == countAfterNative + 1,
      "in-app close signals once; duplicate native close ignored")

    let remote = Call()
    start(remote)
    _ = CallManager.clearActiveCall(remote)
    closed(remote)
    let replacement = Call()
    start(replacement)
    closed(native)
    check(
      model.activeCall === replacement && controller.queued.isEmpty && pendingOperations.isEmpty,
      "remote-first and stale callback preserve replacement")

    let incoming = Call()
    model.activeCall = incoming
    let incomingID = UUID(uuidString: incoming.callUUID!)!
    model.callInvitations = ["fixture": Invitation(callUUID: incoming.callUUID)]
    controller.provider(controller.provider, perform: CXAnswerCallAction(incomingID))
    await runOperations()
    closed(incoming)
    let incomingActions = deliverNativeRequests()
    await runOperations()
    check(
      controller.provider.ended.contains(incomingID) || incomingActions == ["fulfilled"],
      "incoming provider answer registers exact ownership")

    let reset = Call()
    start(reset)
    let resetID = UUID(uuidString: reset.callUUID!)!
    controller.providerDidReset(controller.provider)
    closed(reset)
    _ = deliverNativeRequests()
    await runOperations()
    check(
      !controller.provider.ended.contains(resetID), "provider reset revokes transport ownership")

    start(replacement)
    let reports = controller.provider.ended
    let unknown = CXEndCallAction(call: UUID())
    controller.provider(controller.provider, perform: unknown)
    check(
      model.activeCall === replacement && controller.provider.ended == reports
        && pendingOperations.isEmpty && unknown.resolution == "failed",
      "unrelated UUID never closed or signalled")
    let unregistered = Call()
    model.activeCall = unregistered
    closed(unregistered)
    _ = deliverNativeRequests()
    await runOperations()
    check(
      !controller.provider.ended.contains(UUID(uuidString: unregistered.callUUID!)!),
      "unowned model UUID never reported to native provider")

    let raced = Call()
    start(raced)
    let raceID = UUID(uuidString: raced.callUUID!)!
    let lateSystemEnd = CXEndCallAction(call: raceID)
    let beforeRace = Signals.count
    closed(raced)
    _ = deliverNativeRequests()
    controller.provider(controller.provider, perform: lateSystemEnd)
    await runOperations()
    check(
      lateSystemEnd.resolution == "fulfilled"
        && controller.provider.ended.filter { $0 == raceID }.count <= 1,
      "late native end for the closed call resolves idempotently")
    check(Signals.count == beforeRace + 1, "transport and system end converge on one core end")

    let settled = Call()
    start(settled)
    settled.callState = .ended
    let before = Signals.count
    closed(settled)
    _ = deliverNativeRequests()
    await runOperations()
    check(Signals.count == before, "previously ended core call is not signalled twice")
    if failures > 0 { exit(1) }
  }
}
