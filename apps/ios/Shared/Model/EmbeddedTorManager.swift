//
//  EmbeddedTorManager.swift
//  XauXat (iOS)
//
//  Starts an app-local Tor client and publishes only its loopback SOCKS port.
//  The SimpleX core remains fail-closed until this manager marks Tor as ready.
//

import Foundation
import Combine
import Network
import OSLog
import SimpleXChat
@preconcurrency import Tor

@MainActor
final class EmbeddedTorManager: ObservableObject {
    static let shared = EmbeddedTorManager()

    enum State: Equatable {
        case stopped
        case starting
        case bootstrapping(Int)
        case verifying
        case ready(UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private enum DiagnosticStage: String {
        case start, joined, invalidated, superseded, waiterCancelled, controlReopened, authenticated, bootstrap
        case circuitCheck, probe, probeFailed, repair, failed, ready, manualProbe, manualProbeFailed, manualVerified
    }
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var diagnosticEvents: [String] = []
    private var lastFailureCode: String?
    private var lastBootstrapBucket: Int?

    // Only enum stages, boolean state and aggregate numbers are exported.
    // Never export a port, configuration, raw error, control reply or cookie.
    var diagnosticText: String {
        let status: String
        switch state {
        case .stopped: status = "stopped"
        case .starting: status = "starting"
        case let .bootstrapping(progress): status = "bootstrapping_\(max(0, min(100, progress)))"
        case .verifying: status = "verifying"
        case .ready: status = "ready"
        case .failed: status = "failed"
        }
        return "Embedded Tor (current app process)\n"
            + "state=\(status) runtime_started=\(thread != nil) runtime_finished=\(thread?.isFinished == true) last_failure=\(lastFailureCode ?? "none")\n"
            + diagnosticEvents.joined(separator: "\n")
    }

    private func record(_ stage: DiagnosticStage, error: Error? = nil, count: Int? = nil) {
        let elapsed = Int(max(0, ProcessInfo.processInfo.systemUptime - startedAt))
        let failure = error.map(Self.diagnosticFailure)
        if let failure { lastFailureCode = failure }
        diagnosticEvents.append("+\(elapsed)s tor \(stage.rawValue)"
            + (failure.map { " failure=\($0)" } ?? "") + (count.map { " count=\($0)" } ?? ""))
        if diagnosticEvents.count > 80 { diagnosticEvents.removeFirst(diagnosticEvents.count - 80) }
    }

    private static func diagnosticFailure(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? TorSOCKSProbeError {
            switch error {
            case let .failed(stage): return "socks_failed_" + stage.diagnosticCode
            case let .timedOut(stage): return "socks_timeout_" + stage.diagnosticCode
            case let .rejected(code): return "socks_rejected_\(code)"
            }
        }
        if let error = error as? EmbeddedTorError {
            switch error {
            case .backupProtection: return "backup_protection"
            case .timeout: return "startup_timeout"
            case .processStopped: return "runtime_stopped"
            case .missingControlPort: return "control_port_missing"
            case .controlConnection: return "control_connection"
            case .controlTimeout: return "control_timeout"
            case .authentication: return "control_authentication"
            case .invalidSocksPort: return "socks_listener_invalid"
            case .routeNotReady: return "route_not_ready"
            case .checkFailed: return "route_check_failed"
            case .circuitReset: return "circuit_reset"
            }
        }
        return "other"
    }

    private var thread: TorThread?
    private var controller: TorController?
    private var configuration: TorConfiguration?
    private var authenticated = false
    private var statusObserver: Any?
    private var attempt: UUID?
    private var callbacks: [UUID: (Result<UInt16, Error>) -> Void] = [:]
    private var deadline: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var requestingPort = false
    private var recoveryAttempted = false
    private var readinessGeneration = UUID()
    private var verifiedAt: TimeInterval?
    private var routeRevision = 0
    private var attemptRevision = 0
    private let routeProbe: @MainActor (UInt16, TimeInterval) async throws -> Bool
    private let retryDelay: UInt64
    private let startupTimeout: UInt64

    // Production owns exactly one instance. Dependencies make lifecycle races
    // testable without starting a second C-Tor runtime in the test process.
    init(
        routeProbe: @escaping @MainActor (UInt16, TimeInterval) async throws -> Bool = TorSOCKSProbe.run,
        retryDelay: UInt64 = 2_000_000_000,
        startupTimeout: UInt64 = 240_000_000_000
    ) {
        self.routeProbe = routeProbe
        self.retryDelay = retryDelay
        self.startupTimeout = startupTimeout
    }

    func start(_ completion: @escaping (Result<UInt16, Error>) -> Void) {
        start(waiter: UUID(), completion)
    }

    private func start(waiter: UUID, _ completion: @escaping (Result<UInt16, Error>) -> Void) {
        callbacks[waiter] = completion
        switch state {
        case .starting, .bootstrapping, .verifying:
            // A settled new path must not wait for up to three old-path SOCKS
            // timeouts. Keep all callers, but replace only the stale check.
            if attemptRevision != routeRevision, routeTask != nil {
                record(.superseded)
                begin()
                return
            }
            record(.joined)
            return
        case .stopped, .ready, .failed:
            begin()
        }
    }

    /// Only coordinated follow-up work may reuse a short-lived verification.
    /// Foreground/manual callers retain the default fresh check. Network and
    /// lifecycle changes invalidate this lease even while a check is running.
    func ensureReady(maxAge: TimeInterval = 0) async throws -> UInt16 {
        try Task.checkCancellation()
        if maxAge > 0, case let .ready(port) = state,
           thread?.isFinished == false, isXauXatManagedTorConfig(getNetCfg()),
           let verifiedAt, ProcessInfo.processInfo.systemUptime - verifiedAt < maxAge {
            return port
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                start(waiter: waiter) { continuation.resume(with: $0) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let callback = self.callbacks.removeValue(forKey: waiter) else { return }
                self.record(.waiterCancelled)
                // Detach this caller only. Foreground startup and other callers
                // may still need the shared Tor attempt and its completion.
                callback(.failure(CancellationError()))
            }
        }
    }

    func invalidateReadiness() {
        record(.invalidated)
        routeRevision += 1
        verifiedAt = nil
    }

    /// Opens a fresh SOCKS5 tunnel through the exact loopback endpoint used by
    /// the SimpleX core, then reaches Tor Project through that tunnel. iOS does
    /// not expose URLSession's SOCKS proxy keys, so the probe speaks SOCKS5
    /// directly instead of relying on unavailable CFNetwork configuration.
    func verifyTorRoute(timeout: TimeInterval = 30) async throws -> Bool {
        guard case let .ready(port) = state,
              isXauXatManagedTorConfig(getNetCfg()) else {
            record(.manualProbeFailed, error: EmbeddedTorError.routeNotReady)
            throw EmbeddedTorError.routeNotReady
        }
        let generation = readinessGeneration
        let revision = routeRevision
        record(.manualProbe)
        do {
            guard try await routeProbe(port, timeout) else { throw EmbeddedTorError.checkFailed }
            guard readinessGeneration == generation, routeRevision == revision, case let .ready(currentPort) = state,
                  currentPort == port else { throw EmbeddedTorError.routeNotReady }
            lastFailureCode = nil
            record(.manualVerified)
            return true
        } catch {
            record(.manualProbeFailed, error: error)
            // A failed manual check must not leave a green Ready indicator.
            // Do not invalidate an unrelated, newer startup attempt.
            if case let .ready(currentPort) = state, currentPort == port,
               attempt == nil, readinessGeneration == generation, routeRevision == revision {
                invalidateReadiness()
                setXauXatTorSocksPort(nil)
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func begin() {
        let id = UUID()
        attempt = id
        readinessGeneration = id
        attemptRevision = routeRevision
        verifiedAt = nil
        state = .starting
        lastBootstrapBucket = nil
        record(.start)
        routeTask?.cancel()
        routeTask = nil
        requestingPort = false
        recoveryAttempted = false
        setXauXatTorSocksPort(nil)
        logger.notice("XauXat Tor: starting embedded client")

        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.startupTimeout ?? 240_000_000_000)
            } catch {
                return
            }
            self?.finish(.failure(EmbeddedTorError.timeout), id: id, allowRecovery: false)
        }

        Task { await startTor(id: id) }
    }

    private func startTor(id: UUID) async {
        do {
            // C-Tor cannot safely be run twice concurrently, and re-entering a
            // stopped C runtime is not reliable. Recover a live runtime through
            // its control protocol; a terminated runtime needs a fresh app process.
            if let thread, thread.isFinished { throw EmbeddedTorError.processStopped }
            if thread == nil {
                authenticated = false
                controller = nil

                let directory = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                ).appendingPathComponent("Tor", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                guard excludeFromSystemBackup(directory) else {
                    throw EmbeddedTorError.backupProtection
                }

                let config = TorConfiguration()
                config.ignoreMissingTorrc = true
                config.cookieAuthentication = true
                config.dataDirectory = directory
                config.autoControlPort = true
                config.clientOnly = true
                config.avoidDiskWrites = true
                config.arguments = [
                    "--SocksPort", "127.0.0.1:auto",
                    "--Log", "notice stdout"
                ]

                if let portFile = config.controlPortFile,
                   FileManager.default.fileExists(atPath: portFile.path) {
                    try FileManager.default.removeItem(at: portFile)
                }

                configuration = config
                let torThread = TorThread(configuration: config)
                thread = torThread
                torThread.start()
            }

            guard let thread, !thread.isFinished, let config = configuration else {
                throw EmbeddedTorError.processStopped
            }
            if authenticated, let controller, controller.isConnected {
                // Also repairs a previous recovery interrupted after disabling
                // networking. This cannot enable a direct SimpleX connection.
                do {
                    try await command(controller, "SETCONF", ["DisableNetwork=0"])
                    guard attempt == id else { return }
                    observeCircuit(controller, id: id)
                    return
                } catch {
                    guard attempt == id else { return }
                    record(.controlReopened, error: error)
                    removeObservers()
                    // TorController.disconnect() sends SIGNAL SHUTDOWN in the
                    // pinned framework. Releasing its socket must not kill Tor.
                    self.controller = nil
                    authenticated = false
                    // Reopen the control socket below rather than trusting a
                    // non-nil channel left behind after iOS suspended the app.
                }
            }
            guard let portFile = config.controlPortFile else {
                throw EmbeddedTorError.missingControlPort
            }

            // The framework asserts when its file initializer sees a partial file,
            // so wait for a complete loopback endpoint and authentication cookie.
            for _ in 0..<100 {
                guard attempt == id else { return }
                guard !thread.isFinished else { throw EmbeddedTorError.processStopped }

                if let contents = try? String(contentsOf: portFile, encoding: .utf8),
                   let port = Self.loopbackPort(contents.replacingOccurrences(of: "PORT=", with: "")),
                   let cookie = config.cookie, !cookie.isEmpty {
                    let control = TorController(socketHost: "127.0.0.1", port: port)
                    if control.isConnected {
                        controller = control
                        authenticate(control, cookie: cookie, id: id)
                        return
                    }
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw EmbeddedTorError.controlTimeout
        } catch {
            finish(.failure(error), id: id)
        }
    }

    private func authenticate(_ control: TorController, cookie: Data, id: UUID) {
        control.authenticate(with: cookie) { [weak self] success, _ in
            Task { @MainActor in
                guard let self, self.attempt == id else { return }
                guard success else {
                    self.finish(.failure(EmbeddedTorError.authentication), id: id)
                    return
                }
                self.authenticated = true
                self.record(.authenticated)
                do {
                    // Reauthentication can follow a repair interrupted while
                    // DisableNetwork was set. Restore Tor before waiting for
                    // a circuit; otherwise that retry could wait forever.
                    try await self.command(control, "SETCONF", ["DisableNetwork=0"])
                    guard self.attempt == id else { return }
                    self.observeCircuit(control, id: id)
                } catch {
                    self.finish(.failure(error), id: id)
                }
            }
        }
    }

    private func observeCircuit(_ control: TorController, id: UUID) {
        record(.circuitCheck)
        removeObservers()
        statusObserver = control.addObserver(forStatusEvents: { [weak self] type, _, action, arguments in
            guard type == "STATUS_CLIENT" else { return false }
            Task { @MainActor in
                guard let self, self.attempt == id, !self.requestingPort else { return }
                if action == "BOOTSTRAP", let value = arguments?["PROGRESS"], let progress = Int(value) {
                    self.state = .bootstrapping(progress)
                    let bounded = max(0, min(100, progress))
                    if self.lastBootstrapBucket != bounded / 10 {
                        self.lastBootstrapBucket = bounded / 10
                        self.record(.bootstrap, count: bounded)
                    }
                } else if action == "CIRCUIT_ESTABLISHED" {
                    self.requestingPort = true
                    self.requestSocksPort(control, id: id)
                }
            }
            return false
        })
        Task {
            do {
                try await command(control, "SETEVENTS", ["STATUS_CLIENT"])
                guard attempt == id else { return }
                let established = try await info(control, "status/circuit-established")
                guard attempt == id, !requestingPort else { return }
                if established == "1" {
                    requestingPort = true
                    requestSocksPort(control, id: id)
                }
            } catch {
                // An established-circuit event may already have advanced this
                // attempt; an obsolete snapshot must not reset that progress.
                guard attempt == id, !requestingPort else { return }
                finish(.failure(error), id: id)
            }
        }
    }

    private func requestSocksPort(_ control: TorController, id: UUID) {
        Task {
            do {
                let value = try await info(control, "net/listeners/socks")
                guard attempt == id else { return }
                // Let outstanding mutable control commands finish in order;
                // once they are done, never probe on their old path revision.
                guard attemptRevision == routeRevision else { begin(); return }
                guard let port = Self.loopbackPort(value) else { throw EmbeddedTorError.invalidSocksPort }
                state = .verifying
                routeTask = Task { await self.verifyStartupRoute(port: port, id: id) }
            } catch {
                finish(.failure(error), id: id)
            }
        }
    }

    private func verifyStartupRoute(port: UInt16, id: UUID) async {
        var lastError: Error = EmbeddedTorError.checkFailed

        // A Tor circuit event only proves that the embedded process built a
        // circuit. Do not publish the SOCKS endpoint or let the chat core start
        // until traffic has actually crossed that endpoint and reached Tor.
        for attemptNumber in 1...3 {
            guard attempt == id else { return }
            record(.probe, count: attemptNumber)
            do {
                guard try await routeProbe(port, 30) else {
                    throw EmbeddedTorError.checkFailed
                }
                finish(.success(port), id: id)
                return
            } catch {
                guard attempt == id else { return }
                lastError = error
                record(.probeFailed, error: error)
                logger.error("XauXat Tor: startup route probe \(attemptNumber, privacy: .public) failed: \(Self.diagnosticFailure(error), privacy: .public)")
            }

            if attemptNumber < 3 {
                do {
                    try await Task.sleep(nanoseconds: retryDelay)
                } catch {
                    return
                }
            }
        }

        finish(.failure(lastError), id: id)
    }

    private func finish(_ result: Result<UInt16, Error>, id: UUID, allowRecovery: Bool = true) {
        guard attempt == id else { return }
        if case .success = result, thread?.isFinished != false {
            finish(.failure(EmbeddedTorError.processStopped), id: id, allowRecovery: false)
            return
        }
        if case .success = result, attemptRevision != routeRevision {
            // A path/background change happened while this probe was in flight.
            // Keep every waiter, but do not publish old-path readiness. This
            // also covers foreground startup, which precedes core recovery.
            begin()
            return
        }
        if case .failure = result, allowRecovery, !recoveryAttempted,
           let thread, !thread.isFinished, authenticated,
           let controller, controller.isConnected {
            recoveryAttempted = true
            requestingPort = true
            setXauXatTorSocksPort(nil)
            state = .verifying
            routeTask?.cancel()
            routeTask = nil
            removeObservers()
            Task { await recover(controller, id: id) }
            return
        }
        attempt = nil
        deadline?.cancel()
        deadline = nil
        routeTask?.cancel()
        routeTask = nil
        removeObservers()

        switch result {
        case let .success(port):
            lastFailureCode = nil
            record(.ready)
            if attemptRevision == routeRevision { verifiedAt = ProcessInfo.processInfo.systemUptime }
            setXauXatTorSocksPort(port)
            state = .ready(port)
            logger.notice("XauXat Tor: embedded client is ready")
        case let .failure(error):
            record(.failed, error: error)
            setXauXatTorSocksPort(nil)
            // Dropping the controller closes only its socket. Its disconnect()
            // method would shut down the entire embedded Tor runtime.
            controller = nil
            authenticated = false
            state = .failed(error.localizedDescription)
            logger.error("XauXat Tor: startup failed: \(Self.diagnosticFailure(error), privacy: .public)")
        }

        let pending = Array(callbacks.values)
        callbacks.removeAll()
        pending.forEach { $0(result) }
    }

    private func recover(_ control: TorController, id: UUID) async {
        record(.repair)
        do {
            logger.notice("XauXat Tor: rebuilding private connection after failed route check")
            // Reset only the live client's networking and loopback listener.
            // Never reload a torrc or construct another concurrent TorThread.
            for arguments in [["DisableNetwork=1"], ["SocksPort=0"], ["SocksPort=\"127.0.0.1:auto\"", "DisableNetwork=0"]] {
                guard attempt == id else { return }
                try await command(control, "SETCONF", arguments)
            }
            guard attempt == id else { return }
            requestingPort = false
            observeCircuit(control, id: id)
        } catch {
            finish(.failure(error), id: id)
        }
    }

    private func command(_ control: TorController, _ name: String, _ arguments: [String]) async throws {
        let accepted: Bool = await withCheckedContinuation { continuation in
            let completion = ControlCompletion(continuation)
            let timeout = DispatchWorkItem { completion.resume(false) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5, execute: timeout)
            control.sendCommand(name, arguments: arguments, data: nil) { codes, lines, stop in
                guard let code = codes.first?.intValue, code < 600 else { return false }
                // GETINFO replies belonging to another outstanding request
                // are not an acknowledgement for this command.
                if code == 250, !(codes.count == 1 && lines.count == 1 && String(data: lines[0], encoding: .utf8) == "OK") { return false }
                stop.pointee = true
                timeout.cancel()
                completion.resume(codes.last?.intValue == 250)
                return true
            }
        }
        guard accepted else { throw EmbeddedTorError.controlConnection }
    }

    private func info(_ control: TorController, _ key: String) async throws -> String {
        let value: String? = await withCheckedContinuation { continuation in
            let completion = ControlCompletion(continuation)
            let timeout = DispatchWorkItem { completion.resume(nil) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5, execute: timeout)
            control.sendCommand("GETINFO", arguments: [key], data: nil) { codes, lines, stop in
                // Tor sends 650 status events between command replies. The
                // framework GETINFO helper consumes these as invalid replies.
                guard let code = codes.first?.intValue, code < 600 else { return false }
                let prefix = key + "="
                let result = lines.compactMap { String(data: $0, encoding: .utf8) }.first { $0.hasPrefix(prefix) }
                if code == 250 && result == nil { return false }
                stop.pointee = true
                timeout.cancel()
                completion.resume(codes.allSatisfy { $0.intValue == 250 } ? result.map { String($0.dropFirst(prefix.count)) } : nil)
                return true
            }
        }
        guard let value else { throw EmbeddedTorError.controlConnection }
        return value
    }

    private func removeObservers() {
        controller?.removeObserver(statusObserver)
        statusObserver = nil
    }

    private final class ControlCompletion<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<Value, Never>

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Value) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            continuation.resume(returning: value)
        }
    }

