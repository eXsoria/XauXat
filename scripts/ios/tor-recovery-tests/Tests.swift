import Foundation
import Combine
import Network
import SimpleXChat
import Tor

@MainActor final class ScriptedProbe {
    var calls = 0
    var handler: (UInt16) async throws -> Bool = { _ in true }
    func run(_ port: UInt16) async throws -> Bool { calls += 1; return try await handler(port) }
    func manager(timeout: UInt64 = 3_000_000_000, stall: UInt64 = 60_000_000_000) -> EmbeddedTorManager {
        EmbeddedTorManager(routeProbe: { port, _ in try await self.run(port) }, retryDelay: 0, startupTimeout: timeout, bootstrapStallTimeout: stall)
    }
}

/// Advance the bootstrap clock explicitly. Host scheduling must not turn a
/// healthy-progress test into a real 100-ms stall on a busy macOS runner.
@MainActor final class BootstrapClock {
    var time: TimeInterval = 0
    var ticks = 0
    func manager(_ probe: ScriptedProbe, timeout: UInt64 = 10_000_000_000) -> EmbeddedTorManager {
        EmbeddedTorManager(routeProbe: { port, _ in try await probe.run(port) }, retryDelay: 0,
                           startupTimeout: timeout, bootstrapStallTimeout: 60_000_000_000,
                           bootstrapNow: { self.time }, bootstrapSleep: { _ in
                               self.ticks += 1
                               try await Task.sleep(nanoseconds: 1_000_000)
                           })
    }
}

