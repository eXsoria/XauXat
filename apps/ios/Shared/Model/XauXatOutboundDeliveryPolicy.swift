//
//  XauXatOutboundDeliveryPolicy.swift
//  SimpleX
//

import Foundation

enum XauXatOutboundDeliveryPolicy {
    private static let expirationSafetyMargin: TimeInterval = 5
    private static let fallbackDeliveryWindow = 25
    private static let maximumDeliveryWindow = 60

    /// A stalled send first gets a cheap relay reconnect. Later attempts also
    /// refresh Tor, with a bounded backoff so a broken relay never produces a
    /// tight reconnect loop.
    static func recoveryDelay(attempt: Int) -> TimeInterval {
        switch max(0, attempt) {
        case 0: 8
        case 1: 20
        case 2: 45
        default: 90
        }
    }

    static func shouldRefreshTor(attempt: Int) -> Bool {
        attempt == 1
    }

    static func suspendTimeout(
        defaultTimeout: Int,
        backgroundTimeRemaining: TimeInterval,
        hasPendingDelivery: Bool
    ) -> Int {
        guard hasPendingDelivery else { return defaultTimeout }

        // UIApplication reports a sentinel-sized value while the budget is unavailable.
        guard backgroundTimeRemaining.isFinite, backgroundTimeRemaining < 300 else {
            return max(defaultTimeout, fallbackDeliveryWindow)
        }
        let usable = Int(floor(backgroundTimeRemaining - expirationSafetyMargin))
        return max(1, min(maximumDeliveryWindow, usable))
    }
}