    private static func loopbackPort(_ address: String) -> UInt16? {
        let clean = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = clean.split(separator: ":")
        guard parts.count == 2,
              parts[0] == "127.0.0.1",
              let port = UInt16(parts[1]),
              port > 0 else {
            return nil
        }
        return port
    }
}

private enum EmbeddedTorError: LocalizedError {
    case backupProtection
    case timeout
    case processStopped
    case missingControlPort
    case controlConnection
    case controlTimeout
    case authentication
    case invalidSocksPort
    case routeNotReady
    case checkFailed
    case circuitReset

    var errorDescription: String? {
        switch self {
        case .backupProtection: "XauXat could not protect Tor data from system backup."
        case .timeout: "Tor took too long to start."
        case .processStopped: "The embedded Tor process stopped. Close XauXat completely and reopen it."
        case .missingControlPort: "Tor did not create its control port."
        case .controlConnection: "XauXat could not connect to Tor locally."
        case .controlTimeout: "Tor did not open its control port in time."
        case .authentication: "XauXat could not authenticate with Tor locally."
        case .invalidSocksPort: "Tor did not return a valid local SOCKS port."
        case .routeNotReady: "The managed Tor route is not ready."
        case .checkFailed: "The Tor SOCKS route could not reach Tor Project."
        case .circuitReset: "Tor could not create a fresh circuit."
        }
    }
}

enum TorSOCKSProbeError: LocalizedError, Equatable {
    enum Stage: String {
        case localSocket = "opening the local Tor SOCKS socket"
        case handshake = "negotiating with the local Tor SOCKS proxy"
        case destination = "connecting through Tor to the route-check service"
        case response = "reading the route-check response through Tor"

