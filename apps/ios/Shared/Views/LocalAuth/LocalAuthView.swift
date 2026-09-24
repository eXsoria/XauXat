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
import Combine

struct LocalAuthView: View {
    @EnvironmentObject var m: ChatModel
    var authRequest: LocalAuthRequest
    @State private var password = ""
    @State private var allowToReact = true
    @State private var failedAttempts = 0
    @State private var lockRemaining: TimeInterval?
    @State private var feedbackMessage: String?
    @State private var pendingFailure: Task<Void, Never>?

    var body: some View {
        PasscodeView(passcode: $password, title: authRequest.title ?? "Enter Passcode", reason: displayedReason, submitLabel: "Submit",
                     showsSubmitButton: false, expectedPasscodeLength: authRequest.password.count, buttonsEnabled: $allowToReact) {
            submitPasscode()
        } cancel: {
            m.laRequest = nil
            authRequest.completed(.failed(authError: NSLocalizedString("Authentication cancelled", comment: "PIN entry")))
        }
        .onChange(of: password) { enteredPassword in
            pendingFailure?.cancel()
            if allowToReact && matchesConfiguredPasscode(enteredPassword) {
                submitPasscode()
            } else if allowToReact && enteredPassword.count >= minimumConfiguredPasscodeLength {
                scheduleFailedAttempt(for: enteredPassword)
            }
        }
        .onAppear(perform: refreshAttemptStatus)
        .onDisappear { pendingFailure?.cancel() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if lockRemaining != nil { refreshAttemptStatus() }
        }
    }

    private var displayedReason: String {
        if let lockRemaining {
            return String(
                format: NSLocalizedString("Too many incorrect attempts. Try again in %@.", comment: "PIN lockout countdown"),
                lockDurationText(lockRemaining)
            )
        }
        if let feedbackMessage { return feedbackMessage }
        if authRequest.isAppUnlock, failedAttempts > 0 {
            return String(
                format: NSLocalizedString("%d attempts remaining.", comment: "PIN attempts remaining"),
                XauXatPINAttemptState.maximumAttempts - failedAttempts
            )
        }
        return authRequest.reason
    }

    private var configuredPasscodes: [String] {
        var passcodes = [authRequest.password]
        if authRequest.selfDestruct {
            if let password = kcSelfDestructPassword.get() { passcodes.append(password) }
            if let password = kcDecoyPassword.get() { passcodes.append(password) }
        }
        return passcodes
    }

    private var minimumConfiguredPasscodeLength: Int {
        configuredPasscodes.map(\.count).min() ?? authRequest.password.count
    }

    private func matchesConfiguredPasscode(_ enteredPassword: String) -> Bool {
        configuredPasscodes.contains(enteredPassword)
    }

    private func scheduleFailedAttempt(for candidate: String) {
        pendingFailure = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard allowToReact, password == candidate, !matchesConfiguredPasscode(candidate) else { return }
                submitPasscode()
            }
        }
    }

    private func submitPasscode() {
        pendingFailure?.cancel()
        if let sdPassword = kcSelfDestructPassword.get(), authRequest.selfDestruct && password == sdPassword {
            resetAttemptProtection()
            allowToReact = false
            deleteStorageAndRestart(sdPassword) { r in
                m.laRequest = nil
                authRequest.completed(r)
            }
            return
        }
        if let decoyPassword = kcDecoyPassword.get(), authRequest.selfDestruct && password == decoyPassword {
            resetAttemptProtection()
            allowToReact = false
            openStorageAndRestart(.decoy) { result in
                m.laRequest = nil
                authRequest.completed(result)
            }
            return
        }
        let r: LAResult
        if password == authRequest.password {
            resetAttemptProtection()
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
            if authRequest.isAppUnlock {
                handleFailedAppUnlock()
                return
            }
            r = .failed(authError: NSLocalizedString("Incorrect passcode", comment: "PIN entry"))
        }
        m.laRequest = nil
        authRequest.completed(r)
    }

    private func handleFailedAppUnlock() {
        let destructivePolicyEnabled =
            UserDefaults.standard.bool(forKey: DEFAULT_LA_DESTROY_AFTER_FAILED_ATTEMPTS) &&
            XauXatPlusEntitlements.shared.isAuthorized(for: .duressPIN)
        let policy: XauXatPINFailurePolicy = destructivePolicyEnabled ? .destroy : .lock

        switch XauXatPINAttemptStore.shared.recordFailure(policy: policy) {
        case let .retry(remainingAttempts):
            failedAttempts = XauXatPINAttemptState.maximumAttempts - remainingAttempts
            feedbackMessage = String(
                format: NSLocalizedString("Incorrect passcode. %d attempts remaining.", comment: "PIN attempts remaining"),
                remainingAttempts
            )
            password = ""
        case let .locked(remaining):
            failedAttempts = XauXatPINAttemptState.maximumAttempts
            feedbackMessage = nil
            password = ""
            lockRemaining = remaining
            allowToReact = false
        case .destroy:
            failedAttempts = XauXatPINAttemptState.maximumAttempts
            feedbackMessage = NSLocalizedString("Security reset in progress…", comment: "PIN failed-attempt destruction")
            password = ""
            allowToReact = false
            deleteStorageAndRestart(authRequest.password, duressScopeOverride: .all) { result in
                if case .success = result { XauXatPINAttemptStore.shared.reset() }
                m.laRequest = nil
                authRequest.completed(result)
            }
        }
    }

    private func refreshAttemptStatus() {
        guard authRequest.isAppUnlock else { return }
        let status = XauXatPINAttemptStore.shared.status()
        failedAttempts = status.failedAttempts
        lockRemaining = status.lockRemaining
        allowToReact = status.lockRemaining == nil
        if status.lockRemaining == nil, failedAttempts == 0 {
            feedbackMessage = nil
        }
    }

    private func resetAttemptProtection() {
        XauXatPINAttemptStore.shared.reset()
        failedAttempts = 0
        lockRemaining = nil
        feedbackMessage = nil
    }

    private func lockDurationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(duration)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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

    private func deleteStorageAndRestart(
        _ password: String,
        duressScopeOverride: XauXatDuressScope? = nil,
        completed: @escaping (LAResult) -> Void
    ) {
        Task {
            do {
                let requestedScope = duressScopeOverride ?? XauXatDuressScope.configured
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
