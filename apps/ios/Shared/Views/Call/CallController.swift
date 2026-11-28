//
//  CallController.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 21/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//
// Spec: spec/services/calls.md

import Foundation
import SwiftUI
import CallKit
import StoreKit
import PushKit
import AVFoundation
import SimpleXChat
import WebRTC

// Spec: spec/services/calls.md#CallController
class CallController: NSObject, CXProviderDelegate, PKPushRegistryDelegate, ObservableObject {
    static let shared = CallController()
    static let isInChina = SKStorefront().countryCode == "CHN"
    static func useCallKit() -> Bool {
        #if DEBUG
        // The personally signed LLVC prototype uses the in-app call interface.
        if Bundle.main.bundleIdentifier == "pt.exsoria.xauxat.llvcprototype" {
            return false
        }
        #endif
        return !isInChina && callKitEnabledGroupDefault.get()
    }

    private let provider = CXProvider(configuration: {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = XauXatProductPolicy.videoCallsEnabled
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = UserDefaults.standard.bool(forKey: DEFAULT_CALL_KIT_CALLS_IN_RECENTS)
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.iconTemplateImageData = UIImage(named: "icon-transparent")?.pngData()
        return configuration
    }())
    private let controller = CXCallController()
    private let callManager = CallManager()
    @Published var activeCallInvitation: RcvCallInvitation?
    var shouldSuspendChat: Bool = false
    // One live call per provider. Retain its UUID for a late native end action.
    private var lastNativeCallUUID: UUID?
    private var fulfillOnConnect: CXAnswerCallAction?
    private var pendingPushes: [UUID: Date] = [:]

    // PKPushRegistry is used from notification service extension
    private let registry = PKPushRegistry(queue: nil)

    override init() {
        super.init()
        provider.setDelegate(self, queue: nil)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func providerDidReset(_ provider: CXProvider) {
        logger.debug("CallController.providerDidReset")
        _ = WebRTCClient.callKitAudioChanged(AVAudioSession.sharedInstance(), active: false)
        fulfillOnConnect = nil
        pendingPushes.removeAll()
        lastNativeCallUUID = nil
    }

    // Spec: spec/services/calls.md#CXStartCallAction
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        logger.debug("CallController.provider CXStartCallAction")
        if callManager.startOutgoingCall(callUUID: action.callUUID.uuidString.lowercased()) {
            lastNativeCallUUID = action.callUUID
            action.fulfill()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        } else {
            action.fail()
        }
    }

