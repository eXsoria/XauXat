import Foundation

enum XauXatGroupAccessRulesError: Equatable {
    case invalidUseCount
    case invalidIndividualCount
    case insufficientCapacity(available: Int)
    case expiryInPast

    var message: String {
        switch self {
        case .invalidUseCount:
            return NSLocalizedString("Maximum uses must be at least 1.", comment: "group access validation")
        case .invalidIndividualCount:
            return NSLocalizedString("An individual-access batch needs at least 2 accesses.", comment: "group access validation")
        case let .insufficientCapacity(available):
            return String.localizedStringWithFormat(
                NSLocalizedString("The group has room for only %d more member(s).", comment: "group access validation"),
                available
            )
        case .expiryInPast:
            return NSLocalizedString("Choose an expiry date in the future.", comment: "group access validation")
        }
    }
}

struct XauXatGroupAccessRules: Equatable, Sendable {
    let maxUses: Int
    let expiresAt: Date?
    let requiresCode: Bool
    let individualAccessCount: Int?

    var requestedUses: Int { individualAccessCount ?? maxUses }

    func validationError(availableCapacity: Int, at now: Date = .now) -> XauXatGroupAccessRulesError? {
        if maxUses < 1 { return .invalidUseCount }
        if let individualAccessCount, individualAccessCount < 2 { return .invalidIndividualCount }
        if requestedUses > availableCapacity { return .insufficientCapacity(available: max(0, availableCapacity)) }
        if let expiresAt, expiresAt <= now { return .expiryInPast }
        return nil
    }

    func summary(accessLabel: String? = nil) -> String {
        var parts: [String] = []
        if let accessLabel {
            parts.append(String.localizedStringWithFormat(NSLocalizedString("Access %@", comment: "group access summary"), accessLabel))
        }
        if let individualAccessCount {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("%d individual access(es)", comment: "group access summary"),
                individualAccessCount
            ))
        } else {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("%d use(s)", comment: "group access summary"),
                maxUses
            ))
        }
        parts.append(requiresCode
            ? NSLocalizedString("Code required", comment: "group access summary")
            : NSLocalizedString("No code", comment: "group access summary"))
        if let expiresAt {
            parts.append(String.localizedStringWithFormat(
                NSLocalizedString("Expires %@", comment: "group access summary"),
                expiresAt.formatted(date: .abbreviated, time: .shortened)
            ))
        } else {
            parts.append(NSLocalizedString("No expiry", comment: "group access summary"))
        }
        return parts.joined(separator: " · ")
    }
}

enum XauXatGroupAccessClaimResult: Equatable {
    case allowed(use: Int)
    case revoked
    case codeRequired
    case expired
    case exhausted
}

/// Deterministic policy evaluator used by the editor and tests. The production
/// access slots are separate SimpleX one-time invitations, so the core provides
/// the same atomic claim boundary across devices.
final class XauXatGroupAccessRuleEvaluator: @unchecked Sendable {
    private let rules: XauXatGroupAccessRules
    private let lock = NSLock()
    private var used = 0
    private var revoked = false

    init(rules: XauXatGroupAccessRules) {
        self.rules = rules
    }

    func claim(at now: Date = .now, codeAccepted: Bool) -> XauXatGroupAccessClaimResult {
        lock.lock()
        defer { lock.unlock() }
        if revoked { return .revoked }
        if rules.requiresCode && !codeAccepted { return .codeRequired }
        if let expiresAt = rules.expiresAt, expiresAt <= now { return .expired }
        if used >= rules.maxUses { return .exhausted }
        used += 1
        return .allowed(use: used)
    }

    func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }
}
