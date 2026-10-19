import Foundation
import Combine

/// Serializes complete recovery operations, not only the Tor bootstrap. The
/// native core still owns its outbox, acknowledgements and normal reconnects.
@MainActor
final class XauXatConnectionRecoveryManager: ObservableObject {
    enum State: String, Equatable {
        case idle, waiting, waitingForNetwork, verifyingTor, reconnectingRelays, monitoring, delayed
    }

    struct Relay: Hashable {
        let userId: Int64
        let server: String
    }

    struct RelayHealth {
        let connected: Int
        let connecting: Int
        let errors: Int
        let pendingSubscriptions: Int

        var needsRecovery: Bool {
            pendingSubscriptions > 0 || (connected == 0 && (errors > 0 || connecting > 0))
        }
    }

    enum Scope: Hashable {
        case automatic
        case all
        case relays(Set<Relay>)

        func covers(_ other: Scope) -> Bool {
            switch (self, other) {
            case (.all, _), (.automatic, .automatic): true
            case let (.relays(a), .relays(b)): b.isSubset(of: a)
            default: false
            }
        }
    }

    enum Reason: String { case pendingWork, foreground, networkChange, routeRetry, manual }
    enum Network: String { case unknown, wifi, cellular, ethernet, other }

    struct Context: Equatable {
        var userId: Int64?
        var online: Bool
        // Foreground availability must not depend on the chat being resumed:
        // resuming the chat itself requires a verified Tor route first.
        var active: Bool
        // A local store switch can reuse numeric profile IDs. Keep it in the
        // operation identity, but never include this flag in diagnostics.
        var alternateStore: Bool = false
    }

    enum SessionState: String {
        case running, suspended, stopped, unlockRequired, uninitialized
        var canRecover: Bool { self == .running || self == .suspended }
    }

    enum Blocker: String {
        case appInactive, networkOffline, noActiveProfile, chatStopped
        case unlockRequired, chatUninitialized, chatSuspended

        var message: String {
            switch self {
            case .appInactive: NSLocalizedString("Open XauXat to recover the private connection.", comment: "connection recovery error")
            case .networkOffline: NSLocalizedString("Waiting for a network connection. Try Wi-Fi or mobile data.", comment: "connection recovery error")
            case .noActiveProfile: NSLocalizedString("Open a chat profile before reconnecting messages.", comment: "connection recovery error")
            case .chatStopped: NSLocalizedString("Chat is stopped. Start it before reconnecting messages.", comment: "connection recovery error")
            case .unlockRequired: NSLocalizedString("Unlock XauXat before reconnecting messages.", comment: "connection recovery error")
            case .chatUninitialized: NSLocalizedString("Chat is still opening. Retry when initialization finishes.", comment: "connection recovery error")
            case .chatSuspended: NSLocalizedString("Chat could not resume after verifying Tor. Please retry.", comment: "connection recovery error")
            }
        }
    }

    struct Route {
        let port: UInt16
        let replaced: Bool
    }

    struct Dependencies {
        var context: () -> Context
        var ensureTor: (_ force: Bool) async throws -> Route
        var invalidateTor: () -> Void
        var refreshStartup: () async -> Void = { }
        // The pinned core reconnects all sessions itself when config changes.
        var applyTor: () throws -> Bool
        // Relay -> minimum observed stall duration. Explicit failed sessions
        // may use zero; still-connecting sessions need their native time budget.
        var failedRelays: () async throws -> [Relay: TimeInterval]
        var reconnect: (Scope) async throws -> Void
        var sessionState: () -> SessionState = { .running }
        var resumeChat: (_ isCurrent: @escaping () -> Bool) async throws -> Void = { _ in }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var retryJitter: () -> Double = { Double.random(in: 0.85...1.15) }
        var sleep: (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    }

    enum RecoveryError: LocalizedError {
        case blocked(Blocker), superseded
        var errorDescription: String? {
            switch self {
            case let .blocked(reason): reason.message
            case .superseded: NSLocalizedString("The connection changed during recovery. Please retry.", comment: "connection recovery error")
            }
        }
    }

