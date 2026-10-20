import Foundation

// Keep Keychain I/O deterministic while executing the production policy code.
enum XauXatStorageScope { case primary, decoy }
var scope = XauXatStorageScope.primary
func xauXatStorageScope() -> XauXatStorageScope { scope }
var values: [String: String] = [:]
var failRemoval = false
struct KeyChainItem {
    let forKey: String
    func get() -> String? { values[forKey] }
    func set(_ value: String) -> Bool { values[forKey] = value; return true }
    func remove() -> Bool {
        if failRemoval { return false }
        values[forKey] = nil
        return true
    }
}
let kcPrimaryContactInvitePolicies = KeyChainItem(forKey: "primary")
let kcDecoyContactInvitePolicies = KeyChainItem(forKey: "decoy")
let xauXatContactInvitePoliciesLock = NSLock()

@main struct InvitePolicyTests {
    static var checks = 0
    static func require(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError(message) }
    }
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000)
        let old = XauXatContactInvitePolicy(connectionId: 7, createdAt: now, bundleId: "old-bundle", maxUses: 2)
        require(xauXatSaveContactInvitePolicy(old), "Store the old database's restricted invite")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked, "A reused numeric ID alone retrieves the old database's revoked invitation")
        scope = .decoy
        require(xauXatSaveContactInvitePolicy(old), "Seed the separate local profile")
        scope = .primary
        require(xauXatRemoveContactInvitePolicies(.primary), "A new/deleted primary database clears its old invite policies")
        require(xauXatObserveContactInvitePolicy(connectionId: 7) == nil, "Reused connection IDs cannot inherit Revoked or the old bundle after database replacement")
        scope = .decoy
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.maxUses == 2, "Resetting one database must preserve the other local profile's policies")
        scope = .primary
        require(xauXatRemoveContactInvitePolicies(.primary), "Cleanup is idempotent")

        require(xauXatSaveContactInvitePolicy(old), "Seed an already affected installation")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        let fresh = XauXatContactInvitePolicy(connectionId: 7, createdAt: now.addingTimeInterval(60))
        require(xauXatSaveContactInvitePolicy(fresh), "A newly allocated invite always writes a fresh policy, including Free invites")
        let observed = xauXatObserveContactInvitePolicy(connectionId: 7)!
        require(observed.state == .active && observed.bundleId == nil && observed.maxUses == nil, "An ordinary new invitation cannot inherit a stale bundle or revoked state")
        _ = xauXatSetContactInviteState(connectionId: 7, state: .revoked)
        _ = xauXatSetContactInviteState(connectionId: 7, state: .active)
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked, "Existing revocations remain terminal; observing/reopening never reactivates them")
        failRemoval = true
        require(!xauXatRemoveContactInvitePolicies(.primary), "Cleanup failures are reported so a fresh database cannot silently reuse old policies")
        require(xauXatObserveContactInvitePolicy(connectionId: 7)?.state == .revoked, "A failed cleanup does not silently rewrite stored data")
        failRemoval = false

        require(xauXatPendingContactInviteStatus([]) == "Active", "A pending native invite without an advanced policy is active, not Fully used or Revoked")
        require(xauXatPendingContactInviteStatus([fresh]) == "Active", "Fresh policy is active")
        var used = fresh
        used.state = .used
        var revoked = fresh
        revoked.state = .revoked
        var expired = fresh
        expired.state = .expired
        require(xauXatPendingContactInviteStatus([used, fresh]) == "Active", "A partially used bundle still has an active invite")
        require(xauXatPendingContactInviteStatus([used, used]) == "Fully used", "Only a nonempty fully consumed bundle is Fully used")
        require(xauXatPendingContactInviteStatus([revoked]) == "Revoked", "Revoked remains visible for genuinely revoked invitations")
        require(xauXatPendingContactInviteStatus([used, expired]) == "Expired", "Expiry is not mistaken for revocation")
        print("Production invite policy regression checks passed: \(checks)")
    }
}