@main @MainActor struct Tests {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) {
        checks += 1
        guard value else { fatalError(message) }
    }
    static func reset() { TorTestState.reset(); publishedTorPort = nil; publishedPorts = [] }
    static func until(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for test condition", file: file, line: line)
    }

    static func main() async throws {
        try await readyMustBeRevalidated()
        try await freshnessLeaseIsExplicitAndInvalidatable()
        try await invalidationDuringCheckCannotCreateFreshLease()
        try await newPathDoesNotWaitForOldProbe()
        try await cancelledWaiterKeepsSharedStartupAlive()
        try await manualCheckCannotVerifyAnOldPath()
        try await mobileHandoverCancelsOnlyObsoleteRecovery()
        try await coldStartupFollowsTheFirstMobilePath()
        try await transientColdStartupRetriesKeepItsCompletion()
        try await coldStartupRetriesStopAtTheirBudgetAndAvailabilityGate()
        try await bootstrapStallGetsOneEarlyRepair()
        try await bootstrapProgressKeepsItsOwnTimeBudget()
        try await repeatedBootstrapEventsCannotHideAStall()
        try await persistentBootstrapStallDoesNotResetRepeatedly()
        try await bootstrapWatchDoesNotInterruptRouteVerification()
        try await recoveryRebindsAndPublishesOnlyVerifiedPort()
        try await recoveryFailureIsBounded()
        try await interruptedRepairDoesNotStrandNextRetry()
        try await statusEventsCannotConsumeCommandReplies()
        try await staleControlChannelIsReopened()
        try await unresponsiveControlIsClosedBeforeReopening()
        try await authenticationTimeoutCannotPublishLateSuccess()
        try await missingStatusReplyDiscardsTheChannel()
        try await rejectedStatusReplyIsNotATimeout()
        try await refusedControlConnectionsDoNotPoisonRetry()
        try await refreshRebuildsNetworkingAndKeepsStartupWaiters()
        try await concurrentRefreshesShareOneRepair()
        try await refreshCannotRestartAnUncontrollableRuntime()
        try await repeatedResumeDisposesOldChannels()
        try await manualFailureCannotLeaveReady()
        try await oldManualFailureCannotInvalidateNewReadiness()
        try await deadlineCannotPublishLateSuccess()
        try await deadlineCancelsOutstandingProbe()
        try await terminatedRuntimeIsNotStartedTwice()
        try await diagnosticsCaptureInitialFailureWithoutPrivateData()
        try await realSOCKSProbeCases()
        print("Tor recovery regression checks passed: \(checks)")
    }

    static func refreshRebuildsNetworkingAndKeepsStartupWaiters() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        var oldProbe: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { oldProbe = $0 } }
        var startupResults: [Result<UInt16, Error>] = []
        manager.start { startupResults.append($0) }
        try await until { oldProbe != nil }
        probe.handler = { _ in true }
        let port = try await manager.refreshConnection()
        require(port == 19051 && publishedPorts == [19051], "Refresh must rebuild and verify a new listener before publication")
        require(startupResults.count == 1 && (try? startupResults[0].get()) == port, "Refresh must release the original cold-start callback exactly once")
        require(TorTestState.threadStarts == 1 && TorTestState.closedControllers >= 1, "Refresh must replace the local control channel while retaining the one Tor runtime")
        require(TorTestState.commands.filter { $0 == "SETCONF DisableNetwork=1" }.count == 1, "An explicit refresh must reset networking even when a new probe would succeed")
        oldProbe!.resume(returning: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        require(publishedPorts == [port] && startupResults.count == 1, "The cancelled old probe cannot publish its old port or repeat initialization")
        require(!manager.refreshingConnection && manager.diagnosticText.contains("manualRefresh"), "Refresh completion must restore the UI and record the user action")
    }

    static func concurrentRefreshesShareOneRepair() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        var refreshedProbe: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { refreshedProbe = $0 } }
        let first = Task { try await manager.refreshConnection() }
        try await until { refreshedProbe != nil }
        require(manager.refreshingConnection && publishedTorPort == nil, "Ready must be withdrawn throughout an explicit refresh")
        let joins = manager.diagnosticText.components(separatedBy: "tor joined").count
        let second = Task { try await manager.refreshConnection() }
        try await until { manager.diagnosticText.components(separatedBy: "tor joined").count > joins }
        refreshedProbe!.resume(returning: true)
        let a = try await first.value, b = try await second.value
        require(a == b && TorTestState.commands.filter { $0 == "SETCONF DisableNetwork=1" }.count == 1, "Repeated refresh taps must share one repair and verified result")
    }

    static func refreshCannotRestartAnUncontrollableRuntime() async throws {
        reset()
        let probe = ScriptedProbe()
        let manager = EmbeddedTorManager(routeProbe: { port, _ in try await probe.run(port) },
                                         startupTimeout: 2_000_000_000, controlPollDelay: 1_000_000)
        _ = try await manager.ensureReady()
        TorTestState.refuseConnections = true
        do { _ = try await manager.refreshConnection(); fatalError("Refused control cannot report successful refresh") }
        catch { require(error.localizedDescription.contains("close XauXat completely"), "Unreachable Tor must offer an honest app-reopen fallback") }
        require(TorTestState.threadStarts == 1 && publishedTorPort == nil && !manager.refreshingConnection, "A failed refresh must finish offline without starting another runtime")
        TorTestState.refuseConnections = false
        _ = try await manager.refreshConnection()
        require(publishedTorPort != nil && TorTestState.threadStarts == 1, "A subsequent refresh can recover when local control becomes available again")
        TorTestState.lastThread!.isFinished = true
        do { _ = try await manager.refreshConnection(); fatalError("Stopped C-Tor must not be re-entered") } catch { }
        require(TorTestState.threadStarts == 1 && publishedTorPort == nil, "Refresh retains the stopped-runtime guard")
    }

    static func diagnosticsCaptureInitialFailureWithoutPrivateData() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        probe.handler = { _ in throw TorSOCKSProbeError.timedOut(.handshake) }
        do { _ = try await manager.ensureReady(); fatalError("Failed probe must not become ready") } catch { }
        require(manager.diagnosticText.contains("socks_timeout_handshake") && manager.diagnosticText.contains("repair"), "Export must include initial Tor failures and repair stages before any manual retry")
        require(!manager.diagnosticText.contains("19050") && !manager.diagnosticText.contains("19051"), "Diagnostics must not expose socket ports")
        for _ in 0..<100 { manager.invalidateReadiness() }
        require(manager.diagnosticText.split(separator: "\n").filter { $0.hasPrefix("+") }.count == 80, "Tor diagnostics must remain bounded")
        require(manager.diagnosticText.contains("last_failure=socks_timeout_handshake"), "Snapshot must retain the failure even after old events roll out")

        reset()
        let privateProbe = ScriptedProbe(), privateManager = privateProbe.manager()
        privateProbe.handler = { _ in throw NSError(domain: "smp://private-address.example/key", code: 17, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_MESSAGE_AND_KEY"]) }
        do { _ = try await privateManager.ensureReady(); fatalError("Synthetic failure must not become ready") } catch { }
        let text = privateManager.diagnosticText
        require(text.contains("failure=other") && !text.contains("private-address") && !text.contains("PRIVATE_MESSAGE") && !text.contains("/key"), "Raw error messages, addresses and secrets must never enter the exported journal")
    }

    static func readyMustBeRevalidated() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        require(probe.calls == 1 && publishedTorPort == 19050, "Cold start must verify before publishing")
        var held: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        let first = Task { try await manager.ensureReady() }
        try await until { held != nil }
        require(publishedTorPort == nil, "Old Ready must be withdrawn while checking the live socket")
        var second: Result<UInt16, Error>?
        manager.start { second = $0 }
        held!.resume(returning: true)
        let a = try await first.value
        try await until { second != nil }
        let b = try second!.get()
        require(a == b && probe.calls == 2, "Concurrent starts must share one validation and both finish")
        require(TorTestState.threadStarts == 1, "Resume must reuse the existing Tor runtime")
    }

    static func freshnessLeaseIsExplicitAndInvalidatable() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        _ = try await manager.ensureReady(maxAge: 15)
        require(probe.calls == 1, "Only explicit coordinated follow-up may reuse a recent route check")
        manager.invalidateReadiness()
        _ = try await manager.ensureReady(maxAge: 15)
        require(probe.calls == 2, "Network/lifecycle invalidation must force a new route probe")
        _ = try await manager.ensureReady()
        require(probe.calls == 3, "Default/manual readiness must still check a fresh route")
    }

    static func invalidationDuringCheckCannotCreateFreshLease() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        var held: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        let start = Task { try await manager.ensureReady() }
        try await until { held != nil }
        manager.invalidateReadiness()
        probe.handler = { _ in true }
        held!.resume(returning: true)
        _ = try await start.value
        require(probe.calls == 2 && publishedPorts == [19050], "Startup waiters must receive only a route verified after the last invalidation")
        _ = try await manager.ensureReady(maxAge: 15)
        require(probe.calls == 2, "A probe started before path invalidation cannot grant a reusable lease")
    }

    static func newPathDoesNotWaitForOldProbe() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        var oldProbe: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { oldProbe = $0 } }
        let original = Task { try await manager.ensureReady() }
        try await until { oldProbe != nil }
        manager.invalidateReadiness()
        probe.handler = { _ in true }
        let port = try await manager.ensureReady()
        require(try await original.value == port, "Existing startup callers must follow the fresh path")
        require(probe.calls == 2 && publishedPorts == [19050], "New path must become usable before an unresponsive old probe finishes")
        require(TorTestState.threadStarts == 1, "A path handover must reuse the Tor runtime")
        oldProbe!.resume(returning: true)
        _ = try await manager.ensureReady(maxAge: 15)
        require(probe.calls == 2 && publishedPorts == [19050], "Late old-path success must not publish twice or invalidate fresh readiness")
    }

    static func cancelledWaiterKeepsSharedStartupAlive() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        var held: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        var cancelled = false
        let waiter = Task {
            do { _ = try await manager.ensureReady(); fatalError("Cancelled waiter must not succeed") }
            catch is CancellationError { cancelled = true }
            catch { fatalError("Expected cancellation") }
        }
        try await until { held != nil }
        var startup: Result<UInt16, Error>?
        manager.start { startup = $0 }
        waiter.cancel()
        try await until { cancelled }
        require(startup == nil && publishedTorPort == nil, "Cancellation must finish its waiter promptly without finishing shared startup")
        held!.resume(returning: true)
        try await until { startup != nil }
        require(try startup!.get() == 19050 && probe.calls == 1, "Other callers must retain the original shared startup")
        require(!TorTestState.commands.contains("SETCONF SocksPort=0"), "Cancelling a waiter must not reset Tor networking")
    }

    static func manualCheckCannotVerifyAnOldPath() async throws {
        for success in [true, false] {
            reset()
            let probe = ScriptedProbe(), manager = probe.manager()
            _ = try await manager.ensureReady()
            var held: CheckedContinuation<Bool, Error>?
            probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
            let manual = Task { try await manager.verifyTorRoute() }
            try await until { held != nil }
            manager.invalidateReadiness()
            if success { held!.resume(returning: true) }
            else { held!.resume(throwing: TorSOCKSProbeError.failed(.response)) }
            do { _ = try await manual.value; fatalError("An old-path diagnostic cannot verify a new path") } catch { }
            require(publishedTorPort == 19050, "Old diagnostic completion must not withdraw the current Tor endpoint")
            probe.handler = { _ in true }
            _ = try await manager.ensureReady(maxAge: 15)
            require(probe.calls == 3, "An old manual check must not grant readiness to the new path")
        }
    }

    static func mobileHandoverCancelsOnlyObsoleteRecovery() async throws {
        reset()
        let probe = ScriptedProbe(), tor = probe.manager()
        var oldProbe: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { oldProbe = $0 } }
        var commands = 0
        let recovery = XauXatConnectionRecoveryManager(dependencies: .init(
            context: { .init(userId: 1, online: true, active: true) },
            ensureTor: { _ in .init(port: try await tor.ensureReady(), replaced: false) },
            invalidateTor: { tor.invalidateReadiness() },
            applyTor: { false }, failedRelays: { [:] }, reconnect: { _ in commands += 1 }
        ), networkSettleDelay: 0.01)
        let obsolete = Task { try await recovery.reconnect() }
        try await until { oldProbe != nil }
        var startup: Result<UInt16, Error>?
        tor.start { startup = $0 }
        probe.handler = { _ in true }
        recovery.networkChanged(online: true, network: .cellular)
        try await until { commands == 1 }
        do { try await obsolete.value; fatalError("Old recovery must be cancelled") } catch is CancellationError { }
        require(try startup!.get() == 19050, "Foreground startup must survive cancellation of the coordinator's old waiter")
        require(probe.calls == 2 && TorTestState.threadStarts == 1 && publishedPorts == [19050], "Actual Tor/coordinator handover must finish before the stale socket does")
        oldProbe!.resume(returning: true)
        recovery.pause()
    }

    static func coldStartupFollowsTheFirstMobilePath() async throws {
        reset()
        let probe = ScriptedProbe(), tor = probe.manager()
        var oldProbe: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { oldProbe = $0 } }
        var startup: Result<UInt16, Error>?
        tor.startRetrying(whileAvailable: { true }) { startup = $0 }
        try await until { oldProbe != nil }
        var coreCommands = 0
        let recovery = XauXatConnectionRecoveryManager(dependencies: .init(
            context: { .init(userId: nil, online: true, active: true) },
            ensureTor: { _ in fatalError("Uninitialized chat must not invoke messaging recovery") },
            invalidateTor: { tor.invalidateReadiness() },
            refreshStartup: { await tor.refreshPendingStartup() },
            applyTor: { coreCommands += 1; return false },
            failedRelays: { fatalError("No core summary exists during cold start") },
            reconnect: { _ in coreCommands += 1 }, sessionState: { .uninitialized }
        ), networkSettleDelay: 0.01)
        probe.handler = { _ in true }
        recovery.networkChanged(online: true, network: .cellular)
        try await until { startup != nil }
        require(try startup!.get() == 19050 && probe.calls == 2, "Initial mobile path must reach the original startup callback without any chat profile")
        require(coreCommands == 0 && TorTestState.threadStarts == 1, "Cold path refresh must never activate a store or create another Tor runtime")
        oldProbe!.resume(returning: true)
        recovery.pause()
    }

    static func transientColdStartupRetriesKeepItsCompletion() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        var completions = 0
        var result: Result<UInt16, Error>?
        probe.handler = { _ in
            if probe.calls <= 6 { throw TorSOCKSProbeError.failed(.handshake) }
            return true
        }
        manager.startRetrying(whileAvailable: { true }) { result = $0; completions += 1 }
        try await until { result != nil }
        require(try result!.get() > 0 && probe.calls == 7 && completions == 1, "A transient failed cold attempt must retain its initialization callback until the retry succeeds")
        require(manager.diagnosticText.contains("startupRetry") && TorTestState.threadStarts == 1, "Cold retries must be visible and retain one runtime")
    }

    static func coldStartupRetriesStopAtTheirBudgetAndAvailabilityGate() async throws {
        for available in [false, true] {
            reset()
            let probe = ScriptedProbe(), manager = probe.manager()
            probe.handler = { _ in throw TorSOCKSProbeError.failed(.handshake) }
            var result: Result<UInt16, Error>?
            manager.startRetrying(whileAvailable: { available }) { result = $0 }
            try await until { result != nil }
            if case .success = result! { fatalError("Persistent cold failure must stay closed") }
            require(probe.calls == (available ? 18 : 6), "Cold retries must stop after three attempts or immediately when the foreground/network gate closes")
            require(publishedTorPort == nil && TorTestState.threadStarts == 1, "Cold retry exhaustion must not publish a route or start another runtime")
        }
        reset()
        let probe = ScriptedProbe(), manager = probe.manager(timeout: 200_000_000)
        probe.handler = { _ in try await Task.sleep(nanoseconds: 1_000_000_000); return true }
        var result: Result<UInt16, Error>?
        manager.startRetrying(whileAvailable: { true }) { result = $0 }
        try await until { result != nil }
        require(probe.calls == 1 && !manager.diagnosticText.contains("startupRetry"), "A full bootstrap timeout must reach Retry UI without multiplying its four-minute deadline")
        reset()
        let gatedProbe = ScriptedProbe(), gatedManager = gatedProbe.manager()
        gatedProbe.handler = { _ in throw TorSOCKSProbeError.failed(.handshake) }
        var gates = 0
        var gatedResult: Result<UInt16, Error>?
        gatedManager.startRetrying(whileAvailable: { gates += 1; return gates == 1 }) { gatedResult = $0 }
        try await until { gatedResult != nil }
        require(gates == 2 && gatedProbe.calls == 6, "Cold retries must recheck foreground/network availability after backoff")
        reset()
        let budgetProbe = ScriptedProbe()
        let budgetManager = budgetProbe.manager(timeout: 200_000_000)
        var budgetResult: Result<UInt16, Error>?
        var budgetFinished = false
        budgetProbe.handler = { _ in
            if budgetProbe.calls <= 6 { throw TorSOCKSProbeError.failed(.handshake) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return true
        }
        budgetManager.startRetrying(whileAvailable: { true }) { budgetResult = $0; budgetFinished = true }
        try await until { budgetFinished }
        if case .success = budgetResult! { fatalError("Cold retry budget must expire") }
        require(budgetProbe.calls == 7, "A slow retry must share the original cold-start budget rather than receive another full deadline")
        try await until { if case .failed = budgetManager.state { return true }; return false }
        reset()
        let stoppedProbe = ScriptedProbe(), stoppedManager = stoppedProbe.manager()
        _ = try await stoppedManager.ensureReady()
        TorTestState.lastThread!.isFinished = true
        var stoppedResult: Result<UInt16, Error>?
        stoppedManager.startRetrying(whileAvailable: { true }) { stoppedResult = $0 }
        try await until { stoppedResult != nil }
        require(TorTestState.threadStarts == 1 && !stoppedManager.diagnosticText.contains("startupRetry"), "Cold retry cannot re-enter a terminated C-Tor runtime")
    }

    static func bootstrapStallGetsOneEarlyRepair() async throws {
        reset()
        TorTestState.circuitEstablished = false
        TorTestState.establishAfterRepair = true
        let probe = ScriptedProbe(), clock = BootstrapClock()
        let manager = clock.manager(probe)
        let operation = Task { try await manager.ensureReady() }
        try await until { !TorTestState.statusObservers.isEmpty && TorTestState.completedCommands.contains("GETINFO status/circuit-established") }
        clock.time += 61
        let port = try await operation.value
        require(port == 19051 && probe.calls == 1, "No-progress bootstrap must recover before the overall deadline and verify its replacement listener")
        require(TorTestState.commands.filter { $0 == "SETCONF SocksPort=0" }.count == 1 && TorTestState.threadStarts == 1, "Bootstrap recovery must use the same single controlled repair and Tor runtime")
        require(manager.diagnosticText.contains("bootstrapStalled"), "Cold bootstrap stalls must be visible without raw network details")
    }

    static func bootstrapProgressKeepsItsOwnTimeBudget() async throws {
        reset()
        TorTestState.circuitEstablished = false
        let probe = ScriptedProbe(), clock = BootstrapClock()
        let manager = clock.manager(probe)
        let operation = Task { try await manager.ensureReady() }
        try await until { !TorTestState.statusObservers.isEmpty && TorTestState.completedCommands.contains("GETINFO status/circuit-established") }
        for progress in [10, 20, 30, 40] {
            clock.time += 59
            TorTestState.emitProgress(progress)
            try await until { manager.state == .bootstrapping(progress) }
            let tick = clock.ticks
            try await until { clock.ticks > tick }
        }
        TorTestState.emitCircuit()
        _ = try await operation.value
        require(!TorTestState.commands.contains("SETCONF SocksPort=0") && probe.calls == 1, "A long bootstrap that keeps advancing must not be interrupted by the stall timer")
    }

    static func repeatedBootstrapEventsCannotHideAStall() async throws {
        reset()
        TorTestState.circuitEstablished = false
        TorTestState.establishAfterRepair = true
        let probe = ScriptedProbe(), clock = BootstrapClock()
        let manager = clock.manager(probe)
        let operation = Task { try await manager.ensureReady() }
        try await until { !TorTestState.statusObservers.isEmpty && TorTestState.completedCommands.contains("GETINFO status/circuit-established") }
        var events = 0
        let observation = manager.$state.sink { _ in events += 1 }
        defer { observation.cancel() }
        TorTestState.emitProgress(10)
        try await until { manager.state == .bootstrapping(10) }
        clock.time += 59
        let before = events
        TorTestState.emitProgress(10)
        try await until { events > before }
        clock.time += 2
        _ = try await operation.value
        require(TorTestState.commands.filter { $0 == "SETCONF SocksPort=0" }.count == 1, "Repeated unchanged percentages cannot postpone stalled bootstrap recovery indefinitely")
    }

    static func persistentBootstrapStallDoesNotResetRepeatedly() async throws {
        reset()
        TorTestState.circuitEstablished = false
        let probe = ScriptedProbe(), clock = BootstrapClock()
        let manager = clock.manager(probe)
        let operation = Task { try await manager.ensureReady() }
        try await until { !TorTestState.statusObservers.isEmpty && TorTestState.completedCommands.contains("GETINFO status/circuit-established") }
        clock.time += 61
        try await until { TorTestState.commands.contains("SETCONF SocksPort=0") }
        try await until { !TorTestState.statusObservers.isEmpty && TorTestState.completedCommands.contains("GETINFO status/circuit-established") }
        clock.time += 1000
        require(TorTestState.commands.filter { $0 == "SETCONF SocksPort=0" }.count == 1 && probe.calls == 0, "A persistent stall gets only one repair before its original startup deadline")
        require(publishedTorPort == nil && TorTestState.threadStarts == 1, "No-progress bootstrap must remain fail-closed")
        // Finish the fixture through the current observer after proving that
        // elapsed virtual time cannot trigger another repair.
        TorTestState.emitCircuit()
        _ = try await operation.value
    }

    static func bootstrapWatchDoesNotInterruptRouteVerification() async throws {
        reset()
        let probe = ScriptedProbe(), clock = BootstrapClock()
        let manager = clock.manager(probe)
        var held: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        let operation = Task { try await manager.ensureReady() }
        try await until { held != nil }
        let pending = held!
        clock.time += 1000
        try await Task.sleep(nanoseconds: 10_000_000)
        pending.resume(returning: true)
        _ = try await operation.value
        require(!TorTestState.commands.contains("SETCONF SocksPort=0"), "A slow but live SOCKS route check must keep its separate probe budget")
    }

    static func recoveryRebindsAndPublishesOnlyVerifiedPort() async throws {
        reset()
        let probe = ScriptedProbe()
        probe.handler = { port in
            if port == 19050 { throw TorSOCKSProbeError.failed(.localSocket) }
            return true
        }
        let manager = probe.manager()
        let port = try await manager.ensureReady()
        require(port == 19051 && publishedPorts == [19051], "A failed listener must not be published; only the verified replacement may be used")
        require(TorTestState.commands.contains("SETCONF SocksPort=0"), "Recovery must close the broken listener")
        require(TorTestState.commands.contains("SETCONF SocksPort=\"127.0.0.1:auto\" DisableNetwork=0"), "Recovery must bind a loopback-only dynamic listener and restore Tor networking")
        require(TorTestState.threadStarts == 1, "Recovery must never start a second concurrent C-Tor instance")
    }

    static func recoveryFailureIsBounded() async throws {
        reset()
        let probe = ScriptedProbe()
        probe.handler = { _ in throw TorSOCKSProbeError.timedOut(.destination) }
        let manager = probe.manager()
        do { _ = try await manager.ensureReady(); fatalError("Unavailable Tor route must fail") } catch { }
        require(publishedTorPort == nil && publishedPorts.isEmpty, "Persistent failure must remain closed")
        require(TorTestState.commands.filter { $0 == "SETCONF SocksPort=0" }.count == 1, "Only one repair is allowed per attempt")
        require(probe.calls == 6, "Route retries must remain bounded")
        if case .failed = manager.state { require(true, "Failure is visible") }
        else { fatalError("Persistent route failure left a Ready indicator") }
    }

    static func staleControlChannelIsReopened() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        TorTestState.failNextCommand = true
        _ = try await manager.ensureReady()
        require(TorTestState.controllers == 2 && TorTestState.threadStarts == 1, "A stale control socket must be reopened without a second Tor runtime")
    }

    static func controlManager(_ probe: ScriptedProbe) -> EmbeddedTorManager {
        EmbeddedTorManager(routeProbe: { port, _ in try await probe.run(port) }, retryDelay: 0,
                           startupTimeout: 3_000_000_000, controlReplyTimeout: 0.2, controlPollDelay: 1_000_000)
    }

    static func unresponsiveControlIsClosedBeforeReopening() async throws {
        reset()
        let probe = ScriptedProbe(), manager = controlManager(probe)
        _ = try await manager.ensureReady()
        manager.invalidateReadiness()
        TorTestState.dropCommandContaining = "DisableNetwork=0"
        _ = try await manager.ensureReady()
        require(TorTestState.controllers == 2 && TorTestState.closedControllers == 1,
                "A resumed channel that never answers must be closed before a replacement is used")
        require(TorTestState.threadStarts == 1 && publishedTorPort == 19050,
                "Control-socket recovery must keep the same runtime and listener")
        require(manager.diagnosticText.contains("controlReopened failure=control_command_timeout"),
                "Diagnostics must distinguish a dead command channel from a missing control-port file")
    }

    static func authenticationTimeoutCannotPublishLateSuccess() async throws {
        reset()
        let probe = ScriptedProbe(), manager = controlManager(probe)
        TorTestState.holdAuthentication = true
        do { _ = try await manager.ensureReady(); fatalError("Authentication without a response must finish") } catch { }
        require(manager.diagnosticText.contains("last_failure=control_authentication_timeout") && publishedTorPort == nil,
                "Authentication has its own bounded timeout and must fail closed")
        let late = TorTestState.pendingAuthentication!
        TorTestState.holdAuthentication = false
        _ = try await manager.ensureReady()
        late()
        try await Task.sleep(nanoseconds: 10_000_000)
        require(publishedPorts == [19050] && TorTestState.closedControllers == 1,
                "Late authentication from a discarded channel cannot publish readiness or close the new channel")
    }

    static func missingStatusReplyDiscardsTheChannel() async throws {
        reset()
        let probe = ScriptedProbe(), manager = controlManager(probe)
        TorTestState.dropCommandContaining = "GETINFO status/circuit-established"
        do { _ = try await manager.ensureReady(); fatalError("Missing status reply must time out") } catch { }
        require(manager.diagnosticText.contains("last_failure=control_info_timeout") && TorTestState.closedControllers == 1,
                "A status timeout must close its channel rather than repair Tor through the same dead channel")
        require(!TorTestState.commands.contains("SETCONF SocksPort=0") && publishedTorPort == nil,
                "A control failure does not justify rotating a possibly healthy SOCKS listener")
        _ = try await manager.ensureReady()
        require(TorTestState.controllers == 2 && TorTestState.threadStarts == 1,
                "A fresh retry must reconnect to the existing runtime")
    }

    static func refusedControlConnectionsDoNotPoisonRetry() async throws {
        reset()
        let probe = ScriptedProbe(), manager = controlManager(probe)
        TorTestState.refuseConnections = true
        do { _ = try await manager.ensureReady(); fatalError("Refused socket must fail") } catch { }
        require(manager.diagnosticText.contains("last_failure=control_socket_refused"),
                "An existing endpoint that refuses connections is different from a missing port file")
        require(TorTestState.controllers == 100 && TorTestState.closedControllers == 100 && publishedTorPort == nil,
                "Every failed control connection must be disposed and retries must be bounded")
        TorTestState.refuseConnections = false
        _ = try await manager.ensureReady()
        require(TorTestState.threadStarts == 1 && publishedTorPort == 19050,
                "Temporary local connection refusal must not poison the next retry or spawn C-Tor again")
    }

    static func rejectedStatusReplyIsNotATimeout() async throws {
        reset()
        let probe = ScriptedProbe(), manager = controlManager(probe)
        TorTestState.failCommandContaining = "GETINFO status/circuit-established"
        do { _ = try await manager.ensureReady(); fatalError("Rejected status request must fail") } catch { }
        require(manager.diagnosticText.contains("last_failure=control_response_rejected"),
                "A rejection response must not be reported as a missing response")
        require(TorTestState.closedControllers == 1 && publishedTorPort == nil,
                "A rejected control request must dispose its channel and stay closed")
    }

    static func repeatedResumeDisposesOldChannels() async throws {
        reset()
        let probe = ScriptedProbe(), manager = controlManager(probe)
        _ = try await manager.ensureReady()
        for _ in 0..<25 {
            TorTestState.lastController!.isConnected = false // EOF after suspension
            manager.invalidateReadiness()
            _ = try await manager.ensureReady()
        }
        require(TorTestState.controllers == 26 && TorTestState.closedControllers == 25,
                "Repeated foreground/network recovery cannot accumulate stale control channels")
        require(TorTestState.threadStarts == 1 && probe.calls == 26,
                "Each resume revalidates Tor while retaining exactly one runtime")
    }

    static func statusEventsCannotConsumeCommandReplies() async throws {
        reset()
        TorTestState.injectStatusBeforeReply = true
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        require(publishedTorPort != nil && probe.calls == 1, "Status events interleaved with control replies must not hang or restart bootstrap")
    }

    static func interruptedRepairDoesNotStrandNextRetry() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        TorTestState.failCommandContaining = "SocksPort=0"
        probe.handler = { _ in throw TorSOCKSProbeError.failed(.localSocket) }
        do { _ = try await manager.ensureReady(); fatalError("Interrupted repair should fail") } catch { }
        require(TorTestState.networkDisabled && publishedTorPort == nil, "Failure during repair must remain closed")
        probe.handler = { _ in true }
        _ = try await manager.ensureReady()
        require(!TorTestState.networkDisabled && publishedTorPort != nil, "Reauthenticated retry must restore Tor networking before waiting for a circuit")
        require(TorTestState.threadStarts == 1, "Interrupted repair must reuse the existing C-Tor runtime")
    }

    static func manualFailureCannotLeaveReady() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        probe.handler = { _ in throw TorSOCKSProbeError.failed(.handshake) }
        do { _ = try await manager.verifyTorRoute(); fatalError("Manual failure must be reported") } catch { }
        require(publishedTorPort == nil, "A failed manual route check must withdraw Ready")
        probe.handler = { _ in true }
        _ = try await manager.ensureReady()
        require(publishedTorPort == 19050, "Retry must restore the route only after a fresh check")
    }

    static func oldManualFailureCannotInvalidateNewReadiness() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        var held: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        let manual = Task { try await manager.verifyTorRoute() }
        try await until { held != nil }
        probe.handler = { _ in true }
        _ = try await manager.ensureReady()
        held!.resume(throwing: TorSOCKSProbeError.failed(.response))
        do { _ = try await manual.value; fatalError("Old manual check should fail") } catch { }
        require(publishedTorPort == 19050, "An old failed probe must not invalidate a newer verified route on the same port")
    }

    static func deadlineCannotPublishLateSuccess() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager(timeout: 200_000_000)
        var held: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        let task = Task { try await manager.ensureReady() }
        try await until { held != nil }
        do { _ = try await task.value; fatalError("Startup deadline must finish the caller") } catch { }
        require(publishedTorPort == nil, "Deadline must fail closed without starting another recovery")
        probe.handler = { _ in true }
        _ = try await manager.ensureReady()
        held!.resume(returning: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        require(publishedPorts == [19050], "Late success from an expired attempt must not publish or complete callers twice")
    }

    static func terminatedRuntimeIsNotStartedTwice() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager()
        _ = try await manager.ensureReady()
        TorTestState.lastThread!.isFinished = true
        do { _ = try await manager.ensureReady(); fatalError("A terminated runtime is not Ready") } catch { }
        require(TorTestState.threadStarts == 1 && publishedTorPort == nil, "Do not re-enter a stopped C-Tor runtime inside the same app process")
    }

    static func deadlineCancelsOutstandingProbe() async throws {
        reset()
        let probe = ScriptedProbe(), manager = probe.manager(timeout: 200_000_000)
        var cancelled = false
        probe.handler = { _ in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { cancelled = Task.isCancelled; throw error }
            return true
        }
        do { _ = try await manager.ensureReady(); fatalError("Deadline must finish") } catch { }
        try await until { cancelled }
        require(publishedTorPort == nil, "Deadline must cancel the outstanding probe, not leave its socket/task hanging")
    }

    static func realSOCKSProbeCases() async throws {
        let fragmented = try await SOCKSFixture.open(.fragmentedHTTP)
        defer { fragmented.close() }
        require(try await TorSOCKSProbe.run(port: fragmented.port, timeout: 3), "A fragmented HTTP status line must pass through a real local SOCKS socket")
        let rejected = try await SOCKSFixture.open(.rejectDestination)
        defer { rejected.close() }
        do { _ = try await TorSOCKSProbe.run(port: rejected.port, timeout: 3); fatalError("SOCKS refusal must fail") }
        catch { require(error as? TorSOCKSProbeError == .rejected(4), "Preserve the SOCKS destination reply separately from a dead local proxy") }
        let malformed = try await SOCKSFixture.open(.malformedHTTP)
        defer { malformed.close() }
        do { _ = try await TorSOCKSProbe.run(port: malformed.port, timeout: 3); fatalError("Malformed HTTP must fail") }
        catch { require(error as? TorSOCKSProbeError == .failed(.response), "Malformed HTTP must identify the response stage") }
        let hanging = try await SOCKSFixture.open(.hangHandshake)
        defer { hanging.close() }
        let began = Date()
        do { _ = try await TorSOCKSProbe.run(port: hanging.port, timeout: 0.2); fatalError("Hanging handshake must time out") }
        catch { require(error as? TorSOCKSProbeError == .timedOut(.handshake), "Timeout must identify the handshake stage") }
        require(Date().timeIntervalSince(began) < 2, "A hanging SOCKS receive must not strand its continuation")
        let cancelled = Task { try await TorSOCKSProbe.run(port: hanging.port, timeout: 30) }
        try await Task.sleep(nanoseconds: 40_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation must finish") }
        catch { require(error is CancellationError, "Cancellation must close the socket and resume the caller") }
    }
}