    @Published private(set) var state: State = .idle
    private let dependencies: Dependencies
    private let cooldown: TimeInterval
    private let networkSettleDelay: TimeInterval
    private var epoch = 0
    private var outboundPending = false
    private var subscriptionPending = false
    private var loop: Task<Void, Never>?
    private var loopId: UUID?
    private var networkTask: Task<Void, Never>?
    private var networkSettling = false
    private var network: Network = .unknown
    private var routeRetry: (epoch: Int, context: Context)?

    private struct Flight {
        let id: UUID
        let epoch: Int
        let context: Context
        let scope: Scope
        let force: Bool
        let task: Task<Void, Error>
    }
    private var flight: Flight?
    private var lastGlobal: (epoch: Int, context: Context, time: TimeInterval)?
    private var relayAttempts: [Relay: TimeInterval] = [:]
    private var firstObserved: [Relay: TimeInterval] = [:]
    private var events: [String] = []
    private let startedAt: TimeInterval

    init(dependencies: Dependencies, cooldown: TimeInterval = 15, networkSettleDelay: TimeInterval = 1) {
        self.dependencies = dependencies
        self.cooldown = cooldown
        self.networkSettleDelay = networkSettleDelay
        self.startedAt = dependencies.now()
    }

    /// Callers share an operation only if it covers their scope, profile and
    /// network generation. A broader/newer request waits, then runs separately.
    func reconnect(_ scope: Scope = .all, reason: Reason = .manual) async throws {
        let force = reason == .manual || reason == .networkChange || reason == .routeRetry
        while true {
            try Task.checkCancellation()
            let context = dependencies.context()
            try requireAvailable(context, reason: reason)
            if let current = flight {
                let covered = current.epoch == epoch && current.context == context
                    && current.scope.covers(scope) && (!force || current.force)
                let result = await current.task.result
                try Task.checkCancellation()
                if covered { return try result.get() }
                continue
            }
            if reason != .manual, dependencies.sessionState() == .running,
               let lastGlobal, lastGlobal.epoch == epoch,
               lastGlobal.context == context, dependencies.now() - lastGlobal.time < cooldown {
                record(reason, "coalesced_recent_global")
                return
            }
            let id = UUID(), operationEpoch = epoch
            let task = Task { [self] in
                defer { if flight?.id == id { flight = nil } }
                try await perform(scope, reason: reason, force: force, context: context, epoch: operationEpoch)
            }
            flight = Flight(id: id, epoch: operationEpoch, context: context, scope: scope, force: force, task: task)
            let result = await task.result
            try Task.checkCancellation()
            return try result.get()
        }
    }

    private func requireForegroundNetwork(_ context: Context, reason: Reason) throws {
        let blocker: Blocker? = !context.active ? .appInactive : (!context.online ? .networkOffline : nil)
        if let blocker {
            record(reason, "blocked_" + blocker.rawValue)
            throw RecoveryError.blocked(blocker)
        }
    }

    /// Diagnostic route checks also work before a profile exists or while the
    /// user intentionally stopped chat. They never activate a store or core.
    func verifyRouteOnly() async throws {
        let context = dependencies.context(), operationEpoch = epoch
        try requireForegroundNetwork(context, reason: .manual)
        record(.manual, "route_only")
        do { _ = try await dependencies.ensureTor(true) }
        catch { record(.manual, "route_failed"); throw error }
        try Task.checkCancellation()
        guard operationEpoch == epoch, dependencies.context() == context else {
            record(.manual, "superseded")
            throw RecoveryError.superseded
        }
        record(.manual, "route_verified")
    }

    private func requireAvailable(_ context: Context, reason: Reason) throws {
        try requireForegroundNetwork(context, reason: reason)
        let blocker: Blocker?
        if context.userId == nil { blocker = .noActiveProfile }
        else {
            switch dependencies.sessionState() {
            case .running, .suspended: blocker = nil
            case .stopped: blocker = .chatStopped
            case .unlockRequired: blocker = .unlockRequired
            case .uninitialized: blocker = .chatUninitialized
            }
        }
        if let blocker {
            record(reason, "blocked_" + blocker.rawValue)
            throw RecoveryError.blocked(blocker)
        }
    }

