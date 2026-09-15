//
//  LocalAuthView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 10/04/2023.
//  Copyright © 2023 SimpleX Chat. All rights reserved.
//
// Spec: spec/architecture.md

import SwiftUI
import SimpleXChat

struct LocalAuthView: View {
    @EnvironmentObject var m: ChatModel
    var authRequest: LocalAuthRequest
    @State private var password = ""
    @State private var allowToReact = true

    var body: some View {
        PasscodeView(passcode: $password, title: authRequest.title ?? "Enter Passcode", reason: authRequest.reason, submitLabel: "Submit",
                     buttonsEnabled: $allowToReact) {
            if let sdPassword = kcSelfDestructPassword.get(), authRequest.selfDestruct && password == sdPassword {
                allowToReact = false
                deleteStorageAndRestart(sdPassword) { r in
                    m.laRequest = nil
                    authRequest.completed(r)
                }
                return
            }
            if let decoyPassword = kcDecoyPassword.get(), authRequest.selfDestruct && password == decoyPassword {
                allowToReact = false
                openStorageAndRestart(.decoy) { result in
                    m.laRequest = nil
                    authRequest.completed(result)
                }
                return
            }
            let r: LAResult
            if password == authRequest.password {
                if authRequest.selfDestruct &&
                    (xauXatStorageScope() != .primary ||
                     (!m.chatInitialized && (kcSelfDestructPassword.get() != nil || kcDecoyPassword.get() != nil))) {
                    allowToReact = false
                    openStorageAndRestart(.primary) { result in
                        m.laRequest = nil
                        authRequest.completed(result)
                    }
                    return
                }
                r = .success
            } else {
                r = .failed(authError: NSLocalizedString("Incorrect passcode", comment: "PIN entry"))
            }
            m.laRequest = nil
            authRequest.completed(r)
        } cancel: {
            m.laRequest = nil
            authRequest.completed(.failed(authError: NSLocalizedString("Authentication cancelled", comment: "PIN entry")))
        }
    }

    private func openStorageAndRestart(_ scope: XauXatStorageScope, completed: @escaping (LAResult) -> Void) {
        Task {
            do {
                while m.ctrlInitInProgress {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }

                if m.chatInitialized && xauXatStorageScope() == scope {
                    completed(.success)
                    return
                }

                if m.chatRunning == true {
                    try await stopChatAsync()
                }
                if m.chatInitialized {
                    chatCloseStore()
                }

                clearVisibleChatData()
                setXauXatStorageScope(scope)
                try prepareXauXatStorageScope()
                m.chatDbChanged = true
                m.chatInitialized = false
                resetChatCtrl()
                try initializeChat(start: true)
                m.chatDbChanged = false
                AppChatState.shared.set(.active)

                if scope == .decoy, m.chatInitialized, m.currentUser == nil {
                    let configuredName = UserDefaults.standard.string(forKey: DEFAULT_LA_DECOY_DISPLAY_NAME)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = configuredName?.isEmpty == false ? configuredName! : "Alex"
                    m.currentUser = try apiCreateActiveUser(
                        Profile(displayName: displayName, fullName: ""),
                        pastTimestamp: true
                    )
                    onboardingStageDefault.set(.onboardingComplete)
                    m.onboardingStage = .onboardingComplete
                    try startChat()
                }

                await NtfManager.shared.removeAllNotifications()
                completed(.success)
            } catch {
                logger.error("Unable to open selected local profile: \(error.localizedDescription)")
                completed(.failed(authError: NSLocalizedString("Incorrect passcode", comment: "PIN entry")))
            }
        }
    }

    private func clearVisibleChatData() {
        m.chatId = nil
        m.currentUser = nil
        ItemsModel.shared.reversedChatItems = []
        ItemsModel.shared.chatState.clear()
        ChatModel.shared.secondaryIM?.reversedChatItems = []
        ChatModel.shared.secondaryIM?.chatState.clear()
        m.updateChats([])
        m.users = []
    }

    private func deleteStorageAndRestart(_ password: String, completed: @escaping (LAResult) -> Void) {
        Task {
            do {
                let requestedScope = XauXatDuressScope.configured
                let duressScope: XauXatDuressScope =
                    (requestedScope == .decoy || requestedScope == .all) && kcDecoyPassword.get() == nil
                    ? .primary
                    : requestedScope
                let replacementScope: XauXatStorageScope = duressScope == .decoy ? .decoy : .primary

                /** Waiting until [initializeChat] finishes */
                while (m.ctrlInitInProgress) {
                    try await Task.sleep(nanoseconds: 50_000000)
                }
                if m.chatRunning == true {
                    try await stopChatAsync()
                }
                if m.chatInitialized {
                    /**
                     * The following sequence can bring a user here:
                     * the user opened the app, entered app passcode, went to background, returned back, entered self-destruct code.
                     * In this case database should be closed to prevent possible situation when OS can deny database removal command
                     * */
                    chatCloseStore()
                }

                // Destroy the encryption keys first. Deleting encrypted files
                // afterwards is defense in depth and is not the erasure boundary.
                for scope in duressScope.storageScopes {
                    guard destroyXauXatStorage(scope) else {
                        throw RuntimeError("Unable to destroy selected database key")
                    }
                }

                // Clear sensitive data on screen just in case app fails to hide its views while new database is created
                clearVisibleChatData()
                setXauXatStorageScope(replacementScope)
                try prepareXauXatStorageScope()

                if replacementScope == .decoy {
                    guard kcDecoyPassword.set(password) else {
                        throw RuntimeError("Unable to persist replacement decoy PIN")
                    }
                } else {
                    guard kcAppPassword.set(password) else {
                        throw RuntimeError("Unable to persist replacement app PIN")
                    }
                    if duressScope == .all {
                        _ = kcDecoyPassword.remove()
                    }
                }
                _ = kcSelfDestructPassword.remove()
                await NtfManager.shared.removeAllNotifications()
                let displayName = UserDefaults.standard.string(forKey: DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME)
                UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
                UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME)
                UserDefaults.standard.removeObject(forKey: DEFAULT_LA_DURESS_SCOPE)
                await MainActor.run {
                    m.chatDbChanged = true
                    m.chatInitialized = false
                }
                resetChatCtrl()
                try initializeChat(start: true)
                m.chatDbChanged = false
                AppChatState.shared.set(.active)
                if m.currentUser != nil || !m.chatInitialized { return }
                var profile: Profile? = nil
                if let displayName = displayName, displayName != "" {
                    profile = Profile(displayName: displayName, fullName: "")
                }
                m.currentUser = try apiCreateActiveUser(profile, pastTimestamp: true)
                onboardingStageDefault.set(.onboardingComplete)
                m.onboardingStage = .onboardingComplete
                try startChat()
                completed(.success)
            } catch {
                completed(.failed(authError: NSLocalizedString("Incorrect passcode", comment: "PIN entry")))
            }
        }
    }
}

struct LocalAuthView_Previews: PreviewProvider {
    static var previews: some View {
        LocalAuthView(authRequest: LocalAuthRequest.sample)
    }
}