        var diagnosticCode: String {
            switch self {
            case .localSocket: "local_socket"
            case .handshake: "handshake"
            case .destination: "destination"
            case .response: "response"
            }
        }
    }
    case failed(Stage)
    case timedOut(Stage)
    case rejected(UInt8)

    var errorDescription: String? {
        switch self {
        case let .failed(stage): "Private connection failed while \(stage.rawValue)."
        case let .timedOut(stage): "Private connection timed out while \(stage.rawValue)."
        case let .rejected(code): "Tor could not reach the route-check service (SOCKS reply \(code)). The network or Tor route may be unavailable."
        }
    }
}

enum TorSOCKSProbe {
    private static let queue = DispatchQueue(label: "chat.xauxat.tor-probe", qos: .userInitiated)

    static func run(port: UInt16, timeout timeoutInterval: TimeInterval) async throws -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw EmbeddedTorError.invalidSocksPort
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let expires = Date().addingTimeInterval(timeoutInterval)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
        defer {
            timeout.cancel()
            connection.cancel()
        }
        var stage = TorSOCKSProbeError.Stage.localSocket
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await connect(connection)

                stage = .handshake
                try await send(Data([0x05, 0x01, 0x00]), on: connection)
                guard try await receiveExactly(2, from: connection) == Data([0x05, 0x00]) else {
                    throw TorSOCKSProbeError.failed(.handshake)
                }

