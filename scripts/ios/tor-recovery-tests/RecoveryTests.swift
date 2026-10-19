import Foundation

typealias Recovery = XauXatConnectionRecoveryManager

@MainActor final class RecoveryFixture {
    var context = Recovery.Context(userId: 1, online: true, active: true)
    let first = Recovery.Relay(userId: 1, server: "smp://private-relay-a.example")
    let second = Recovery.Relay(userId: 1, server: "smp://private-relay-b.example")
    var failed: Set<Recovery.Relay> = []
    var connectingGrace: TimeInterval = 0
    var commands: [Recovery.Scope] = []
    var forces: [Bool] = []
    var applyCount = 0
    var summaryCount = 0
    var invalidations = 0
    var clock: TimeInterval = 100
    var route = Recovery.Route(port: 19050, replaced: false)
    var sessionState: Recovery.SessionState = .running
    var resumeCount = 0
    var resume: (() async throws -> Void)?
    var ensure: (() async throws -> Void)?
    var applyFailure = false
    var configurationReconnected = false
    var relayFailure: Recovery.Relay?
    var onReconnect: ((Recovery.Scope) async -> Void)?
    var sleep: (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
    lazy var manager = Recovery(dependencies: .init(
        context: { self.context },
        ensureTor: { force in
            self.forces.append(force)
            try await self.ensure?()
            return self.route
        },
        invalidateTor: { self.invalidations += 1 },
        applyTor: {
            self.applyCount += 1
            if self.applyFailure { throw Failure.synthetic }
            return self.configurationReconnected
        },
        failedRelays: {
            self.summaryCount += 1
            return Dictionary(uniqueKeysWithValues: self.failed.map { ($0, self.connectingGrace) })
        },
        reconnect: { scope in
            self.commands.append(scope)
            await self.onReconnect?(scope)
            if let relay = self.relayFailure, scope == .relays([relay]) { throw Failure.synthetic }
        },
        sessionState: { self.sessionState },
        resumeChat: { isCurrent in
            self.resumeCount += 1
            try await self.resume?()
            guard isCurrent() else { throw Recovery.RecoveryError.superseded }
            self.sessionState = .running
        },
        now: { self.clock },
        retryJitter: { 1 },
        sleep: { try await self.sleep($0) }
    ), networkSettleDelay: 0.02)

    enum Failure: Error { case synthetic }
}

@main @MainActor struct RecoveryTests {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) {
        checks += 1
        guard value else { fatalError(message) }
    }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("Timed out waiting for recovery condition")
    }
    static func failed(_ task: Task<Void, Error>, _ message: String) async {
        do { try await task.value; fatalError(message) } catch { require(true, message) }
    }

    static func main() async throws {
        try await suspendedChatVerifiesTorBeforeResuming()
        try await suspendedChatCannotWidenStaleProfileTargets()
        try await blockedRequestsExplainWhy()
        try await routeOnlyDoesNotActivateAStoppedOrMissingProfile()
        try await routeOnlyRejectsLateResults()
        try await changedContextCannotResumeAfterTor()
        try await failedRouteCannotResumeChat()
        try await failedResumeCannotReconnect()
        try await unlockDuringVerificationPreventsCoreCommands()
        try await identicalRequestsShareWholeOperation()
        try await cancelledWaiterCannotAbortSharedOperation()
        relayHealthSelection()
        try await automaticRecoveryIsSelective()
        try await emptyAndHealthySnapshotsDoNotDisturbTor()
        try await broaderRequestWaitsForNarrowerOperation()
        try await globalOperationCoversConcurrentAutomaticRequest()
        try await replacementEndpointWidensRecovery()
        try await changedConfigurationDoesNotReconnectTwice()
        try await newPathCannotReuseOldOperation()
        try await pathChangeStopsRemainingRelayCommands()
        try await offlineAndProfileChangesDiscardLateResults()
        try await pausePreventsLateReconnect()
        try await failuresStayClosedAndDiagnosticsStayPrivate()
        try await failedRelayDoesNotPreventOtherRepairs()
        try await automaticRetriesRespectCooldown()
        try await connectingSessionsGetTheirNativeTimeBudget()
        try await pendingWorkCanFinishDuringBackoff()
        try await offlineDuringBackoffDoesNotReconnect()
        try await pathFlapsSettleOnce()
        try await failedHandoverRetriesWithoutAnOutbox()
        try await routeRetriesBackOffAndStopAfterSuccess()
        try await routeRetriesRespectContextAndSessionGates()
        try await clearingOutboxDoesNotCancelRouteRecovery()
        try await verifiedConfigurationStopsRouteRetries()
        try await failedRouteInterruptsAnOlderOutboxBackoff()
        routeRetryTimingIsBounded()
        try await diagnosticJournalIsBounded()
        print("Coordinated recovery regression checks passed: \(checks)")
    }

    static func suspendedChatVerifiesTorBeforeResuming() async throws {
        for reason in [Recovery.Reason.manual, .networkChange, .pendingWork] {
            let f = RecoveryFixture()
            f.sessionState = .suspended
            f.ensure = {
                require(f.resumeCount == 0 && f.commands.isEmpty, "Tor must be checked before chat activation")
            }
            f.resume = {
                require(f.forces.count == 1 && f.applyCount == 1, "Verified routing must be applied before activation")
                require(f.commands.isEmpty, "No relay commands may precede activation")
            }
            try await f.manager.reconnect(reason == .pendingWork ? .automatic : .all, reason: reason)
            require(f.sessionState == .running && f.resumeCount == 1 && f.commands == [.all], "Foreground recovery must resume a suspended chat")
            require(f.summaryCount == 0, "A suspended core cannot be queried for relay health first")
            require(f.manager.diagnosticText.contains("chat_resumed"), "Export must explain successful chat resumption")
        }
    }

    static func blockedRequestsExplainWhy() async throws {
        for blocker in [Recovery.Blocker.appInactive, .networkOffline, .noActiveProfile, .chatStopped, .unlockRequired, .chatUninitialized] {
            let f = RecoveryFixture()
            switch blocker {
            case .appInactive: f.context.active = false
            case .networkOffline: f.context.online = false
            case .noActiveProfile: f.context.userId = nil
            case .chatStopped: f.sessionState = .stopped
            case .unlockRequired: f.sessionState = .unlockRequired
            case .chatUninitialized: f.sessionState = .uninitialized
            default: fatalError("Unexpected fixture blocker")
            }
            do { try await f.manager.reconnect(); fatalError("Unavailable context must fail") }
            catch let error as Recovery.RecoveryError {
                guard case let .blocked(actual) = error else { fatalError("Expected specific blocker") }
                require(actual == blocker, "UI error must identify the actual preflight blocker")
            }
            require(f.manager.diagnosticText.contains("blocked_" + blocker.rawValue), "Preflight failures must not disappear from diagnostics")
            require(f.forces.isEmpty && f.applyCount == 0 && f.resumeCount == 0 && f.commands.isEmpty, "Unavailable context must do no core work")
        }
    }

    static func suspendedChatCannotWidenStaleProfileTargets() async throws {
        let f = RecoveryFixture()
        f.sessionState = .suspended
        let stale = Recovery.Relay(userId: 2, server: "smp://old-profile.example")
        await failed(Task { try await f.manager.reconnect(.relays([stale])) }, "Stale profile targets cannot become a global repair when suspended")
        require(f.forces.isEmpty && f.applyCount == 0 && f.resumeCount == 0 && f.commands.isEmpty, "Validate requested profile before widening recovery")
    }

    static func routeOnlyDoesNotActivateAStoppedOrMissingProfile() async throws {
        for state in [Recovery.SessionState.stopped, .uninitialized, .unlockRequired] {
            let f = RecoveryFixture()
            f.context.userId = nil
            f.sessionState = state
            try await f.manager.verifyRouteOnly()
            require(f.forces == [true] && f.applyCount == 0 && f.resumeCount == 0 && f.commands.isEmpty, "Route diagnostics must never activate/open a protected or stopped chat")
        }
        for online in [true, false] {
            let f = RecoveryFixture()
            f.context.active = !online
            f.context.online = online
            await failed(Task { try await f.manager.verifyRouteOnly() }, "Route-only checks require foreground and network")
            require(f.forces.isEmpty, "Background/offline diagnostic checks must not start Tor work")
        }
    }

    static func routeOnlyRejectsLateResults() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.ensure = { await withCheckedContinuation { held = $0 } }
        let operation = Task { try await f.manager.verifyRouteOnly() }
        try await until { held != nil }
        f.context.online = false
        f.manager.networkChanged(online: false)
        held!.resume()
        await failed(operation, "A stale route-only check cannot report success")
        require(!f.manager.diagnosticText.contains("route_verified"), "No green route result may survive a network change")
    }

    static func changedContextCannotResumeAfterTor() async throws {
        for change in 0..<4 {
            let f = RecoveryFixture()
            f.sessionState = .suspended
            var held: CheckedContinuation<Void, Never>?
            f.resume = { await withCheckedContinuation { held = $0 } }
            let operation = Task { try await f.manager.reconnect() }
            try await until { held != nil }
            switch change {
            case 0: f.context.active = false; f.manager.pause()
            case 1: f.context.userId = 2
            case 2: f.context.alternateStore = true
            default: f.context.online = false; f.manager.networkChanged(online: false)
            }
            held!.resume()
            await failed(operation, "An NSE activation waiter must reject stale foreground/profile/path state")
            require(f.sessionState == .suspended && f.commands.isEmpty, "Invalidated activation cannot resume or reconnect the core")
            require(!f.manager.diagnosticText.contains("alternateStore"), "Diagnostics must not disclose local store selection")
        }
    }

    static func failedRouteCannotResumeChat() async throws {
        let f = RecoveryFixture()
        f.sessionState = .suspended
        f.ensure = { throw RecoveryFixture.Failure.synthetic }
        await failed(Task { try await f.manager.reconnect() }, "Tor failure must propagate")
        require(f.resumeCount == 0 && f.applyCount == 0 && f.commands.isEmpty, "Chat must stay suspended until Tor is verified")
        f.manager.pause()
    }

    static func failedResumeCannotReconnect() async throws {
        let f = RecoveryFixture()
        f.sessionState = .suspended
        f.resume = { throw RecoveryFixture.Failure.synthetic }
        await failed(Task { try await f.manager.reconnect() }, "Activation failure must propagate")
        require(f.commands.isEmpty && f.manager.diagnosticText.contains("resume_failed"), "Failed activation must not send relay commands")
    }

    static func unlockDuringVerificationPreventsCoreCommands() async throws {
        let f = RecoveryFixture()
        f.sessionState = .suspended
        f.ensure = { f.sessionState = .unlockRequired }
        await failed(Task { try await f.manager.reconnect() }, "A protected store becoming locked must stop recovery")
        require(f.applyCount == 0 && f.resumeCount == 0 && f.commands.isEmpty, "A late Tor result cannot bypass store authentication")
    }

    static func identicalRequestsShareWholeOperation() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.ensure = { await withCheckedContinuation { held = $0 } }
        let first = Task { try await f.manager.reconnect(.all) }
        try await until { held != nil }
        let second = Task { try await f.manager.reconnect(.all) }
        try await Task.sleep(nanoseconds: 10_000_000)
        held!.resume()
        try await first.value
        try await second.value
        require(f.forces == [true] && f.applyCount == 1 && f.commands == [.all], "Concurrent requests must share Tor, config and core reconnect")
    }

    static func cancelledWaiterCannotAbortSharedOperation() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.ensure = { await withCheckedContinuation { held = $0 } }
        let owner = Task { try await f.manager.reconnect(.all) }
        try await until { held != nil }
        let waiter = Task { try await f.manager.reconnect(.all) }
        try await Task.sleep(nanoseconds: 10_000_000)
        owner.cancel()
        held!.resume()
        await failed(owner, "Cancelled caller must receive cancellation")
        try await waiter.value
        require(f.commands == [.all], "A cancelled waiter must not cancel shared work needed by another caller")
    }

    static func relayHealthSelection() {
        require(!Recovery.RelayHealth(connected: 1, connecting: 0, errors: 1, pendingSubscriptions: 0).needsRecovery,
                "A connected relay must not be reset merely because an error counter is nonzero")
        require(Recovery.RelayHealth(connected: 1, connecting: 0, errors: 0, pendingSubscriptions: 1).needsRecovery,
                "A pending subscription on a shared relay still needs recovery")
        require(Recovery.RelayHealth(connected: 0, connecting: 1, errors: 0, pendingSubscriptions: 0).needsRecovery,
                "An attempted but stalled connection is eligible after backoff")
        require(Recovery.RelayHealth(connected: 0, connecting: 0, errors: 1, pendingSubscriptions: 0).needsRecovery,
                "An errored disconnected session needs recovery")
        require(!Recovery.RelayHealth(connected: 0, connecting: 0, errors: 0, pendingSubscriptions: 0).needsRecovery,
                "An unused relay is not evidence of a failed connection")
    }

    static func automaticRecoveryIsSelective() async throws {
        let f = RecoveryFixture()
        f.failed = [f.first, f.second, .init(userId: 2, server: "another-profile")]
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(Set(f.commands) == Set([.relays([f.first]), .relays([f.second])]), "Only failed relays in the selected profile may reconnect")
        require(f.forces == [false] && f.applyCount == 1, "Automatic recovery may reuse recent verification and must apply its route once")
    }

    static func emptyAndHealthySnapshotsDoNotDisturbTor() async throws {
        let f = RecoveryFixture()
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands.isEmpty && f.forces.isEmpty && f.applyCount == 0, "No failed sessions must leave healthy Tor/relays untouched")
    }

    static func broaderRequestWaitsForNarrowerOperation() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.ensure = { if f.forces.count == 1 { await withCheckedContinuation { held = $0 } } }
        let first = Task { try await f.manager.reconnect(.relays([f.first])) }
        try await until { held != nil }
        let broader = Task { try await f.manager.reconnect(.all) }
        try await Task.sleep(nanoseconds: 10_000_000)
        require(f.forces.count == 1, "Broader recovery must not run concurrently")
        held!.resume()
        try await first.value
        try await broader.value
        require(f.commands == [.relays([f.first]), .all], "A narrow operation cannot falsely satisfy a global request")
    }

    static func globalOperationCoversConcurrentAutomaticRequest() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.ensure = { await withCheckedContinuation { held = $0 } }
        let global = Task { try await f.manager.reconnect(.all) }
        try await until { held != nil }
        let automatic = Task { try await f.manager.reconnect(.automatic, reason: .pendingWork) }
        try await Task.sleep(nanoseconds: 10_000_000)
        held!.resume()
        try await global.value
        try await automatic.value
        require(f.commands == [.all] && f.summaryCount == 0, "Global repair must satisfy concurrent pending-work requests")
    }

    static func replacementEndpointWidensRecovery() async throws {
        let f = RecoveryFixture()
        f.failed = [f.first]
        f.route = .init(port: 19051, replaced: true)
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands == [.all] && f.applyCount == 1, "A replaced SOCKS endpoint must be applied before reconnecting every old session")
    }

    static func changedConfigurationDoesNotReconnectTwice() async throws {
        let f = RecoveryFixture()
        f.failed = [f.first]
        f.configurationReconnected = true
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.applyCount == 1 && f.commands.isEmpty, "Native configuration reconnect must not be followed by a duplicate reconnect command")
        try await f.manager.reconnect(.all, reason: .foreground)
        require(f.forces.count == 1, "Native global reconnect must satisfy a recent foreground request")
        let foreground = RecoveryFixture()
        foreground.manager.configurationApplied()
        try await foreground.manager.reconnect(.automatic, reason: .pendingWork)
        require(foreground.commands.isEmpty && foreground.forces.isEmpty, "Foreground config application must cover immediate pending recovery")
    }

    static func newPathCannotReuseOldOperation() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.ensure = { if f.forces.count == 1 { await withCheckedContinuation { held = $0 } } }
        let old = Task { try await f.manager.reconnect(.all) }
        try await until { held != nil }
        f.manager.networkChanged(online: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        held!.resume()
        await failed(old, "An old path result must be discarded")
        try await until { f.commands.count == 1 }
        require(f.forces == [true, true] && f.commands == [.all] && f.applyCount == 1, "Latest path must force a fresh verification and exactly one reconnect")
        require(f.invalidations == 1, "Even same-type online paths must invalidate route freshness")
    }

    static func pathChangeStopsRemainingRelayCommands() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.onReconnect = { _ in await withCheckedContinuation { held = $0 } }
        let operation = Task { try await f.manager.reconnect(.relays([f.first, f.second])) }
        try await until { held != nil }
        f.context.online = false
        f.manager.networkChanged(online: false)
        held!.resume()
        await failed(operation, "An old relay batch must stop when the path changes")
        require(f.commands.count == 1, "Remaining relay commands cannot run after a path change")
    }

    static func offlineAndProfileChangesDiscardLateResults() async throws {
        for changeProfile in [false, true] {
            let f = RecoveryFixture()
            var held: CheckedContinuation<Void, Never>?
            f.ensure = { await withCheckedContinuation { held = $0 } }
            let operation = Task { try await f.manager.reconnect(.all) }
            try await until { held != nil }
            if changeProfile { f.context.userId = 2 }
            else { f.context.online = false; f.manager.networkChanged(online: false) }
            held!.resume()
            await failed(operation, "A changed context must reject a late route")
            require(f.applyCount == 0 && f.commands.isEmpty, "Late results must not reconfigure a different profile or offline core")
        }
    }

    static func pausePreventsLateReconnect() async throws {
        let f = RecoveryFixture()
        var held: CheckedContinuation<Void, Never>?
        f.ensure = { await withCheckedContinuation { held = $0 } }
        let operation = Task { try await f.manager.reconnect(.all) }
        try await until { held != nil }
        f.context.active = false
        f.manager.pause()
        held!.resume()
        await failed(operation, "Suspended recovery must not resume with a late Tor result")
        require(f.commands.isEmpty && f.applyCount == 0, "Background transition must prevent late core work")
    }

    static func failuresStayClosedAndDiagnosticsStayPrivate() async throws {
        for failureInRoute in [true, false] {
            let f = RecoveryFixture()
            if failureInRoute { f.ensure = { throw RecoveryFixture.Failure.synthetic } }
            else { f.applyFailure = true }
            await failed(Task { try await f.manager.reconnect(.relays([f.first])) }, "Failed route/config must propagate")
            require(f.commands.isEmpty, "Failed verification/configuration cannot issue reconnect commands")
            require(!f.manager.diagnosticText.contains("private-relay") && !f.manager.diagnosticText.contains("synthetic"), "Export must exclude addresses and raw error details")
            f.manager.pause()
        }
    }

    static func failedRelayDoesNotPreventOtherRepairs() async throws {
        let f = RecoveryFixture()
        f.relayFailure = f.first
        await failed(Task { try await f.manager.reconnect(.relays([f.first, f.second])) }, "Relay failure must be reported")
        require(f.commands == [.relays([f.first]), .relays([f.second])], "One failed command must not starve other selected relays")
    }

    static func automaticRetriesRespectCooldown() async throws {
        let f = RecoveryFixture()
        f.failed = [f.first]
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands.count == 1, "Duplicate automatic requests must respect each relay's cooldown")
        f.clock += 16
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands.count == 2, "Failed sessions must remain eligible after bounded cooldown")
        try await f.manager.reconnect(.all)
        try await f.manager.reconnect(.all, reason: .foreground)
        require(f.commands.count == 3, "Recent global recovery must cover a redundant foreground request")
        try await f.manager.reconnect(.all)
        require(f.commands.count == 4, "Explicit manual retry must bypass the success cooldown")
    }

    static func connectingSessionsGetTheirNativeTimeBudget() async throws {
        let f = RecoveryFixture()
        f.failed = [f.first]
        f.connectingGrace = 100
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        f.clock += 99
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands.isEmpty && f.forces.isEmpty, "A still-connecting relay must get its native connect/command time budget")
        f.clock += 1
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands == [.relays([f.first])], "A persistently stalled connection must eventually be recovered")
        f.clock += 16
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands.count == 1, "A restarted connection must receive a new grace window")
        f.failed = []
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        f.clock += 200
        f.failed = [f.first]
        try await f.manager.reconnect(.automatic, reason: .pendingWork)
        require(f.commands.count == 1, "A recovered relay cannot inherit an old stall timer on a new incident")
    }

    static func pendingWorkCanFinishDuringBackoff() async throws {
        let f = RecoveryFixture()
        var sleeping = false
        f.sleep = { _ in sleeping = true; try await Task.sleep(nanoseconds: 100_000_000) }
        f.failed = [f.first]
        f.manager.setOutboundPending(true)
        try await until { sleeping }
        f.manager.setOutboundPending(false)
        try await Task.sleep(nanoseconds: 15_000_000)
        require(f.commands.isEmpty && f.forces.isEmpty, "Finishing delivery during backoff must cancel recovery")
    }

    static func offlineDuringBackoffDoesNotReconnect() async throws {
        let f = RecoveryFixture()
        var sleeping = false
        f.sleep = { _ in sleeping = true; try await Task.sleep(nanoseconds: 20_000_000) }
        f.failed = [f.first]
        f.manager.setOutboundPending(true)
        try await until { sleeping }
        f.context.online = false
        try await Task.sleep(nanoseconds: 35_000_000)
        require(f.commands.isEmpty && f.forces.isEmpty, "An offline transition during retry sleep must suppress network work")
        f.manager.pause()
    }

    static func pathFlapsSettleOnce() async throws {
        let f = RecoveryFixture()
        f.manager.networkChanged(online: true)
        f.context.online = false
        f.manager.networkChanged(online: false)
        f.context.online = true
        f.manager.networkChanged(online: true)
        try await until { f.commands.count == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        require(f.commands == [.all] && f.forces == [true] && f.invalidations == 3, "Flapping paths must produce one fresh recovery after settling")
    }

    static func failedHandoverRetriesWithoutAnOutbox() async throws {
        let f = RecoveryFixture()
        f.sessionState = .suspended
        var delays: [TimeInterval] = []
        f.sleep = { delay in
            delays.append(delay)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        f.ensure = { if f.forces.count == 1 { throw RecoveryFixture.Failure.synthetic } }
        f.manager.networkChanged(online: true, network: .cellular)
        try await until { f.commands == [.all] }
        require(delays.first == 0.04 && delays.contains(2), "Cellular handover must settle before a separately backed-off route retry")
        require(f.forces == [true, true] && f.summaryCount == 0, "An unavailable incoming route needs fresh verification even with an empty outbox")
        require(f.resumeCount == 1 && f.applyCount == 1, "Only the successful retry may resume messaging")
        require(f.manager.diagnosticText.contains("network=cellular") && f.manager.diagnosticText.contains("route_retry=false"), "Safe diagnostics must identify cellular handover and resolved retry demand")
        f.manager.pause()
    }

    static func routeRetriesBackOffAndStopAfterSuccess() async throws {
        let f = RecoveryFixture()
        var delays: [TimeInterval] = []
        f.sleep = { delay in
            delays.append(delay)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        f.ensure = { if f.forces.count < 4 { throw RecoveryFixture.Failure.synthetic } }
        await failed(Task { try await f.manager.reconnect() }, "Initial unavailable route must be reported")
        try await until { f.commands == [.all] }
        try await Task.sleep(nanoseconds: 15_000_000)
        require(delays == [2, 5, 10], "Persistent route failure must back off rather than spin")
        require(f.forces == [true, true, true, true] && f.applyCount == 1, "Every route retry must be fresh and stay closed until success")
        require(f.manager.diagnosticText.contains("route_retry=false"), "A successful global repair must stop route-only retries")
        f.manager.pause()
    }

    static func routeRetriesRespectContextAndSessionGates() async throws {
        for change in 0..<7 {
            let f = RecoveryFixture()
            var sleeping: CheckedContinuation<Void, Error>?
            f.sleep = { _ in try await withCheckedThrowingContinuation { sleeping = $0 } }
            f.manager.routeUnavailable()
            try await until { sleeping != nil }
            switch change {
            case 0: f.context.active = false; f.manager.pause()
            case 1: f.context.online = false; f.manager.networkChanged(online: false)
            case 2: f.context.userId = 2
            case 3: f.context.alternateStore = true
            case 4: f.sessionState = .stopped
            case 5: f.sessionState = .unlockRequired
            default: f.sessionState = .uninitialized
            }
            sleeping!.resume()
            try await Task.sleep(nanoseconds: 15_000_000)
            require(f.forces.isEmpty && f.commands.isEmpty && f.resumeCount == 0, "A delayed route retry cannot cross a lifecycle, profile, store or session gate")
            f.manager.pause()
        }
    }

    static func clearingOutboxDoesNotCancelRouteRecovery() async throws {
        let f = RecoveryFixture()
        var sleeping: CheckedContinuation<Void, Error>?
        f.sleep = { _ in try await withCheckedThrowingContinuation { sleeping = $0 } }
        f.manager.routeUnavailable()
        try await until { sleeping != nil }
        f.manager.setOutboundPending(false)
        f.manager.setSubscriptionPending(false)
        sleeping!.resume()
        try await until { f.commands == [.all] }
        require(f.forces == [true], "Incoming route recovery must survive an empty outbox and subscription summary")
        f.manager.pause()
    }

    static func verifiedConfigurationStopsRouteRetries() async throws {
        let f = RecoveryFixture()
        var sleeping: CheckedContinuation<Void, Error>?
        f.sleep = { _ in try await withCheckedThrowingContinuation { sleeping = $0 } }
        f.manager.routeUnavailable()
        try await until { sleeping != nil }
        f.manager.configurationApplied()
        sleeping!.resume()
        try await Task.sleep(nanoseconds: 15_000_000)
        require(f.forces.isEmpty && f.manager.diagnosticText.contains("route_retry=false"), "A verified foreground configuration reconnect must satisfy pending route recovery")
        f.manager.pause()
    }

    static func failedRouteInterruptsAnOlderOutboxBackoff() async throws {
        let f = RecoveryFixture()
        var oldSleep: CheckedContinuation<Void, Error>?
        var delays: [TimeInterval] = []
        f.sleep = { delay in
            delays.append(delay)
            if delay == 8 { try await withCheckedThrowingContinuation { oldSleep = $0 } }
            else { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        f.manager.setOutboundPending(true)
        try await until { oldSleep != nil }
        f.ensure = { if f.forces.count == 1 { throw RecoveryFixture.Failure.synthetic } }
        await failed(Task { try await f.manager.reconnect() }, "Failed manual route must schedule prompt recovery")
        try await until { f.commands == [.all] }
        require(Array(delays.prefix(2)) == [8, 2], "Route failure must replace an older outbox backoff immediately")
        f.manager.setOutboundPending(false)
        oldSleep!.resume()
        f.manager.pause()
    }

    static func routeRetryTimingIsBounded() {
        require(Recovery.routeRetryDelay(attempt: -1, jitter: 1) == 2, "First route retry must be prompt")
        require(Recovery.routeRetryDelay(attempt: 1000, jitter: 100) == 90, "Long outages must have a capped retry rate")
        require(Recovery.routeRetryDelay(attempt: 1, jitter: -10) == 4.25, "Jitter must be bounded below")
    }

    static func diagnosticJournalIsBounded() async throws {
        let f = RecoveryFixture()
        for _ in 0..<100 { try await f.manager.reconnect(.automatic, reason: .pendingWork) }
        require(f.manager.diagnosticText.split(separator: "\n").filter { $0.hasPrefix("+") }.count == 80, "Diagnostic journal must retain at most 80 events plus its snapshot")
    }
}
