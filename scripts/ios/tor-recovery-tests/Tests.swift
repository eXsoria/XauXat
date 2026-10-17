import Foundation
import Network
import SimpleXChat
import Tor

@MainActor final class ScriptedProbe {
    var calls = 0
    var handler: (UInt16) async throws -> Bool = { _ in true }
    func run(_ port: UInt16) async throws -> Bool { calls += 1; return try await handler(port) }
    func manager(timeout: UInt64 = 3_000_000_000) -> EmbeddedTorManager {
        EmbeddedTorManager(routeProbe: { port, _ in try await self.run(port) }, retryDelay: 0, startupTimeout: timeout)
    }
}

@main @MainActor struct Tests {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) {
        checks += 1
        guard value else { fatalError(message) }
    }
    static func reset() { TorTestState.reset(); publishedTorPort = nil; publishedPorts = [] }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for test condition")
    }

    static func main() async throws {
        try await readyMustBeRevalidated()
        try await freshnessLeaseIsExplicitAndInvalidatable()
        try await invalidationDuringCheckCannotCreateFreshLease()
        try await recoveryRebindsAndPublishesOnlyVerifiedPort()
        try await recoveryFailureIsBounded()
        try await interruptedRepairDoesNotStrandNextRetry()
        try await statusEventsCannotConsumeCommandReplies()
        try await staleControlChannelIsReopened()
        try await manualFailureCannotLeaveReady()
        try await oldManualFailureCannotInvalidateNewReadiness()
        try await deadlineCannotPublishLateSuccess()
        try await deadlineCancelsOutstandingProbe()
        try await terminatedRuntimeIsNotStartedTwice()
        try await diagnosticsCaptureInitialFailureWithoutPrivateData()
        try await realSOCKSProbeCases()
        print("Tor recovery regression checks passed: \(checks)")
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