// Loopback-only SOCKS peer. It never forwards or contacts Tor/relays/the Internet.
final class SOCKSFixture {
    enum Mode { case fragmentedHTTP, rejectDestination, malformedHTTP, hangHandshake }
    let listener: NWListener
    let mode: Mode
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    var port: UInt16 { listener.port!.rawValue }
    init(_ mode: Mode) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    static func open(_ mode: Mode) async throws -> SOCKSFixture {
        let fixture = try SOCKSFixture(mode)
        fixture.listener.newConnectionHandler = { [weak fixture] connection in
            guard let fixture else { connection.cancel(); return }
            fixture.lock.lock(); fixture.connections.append(connection); fixture.lock.unlock()
            connection.start(queue: .global(qos: .userInitiated))
            Task { try? await fixture.serve(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fixture.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    fixture.listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    fixture.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            fixture.listener.start(queue: .global(qos: .userInitiated))
        }
        return fixture
    }
    func close() {
        listener.cancel()
        lock.lock(); let all = connections; connections.removeAll(); lock.unlock()
        all.forEach { $0.cancel() }
    }
    func serve(_ connection: NWConnection) async throws {
        _ = try await read(connection, count: 3)
        if mode == .hangHandshake { return }
        try await send(connection, Data([5, 0]))
        let header = try await read(connection, count: 5)
        guard header[3] == 3 else { fatalError("Probe must send the destination hostname through SOCKS") }
        let address = try await read(connection, count: Int(header[4]) + 2)
        guard String(data: address.dropLast(2), encoding: .utf8) == "check.torproject.org" else { fatalError("Unexpected destination") }
        try await send(connection, Data([5, mode == .rejectDestination ? 4 : 0, 0, 1, 0, 0, 0, 0, 0, 0]))
        if mode == .rejectDestination { return }
        var request = Data()
        while request.range(of: Data([13, 10, 13, 10])) == nil {
            request.append(try await read(connection, count: 1))
            guard request.count < 1024 else { fatalError("Unexpected route-check request") }
        }
        guard String(data: request, encoding: .utf8)?.hasPrefix("HEAD / HTTP/1.1\r\n") == true else {
            fatalError("The probe must request headers only, never the exit-IP API")
        }
        if mode == .malformedHTTP { try await send(connection, Data("NOT HTTP\r\n".utf8)); return }
        try await send(connection, Data("H".utf8))
        try await Task.sleep(nanoseconds: 30_000_000)
        try await send(connection, Data("TTP/1.1 200 OK\r\n\r\n{}".utf8))
    }
    func read(_ connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "FixtureEOF", code: 1)) }
            }
        }
    }
    func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
