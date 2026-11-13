#if DEBUG
import Foundation
import SimpleXChat

/// Local test pairing. The invitation is exchanged over the developer's USB
/// connection. Only the explicitly selected synthetic contact uses this store.
@MainActor
final class XauXatDirectCallTest {
    static let shared = XauXatDirectCallTest()

    private struct Pairing: Decodable {
        let contactName: String
        let role: Role
        enum Role: String, Decodable { case invite, join }
    }

    private var enabled: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return Bundle.main.bundleIdentifier == "pt.exsoria.xauxat.llvcprototype"
        #endif
    }
    var canOpenLocalProfile: Bool {
        pairing != nil && !xauXatRequiresUnlockBeforeInitialization()
    }
    var holdsTorForTest: Bool {
        canOpenLocalProfile && UserDefaults.standard.bool(forKey: "xauxatHoldTorForCallTest")
    }
    private var control: chat_ctrl?
    private var testUser: User?
    private var peer: Contact?
    private var incoming: RcvCallInvitation?
    private var setup: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    private var directory: URL {
        getDocumentsDirectory().appendingPathComponent("direct-call-test", isDirectory: true)
    }

    private var pairing: Pairing? {
        guard enabled, xauXatStorageScope() == .primary,
              let data = try? Data(contentsOf: directory.appendingPathComponent("pairing.json"))
        else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    private func localContact() -> Contact? {
        guard let pairing, xauXatAppIsForeground(),
              AppChatState.shared.value != .stopped,
              (!UserDefaults.standard.bool(forKey: DEFAULT_PERFORM_LA)
               || ChatModel.shared.contentViewAccessAuthenticated) else { return nil }
        let matches = ChatModel.shared.chats.compactMap { chat -> Contact? in
            guard case let .direct(contact) = chat.chatInfo,
                  (contact.displayName == pairing.contactName || contact.chatViewName == pairing.contactName), contact.ready,
                  xauXatContactInvitePermissions(contact).calls else { return nil }
            return contact
        }
        return matches.count == 1 ? matches.first : nil
    }

    func start() {
        guard pairing != nil, localContact() != nil, setup == nil, reader == nil else { return }
        setup = Task {
            defer { setup = nil }
            do {
                guard let pairing else { return }
                let ctrl = try await open()
                guard let testUser else { return }
                let list: ChatResponse1 = try await chatSendCmd(.apiListContacts(userId: testUser.userId), ctrl: ctrl, log: false)
                guard case let .contactsList(_, contacts) = list, contacts.count <= 1 else {
                    throw RuntimeError("Unexpected call test contacts")
                }
                peer = contacts.first(where: { $0.ready })
                if contacts.isEmpty {
                    switch pairing.role {
                    case .invite:
                        let output = directory.appendingPathComponent("invitation.txt")
                        if !FileManager.default.fileExists(atPath: output.path) {
                            let result: ChatResponse1 = try await chatSendCmd(.apiAddContact(userId: testUser.userId, incognito: false), ctrl: ctrl, log: false)
                            guard case let .invitation(_, link, _) = result else { throw result.unexpected }
                            try Data(link.connFullLink.utf8).write(to: output, options: [.atomic, .completeFileProtection])
                        }
                    case .join:
                        let input = directory.appendingPathComponent("join.txt")
                        if FileManager.default.fileExists(atPath: input.path) {
                            let link = try String(contentsOf: input, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard let url = URLComponents(string: link), url.scheme == "simplex",
                                  url.path == "/invitation", url.fragment != nil, link.utf8.count <= 8192,
                                  !link.contains(where: \.isWhitespace) else { throw RuntimeError("Invalid local call invitation") }
                            let result: ChatResponse1 = try await chatSendCmd(.apiConnect(userId: testUser.userId, incognito: false,
                                connLink: CreatedConnLink(connFullLink: link, connShortLink: nil)), ctrl: ctrl, log: false)
                            guard case .sentConfirmation = result else { throw result.unexpected }
                            try FileManager.default.removeItem(at: input)
                        }
                    }
                }
                XauXatCallTiming.mark(peer == nil ? "direct.waiting_for_pair" : "direct.paired")
                listen(ctrl)
            } catch {
                XauXatCallTiming.mark("direct.setup_failed")
                logger.error("Dedicated SMP call test setup failed: \(responseError(error), privacy: .private)")
            }
        }
    }

    func usesDirectSignaling(for contact: Contact) -> Bool {
        guard let name = pairing?.contactName else { return false }
        return contact.displayName == name || contact.chatViewName == name
    }

    private func open() async throws -> chat_ctrl {
        if let control, testUser != nil { return control }
        let ctrl: chat_ctrl
        if let control {
            ctrl = control
        } else {
            guard excludeFromSystemBackup(directory), let key = xauXatDirectCallTestDatabaseKey() else {
                throw RuntimeError("Call test storage unavailable")
            }
            let (status, handle) = chatInitTemporaryDatabase(url: directory.appendingPathComponent("calls"), key: key)
            guard status == .ok, let handle else { throw RuntimeError("Could not open call test storage") }
            ctrl = handle
            control = handle
        }
        var config = NetCfg.defaults
        config.smpProxyMode = .never
        config.smpWebPortServers = .all
        let user = try apiGetActiveUser(ctrl: ctrl) ?? apiCreateActiveUser(Profile(displayName: "XauXat call test", fullName: ""), ctrl: ctrl)
        try await sendOK(.apiSetNetworkConfig(networkConfig: config), ctrl)
        let result: ChatResponse0 = try await chatSendCmd(.startChat(mainApp: true, enableSndFiles: false), ctrl: ctrl, log: false)
        switch result {
        case .chatRunning, .chatStarted: break
        default: throw result.unexpected
        }
        testUser = user
        return ctrl
    }

    func sendIfSelected(_ contact: Contact, _ command: (Contact) -> ChatCommand) async throws -> Bool {
        guard usesDirectSignaling(for: contact) else { return false }
        start()
        await setup?.value
        guard localContact()?.apiId == contact.apiId, let peer, let control else {
            throw RuntimeError("Dedicated SMP call pairing is not ready")
        }
        let cmd = command(peer)
        switch cmd {
        case .apiSendCallInvitation, .apiRejectCall, .apiSendCallOffer, .apiSendCallAnswer,
             .apiSendCallExtraInfo, .apiEndCall, .apiCallStatus:
            XauXatCallTiming.mark("direct.\(cmd.cmdType)")
            try await sendOK(cmd, control)
            if case .apiEndCall = cmd { incoming = nil }
            if case .apiRejectCall = cmd { incoming = nil }
            return true
        default: throw RuntimeError("Command is outside the dedicated call protocol")
        }
    }

    private func sendOK(_ command: ChatCommand, _ ctrl: chat_ctrl) async throws {
        let result: ChatResponse2 = try await chatSendCmd(command, ctrl: ctrl, log: false)
        guard case .cmdOk = result else { throw result.unexpected }
    }

    func restoreIncomingInvitation() {
        guard let incoming, incoming.contact.apiId == localContact()?.apiId,
              ChatModel.shared.activeCall == nil, incoming.callTs.timeIntervalSinceNow >= -60 else { return }
        ChatModel.shared.callInvitations[incoming.contact.id] = incoming
    }

    private func listen(_ ctrl: chat_ctrl) {
        guard reader == nil else { return }
        let address = UInt(bitPattern: ctrl)
        reader = Task {
            let nativeReader = DispatchQueue(label: "pt.exsoria.xauxat.direct-call-test")
            while !Task.isCancelled {
                let event: APIResult<ChatEvent>? = await withCheckedContinuation { continuation in
                    nativeReader.async {
                        let event: APIResult<ChatEvent>? = UnsafeMutableRawPointer(bitPattern: address).flatMap {
                            recvSimpleXMsg($0)
                        }
                        continuation.resume(returning: event)
                    }
                }
                if case let .result(event) = event { await receive(event) }
            }
        }
    }

    private func receive(_ event: ChatEvent) async {
        let model = ChatModel.shared
        guard let contact = localContact(), let user = model.currentUser else { return }
        if case let .contactConnected(_, connected, _) = event {
            guard peer == nil || peer?.apiId == connected.apiId else { return }
            peer = connected
            XauXatCallTiming.mark("direct.paired")
            return
        }
        guard let peer else { return }
        switch event {
        case let .callInvitation(inv) where inv.contact.apiId == peer.apiId:
            guard inv.callType.capabilities.encryption, inv.sharedKey != nil,
                  inv.callTs.timeIntervalSinceNow >= -60, model.activeCall == nil,
                  model.callInvitations[contact.id] == nil else { return }
            var mapped = inv
            mapped.contact = contact
            mapped.user = user
            incoming = mapped
            await processReceivedMsg(.callInvitation(callInvitation: mapped))
        case let .callOffer(source, remote, type, offer, key, confirmation) where remote.apiId == peer.apiId:
            guard type.capabilities.encryption, key != nil else { return }
            await processReceivedMsg(.callOffer(user: source, contact: contact, callType: type, offer: offer, sharedKey: key, askConfirmation: confirmation))
        case let .callAnswer(source, remote, answer) where remote.apiId == peer.apiId:
            await processReceivedMsg(.callAnswer(user: source, contact: contact, answer: answer))
        case let .callExtraInfo(source, remote, info) where remote.apiId == peer.apiId:
            await processReceivedMsg(.callExtraInfo(user: source, contact: contact, extraInfo: info))
        case let .callEnded(source, remote) where remote.apiId == peer.apiId:
            incoming = nil
            await processReceivedMsg(.callEnded(user: source, contact: contact))
        default: break
        }
    }
}
#endif