    private func requireCurrent(_ context: Context, _ operationEpoch: Int, reason: Reason) throws {
        try Task.checkCancellation()
        guard epoch == operationEpoch, dependencies.context() == context else {
            record(reason, "superseded")
            throw RecoveryError.superseded
        }
        try requireAvailable(context, reason: reason)
    }

    private func requireResumed(reason: Reason) throws {
        guard dependencies.sessionState() == .running else {
            record(reason, "blocked_chatSuspended")
            throw RecoveryError.blocked(.chatSuspended)
        }
    }

    private func perform(_ requested: Scope, reason: Reason, force: Bool, context: Context, epoch operationEpoch: Int) async throws {
        do {
            try requireCurrent(context, operationEpoch, reason: reason)
            if case let .relays(relays) = requested {
                guard !relays.isEmpty, relays.allSatisfy({ $0.userId == context.userId }) else {
                    record(reason, "invalid_targets")
                    throw RecoveryError.superseded
                }
            }
            var scope = requested
            if dependencies.sessionState() == .suspended {
                // A suspended core cannot provide a reliable relay summary.
                // Verify Tor first, then resume the existing profile/session.
                scope = .all
                record(reason, "chat_resume_required")
            }
            if scope == .automatic {
                // No failed/pending session is evidence for leaving healthy
                // sessions alone, even when a delivery receipt is delayed.
                let failed: [Relay: TimeInterval]
                do { failed = try await dependencies.failedRelays() }
                catch { record(reason, "summary_failed"); throw error }
                try requireCurrent(context, operationEpoch, reason: reason)
                let now = dependencies.now()
                firstObserved = firstObserved.filter { failed[$0.key] != nil }
                var targets: Set<Relay> = []
                for (relay, grace) in failed where relay.userId == context.userId {
                    if firstObserved[relay] == nil { firstObserved[relay] = now }
                    if now - firstObserved[relay]! >= max(0, grace),
                       now - (relayAttempts[relay] ?? -.infinity) >= cooldown {
                        targets.insert(relay)
                    }
                }
                guard !targets.isEmpty else {
                    state = .monitoring
                    record(reason, "no_eligible_failed_relays")
                    return
                }
                scope = .relays(targets)
            }
            if case let .relays(relays) = scope {
                guard !relays.isEmpty, relays.allSatisfy({ $0.userId == context.userId }) else {
                    throw RecoveryError.superseded
                }
            }
            state = .verifyingTor
            record(reason, "verify_route")
            let route: Route
            do { route = try await dependencies.ensureTor(force) }
            catch {
                record(reason, "route_failed")
                if !(error is CancellationError), epoch == operationEpoch, dependencies.context() == context {
                    routeUnavailable()
                }
                throw error
            }
            try requireCurrent(context, operationEpoch, reason: reason)
            // A replaced listener invalidates every old core session. This is
            // a reason to widen a relay repair to all servers.
            if route.replaced { scope = .all; record(reason, "endpoint_replaced") }
            let configurationReconnected: Bool
            do { configurationReconnected = try dependencies.applyTor() }
            catch { record(reason, "configuration_failed"); throw error }
            try requireCurrent(context, operationEpoch, reason: reason)
            if dependencies.sessionState() != .running {
                record(reason, "resume_chat")
                do {
                    try await dependencies.resumeChat { [self] in
                        epoch == operationEpoch && dependencies.context() == context
                    }
                }
                catch { record(reason, "resume_failed"); throw error }
                try requireCurrent(context, operationEpoch, reason: reason)
                try requireResumed(reason: reason)
                record(reason, "chat_resumed")
            }
            state = .reconnectingRelays
            if configurationReconnected {
                scope = .all
                record(reason, "configuration_reconnected_all")
            } else if case let .relays(relays) = scope {
                for relay in relays {
                    relayAttempts[relay] = dependencies.now()
                    firstObserved[relay] = dependencies.now()
                }
                // Keep this in-memory map bounded when profiles/relays change.
                relayAttempts = relayAttempts.filter { dependencies.now() - $0.value < 300 }
                record(reason, "reconnect_selected", count: relays.count)
            } else {
                record(reason, "reconnect_all")
            }
            if configurationReconnected {
                // Do not immediately tear down the sessions the native config
                // change just restarted (simplexmq efaad8e setNetworkConfig).
            } else if case let .relays(relays) = scope {
                var failure: Error?
                for relay in relays.sorted(by: { $0.server < $1.server }) {
                    try requireCurrent(context, operationEpoch, reason: reason)
                    try requireResumed(reason: reason)
                    do { try await dependencies.reconnect(.relays([relay])) }
                    catch { record(reason, "relay_command_failed"); failure = error }
                }
                if let failure { throw failure }
            } else {
                try requireResumed(reason: reason)
                do { try await dependencies.reconnect(scope) }
                catch { record(reason, "relay_command_failed"); throw error }
            }
            try requireCurrent(context, operationEpoch, reason: reason)
            try requireResumed(reason: reason)
            if scope == .all {
                routeRetry = nil
                lastGlobal = (operationEpoch, context, dependencies.now())
                firstObserved.removeAll()
            }
            state = .monitoring
            record(reason, "command_accepted")
        } catch {
            if epoch == operationEpoch, dependencies.context() == context { state = .delayed }
            throw error
        }
    }

