import Foundation

// Keep Keychain I/O deterministic while executing the production policy code.
enum XauXatStorageScope { case primary, decoy }
var scope = XauXatStorageScope.primary
func xauXatStorageScope() -> XauXatStorageScope { scope }
var values: [String: String] = [:]
var failRemoval = false
var failSave = false
let policyTestDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
func getAppDirectory(_ storage: XauXatStorageScope) -> URL {
    let directory = policyTestDirectory.appendingPathComponent(storage == .primary ? "primary" : "decoy")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
func excludeFromSystemBackup(_ url: URL) -> Bool { true }
struct KeyChainItem {
    let forKey: String
    func get() -> String? { values[forKey] }
    func set(_ value: String) -> Bool {
        if failSave { return false }
        values[forKey] = value; return true
    }
    func remove() -> Bool {
        if failRemoval { return false }
        values[forKey] = nil
        return true
    }
}
let kcPrimaryContactInvitePolicies = KeyChainItem(forKey: "primary")
let kcDecoyContactInvitePolicies = KeyChainItem(forKey: "decoy")
let xauXatContactInvitePoliciesLock = NSLock()

// Exercise the actual accepted-link flow; native allocation and presentation
// are adapters, while policy serialization and the connection callback are real.
struct CreatedConnLink {}
struct ConnectionPlan {}
enum ConnReqType { case invitation, contact }
struct PendingContactConnection {
    var pccConnId: Int64
    var apiId: Int64 { pccConnId }
    var id: String { ":\(pccConnId)" }
}
var nextConnection: (ConnReqType, PendingContactConnection)?
struct Connection { var connId: Int64 }
struct Contact {
    var contactId: Int64
    var activeConn: Connection? = nil
    var apiId: Int64 { contactId }
    var id: String { "@\(contactId)" }
}
enum ChatInfo {
    case direct(Contact), contactConnection(PendingContactConnection)
    var contact: Contact? { if case let .direct(contact) = self { return contact }; return nil }
}
struct Chat { var id: String; var chatInfo: ChatInfo }
struct User { var userId: Int64 = 1 }
struct MsgContent {}
enum APIResult<R> { case result(R) }
enum ChatResponse1 {
    case sentConfirmation(Int, PendingContactConnection)
    case sentInvitation(Int, PendingContactConnection)
    case contactAlreadyExists(Int, Contact)
    case startedConnectionToContact(Int, Contact)
}
enum ChatCommand {
    case apiConnect(userId: Int64, incognito: Bool, connLink: CreatedConnLink)
    case apiConnectPreparedContact(contactId: Int64, incognito: Bool, msg: MsgContent?)
}
var nextPreparedContact: Contact?
var knownContact: Contact?
var onNativeReply: (() -> Void)?
func chatApiSendCmdWithRetry(_ command: ChatCommand) async -> APIResult<ChatResponse1>? {
    onNativeReply?()
    switch command {
    case .apiConnect:
        if let knownContact { return .result(.contactAlreadyExists(1, knownContact)) }
        guard let (kind, connection) = nextConnection else { return nil }
        if case .invitation = kind { return .result(.sentConfirmation(1, connection)) }
        return .result(.sentInvitation(1, connection))
    case .apiConnectPreparedContact:
        if let knownContact { return .result(.contactAlreadyExists(1, knownContact)) }
        return nextPreparedContact.map { .result(.startedConnectionToContact(1, $0)) }
    }
}
final class ChatModel {
    static let shared = ChatModel()
    var updatedConnections: [Int64] = []
    var currentUser: User? = User()
    var preparedContact: Contact?
    var chats: [Chat] = []
    struct ShowingInvitation { var pcc: PendingContactConnection }
    var showingInvitation: ShowingInvitation?
    func removeChat(_ id: String) { chats.removeAll { $0.id == id } }
    func getContactChat(_ id: Int64) -> Chat? {
        guard let contact = preparedContact, contact.contactId == id else { return nil }
        return Chat(id: "@\(id)", chatInfo: .direct(contact))
    }
    func updateContactConnection(_ connection: PendingContactConnection) {
        updatedConnections.append(connection.pccConnId)
    }
}
final class AlertManager {
    static let shared = AlertManager()
    func showAlert(_ alert: Int) {}
    var errors = 0
    func showAlertMsg(title: String, message: String) { errors += 1 }
}
final class ItemsModel {
    static let shared = ItemsModel()
    func loadOpenChat(_ id: String) {}
}
struct Logger { func error(_ text: String) {} }
let logger = Logger()
enum ChatType { case contactConnection, direct }
var deletedPendingConnections: [Int64] = []
var deletedDirectConnections: [Int64] = []
func apiDeleteChat(type: ChatType, id: Int64) async throws {
    switch type {
    case .contactConnection: deletedPendingConnections.append(id)
    case .direct: deletedDirectConnections.append(id)
    }
}
func apiConnectResponseAlert<R>(_ result: APIResult<R>) async {}
func contactAlreadyExistsAlert(_ contact: Contact) async {}
func connReqSentAlert(_ type: ConnReqType) -> Int { 0 }
func planToConnReqType(_ plan: ConnectionPlan) -> ConnReqType? { nil }
func dismissAllSheets(animated: Bool, completion: (() -> Void)? = nil) { completion?() }

@main struct InvitePolicyTests {
    static var checks = 0
    static func require(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError(message) }
    }
    static func acceptLink(permissions: XauXatContactInvitePermissions? = nil, expiresAt: Date? = nil) async {
        await withCheckedContinuation { done in
            connectViaLink(CreatedConnLink(), connectionPlan: nil, dismiss: false, incognito: false,
                xauXatExpiresAt: expiresAt, xauXatPermissions: permissions, cleanup: { done.resume() })
        }
    }

    static func main() async {
        defer { try? FileManager.default.removeItem(at: policyTestDirectory) }
        let now = Date(timeIntervalSince1970: 1_000)
        let old = XauXatContactInvitePolicy(connectionId: 7, createdAt: now, bundleId: "old-bundle", maxUses: 2)
        require(xauXatSaveContactInvitePolicy(old), "Store the old database's restricted invite")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked, "A reused numeric ID alone retrieves the old database's revoked invitation")
        scope = .decoy
        require(xauXatSaveContactInvitePolicy(old), "Seed the separate local profile")
        scope = .primary
        require(xauXatRemoveContactInvitePolicies(.primary), "A new/deleted primary database clears its old invite policies")
        require(xauXatObserveContactInvitePolicy(connectionId: 7) == nil, "Reused connection IDs cannot inherit Revoked or the old bundle after database replacement")
        scope = .decoy
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.maxUses == 2, "Resetting one database must preserve the other local profile's policies")
        scope = .primary
        require(xauXatRemoveContactInvitePolicies(.primary), "Cleanup is idempotent")

        require(xauXatSaveContactInvitePolicy(old), "Seed an already affected installation")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        let fresh = XauXatContactInvitePolicy(connectionId: 7, createdAt: now.addingTimeInterval(60))
        require(xauXatSaveContactInvitePolicy(fresh), "A newly allocated invite always writes a fresh policy, including Free invites")
        let observed = xauXatObserveContactInvitePolicy(connectionId: 7)!
        require(observed.state == .active && observed.bundleId == nil && observed.maxUses == nil, "An ordinary new invitation cannot inherit a stale bundle or revoked state")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        _ = xauXatSetContactInviteState(connectionId: 7, state: .active)
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked, "Existing revocations remain terminal; observing/reopening never reactivates them")
        failRemoval = true
        require(!xauXatRemoveContactInvitePolicies(.primary), "Cleanup failures are reported so a fresh database cannot silently reuse old policies")
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked, "A failed cleanup does not silently rewrite stored data")
        failRemoval = false

        require(xauXatPendingContactInviteStatus([]) == "Active", "A pending native invite without an advanced policy is active, not Fully used or Revoked")
        require(xauXatPendingContactInviteStatus([fresh]) == "Active", "Fresh policy is active")
        var used = fresh
        used.state = .used
        var revoked = fresh
        revoked.state = .revoked
        var expired = fresh
        expired.state = .expired
        require(xauXatPendingContactInviteStatus([used, fresh]) == "Active", "A partially used bundle still has an active invite")
        require(xauXatPendingContactInviteStatus([used, used]) == "Fully used", "Only a nonempty fully consumed bundle is Fully used")
        require(xauXatPendingContactInviteStatus([revoked]) == "Revoked", "Revoked remains visible for genuinely revoked invitations")
        require(xauXatPendingContactInviteStatus([used, expired]) == "Expired", "Expiry is not mistaken for revocation")

        let linkedContact = Contact(contactId: 70, activeConn: Connection(connId: 7))
        ChatModel.shared.chats = [Chat(id: linkedContact.id, chatInfo: .direct(linkedContact))]
        await expirePendingXauXatContactInvites()
        require(deletedDirectConnections == [70], "A genuine revocation still reaches the existing native deletion path")
        deletedDirectConnections = []

        for connectionKind in [ConnReqType.invitation, .contact] {
          for staleState in [XauXatContactInviteState.revoked, .expired, .used] {
            let stale = XauXatContactInvitePolicy(connectionId: 7, createdAt: now,
                expiresAt: now.addingTimeInterval(1), permissions: .init(messages: false, calls: false),
                bundleId: "old-bundle", maxUses: 2)
            _ = xauXatSaveContactInvitePolicy(stale)
            _ = xauXatSetContactInviteState(connectionId: 7, state: staleState)
            nextConnection = (connectionKind, PendingContactConnection(pccConnId: 7))
            await acceptLink()
            let accepted = xauXatObserveContactInvitePolicy(connectionId: 7)!
            require(accepted.state == .active, "A plain accepted QR must replace a reused ID's old \(staleState) policy")
            require(accepted.expiresAt == nil && accepted.bundleId == nil && accepted.maxUses == nil,
                    "The new connection cannot inherit an old expiry or invitation bundle")
            require((accepted.permissions ?? .init()) == .init(), "An ordinary QR cannot inherit old message/call restrictions")
            require(xauXatContactInvitePolicies().first(where: { $0.connectionId == 7 })?.state == .active,
                    "Reloading policies for startup cleanup must preserve the new ordinary connection")
            ChatModel.shared.chats = [Chat(id: linkedContact.id, chatInfo: .direct(linkedContact))]
            await expirePendingXauXatContactInvites()
            require(deletedDirectConnections.isEmpty && ChatModel.shared.chats.count == 1,
                    "Actual foreground/startup cleanup must not delete the newly accepted contact")
            require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .used,
                    "Cleanup records the new connection as used rather than expiring the old invitation")
          }
        }

        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        await acceptLink(permissions: .init(messages: false, calls: true), expiresAt: expiry)
        let restricted = xauXatObserveContactInvitePolicy(connectionId: 7)!
        require(restricted.expiresAt == expiry && restricted.permissions == .init(messages: false, calls: true),
                "A new advanced QR still retains its own signed expiry and permissions")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        let beforeFailure = ChatModel.shared.updatedConnections.count
        nextConnection = nil
        await acceptLink()
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked,
                "Failed/already-known connections cannot revive an existing revoked invite")
        require(ChatModel.shared.updatedConnections.count == beforeFailure,
                "A failed connection does not publish a pending connection")
        knownContact = Contact(contactId: 7, activeConn: Connection(connId: 7))
        await acceptLink()
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked,
                "An already-known contact cannot reset an existing revocation")
        knownContact = nil

        nextConnection = (.invitation, PendingContactConnection(pccConnId: 7))
        failSave = true
        let beforeError = AlertManager.shared.errors
        let recoveredConnection = await apiConnect(incognito: false, connLink: CreatedConnLink())
        require(recoveredConnection != nil && AlertManager.shared.errors == beforeError,
                "A failed Keychain write must durably recover the newly accepted connection policy")
        require(deletedPendingConnections.isEmpty, "Recovery must not delete native connection history")
        let staleKeychain = values
        values = [:]
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .active,
                "Reopening from disk without Keychain must retain the fresh policy")
        values = staleKeychain
        ChatModel.shared.chats = [Chat(id: linkedContact.id, chatInfo: .direct(linkedContact))]
        await expirePendingXauXatContactInvites()
        require(deletedDirectConnections.isEmpty && ChatModel.shared.chats.count == 1,
                "Relaunch cleanup cannot delete a fresh contact after Keychain persistence fails")
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .used,
                "Policy state changes continue to persist while Keychain is unavailable")
        failSave = false
        _ = xauXatSetContactInviteState(connectionId: 7, state: .used)
        require(!FileManager.default.fileExists(atPath: contactInvitePolicyRecoveryURL(.primary).path),
                "The recovery copy is removed after current state reaches Keychain")

        ChatModel.shared.preparedContact = Contact(contactId: 99)
        nextPreparedContact = Contact(contactId: 99, activeConn: Connection(connId: 7))
        let prepared = await apiConnectPreparedContact(contactId: 99, incognito: false, msg: nil)
        require(prepared != nil && xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .active,
                "A prepared chat's first real connection must replace a stale reused ID policy")
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.expiresAt == nil,
                "The prepared connection cannot inherit a previous invitation's expiry")
        let existingPolicy = XauXatContactInvitePolicy(connectionId: 7, createdAt: .now,
            expiresAt: expiry, permissions: .init(messages: false, calls: true))
        _ = xauXatSaveContactInvitePolicy(existingPolicy)
        ChatModel.shared.preparedContact = nextPreparedContact
        knownContact = nextPreparedContact
        _ = await apiConnectPreparedContact(contactId: 99, incognito: false, msg: nil)
        require(xauXatObserveContactInvitePolicy(connectionId: 7) == existingPolicy,
                "The core's already-connected response keeps the connection's own expiry and permissions")
        knownContact = nil
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        _ = await apiConnectPreparedContact(contactId: 99, incognito: false, msg: nil)
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .active,
                "A successful retry must replace the reused ID policy even when the UI already knows the prepared connection")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        ChatModel.shared.preparedContact = Contact(contactId: 99)
        nextPreparedContact = nil
        _ = await apiConnectPreparedContact(contactId: 99, incognito: false, msg: nil)
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked,
                "A failed prepared connection cannot revive an old revocation")
        nextPreparedContact = Contact(contactId: 99, activeConn: Connection(connId: 7))
        deletedPendingConnections = []
        failSave = true
        scope = .decoy
        let originalDecoyPolicy = xauXatObserveContactInvitePolicy(connectionId: 7)
        scope = .primary
        let recoveredPrepared = await apiConnectPreparedContact(contactId: 99, incognito: false, msg: nil)
        require(recoveredPrepared != nil && deletedPendingConnections.isEmpty,
                "A prepared join also survives failed Keychain persistence without deleting history")
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .active,
                "Prepared-policy recovery supersedes the stale revocation on disk")
        scope = .decoy
        require(xauXatObserveContactInvitePolicy(connectionId: 7) == originalDecoyPolicy,
                "A recovery policy cannot leak into the other storage scope")
        scope = .primary
        failSave = false
        _ = xauXatSetContactInviteState(connectionId: 7, state: .active)

        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        scope = .decoy
        _ = xauXatSaveContactInvitePolicy(existingPolicy)
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        scope = .primary
        for changeStorage in [true, false] {
            let beforeSwitchError = AlertManager.shared.errors
            onNativeReply = {
                if changeStorage { scope = .decoy }
                else { ChatModel.shared.currentUser = User(userId: 2) }
            }
            let switched = await apiConnect(incognito: false, connLink: CreatedConnLink())
            require(switched == nil && xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked,
                    "Storage and user switches independently prevent new-connection policy writes")
            require(AlertManager.shared.errors == beforeSwitchError,
                    "A superseded connection cannot present a storage error over the new profile")
            scope = .primary
            ChatModel.shared.currentUser = User()
            let switchedPrepared = await apiConnectPreparedContact(contactId: 99, incognito: false, msg: nil)
            require(switchedPrepared == nil && xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked,
                    "Prepared connections also reject storage and user switches independently")
            onNativeReply = nil
            scope = .primary
            ChatModel.shared.currentUser = User()
            require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked,
                    "The original policy remains unchanged after either type of supersession")
        }
        failSave = true
        require(xauXatSaveContactInvitePolicy(existingPolicy), "Advanced permissions survive failed Keychain writes too")
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.permissions == existingPolicy.permissions,
                "Recovery retains the new link's own message and call restrictions")
        let future = expiry.addingTimeInterval(1)
        require(xauXatObserveContactInvitePolicy(connectionId: 7, at: future)?.state == .expired,
                "Expiry remains enforceable while the recovery copy is authoritative")
        require(xauXatRemoveContactInvitePolicies(.primary), "Database reset removes the recovery copy as well as Keychain state")
        require(xauXatObserveContactInvitePolicy(connectionId: 7) == nil, "A recovery copy cannot survive database replacement")
        scope = .decoy
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked,
                "Resetting recovered primary policies preserves the alternate profile")
        scope = .primary
        failSave = false
        print("Production invite policy regression checks passed: \(checks)")
    }
}
