//
//  XauXatOutboundDeliveryPolicy.swift
//  SimpleX
//

import Foundation

enum XauXatOutboundDeliveryPolicy {
    private static let expirationSafetyMargin: TimeInterval = 5
    private static let fallbackDeliveryWindow = 25
    private static let maximumDeliveryWindow = 60

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