    func setOutboundPending(_ pending: Bool) { outboundPending = pending; updateLoop() }
    func setSubscriptionPending(_ pending: Bool) { subscriptionPending = pending; updateLoop() }
    private var hasPendingWork: Bool { outboundPending || subscriptionPending }
    private var needsRouteRetry: Bool {
        guard let routeRetry else { return false }
        return routeRetry.epoch == epoch && routeRetry.context == dependencies.context()
    }
    private var hasRecoveryWork: Bool { hasPendingWork || needsRouteRetry }

    /// A temporarily unavailable route also blocks incoming messages. Recover
    /// it in the foreground even when no outbound message has been queued.
    func routeUnavailable() {
        let context = dependencies.context()
        guard context.active, context.online, context.userId != nil,
              dependencies.sessionState().canRecover else { return }
        if !needsRouteRetry {
            // An old outbox check may be sleeping for 90 seconds. Promoting
            // it to a failed-route repair must start the short backoff now.
            // Cancel the scheduler only, never a caller's shared flight.
            loop?.cancel()
            loop = nil
            loopId = nil
        }
        routeRetry = (epoch, context)
        lastGlobal = nil
        record(.routeRetry, "scheduled")
        updateLoop()
    }

    static func routeRetryDelay(attempt: Int, jitter: Double) -> TimeInterval {
        let delays: [TimeInterval] = [2, 5, 10, 20, 45, 90]
        let delay = delays[min(max(0, attempt), delays.count - 1)]
        return min(90, delay * max(0.85, min(1.15, jitter)))
    }

    private func updateLoop() {
        guard hasRecoveryWork else { stopLoop(); return }
        guard loop == nil else { return }
        let context = dependencies.context()
        guard context.active, context.userId != nil, dependencies.sessionState().canRecover else {
            try? requireAvailable(context, reason: .pendingWork)
            return
        }
        let id = UUID()
        loopId = id
        loop = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while self.hasRecoveryWork && !Task.isCancelled {
                let context = self.dependencies.context()
                let operationEpoch = self.epoch
                guard context.active else { break }
                guard context.userId != nil, self.dependencies.sessionState().canRecover else {
                    try? self.requireAvailable(context, reason: .pendingWork)
                    break
                }
                if !context.online || self.networkSettling {
                    self.state = context.online ? .waiting : .waitingForNetwork
                    do { try await self.dependencies.sleep(1) } catch { break }
                    continue
                }
                self.state = attempt == 0 ? .waiting : .monitoring
                let delay = self.needsRouteRetry
                    ? Self.routeRetryDelay(attempt: attempt, jitter: self.dependencies.retryJitter())
                    : XauXatOutboundDeliveryPolicy.recoveryDelay(attempt: attempt)
                if self.needsRouteRetry { self.record(.routeRetry, "backoff", count: Int(delay.rounded(.up))) }
                do { try await self.dependencies.sleep(delay) }
                catch { break }
                // The path, profile and pending work can change during backoff.
                guard self.hasRecoveryWork, !Task.isCancelled else { break }
                guard self.epoch == operationEpoch, self.dependencies.context() == context, !self.networkSettling else { continue }
                do {
                    if self.needsRouteRetry { try await self.reconnect(.all, reason: .routeRetry) }
                    else { try await self.reconnect(.automatic, reason: .pendingWork) }
                }
                catch { /* bounded retry; the core retains pending messages */ }
                attempt += 1
            }
            guard self.loopId == id else { return }
            self.loop = nil
            self.loopId = nil
            if !self.hasRecoveryWork { self.state = .idle }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        loopId = nil
        if flight?.scope == .automatic { flight?.task.cancel() }
        if flight == nil { state = .idle }
    }

