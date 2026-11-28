import Foundation

typealias ChatId = String
public typealias LocalizedStringKey = String
public struct User: Decodable {
    var userId = 1
    var showNotifications = true
    static let sampleData = User()
}
public struct Contact: Decodable {
    var id = "A"
    var calls = true
    static let sampleData = Contact()
}
public struct CallCapabilities: Decodable { let encryption: Bool }
public struct CallType: Decodable {
    enum Media: String, Decodable { case audio, video }
    let media: Media
    let capabilities: CallCapabilities
}
func xauXatContactInvitePermissions(_ contact: Contact) -> Contact { contact }
typealias Call = Active
final class Active {
    enum Direction { case incoming }
    enum State { case invitationAccepted }
    var contact: Contact
    let callUUID: String?
    var initialCallType = CallType.Media.audio
    var speakerEnabled = false
    var microphoneRequested = true
    struct Sources { var mic = true }; var localMediaSources = Sources()
    let callCommand = WebRTCCommandProcessor()
    var webRTCClient: WebRTCClient?
    var usesCallKit: Bool { ModeFixture(callUUID: callUUID).usesCallKit }
    var localRendererAspectRatio: CGFloat?
    var didConnectWebRTC = false
    var offers = 0
    init(contact: Contact, callUUID: String?) {
        self.contact = contact
        self.callUUID = callUUID
    }
    convenience init(direction: Direction, contact: Contact, callUUID: String?, callState: State,
                     initialCallType: CallType.Media, sharedKey: String?, startWithModifiedVoice: Bool) {
        self.init(contact: contact, callUUID: callUUID)
    }
}
final class ChatModel {
    static let shared = ChatModel()
    var callInvitations: [String: RcvCallInvitation] = [:]
    var currentUser: User? = User.sampleData
    var chatInitialized = true
    var chatRunning: Bool? = true
    var showCallView = false
    var activeCall: Active?
    var ntfCallInvitationAction: (String, Int)?
}
var serverInvitations: [RcvCallInvitation] = []
func apiGetCallInvitations() async throws -> [RcvCallInvitation] { serverInvitations }

struct CXErrorCodeIncomingCallError: Error {
    enum Code { case unknown, unentitled, callUUIDAlreadyExists, filteredByDoNotDisturb }
    let code: Code
}
final class NtfManager {
    static let shared = NtfManager()
    func notifyCallInvitation(_ invitation: RcvCallInvitation) {}
}
final class CallController {
    static var enabled = true
    static func useCallKit() -> Bool { enabled }
    static let shared = CallController()
    var endedByContact: [String] = []
    var answeredUUID: String?
    func endCall(call: Active, completed: @escaping () -> Void) {
        endedByContact.append(call.contact.id)
        // The core addresses /_call end by contact and replaces that entry on a new invitation.
        ChatModel.shared.callInvitations.removeValue(forKey: call.contact.id)
        ChatModel.shared.activeCall = nil
        completed()
    }
    func reportCallRemoteEnded(call: Active) {}
    func answerCall(invitation: RcvCallInvitation, startWithModifiedVoice: Bool) {
        guard ChatModel.shared.callInvitations[invitation.contact.id]?.matches(invitation) == true else { return }
        answeredUUID = invitation.callUUID
    }
    var presentations = 0
    var activeCallInvitation: RcvCallInvitation?
    var latest: RcvCallInvitation?
    var completion: ((Error?) -> Void)?
    func reportNewIncomingCall(invitation: RcvCallInvitation, completion: @escaping (Error?) -> Void) {
        latest = invitation; presentations += 1; self.completion = completion
    }
    func callAction(invitation: RcvCallInvitation, action: Int) {}
}

