import Foundation

struct Binding<Value> { let get: () -> Value; let set: (Value) -> Void }
enum CallMediaSource { case mic, camera }
enum WCallCommand {
    case capabilities(media: CallType.Media), start(media: CallType.Media, aesKey: String?, iceServers: [String]?, relay: Bool)
    case offer, end, media(source: CallMediaSource, enable: Bool)
}
let DEFAULT_WEBRTC_POLICY_RELAY = "test.relay"
func getIceServers() -> [String]? { ["test-relay"] }
enum XauXatProductPolicy { static func callMedia(_ media: CallType.Media) -> CallType.Media { media } }
enum XauXatCallTiming { static func mark(_ stage: String) {} }
final class XauXatRealtimeVoiceMasking {
    static let shared = XauXatRealtimeVoiceMasking()
    var beginnings = 0
    func beginCall(_ call: Active) { beginnings += 1 }
    func endCall(_ call: Active) {}
}
final class CallSoundsPlayer {
    static let shared = CallSoundsPlayer()
    func stop() {}
    func vibrate(long: Bool) {}
}
final class XauXatRealtimeAudioDevice {
    static let shared = XauXatRealtimeAudioDevice()
    func suspendCapture() {}
}
typealias CallManager = Manager
extension Manager {
    @discardableResult
    static func clearActiveCall(_ call: Active) -> Bool {
        guard ChatModel.shared.activeCall === call else { return false }
        call.finishWebRTC()
        ChatModel.shared.activeCall = nil
        return true
    }
}
struct AVAudioSession {
    enum Category: String { case ambient }
    enum Mode: String { case `default` }
}
final class RTCAudioSession {
    static let shared = RTCAudioSession()
    static func sharedInstance() -> RTCAudioSession { shared }
    var useManualAudio = false
    var isAudioEnabled = false
    var releases = 0
    var resets = 0
    var notifications: [Bool] = []
    func audioSessionDidActivate(_ session: AVAudioSession) { notifications.append(true) }
    func audioSessionDidDeactivate(_ session: AVAudioSession) { notifications.append(false) }
    func lockForConfiguration() {}
    func unlockForConfiguration() {}
    func setActive(_ active: Bool) throws { if !active { releases += 1 } }
    func setCategory(_ name: String) throws { resets += 1 }
    func setMode(_ mode: String) throws {}
}
final class RTCAudioTrack { var isEnabled = true }
struct RTCMediaConstraints { let mandatoryConstraints: [String:String]?; let optionalConstraints: [String:String]? }
struct Factory {
    func audioSource(with: RTCMediaConstraints) -> Int { 1 }
    func audioTrack(with: Int, trackId: String) -> RTCAudioTrack { RTCAudioTrack() }
}
final class WebRTCClient {
    static let audioQueue = DispatchQueue(label: "headless.audio")
    static weak var audioSessionOwner: WebRTCClient?
    static var activatedAudioSession = false
    static var nativeAudioActive = false
    static let factory = Factory()
    let rtcAudioSession = RTCAudioSession.shared
    let captureLock = NSLock()
    weak var ownedAudioTrack: RTCAudioTrack?
    var captureAllowed = true
    var captureEnded = false
    let usesCallKitAudio: Bool
    let response: (String) async -> Void
    var activeCall: Int?
    var blockMedia: (() async -> Void)?
    init(_ response: @escaping (String) async -> Void, _ aspect: Binding<CGFloat?>, usesCallKitAudio: Bool) {
        self.response = response
        self.usesCallKitAudio = usesCallKitAudio
        claimAudioSession()
    }
    func sendCallCommand(command: WCallCommand) async {
        switch command {
        case let .start(_, key, servers, _):
            precondition(key == "fixture" && servers == ["test-relay"])
            activeCall = 1
            await response("offer")
        case .capabilities: await response("invitation")
        case .media:
            await blockMedia?()
            await response("late")
        default: break
        }
    }
    func endCall() { audioSessionToDefaults() }
}
actor Gate {
    var waiting: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
    var blocked: Bool { waiting != nil }
}
@MainActor
func verifyHeadlessCalls() async throws {
    let model = ChatModel.shared
    let manager = Manager()
    let rtc = RTCAudioSession.shared
    let system = AVAudioSession()
    _ = WebRTCClient.callKitAudioChanged(system, active: true)
    let native = RcvCallInvitation(user: .sampleData, contact: .sampleData, callType: CallType(media: .audio, capabilities: CallCapabilities(encryption: true)), sharedKey: "fixture", callUUID: UUID().uuidString, callTs: Date())
    model.callInvitations[native.contact.id] = native
    manager.answerIncomingCall(invitation: native)
    func waitFor(_ condition: () -> Bool) async {
        let start = ProcessInfo.processInfo.systemUptime
        while !condition() && ProcessInfo.processInfo.systemUptime - start < 2 { await Task.yield() }
        precondition(condition())
    }
    await waitFor { model.activeCall?.offers == 1 }
    let first = model.activeCall!
    let client = first.webRTCClient!
    WebRTCClient.audioQueue.sync { precondition(rtc.useManualAudio && rtc.isAudioEnabled) }
    let earlyTrack = client.createAudioTrack()
    precondition(manager.enableMedia(source: .mic, enable: false, callUUID: first.callUUID!))
    first.updateMicrophonePermission(true)
    precondition(!earlyTrack.isEnabled && !first.localMediaSources.mic)
    precondition(manager.enableMedia(source: .mic, enable: true, callUUID: first.callUUID!))
    first.updateMicrophonePermission(false)
    precondition(!first.localMediaSources.mic)
    first.updateMicrophonePermission(true)
    precondition(earlyTrack.isEnabled && first.localMediaSources.mic)
    await waitFor { first.offers == 3 }
    let starts = XauXatRealtimeVoiceMasking.shared.beginnings
    first.attachWebRTC()
    precondition(first.webRTCClient === client && starts == XauXatRealtimeVoiceMasking.shared.beginnings)
    let track = client.createAudioTrack()
    let gate = Gate()
    client.blockMedia = { await gate.wait() }
    let media = Task { await first.callCommand.processCommand(.media(source: .mic, enable: true)) }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !(await gate.blocked) {
        precondition(ProcessInfo.processInfo.systemUptime < deadline)
        await Task.yield()
    }
    Manager.clearActiveCall(first)
    precondition(!track.isEnabled && !client.createAudioTrack().isEnabled)
    let replacement = Active(contact: .sampleData, callUUID: nil)
    model.activeCall = replacement
    replacement.attachWebRTC()
    let next = replacement.webRTCClient!
    WebRTCClient.audioQueue.sync {
        precondition(WebRTCClient.audioSessionOwner === next && rtc.isAudioEnabled && !rtc.useManualAudio)
        WebRTCClient.activatedAudioSession = true
    }
    precondition(!WebRTCClient.callKitAudioChanged(system, active: false))
    precondition(rtc.isAudioEnabled && rtc.notifications == [true, false])
    await first.callCommand.finish()
    await gate.release()
    await media.value
    WebRTCClient.audioQueue.sync { precondition(rtc.releases == 0 && rtc.resets == 0) }
    precondition(first.offers == 3 && replacement.offers == 0)
    await first.callCommand.processCommand(.start(media: .audio, aesKey: nil, iceServers: nil, relay: false))
    Manager.clearActiveCall(replacement)
    await replacement.callCommand.finish()
    WebRTCClient.audioQueue.sync { precondition(rtc.releases == 1 && rtc.resets == 1) }
    let outgoing = Active(contact: .sampleData, callUUID: UUID().uuidString)
    model.activeCall = outgoing
    precondition(manager.startOutgoingCall(callUUID: outgoing.callUUID!))
    await waitFor { outgoing.offers == 1 }
    outgoing.attachWebRTC()
    precondition(outgoing.webRTCClient != nil && outgoing.offers == 1)
    Manager.clearActiveCall(outgoing)
    await outgoing.callCommand.finish()
    print("Native incoming offer and outgoing invitation work without a view. Remount, microphone permissions after mute, prior activation, late native deactivation, old capture and teardown ownership passed.")
}