    /// Every path callback matters, including Wi-Fi -> Wi-Fi. Only the latest
    /// settled generation may reconfigure/reconnect the core.
    func networkChanged(online: Bool, network: Network = .unknown) {
        epoch += 1
        self.network = network
        routeRetry = nil
        dependencies.invalidateTor()
        // ensureReady detaches cancelled waiters without cancelling other Tor
        // clients. A new path can now check immediately after settling.
        flight?.task.cancel()
        lastGlobal = nil
        relayAttempts.removeAll()
        firstObserved.removeAll()
        networkTask?.cancel()
        networkSettling = online
        record(.networkChange, online ? "path_online_" + network.rawValue : "path_offline")
        if !online { state = .waitingForNetwork; return }
        let expectedEpoch = epoch
        networkTask = Task { [weak self] in
            guard let self else { return }
            let settle = network == .cellular ? self.networkSettleDelay * 2 : self.networkSettleDelay
            do { try await self.dependencies.sleep(settle) } catch { return }
            guard self.epoch == expectedEpoch, !Task.isCancelled else { return }
            self.networkSettling = false
            do { try self.requireForegroundNetwork(self.dependencies.context(), reason: .networkChange) }
            catch { return }
            // The very first Tor bootstrap precedes any profile or database.
            // Refresh only its existing callers; this opens no store/core.
            await self.dependencies.refreshStartup()
            guard self.epoch == expectedEpoch, !Task.isCancelled else { return }
            do { try self.requireAvailable(self.dependencies.context(), reason: .networkChange) }
            catch { return }
            do { try await self.reconnect(.all, reason: .networkChange) } catch { }
            self.updateLoop()
        }
    }

    func pause() {
        record(.foreground, "paused")
        epoch += 1
        routeRetry = nil
        dependencies.invalidateTor()
        networkTask?.cancel()
        networkTask = nil
        networkSettling = false
        stopLoop()
        flight?.task.cancel()
        lastGlobal = nil
        relayAttempts.removeAll()
        firstObserved.removeAll()
        state = .idle
    }

    func resume() { updateLoop() }

    /// Foreground must apply a changed endpoint before activating the core.
    /// Account for that native global reconnect when activation completes.
    func configurationApplied() {
        let context = dependencies.context()
        guard context.active, context.online else { return }
        routeRetry = nil
        lastGlobal = (epoch, context, dependencies.now())
        firstObserved.removeAll()
        record(.foreground, "configuration_reconnected_all")
    }

    // Only allowlisted stages, elapsed seconds and aggregate counts. Never
    // interpolate errors, server addresses, user IDs or message/contact data.
    private func record(_ reason: Reason, _ stage: String, count: Int? = nil) {
        let elapsed = Int(max(0, dependencies.now() - startedAt))
        events.append("+\(elapsed)s \(reason.rawValue) \(stage)\(count.map { " count=\($0)" } ?? "")")
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }

    var diagnosticText: String {
        let context = dependencies.context()
        return "Connection recovery (current app process)\n"
            + "foreground=\(context.active) online=\(context.online) network=\(network.rawValue) profile_available=\(context.userId != nil) session=\(dependencies.sessionState().rawValue) recovery=\(state.rawValue) route_retry=\(needsRouteRetry)\n"
            + events.joined(separator: "\n")
    }
}
