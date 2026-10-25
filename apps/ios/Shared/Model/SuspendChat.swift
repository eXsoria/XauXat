//
//  SuspendChat.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 26/06/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import Foundation
import UIKit
import SimpleXChat
import SwiftUI

private let suspendLockQueue = DispatchQueue(label: "pt.exsoria.xauxat.suspend.lock")

let bgSuspendTimeout: Int = 5 // seconds

let terminationTimeout: Int = 3 // seconds

let DEFAULT_XAUXAT_EMPTY_SETUP = "xauxatEmptySetup"

let activationDelay: TimeInterval = 1.5

let nseSuspendTimeout: TimeInterval = 5

private func _suspendChat(timeout: Int) {
    // this is a redundant check to prevent logical errors, like the one fixed in this PR
    let state = AppChatState.shared.value
    if !state.canSuspend {
        logger.error("_suspendChat called, current state: \(state.rawValue)")
    } else if ChatModel.ok {
        AppChatState.shared.set(.suspending)
        apiSuspendChat(timeoutMicroseconds: timeout * 1000000)
        let endTask = beginBGTask(chatSuspended)
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeout) + 1, execute: endTask)
    } else {
        AppChatState.shared.set(.suspended)
    }
}

let seSubscriber = seMessageSubscriber {
    switch $0 {
    case let .state(state):
        switch state {
        case .inactive:
            if AppChatState.shared.value.inactive { activateChat() }
        case .sendingMessage:
            if AppChatState.shared.value.canSuspend { suspendChat() }
        }
    }
}

func suspendChat() {
    suspendLockQueue.sync {
        let deliveryManager = OutboundDeliveryManager.shared
        let timeout = deliveryManager.suspendTimeout(
            defaultTimeout: appSuspendTimeout,
            backgroundTimeRemaining: UIApplication.shared.backgroundTimeRemaining
        )
        logger.notice(
            "Suspending chat with \(timeout, privacy: .public)s delivery window for \(deliveryManager.pendingMessageCount, privacy: .public) pending message(s)"
        )
        _suspendChat(timeout: timeout)
    }
}

func suspendBgRefresh() {
    suspendLockQueue.sync {
        if case .bgRefresh = AppChatState.shared.value  {
            _suspendChat(timeout: bgSuspendTimeout)
        }
    }
}

func terminateChat() {
    logger.debug("terminateChat")
    suspendLockQueue.sync {
        switch AppChatState.shared.value {
        case .suspending:
            // suspend instantly if already suspending
            _chatSuspended()
            // when apiSuspendChat is called with timeout 0, it won't send any events on suspension
            if ChatModel.ok { apiSuspendChat(timeoutMicroseconds: 0) }
            chatCloseStore()
        case .suspended:
            chatCloseStore()
        case .stopped:
            chatCloseStore()
        default:
            // the store will be closed in _chatSuspended when event is received
            _suspendChat(timeout: terminationTimeout)
        }
    }
}

func chatSuspended() {
    suspendLockQueue.sync {
        if case .suspending = AppChatState.shared.value {
            _chatSuspended()
        }
    }
}

private func _chatSuspended() {
    logger.debug("_chatSuspended")
    AppChatState.shared.set(.suspended)
    if ChatModel.shared.chatRunning == true {
        ChatReceiver.shared.stop()
    }
    chatCloseStore()
}

func setAppState(_ appState: AppState) {
    suspendLockQueue.sync {
        AppChatState.shared.set(appState)
    }
}

@discardableResult
func activateChat(appState: AppState = .active) -> Bool {
    logger.debug("DEBUGGING: activateChat")
    guard isXauXatTorReady() else {
        logger.error("XauXat: refusing to activate chat before embedded Tor is ready")
        return false
    }
    return suspendLockQueue.sync {
        guard ChatModel.ok, hasChatCtrl() else { return false }
        // Publish success only after both stores and the native core reopen.
        // Otherwise recovery would treat a closed SQLite handle as running.
        guard apiActivateChat() else {
            AppChatState.shared.set(.suspended)
            logger.error("XauXat could not reopen the chat session")
            return false
        }
        AppChatState.shared.set(appState)
        logger.debug("DEBUGGING: activateChat: after apiActivateChat")
        return true
    }
}

func initChatAndMigrate(refreshInvitations: Bool = true, start: Bool = true) {
    let m = ChatModel.shared
    if (!m.chatInitialized) {
        m.v3DBMigration = v3DBMigrationDefault.get()
        if AppChatState.shared.value == .stopped && storeDBPassphraseGroupDefault.get() && kcDatabasePassword.get() != nil {
            initialize(start: start, confirmStart: true)
        } else {
            initialize(start: start)
        }
    }

    func initialize(start: Bool, confirmStart: Bool = false) {
        do {
            try initializeChat(start: m.v3DBMigration.startChat && start, confirmStart: m.v3DBMigration.startChat && confirmStart, refreshInvitations: refreshInvitations)
        } catch let error {
            AlertManager.shared.showAlertMsg(
                title: start ? "Error starting chat" : "Error opening chat",
                message: "Please contact developers.\nError: \(responseError(error))"
            )
        }
    }
}

func startChatForCall() {
    logger.debug("DEBUGGING: startChatForCall")
    if .active != AppChatState.shared.value || !isChatStoreOpen() {
        guard activateChat() else { return }
    }
    if ChatModel.shared.chatRunning == true {
        ChatReceiver.shared.start()
        logger.debug("DEBUGGING: startChatForCall: after ChatReceiver.shared.start")
    }
}

func startChatAndActivate(ifAllowed: @escaping () -> Bool = { true }, _ completion: @escaping () -> Void) {
    // Callers and NSE callbacks run on the main queue. Complete this operation
    // only once, even if a late/duplicate extension callback reaches it.
    var finished = false
    func finish() {
        guard !finished else { return }
        finished = true
        completion()
    }
    logger.debug("DEBUGGING: startChatAndActivate")
    guard ifAllowed() else { finish(); return }
    if AppChatState.shared.value == .active && isChatStoreOpen() {
        if ChatModel.shared.chatRunning == true { ChatReceiver.shared.start() }
        finish()
    } else if nseStateGroupDefault.get().inactive {
        activate()
    } else {
        // setting app state to "activating" to notify NSE that it should suspend
        setAppState(.activating)
        waitNSESuspended(timeout: nseSuspendTimeout) { ok in
            guard !finished else { return }
            // The core can have moved on while the extension was suspending.
            // Do not overwrite shared NSE state on behalf of an old activation.
            guard AppChatState.shared.value == .activating, ifAllowed() else {
                finish()
                return
            }
            if !ok {
                // if for some reason NSE failed to suspend,
                // e.g., it crashed previously without setting its state to "suspended",
                // set it to "suspended" state anyway, so that next time app
                // does not have to wait when activating.
                nseStateGroupDefault.set(.suspended)
            }
            activate()
        }
    }

    func activate() {
        guard ifAllowed() else { finish(); return }
        logger.debug("DEBUGGING: startChatAndActivate: before activateChat")
        if activateChat(), ChatModel.shared.chatRunning == true {
            ChatReceiver.shared.start()
        }
        finish()
        logger.debug("DEBUGGING: startChatAndActivate: after activateChat")
    }
}

// appStateGroupDefault must not be used in the app directly, only via this singleton
class AppChatState {
    static let shared = AppChatState()
    private var value_ = appStateGroupDefault.get()

    var value: AppState {
        value_
    }

    func set(_ state: AppState) {
        appStateGroupDefault.set(state)
        sendAppState(state)
        value_ = state
    }
}