    // Spec: spec/services/calls.md#CXAnswerCallAction
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        logger.debug("CallController.provider CXAnswerCallAction")
        fulfillOnConnect = action
        Task { @MainActor in
            let chatIsReady = await waitUntilChatStarted(for: action)
            guard canAnswer(action) else { return }
            if !chatIsReady {
                finishAnswer(for: action.callUUID, connected: false)
                return
            }
            let callUUID = action.callUUID.uuidString.lowercased()
            if !ChatModel.shared.callInvitations.values.contains(where: { $0.callUUID == callUUID }) {
                try? await justRefreshCallInvitations()
            }
            guard canAnswer(action) else { return }
            // CallKit activates lock-screen audio after WebRTC connects.
            if callManager.answerIncomingCall(callUUID: callUUID) {
                lastNativeCallUUID = action.callUUID
            } else {
                finishAnswer(for: action.callUUID, connected: false)
            }
        }
    }

    // Spec: spec/services/calls.md#CXEndCallAction
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        logger.debug("CallController.provider CXEndCallAction")
        let reportedPush = pendingPushes[action.callUUID] != nil
        finishAnswer(for: action.callUUID, connected: false)
        callManager.endCall(callUUID: action.callUUID.uuidString.lowercased()) { ok in
            if ok || reportedPush || self.lastNativeCallUUID == action.callUUID {
                action.fulfill()
            } else {
                action.fail()
            }
            self.suspendOnEndCall()
        }
    }

    // Spec: spec/services/calls.md#CXSetMutedCallAction
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if callManager.enableMedia(source: .mic, enable: !action.isMuted, callUUID:  action.callUUID.uuidString.lowercased()) {
            action.fulfill()
        } else {
            action.fail()
        }
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        logger.debug("timed out: \(String(describing: action))")
        if let answer = fulfillOnConnect, answer.uuid == action.uuid {
            fulfillOnConnect = nil
            pendingPushes.removeValue(forKey: answer.callUUID)
            callManager.endCall(callUUID: answer.callUUID.uuidString.lowercased()) { _ in }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        logger.debug("CallController: activating audioSession and audio in WebRTCClient")
        guard WebRTCClient.callKitAudioChanged(audioSession, active: true) else { return }
        let callAtActivation = ChatModel.shared.activeCall
        do {
            let hasVideo = ChatModel.shared.activeCall?.hasVideo == true
            if hasVideo {
                try audioSession.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
            } else {
                try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
            }
            // Without any delay sound is not playing from speaker or external device in incoming call
            Task { @MainActor in
                for i in 0 ... 3 {
                    try? await Task.sleep(nanoseconds: UInt64(i) * 300_000000)
                    guard let callAtActivation, ChatModel.shared.activeCall === callAtActivation,
                          WebRTCClient.callKitAudioActive else { return }
                    if let preferred = audioSession.preferredInputDevice() {
                        try? audioSession.setPreferredInput(preferred)
                    } else if hasVideo {
                        try? audioSession.overrideOutputAudioPort(.speaker)
                    }
                }
            }
            logger.debug("audioSession category set")
        } catch {
            logger.error("failed activating audio session")
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        logger.debug("CallController: deactivating audioSession and audio in WebRTCClient")
        _ = WebRTCClient.callKitAudioChanged(audioSession, active: false)
        suspendOnEndCall()
    }

    func suspendOnEndCall() {
        if shouldSuspendChat {
            // The delay allows to accept the second call before suspending a chat
            // see `.onChange(of: scenePhase)` in SimpleXApp
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                logger.debug("CallController: shouldSuspendChat \(String(describing: self?.shouldSuspendChat))")
                if ChatModel.shared.activeCall == nil && self?.shouldSuspendChat == true {
                    self?.shouldSuspendChat = false
                    suspendChat()
                    BGManager.shared.schedule()
                }
            }
        }
    }

    @MainActor
    private func waitUntilChatStarted(for action: CXAnswerCallAction) async -> Bool {
        let deadline = min(action.timeoutDate, Date().addingTimeInterval(30))
        var requestedActivation = false
        let model = ChatModel.shared
        while canAnswer(action), Date() < deadline {
            let state = AppChatState.shared.value
            if state == .stopped || xauXatRecoverySessionState() == .unlockRequired { return false }
            if let expiry = pendingPushes[action.callUUID], expiry <= Date() { return false }
            if model.chatInitialized, model.chatRunning == true {
                if state == .active && isChatStoreOpen() { return true }
                // A foreground invitation can reach CallKit without a PushKit wake.
                if pendingPushes[action.callUUID] == nil, !requestedActivation, state != .activating,
                   xauXatRecoverySessionState() == .suspended, isXauXatTorReady(),
                   let userId = model.currentUser?.userId {
                    let scope = xauXatStorageScope()
                    requestedActivation = true
                    if !xauXatAppIsForeground() { shouldSuspendChat = true }
                    startChatAndActivate(ifAllowed: {
                        self.canAnswer(action) && xauXatRecoverySessionState().canRecover && isXauXatTorReady()
                            && model.currentUser?.userId == userId && xauXatStorageScope() == scope
                    }) {}
                    if AppChatState.shared.value == .active && isChatStoreOpen() { return true }
                }
            }
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return false }
        }
        return false
    }

    @objc(pushRegistry:didUpdatePushCredentials:forType:)
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        logger.debug("CallController: didUpdate push credentials for type \(type.rawValue)")
    }

    // Spec: spec/services/calls.md#pushRegistryDidReceive
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        logger.debug("CallController: did receive push with type \(type.rawValue)")
        if type != .voIP {
            completion()
            return
        }
        if AppChatState.shared.value == .stopped {
            self.reportExpiredCall(payload: payload, completion)
            return
        }
        // Extract the call information from the push notification payload
        let m = ChatModel.shared
        if let contactId = payload.dictionaryPayload["contactId"] as? String,
           let displayName = payload.dictionaryPayload["displayName"] as? String,
           let callUUID = payload.dictionaryPayload["callUUID"] as? String,
           let uuid = UUID(uuidString: callUUID),
           let callTsInterval = payload.dictionaryPayload["callTs"] as? TimeInterval,
           let mediaStr = payload.dictionaryPayload["media"] as? String,
           let media = CallMediaType(rawValue: mediaStr) {
            let update = self.cxCallUpdate(contactId, displayName, media)
            let callTs = Date(timeIntervalSince1970: callTsInterval)
            if callTs.timeIntervalSinceNow >= -180 {
                logger.debug("CallController: report pushkit call via CallKit")
                pendingPushes = pendingPushes.filter { $0.value > Date() }
                let expires = min(callTs, Date()).addingTimeInterval(180)
                pendingPushes[uuid] = expires
                provider.reportNewIncomingCall(with: uuid, update: update) { error in
                    completion()
                    Task { @MainActor in
                        guard self.pendingPushes[uuid] == expires else { return }
                        if let error, !Self.alreadyReported(error) {
                            self.pendingPushes.removeValue(forKey: uuid)
                            guard m.callInvitations[contactId]?.callUUID == callUUID else { return }
                            m.callInvitations.removeValue(forKey: contactId)
                        } else {
                            await self.prepareChatForPush(uuid, expires: expires)
                        }
                    }
                }
            } else {
                logger.debug("CallController will expire call 1")
                self.reportExpiredCall(update: update, completion)
            }
        } else {
            logger.debug("CallController will expire call 2")
            self.reportExpiredCall(payload: payload, completion)
        }
    }

    @MainActor
    private func prepareChatForPush(_ uuid: UUID, expires: Date) async {
        let model = ChatModel.shared
        let scope = xauXatStorageScope()
        var userId = model.currentUser?.userId
        func canPrepare() -> Bool {
            if let answer = fulfillOnConnect, answer.callUUID == uuid, !canAnswer(answer) { return false }
            return pendingPushes[uuid] == expires && Date() < expires && AppChatState.shared.value != .stopped
                && xauXatStorageScope() == scope && model.currentUser?.userId == userId
                && !model.ctrlInitInProgress && model.migrationState == nil && !xauXatStoragePromotionPending()
                && xauXatRecoverySessionState() != .unlockRequired
                && (model.chatInitialized || !xauXatRequiresUnlockBeforeInitialization())
        }
        guard canPrepare() else { return }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + expires.timeIntervalSinceNow
            _ = try await EmbeddedTorManager.shared.readyBefore(deadline, maxAge: 15)
            guard canPrepare(), isXauXatTorReady() else { return }
            if !model.chatInitialized {
                guard v3DBMigrationDefault.get().startChat else { return }
                if !nseStateGroupDefault.get().inactive {
                    let suspended = await withCheckedContinuation { continuation in
                        waitNSESuspended(timeout: nseSuspendTimeout) { continuation.resume(returning: $0) }
                    }
                    guard suspended, nseStateGroupDefault.get().inactive,
                          canPrepare(), isXauXatTorReady() else { return }
                }
                try initializeChat(start: true, refreshInvitations: false)
                userId = model.currentUser?.userId
            } else {
                guard model.chatRunning == true else { return }
                _ = try applyXauXatRecoveryConfiguration()
            }
            guard canPrepare(), userId != nil, model.chatRunning == true else { return }
            if !xauXatAppIsForeground() { shouldSuspendChat = true }
            startChatAndActivate(ifAllowed: { canPrepare() && isXauXatTorReady() }) {}
        } catch {
            logger.error("CallController: could not prepare the private connection for the incoming call")
        }
    }

    // This function fulfils the requirement to always report a call when PushKit notification is received,
    // even when there is no more active calls by the time PushKit payload is processed.
    // See the note in the bottom of this article:
    // https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate/2875784-pushregistry
    private func reportExpiredCall(update: CXCallUpdate, _ completion: @escaping () -> Void) {
        logger.debug("CallController: report expired pushkit call via CallKit")
        let uuid = UUID()
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if error == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
                }
            }
            completion()
        }
    }

    private func reportExpiredCall(payload: PKPushPayload, _ completion: @escaping () -> Void) {
        let update = CXCallUpdate()
        let displayName = payload.dictionaryPayload["displayName"] as? String
        let media = payload.dictionaryPayload["media"] as? String
        update.localizedCallerName = displayName ?? NSLocalizedString("Unknown caller", comment: "callkit banner")
        update.hasVideo = false
        reportExpiredCall(update: update, completion)
    }

    static func alreadyReported(_ error: Error) -> Bool {
        (error as? CXErrorCodeIncomingCallError)?.code == .callUUIDAlreadyExists
    }

    static func allowsInAppFallback(after error: Error) -> Bool {
        guard let callKitError = error as? CXErrorCodeIncomingCallError else { return true }
        // Keep the native UUID for duplicates and calls suppressed by system policy.
        return callKitError.code == .unknown || callKitError.code == .unentitled
    }

    // Spec: spec/services/calls.md#reportNewIncomingCall
    func reportNewIncomingCall(invitation: RcvCallInvitation, completion: @escaping (Error?) -> Void) {
        logger.debug("CallController.reportNewIncomingCall, UUID=\(String(describing: invitation.callUUID))")
        if CallController.useCallKit(), let callUUID = invitation.callUUID, let uuid = UUID(uuidString: callUUID) {
            if invitation.callTs.timeIntervalSinceNow >= -180 {
                let update = cxCallUpdate(invitation: invitation)
                provider.reportNewIncomingCall(with: uuid, update: update, completion: completion)
            }
        } else {
            presentIncomingCallInApp(invitation)
        }
    }

    func presentIncomingCallInApp(_ invitation: RcvCallInvitation) {
        NtfManager.shared.notifyCallInvitation(invitation)
        if invitation.callTs.timeIntervalSinceNow >= -180 {
            activeCallInvitation = invitation
        }
    }

    private func cxCallUpdate(invitation: RcvCallInvitation) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: invitation.contact.id)
        update.hasVideo = false
        update.localizedCallerName = xauXatIsChatHidden(invitation.contact.id) || invitation.user.hidden || xauXatIsProfileProtected(invitation.user.userId)
            ? NSLocalizedString("XauXat call", comment: "hidden conversation callkit banner")
            : invitation.contact.displayName
        return update
    }

    private func cxCallUpdate(_ contactId: String, _ displayName: String, _ media: CallMediaType) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: contactId)
        update.hasVideo = false
        update.localizedCallerName = displayName
        return update
    }

    private func canAnswer(_ action: CXAnswerCallAction) -> Bool {
        fulfillOnConnect?.uuid == action.uuid && !action.isComplete && action.timeoutDate > Date()
    }

    private func finishAnswer(for callUUID: UUID, connected: Bool) {
        pendingPushes.removeValue(forKey: callUUID)
        guard let action = fulfillOnConnect, action.callUUID == callUUID else { return }
        guard canAnswer(action) else { return }
        fulfillOnConnect = nil
        if connected { action.fulfill() } else { action.fail() }
    }

    func reportIncomingCall(call: Call, connectedAt dateConnected: Date?) {
        logger.debug("CallController: reporting incoming call connected")
        if CallController.useCallKit(), let callUUID = call.callUUID, let uuid = UUID(uuidString: callUUID) {
            finishAnswer(for: uuid, connected: true)
        }
    }

    // Spec: spec/services/calls.md#reportOutgoingCall
    func reportOutgoingCall(call: Call, connectedAt dateConnected: Date?) {
        logger.debug("CallController: reporting outgoing call connected")
        if CallController.useCallKit(), let callUUID = call.callUUID, let uuid = UUID(uuidString: callUUID) {
            provider.reportOutgoingCall(with: uuid, connectedAt: dateConnected)
        }
    }

    func reportCallRemoteEnded(invitation: RcvCallInvitation) {
        logger.debug("CallController: reporting remote ended")
        if CallController.useCallKit(), let callUUID = invitation.callUUID, let uuid = UUID(uuidString: callUUID) {
            finishAnswer(for: uuid, connected: false)
            provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        } else if activeCallInvitation?.matches(invitation) == true {
            activeCallInvitation = nil
        }
    }

    func reportCallRemoteEnded(call: Call) {
        logger.debug("CallController: reporting remote ended")
        if CallController.useCallKit(), let callUUID = call.callUUID, let uuid = UUID(uuidString: callUUID) {
            finishAnswer(for: uuid, connected: false)
            provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        }
    }

    @MainActor
    func endCallAfterSignalingFailure(_ call: Call) -> Bool {
        guard ChatModel.shared.activeCall === call else { return false }
        if CallController.useCallKit(), let callUUID = call.callUUID, let uuid = UUID(uuidString: callUUID) {
            finishAnswer(for: uuid, connected: false)
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
        }
        let cleared = CallManager.clearActiveCall(call)
        suspendOnEndCall()
        return cleared
    }

    @MainActor
    func startCall(_ contact: Contact, _ media: CallMediaType) {
        logger.debug("CallController.startCall")
        guard xauXatContactInvitePermissions(contact).calls else {
            AlertManager.shared.showAlertMsg(
                title: "Calls unavailable",
                message: "This contact invite does not allow calls."
            )
            return
        }

        let media = XauXatProductPolicy.callMedia(media)
        let useRelay = UserDefaults.standard.bool(forKey: DEFAULT_WEBRTC_POLICY_RELAY)
        let callProtection = useRelay
            ? NSLocalizedString("Your call uses end-to-end encryption when supported by both devices. A call relay hides your IP address from the other person.", comment: "call privacy warning with relay")
            : NSLocalizedString("Your call uses end-to-end encryption when supported by both devices. A direct connection can reveal your IP address to the other person.", comment: "call privacy warning without mandatory relay")
        let voiceMaskMessage = callProtection + "\n\n" + NSLocalizedString("Your voice can still identify you. For an extra layer of privacy, use the xauxat voice mask.", comment: "call privacy warning voice mask recommendation")
        #if DEBUG
        let privacyMessage = XauXatDirectCallTest.shared.usesDirectSignaling(for: contact)
            ? voiceMaskMessage + "\n\n" + NSLocalizedString("The messaging relay can see your IP address during this test call.", comment: "direct SMP test privacy warning")
            : voiceMaskMessage
        #else
        let privacyMessage = voiceMaskMessage
        #endif

        showAlert(NSLocalizedString("Important warning", comment: "call privacy alert title"), message: privacyMessage) {
            var actions = [
                UIAlertAction(title: NSLocalizedString("Continue", comment: "start call without voice modification"), style: .default) { [weak self] _ in
                    self?.startCallAfterPrivacyConfirmation(contact, media, startWithModifiedVoice: false)
                }
            ]
            actions.append(UIAlertAction(title: NSLocalizedString("use voice mask", comment: "start call with LLVC enabled"), style: .default) { [weak self] _ in
                self?.startCallAfterPrivacyConfirmation(contact, media, startWithModifiedVoice: true)
            })
            actions.append(UIAlertAction(title: NSLocalizedString("Cancel", comment: "alert button"), style: .cancel))
            return actions
        }
    }

    private func startCallAfterPrivacyConfirmation(_ contact: Contact, _ media: CallMediaType, startWithModifiedVoice: Bool) {
        guard ChatModel.shared.activeCall == nil else { return }
        XauXatCallTiming.mark("outgoing.start")
        let callUUID = callManager.newOutgoingCall(contact, media, startWithModifiedVoice: startWithModifiedVoice)
        guard let uuid = UUID(uuidString: callUUID) else {
            return
        }
        if CallController.useCallKit() {
            let handle = CXHandle(type: .generic, value: contact.id)
            let action = CXStartCallAction(call: uuid, handle: handle)
            action.isVideo = media == .video
            requestTransaction(with: action, onFailure: {
                DispatchQueue.main.async {
                    if let call = ChatModel.shared.activeCall, call.callUUID == callUUID,
                       CallManager.clearActiveCall(call) {
                        AlertManager.shared.showAlertMsg(title: "Call failed", message: "The iOS call interface could not start the call.")
                    }
                }
            }) {
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .generic, value: contact.id)
                update.hasVideo = false
                update.localizedCallerName = contact.displayName
                self.provider.reportCall(with: uuid, updated: update)
            }
        } else if callManager.startOutgoingCall(callUUID: callUUID) {
            logger.debug("CallController.startCall: call started")
        } else {
            logger.error("CallController.startCall: no active call")
        }
    }

    func answerCall(invitation: RcvCallInvitation, startWithModifiedVoice: Bool = false) {
        logger.debug("CallController: answering a call")
        guard ChatModel.shared.callInvitations[invitation.contact.id]?.matches(invitation) == true else { return }
        if CallController.useCallKit(), let callUUID = invitation.callUUID, let uuid = UUID(uuidString: callUUID) {
            requestTransaction(with: CXAnswerCallAction(call: uuid))
        } else {
            callManager.answerIncomingCall(invitation: invitation, startWithModifiedVoice: startWithModifiedVoice)
        }
        if invitation.contact.id == self.activeCallInvitation?.contact.id {
            self.activeCallInvitation = nil
        }
    }

    func endCallAfterTransportClosed(_ call: Call) {
        guard ChatModel.shared.activeCall === call else { return }
        if let uuid = call.callUUID.flatMap(UUID.init(uuidString:)), lastNativeCallUUID == uuid {
            finishAnswer(for: uuid, connected: false)
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
        }
        callManager.endCall(call: call) {}
        suspendOnEndCall()
    }

    func endCall(callUUID: String) {
        let uuid = UUID(uuidString: callUUID)
        logger.debug("CallController: ending the call with UUID \(callUUID)")
        if CallController.useCallKit(), let uuid {
            requestTransaction(with: CXEndCallAction(call: uuid))
        } else {
            callManager.endCall(callUUID: callUUID) { ok in
                if ok {
                    logger.debug("CallController.endCall: call ended")
                } else {
                    logger.error("CallController.endCall: no active call pr call invitation to end")
                }
            }
        }
    }

    func endCall(invitation: RcvCallInvitation) {
        logger.debug("CallController: ending the call with invitation")
        if activeCallInvitation?.matches(invitation) == true {
            self.activeCallInvitation = nil
        }
        callManager.endCall(invitation: invitation) {}
    }

    func endCall(call: Call, completed: @escaping () -> Void) {
        logger.debug("CallController: ending the call with call instance")
        callManager.endCall(call: call, completed: completed)
    }

    func callAction(invitation: RcvCallInvitation, action: NtfCallAction) {
        switch action {
        case .accept: answerCall(invitation: invitation)
        case .reject: endCall(invitation: invitation)
        }
    }

    func showInRecents(_ show: Bool) {
        let conf = provider.configuration
        conf.includesCallsInRecents = show
        provider.configuration = conf
    }

    // Spec: spec/services/calls.md#hasActiveCalls
    func hasActiveCalls() -> Bool {
        controller.callObserver.calls.count > 0
    }

    private func requestTransaction(with action: CXAction, onFailure: @escaping () -> Void = {}, onSuccess: @escaping () -> Void = {}) {
        controller.request(CXTransaction(action: action)) { error in
            if let error = error {
                logger.error("CallController.requestTransaction error requesting transaction: \(error.localizedDescription)")
                onFailure()
            } else {
                logger.debug("CallController.requestTransaction requested transaction successfully")
                onSuccess()
            }
        }
    }
}
