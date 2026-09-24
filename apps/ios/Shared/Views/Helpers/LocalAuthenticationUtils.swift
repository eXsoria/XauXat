//
//  LocalAuthenticationUtils.swift
//  SimpleX (iOS)
//
//  Created by Efim Poberezkin on 26.05.2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import LocalAuthentication
import SimpleXChat

enum LAResult {
    case success
    case failed(authError: String?)
    case unavailable(authError: String?)
}

enum XauXatDuressScope: String, CaseIterable, Identifiable {
    case primary
    case decoy
    case all

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .primary: "Main environment"
        case .decoy: "Decoy environment"
        case .all: "Both environments"
        }
    }

    var storageScopes: [XauXatStorageScope] {
        switch self {
        case .primary: [.primary]
        case .decoy: [.decoy]
        case .all: [.primary, .decoy]
        }
    }

    static var configured: XauXatDuressScope {
        guard let rawValue = UserDefaults.standard.string(forKey: DEFAULT_LA_DURESS_SCOPE),
              let scope = XauXatDuressScope(rawValue: rawValue) else { return .primary }
        return scope
    }
}

func authorize(_ text: String, _ authorized: Binding<Bool>) {
    authenticate(reason: text) { laResult in
        switch laResult {
        case .success: authorized.wrappedValue = true
        case .unavailable: authorized.wrappedValue = true
        case .failed: authorized.wrappedValue = false
        }
    }
}

struct LocalAuthRequest {
    var title: LocalizedStringKey? // if title is null, reason is shown
    var reason: String
    var password: String
    var isAppUnlock: Bool
    var selfDestruct: Bool
    var completed: (LAResult) -> Void

    static var sample = LocalAuthRequest(title: "Enter Passcode", reason: "Authenticate", password: "", isAppUnlock: true, selfDestruct: false, completed: { _ in })
}

struct XauXatPINAttemptStatus {
    let failedAttempts: Int
    let lockRemaining: TimeInterval?
}

final class XauXatPINAttemptStore {
    static let shared = XauXatPINAttemptStore()

    private let lock = NSLock()

    func status(
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> XauXatPINAttemptStatus {
        lock.lock()
        defer { lock.unlock() }

        var state = load()
        let previous = state
        let remaining = state.lockRemaining(now: now, uptime: uptime)
        if state != previous { save(state) }
        return XauXatPINAttemptStatus(failedAttempts: state.failedAttempts, lockRemaining: remaining)
    }

    func recordFailure(
        policy: XauXatPINFailurePolicy,
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> XauXatPINFailureOutcome {
        lock.lock()
        defer { lock.unlock() }

        var state = load()
        let outcome = state.recordFailure(policy: policy, now: now, uptime: uptime)
        save(state)
        return outcome
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _ = kcAppPINAttemptState.remove()
    }

    private func load() -> XauXatPINAttemptState {
        guard let value = kcAppPINAttemptState.get(),
              let data = value.data(using: .utf8),
              let state = try? JSONDecoder().decode(XauXatPINAttemptState.self, from: data) else {
            return XauXatPINAttemptState()
        }
        return state
    }

    private func save(_ state: XauXatPINAttemptState) {
        guard state != XauXatPINAttemptState(),
              let data = try? JSONEncoder().encode(state),
              let value = String(data: data, encoding: .utf8) else {
            _ = kcAppPINAttemptState.remove()
            return
        }
        _ = kcAppPINAttemptState.set(value)
    }
}

func authenticate(title: LocalizedStringKey? = nil, reason: String, selfDestruct: Bool = false, completed: @escaping (LAResult) -> Void) {
    logger.debug("DEBUGGING: authenticate")
    // When a decoy profile exists, app unlock always asks for a PIN. Face ID or
    // the device passcode cannot choose which local database should be opened.
    if selfDestruct, kcDecoyPassword.get() != nil {
        if let password = kcAppPassword.get() {
            DispatchQueue.main.async {
                ChatModel.shared.laRequest = LocalAuthRequest(
                    title: title,
                    reason: reason,
                    password: password,
                    isAppUnlock: selfDestruct,
                    selfDestruct: true,
                    completed: completed
                )
            }
        } else {
            completed(.unavailable(authError: NSLocalizedString("No app password", comment: "Authentication unavailable")))
        }
        return
    }
    switch privacyLocalAuthModeDefault.get() {
    case .system: systemAuthenticate(reason, completed)
    case .passcode:
        if let password = kcAppPassword.get() {
            DispatchQueue.main.async {
                ChatModel.shared.laRequest = LocalAuthRequest(
                    title: title,
                    reason: reason,
                    password: password,
                    isAppUnlock: selfDestruct,
                    selfDestruct: selfDestruct && UserDefaults.standard.bool(forKey: DEFAULT_LA_SELF_DESTRUCT),
                    completed: completed
                )
            }
        } else {
            completed(.unavailable(authError: NSLocalizedString("No app password", comment: "Authentication unavailable")))
        }
    }
}

func systemAuthenticate(_ reason: String, _ completed: @escaping (LAResult) -> Void) {
    logger.debug("DEBUGGING: systemAuthenticate")
    let laContext = LAContext()
    var authAvailabilityError: NSError?
    if laContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authAvailabilityError) {
        logger.debug("DEBUGGING: systemAuthenticate: canEvaluatePolicy callback")
        laContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authError in
            logger.debug("DEBUGGING: systemAuthenticate evaluatePolicy callback")
            DispatchQueue.main.async {
                if success {
                    completed(LAResult.success)
                } else {
                    logger.error("DEBUGGING: systemAuthenticate authentication error: \(authError.debugDescription)")
                    completed(LAResult.failed(authError: authError?.localizedDescription))
                }
            }
        }
    } else {
        logger.error("DEBUGGING: authentication availability error: \(authAvailabilityError.debugDescription)")
        completed(LAResult.unavailable(authError: authAvailabilityError?.localizedDescription))
    }
}

func laTurnedOnAlert() -> Alert {
    mkAlert(
        title: "SimpleX Lock turned on",
        message: "You will be required to authenticate when you start or resume the app after 30 seconds in background."
    )
}

func laPasscodeNotSetAlert() -> Alert {
    mkAlert(
        title: "SimpleX Lock not enabled!",
        message: "You can turn on SimpleX Lock via Settings."
    )
}

func laFailedAlert() -> Alert {
    mkAlert(
        title: "Authentication failed",
        message: "You could not be verified; please try again."
    )
}

func laUnavailableInstructionAlert() -> Alert {
    mkAlert(
        title: "Authentication unavailable",
        message: "Device authentication is not enabled. You can turn on SimpleX Lock via Settings, once you enable device authentication."
    )
}

func laUnavailableTurningOffAlert() -> Alert {
    mkAlert(
        title: "Authentication unavailable",
        message: "Device authentication is disabled. Turning off SimpleX Lock."
    )
}