                let host = Array("check.torproject.org".utf8)
                guard host.count <= UInt8.max else { throw EmbeddedTorError.checkFailed }
                var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(host.count)])
                request.append(contentsOf: host)
                request.append(contentsOf: [0x00, 0x50]) // HTTP port 80
                stage = .destination
                try await send(request, on: connection)

                let reply = try await receiveExactly(4, from: connection)
                guard reply[0] == 0x05 else { throw TorSOCKSProbeError.failed(.destination) }
                guard reply[1] == 0x00 else { throw TorSOCKSProbeError.rejected(reply[1]) }
                switch reply[3] {
                case 0x01:
                    _ = try await receiveExactly(6, from: connection)
                case 0x03:
                    let length = Int(try await receiveExactly(1, from: connection)[0])
                    _ = try await receiveExactly(length + 2, from: connection)
                case 0x04:
                    _ = try await receiveExactly(18, from: connection)
                default:
                    throw TorSOCKSProbeError.failed(.destination)
                }

                let http = "HEAD / HTTP/1.1\r\nHost: check.torproject.org\r\nConnection: close\r\n\r\n"
                stage = .response
                try await send(Data(http.utf8), on: connection)
                // TCP preserves byte order, not packet boundaries. Even "HTTP/" may
                // arrive in several reads on a healthy, slow Tor circuit.
                var response = Data()
                while response.count < 4096 {
                    let next = try await receive(maximum: min(256, 4096 - response.count), from: connection)
                    guard !next.isEmpty else { throw TorSOCKSProbeError.failed(.response) }
                    response.append(next)
                    if let valid = validHTTPStatusLine(response) {
                        guard valid else { throw TorSOCKSProbeError.failed(.response) }
                        return true
                    }
                }
                throw TorSOCKSProbeError.failed(.response)
            } onCancel: {
                connection.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if Date() >= expires { throw TorSOCKSProbeError.timedOut(stage) }
            if let error = error as? TorSOCKSProbeError { throw error }
            throw TorSOCKSProbeError.failed(stage)
        }
    }

    static func validHTTPStatusLine(_ response: Data) -> Bool? {
        guard let end = response.range(of: Data([13, 10])) else { return nil }
        guard let line = String(data: response[..<end.lowerBound], encoding: .ascii) else { return false }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[0] == "HTTP/1.0" || fields[0] == "HTTP/1.1",
              fields[1].count == 3, let code = Int(fields[1]), (100...599).contains(code) else { return false }
        return true
    }

    private static func connect(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ConnectionCompletion(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.resume()
                case let .failed(error):
                    completion.resume(throwing: error)
                case .cancelled:
                    completion.resume(throwing: EmbeddedTorError.checkFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var data = Data()
        while data.count < count {
            let next = try await receive(maximum: count - data.count, from: connection)
            guard !next.isEmpty else { throw EmbeddedTorError.checkFailed }
            data.append(next)
        }
        return data
    }

    private static func receive(maximum: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: EmbeddedTorError.checkFailed)
                }
            }
        }
    }

    /// `NWConnection` state callbacks are `@Sendable`. This one-shot box keeps
    /// the checked continuation safe if Network.framework emits several
    /// terminal states, and remains valid when the project moves to Swift 6.
    private final class ConnectionCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<Void, Error>

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(throwing error: Error? = nil) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()

            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}
