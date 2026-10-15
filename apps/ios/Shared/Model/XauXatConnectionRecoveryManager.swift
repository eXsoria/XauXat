import Foundation
import Combine

/// Serializes complete recovery operations, not only the Tor bootstrap. The
/// native core still owns its outbox, acknowledgements and normal reconnects.
@MainActor
final class XauXatConnectionRecoveryManager: ObservableObject {
    enum State: Equatable {
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

    enum Reason: String { case pendingWork, foreground, networkChange, manual }

    struct Context: Equatable {
        var userId: Int64?
        var online: Bool
        var active: Bool
    }

    struct Route {
        let port: UInt16
        let replaced: Bool
    }

    struct Dependencies {
        var context: () -> Context
        var ensureTor: (_ force: Bool) async throws -> Route
        var invalidateTor: () -> Void
        // The pinned core reconnects all sessions itself when config changes.
        var applyTor: () throws -> Bool
        // Relay -> minimum observed stall duration. Explicit failed sessions
        // may use zero; still-connecting sessions need their native time budget.
        var failedRelays: () async throws -> [Relay: TimeInterval]
        var reconnect: (Scope) async throws -> Void
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    }

    enum RecoveryError: LocalizedError {
        case unavailable, superseded
        var errorDescription: String? {
            switch self {
            case .unavailable: NSLocalizedString("Recovery is waiting for an active app and a network connection.", comment: "connection recovery error")
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
        let force = reason == .manual || reason == .networkChange
        while true {
            try Task.checkCancellation()
            let context = dependencies.context()
            guard context.active, context.online, context.userId != nil else { throw RecoveryError.unavailable }
            if let current = flight {
                let covered = current.epoch == epoch && current.context == context
                    && current.scope.covers(scope) && (!force || current.force)
                let result = await current.task.result
                try Task.checkCancellation()
                if covered { return try result.get() }
                continue
            }
            if reason != .manual, let lastGlobal, lastGlobal.epoch == epoch,
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

    private func requireCurrent(_ context: Context, _ operationEpoch: Int) throws {
        try Task.checkCancellation()
        guard epoch == operationEpoch, dependencies.context() == context else { throw RecoveryError.superseded }
        guard context.active, context.online, context.userId != nil else { throw RecoveryError.unavailable }
    }

    private func perform(_ requested: Scope, reason: Reason, force: Bool, context: Context, epoch operationEpoch: Int) async throws {
        do {
            try requireCurrent(context, operationEpoch)
            var scope = requested
            if scope == .automatic {
                // No failed/pending session is evidence for leaving healthy
                // sessions alone, even when a delivery receipt is delayed.
                let failed: [Relay: TimeInterval]
                do { failed = try await dependencies.failedRelays() }
                catch { record(reason, "summary_failed"); throw error }
                try requireCurrent(context, operationEpoch)
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
            catch { record(reason, "route_failed"); throw error }
            try requireCurrent(context, operationEpoch)
            // A replaced listener invalidates every old core session. This is
            // a reason to widen a relay repair to all servers.
            if route.replaced { scope = .all; record(reason, "endpoint_replaced") }
            let configurationReconnected: Bool
            do { configurationReconnected = try dependencies.applyTor() }
            catch { record(reason, "configuration_failed"); throw error }
            try requireCurrent(context, operationEpoch)
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
                    try requireCurrent(context, operationEpoch)
                    do { try await dependencies.reconnect(.relays([relay])) }
                    catch { record(reason, "relay_command_failed"); failure = error }
                }
                if let failure { throw failure }
            } else {
                do { try await dependencies.reconnect(scope) }
                catch { record(reason, "relay_command_failed"); throw error }
            }
            try requireCurrent(context, operationEpoch)
            if scope == .all {
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

    private func updateLoop() {
        guard hasPendingWork else { stopLoop(); return }
        guard loop == nil, dependencies.context().active else { return }
        let id = UUID()
        loopId = id
        loop = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while self.hasPendingWork && !Task.isCancelled {
                let context = self.dependencies.context()
                guard context.active else { break }
                if !context.online || self.networkSettling {
                    self.state = context.online ? .waiting : .waitingForNetwork
                    do { try await self.dependencies.sleep(1) } catch { break }
                    continue
                }
                self.state = attempt == 0 ? .waiting : .monitoring
                do { try await self.dependencies.sleep(XauXatOutboundDeliveryPolicy.recoveryDelay(attempt: attempt)) }
                catch { break }
                // The path, profile and pending work can change during backoff.
                guard self.hasPendingWork, !Task.isCancelled else { break }
                guard self.dependencies.context() == context, !self.networkSettling else { continue }
                do { try await self.reconnect(.automatic, reason: .pendingWork) }
                catch { /* bounded retry; the core retains pending messages */ }
                attempt += 1
            }
            guard self.loopId == id else { return }
            self.loop = nil
            self.loopId = nil
            if !self.hasPendingWork { self.state = .idle }
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
    func networkChanged(online: Bool) {
        epoch += 1
        dependencies.invalidateTor()
        lastGlobal = nil
        relayAttempts.removeAll()
        firstObserved.removeAll()
        networkTask?.cancel()
        networkSettling = online
        record(.networkChange, online ? "path_online" : "path_offline")
        if !online { state = .waitingForNetwork; return }
        let expectedEpoch = epoch
        networkTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.dependencies.sleep(self.networkSettleDelay) } catch { return }
            guard self.epoch == expectedEpoch, !Task.isCancelled else { return }
            self.networkSettling = false
            guard self.dependencies.context().active else { return }
            do { try await self.reconnect(.all, reason: .networkChange) } catch { }
            self.updateLoop()
        }
    }

    func pause() {
        epoch += 1
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
        "Connection recovery (current app process)\n" + events.joined(separator: "\n")
    }
}
