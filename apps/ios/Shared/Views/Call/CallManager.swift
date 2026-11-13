//
//  CallManager.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 22/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import Foundation
import SimpleXChat

enum XauXatProductPolicy {
    static let videoCallsEnabled = false

    static func callMedia(_ requested: CallMediaType) -> CallMediaType {
        videoCallsEnabled ? requested : .audio
    }
}

class CallManager {
    func newOutgoingCall(_ contact: Contact, _ media: CallMediaType, startWithModifiedVoice: Bool) -> String {
        let media = XauXatProductPolicy.callMedia(media)
        let uuid = UUID().uuidString.lowercased()
        let call = Call(
            direction: .outgoing, contact: contact, callUUID: uuid,
            callState: .waitCapabilities, initialCallType: media, startWithModifiedVoice: startWithModifiedVoice
        )
        call.speakerEnabled = media == .video
        ChatModel.shared.activeCall = call
        return uuid
    }

    func startOutgoingCall(callUUID: String) -> Bool {
        let m = ChatModel.shared
        if let call = m.activeCall, call.callUUID == callUUID {
            m.showCallView = true
            Task { await m.callCommand.processCommand(.capabilities(media: call.initialCallType)) }
            return true
        }
        return false
    }

    func answerIncomingCall(callUUID: String) -> Bool {
        if let invitation = getCallInvitation(callUUID) {
            answerIncomingCall(invitation: invitation)
            return true
        }
        return false
    }

    func answerIncomingCall(invitation: RcvCallInvitation, startWithModifiedVoice: Bool = false) {
        XauXatCallTiming.mark("incoming.accept")
        let m = ChatModel.shared
        let media = XauXatProductPolicy.callMedia(invitation.callType.media)
        m.callInvitations.removeValue(forKey: invitation.contact.id)
        let call = Call(
            direction: .incoming,
            contact: invitation.contact,
            callUUID: invitation.callUUID,
            callState: .invitationAccepted,
            initialCallType: media,
            sharedKey: invitation.sharedKey,
            startWithModifiedVoice: startWithModifiedVoice
        )
        call.speakerEnabled = media == .video
        let useRelay = UserDefaults.standard.bool(forKey: DEFAULT_WEBRTC_POLICY_RELAY)
        let iceServers = getIceServers()
        logger.debug("answerIncomingCall useRelay: \(useRelay)")
        logger.debug("answerIncomingCall iceServers: \(String(describing: iceServers))")
        // When in active call user wants to accept another call, this can only work after delay (to hide and show activeCallView)
        DispatchQueue.main.asyncAfter(deadline: .now() + (m.activeCall == nil ? 0 : 1)) {
            m.activeCall = call
            m.showCallView = true

            Task {
                await m.callCommand.processCommand(.start(
                media: media,
                aesKey: invitation.sharedKey,
                iceServers: iceServers,
                relay: useRelay
                ))
            }
        }
    }

    func enableMedia(source: CallMediaSource, enable: Bool, callUUID: String) -> Bool {
        if let call = ChatModel.shared.activeCall, call.callUUID == callUUID {
            let m = ChatModel.shared
            Task { await m.callCommand.processCommand(.media(source: source, enable: enable)) }
            return true
        }
        return false
    }

    func endCall(callUUID: String, completed: @escaping (Bool) -> Void) {
        if let call = ChatModel.shared.activeCall, call.callUUID == callUUID {
            endCall(call: call) { completed(true) }
        } else if let invitation = getCallInvitation(callUUID) {
            endCall(invitation: invitation) { completed(true) }
        } else {
            completed(false)
        }
    }

    func endCall(call: Call, completed: @escaping () -> Void) {
        let shouldSignal = call.callState != .ended
        if Self.clearActiveCall(call), shouldSignal {
            Task {
                XauXatCallTiming.mark("end.sending")
                do {
                    try await apiEndCall(call.contact)
                    XauXatCallTiming.mark("end.queued")
                } catch {
                    XauXatCallTiming.mark("end.failed")
                    logger.error("CallController.provider apiEndCall error: \(responseError(error))")
                }
            }
        }
        completed()
    }

    @discardableResult
    static func clearActiveCall(_ call: Call) -> Bool {
        let m = ChatModel.shared
        guard m.activeCall === call else { return false }
        call.callState = .ended
        m.showCallView = false
        m.activeCallViewIsCollapsed = false
        m.activeCall = nil
        return true
    }

    func endCall(invitation: RcvCallInvitation, completed: @escaping () -> Void) {
        let m = ChatModel.shared
        let id = invitation.contact.id
        guard let current = m.callInvitations[id], current.callTs == invitation.callTs,
              current.callUUID == invitation.callUUID else {
            completed()
            return
        }
        m.callInvitations.removeValue(forKey: id)
        completed()
        Task {
            XauXatCallTiming.mark("reject.sending")
            do {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "xauxatLegacyReject") {
                    // The prebuilt iOS core only sends XCallEnd for /_call end.
                    try await apiEndCall(invitation.contact)
                } else {
                    try await apiRejectCall(invitation.contact)
                }
                #else
                try await apiRejectCall(invitation.contact)
                #endif
                XauXatCallTiming.mark("reject.queued")
            } catch {
                XauXatCallTiming.mark("reject.failed")
                logger.error("CallController.provider apiRejectCall error: \(responseError(error))")
            }
        }
    }

    private func getCallInvitation(_ callUUID: String) -> RcvCallInvitation? {
        if let (_, invitation) = ChatModel.shared.callInvitations.first(where: { (_, inv) in inv.callUUID == callUUID }) {
            return invitation
        }
        return nil
    }
}
