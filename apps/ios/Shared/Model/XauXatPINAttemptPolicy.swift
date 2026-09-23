//
//  XauXatPINAttemptPolicy.swift
//  XauXat
//
//  Persistent policy state for app-unlock PIN failures.
//

import Foundation

enum XauXatPINFailurePolicy: Equatable {
    case lock
    case destroy
}

enum XauXatPINFailureOutcome: Equatable {
    case retry(remainingAttempts: Int)
    case locked(remaining: TimeInterval)
    case destroy
}

struct XauXatPINAttemptState: Codable, Equatable {
    static let maximumAttempts = 3
    static let lockDuration: TimeInterval = 60 * 60

    private(set) var failedAttempts = 0
    private(set) var lockedAt: Date?
    private(set) var lockedAtUptime: TimeInterval?

    mutating func recordFailure(
        policy: XauXatPINFailurePolicy,
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> XauXatPINFailureOutcome {
        if let remaining = activeLockRemaining(now: now, uptime: uptime) {
            return .locked(remaining: remaining)
        }

        clearExpiredLockIfNeeded(now: now, uptime: uptime)
        failedAttempts += 1
        guard failedAttempts >= Self.maximumAttempts else {
            return .retry(remainingAttempts: Self.maximumAttempts - failedAttempts)
        }

        lockedAt = now
        lockedAtUptime = uptime
        return policy == .destroy ? .destroy : .locked(remaining: Self.lockDuration)
    }

    mutating func lockRemaining(
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        if let remaining = activeLockRemaining(now: now, uptime: uptime) {
            return remaining
        }
        clearExpiredLockIfNeeded(now: now, uptime: uptime)
        return nil
    }

    mutating func reset() {
        failedAttempts = 0
        lockedAt = nil
        lockedAtUptime = nil
    }

    private func activeLockRemaining(now: Date, uptime: TimeInterval) -> TimeInterval? {
        guard let lockedAt else { return nil }

        let wallElapsed = max(0, now.timeIntervalSince(lockedAt))
        var remaining = max(0, Self.lockDuration - wallElapsed)

        if let lockedAtUptime, uptime >= lockedAtUptime {
            let uptimeElapsed = uptime - lockedAtUptime
            remaining = min(remaining, max(0, Self.lockDuration - uptimeElapsed))
        }

        return remaining > 0 ? remaining : nil
    }

    private mutating func clearExpiredLockIfNeeded(now: Date, uptime: TimeInterval) {
        guard lockedAt != nil, activeLockRemaining(now: now, uptime: uptime) == nil else { return }
        reset()
    }
}