@MainActor
func verifyInvitations() async throws {
    let model = ChatModel.shared, controller = CallController.shared
    var mode = ModeFixture(callUUID: nil)
    precondition(!mode.usesCallKit)
    mode.callUUID = "invalid"
    precondition(!mode.usesCallKit)
    mode.callUUID = UUID().uuidString
    precondition(mode.usesCallKit)
    CallController.enabled = false
    precondition(!mode.usesCallKit)
    CallController.enabled = true
    func decode(_ uuidField: String) throws -> RcvCallInvitation {
        let data = Data("""
        {"user":{"userId":1,"showNotifications":true},"contact":{"id":"A","calls":true},
        "callType":{"media":"audio","capabilities":{"encryption":true}},"callTs":1\(uuidField)}
        """.utf8)
        return try JSONDecoder().decode(RcvCallInvitation.self, from: data)
    }
    let absent = try decode(""), null = try decode(",\"callUUID\":null")
    var native = try decode(",\"callUUID\":\"native\"")
    native.callTs = Date()
    precondition(absent.callUUID == nil && null.callUUID == nil && native.callUUID == "native")
    model.callInvitations["A"] = absent
    activateCall(absent)
    precondition(controller.presentations == 1, "A nil UUID with no active call can ring")
    model.activeCall = Active(contact: absent.contact, callUUID: nil)
    activateCall(absent)
    precondition(controller.presentations == 1)
    model.activeCall?.contact.id = "another"
    activateCall(absent)
    precondition(controller.presentations == 2)
    model.activeCall = nil
    model.callInvitations["A"] = nil
    activateCall(absent)
    precondition(controller.presentations == 2, "Cancelled invitation cannot be presented by a late callback")
    var denied = native
    denied.contact.id = "blocked"; denied.contact.calls = false
    denied.callTs = native.callTs.addingTimeInterval(10)
    serverInvitations = [native, denied]
    try await refreshCallInvitations()
    precondition(model.callInvitations["blocked"] == nil && controller.latest?.callUUID == "native" && controller.presentations == 3)
    for code: CXErrorCodeIncomingCallError.Code in [.callUUIDAlreadyExists, .filteredByDoNotDisturb] {
        controller.completion?(CXErrorCodeIncomingCallError(code: code))
        await Task.yield()
        precondition(model.callInvitations["A"]?.callUUID == "native")
    }
    for code: CXErrorCodeIncomingCallError.Code in [.unentitled, .unknown] {
        model.callInvitations["A"] = native
        controller.completion?(CXErrorCodeIncomingCallError(code: code))
        await withCheckedContinuation { cont in DispatchQueue.main.async { cont.resume() } }
        precondition(model.callInvitations["A"]?.callUUID == nil && controller.activeCallInvitation?.matches(model.callInvitations["A"]!) == true)
        controller.activeCallInvitation = nil
    }
    var replacement = native; replacement.callUUID = "new"; replacement.callTs = Date()
    model.callInvitations["A"] = replacement
    controller.completion?(CXErrorCodeIncomingCallError(code: .unknown))
    await withCheckedContinuation { cont in DispatchQueue.main.async { cont.resume() } }
    precondition(model.callInvitations["A"]?.callUUID == "new")
    let banner = BannerFixture()
    model.activeCall = Active(contact: replacement.contact, callUUID: "previous")
    banner.answer(replacement, startWithModifiedVoice: false)
    await withCheckedContinuation { cont in DispatchQueue.main.async { cont.resume() } }
    precondition(controller.endedByContact.isEmpty, "Ending the previous call by contact cancels its replacement")
    precondition(controller.answeredUUID == replacement.callUUID && model.activeCall == nil)

    controller.answeredUUID = nil
    let duplicate = Active(contact: replacement.contact, callUUID: replacement.callUUID)
    model.activeCall = duplicate
    banner.answer(replacement, startWithModifiedVoice: false)
    precondition(model.activeCall === duplicate && controller.answeredUUID == nil)

    let other = Contact(id: "other")
    model.activeCall = Active(contact: other, callUUID: "other-call")
    banner.answer(native, startWithModifiedVoice: false)
    precondition(model.activeCall?.contact.id == other.id, "A stale banner must not hang up a current call")
    banner.answer(replacement, startWithModifiedVoice: false)
    await withCheckedContinuation { cont in DispatchQueue.main.async { cont.resume() } }
    precondition(controller.endedByContact == [other.id] && controller.answeredUUID == replacement.callUUID)
    print("Incoming invitation decoder, permissions, stale and duplicate events, and consecutive in-app calls passed.")
}
