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
        case ready(UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var thread: TorThread?
    private var controller: TorController?
    private var configuration: TorConfiguration?
    private var authenticated = false
    private var circuitObserver: Any?
    private var statusObserver: Any?
    private var attempt: UUID?
    private var callbacks: [(Result<UInt16, Error>) -> Void] = []
    private var deadline: Task<Void, Never>?
    private var requestingPort = false

    private init() {}

    func start(_ completion: @escaping (Result<UInt16, Error>) -> Void) {
        if case let .ready(port) = state, let thread, !thread.isFinished {
            completion(.success(port))
            return
        }

        callbacks.append(completion)
        switch state {
        case .starting, .bootstrapping:
            return
        case .stopped, .ready, .failed:
            begin()
        }
    }

    /// Opens a fresh SOCKS5 tunnel through the exact loopback endpoint used by
    /// the SimpleX core, then reaches Tor Project through that tunnel. iOS does
    /// not expose URLSession's SOCKS proxy keys, so the probe speaks SOCKS5
    /// directly instead of relying on unavailable CFNetwork configuration.
    func verifyTorRoute() async throws -> Bool {
        guard case let .ready(port) = state,
              isXauXatManagedTorConfig(getNetCfg()) else {
            throw EmbeddedTorError.routeNotReady
        }
        return try await TorSOCKSProbe.run(port: port)
    }

    private func begin() {
        let id = UUID()
        attempt = id
        state = .starting
        requestingPort = false
        setXauXatTorSocksPort(nil)
        logger.notice("XauXat Tor: starting embedded client")

        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 240_000_000_000)
            } catch {
                return
            }
            self?.finish(.failure(EmbeddedTorError.timeout), id: id)
        }

        Task { await startTor(id: id) }
    }

    private func startTor(id: UUID) async {
        do {
            if thread == nil || thread?.isFinished == true {
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
                observeCircuit(controller, id: id)
                return
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
                    guard control.isConnected else { throw EmbeddedTorError.controlConnection }
                    controller = control
                    authenticate(control, cookie: cookie, id: id)
                    return
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
                self.observeCircuit(control, id: id)
            }
        }
    }

    private func observeCircuit(_ control: TorController, id: UUID) {
        removeObservers()
        statusObserver = control.addObserver(forStatusEvents: { [weak self] _, _, action, arguments in
            guard action == "BOOTSTRAP", let value = arguments?["PROGRESS"], let progress = Int(value) else {
                return false
            }
            Task { @MainActor in
                guard let self, self.attempt == id, !self.requestingPort else { return }
                self.state = .bootstrapping(progress)
            }
            return false
        })
        circuitObserver = control.addObserver(forCircuitEstablished: { [weak self] established in
            guard established else { return }
            Task { @MainActor in
                guard let self, self.attempt == id, !self.requestingPort else { return }
                self.requestingPort = true
                self.requestSocksPort(control, id: id)
            }
        })
    }

    private func requestSocksPort(_ control: TorController, id: UUID) {
        control.getInfoForKeys(["net/listeners/socks"]) { [weak self] values in
            Task { @MainActor in
                guard let self, self.attempt == id else { return }
                guard values.count == 1, let port = Self.loopbackPort(values[0]) else {
                    self.finish(.failure(EmbeddedTorError.invalidSocksPort), id: id)
                    return
                }
                self.finish(.success(port), id: id)
            }
        }
    }

    private func finish(_ result: Result<UInt16, Error>, id: UUID) {
        guard attempt == id else { return }
        attempt = nil
        deadline?.cancel()
        deadline = nil
        removeObservers()

        switch result {
        case let .success(port):
            setXauXatTorSocksPort(port)
            state = .ready(port)
            logger.notice("XauXat Tor: embedded client is ready")
        case let .failure(error):
            setXauXatTorSocksPort(nil)
            state = .failed(error.localizedDescription)
            logger.error("XauXat Tor: startup failed: \(error.localizedDescription, privacy: .public)")
        }

        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { $0(result) }
    }

    private func removeObservers() {
        controller?.removeObserver(circuitObserver)
        controller?.removeObserver(statusObserver)
        circuitObserver = nil
        statusObserver = nil
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

    var errorDescription: String? {
        switch self {
        case .backupProtection: "XauXat could not protect Tor data from system backup."
        case .timeout: "Tor took too long to start."
        case .processStopped: "The embedded Tor process stopped."
        case .missingControlPort: "Tor did not create its control port."
        case .controlConnection: "XauXat could not connect to Tor locally."
        case .controlTimeout: "Tor did not open its control port in time."
        case .authentication: "XauXat could not authenticate with Tor locally."
        case .invalidSocksPort: "Tor did not return a valid local SOCKS port."
        case .routeNotReady: "The managed Tor route is not ready."
        case .checkFailed: "The Tor SOCKS route could not reach Tor Project."
        }
    }
}

private enum TorSOCKSProbe {
    private static let queue = DispatchQueue(label: "chat.xauxat.tor-probe", qos: .userInitiated)

    static func run(port: UInt16) async throws -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw EmbeddedTorError.invalidSocksPort
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        defer {
            timeout.cancel()
            connection.cancel()
        }
        try await connect(connection)

        try await send(Data([0x05, 0x01, 0x00]), on: connection)
        guard try await receiveExactly(2, from: connection) == Data([0x05, 0x00]) else {
            throw EmbeddedTorError.checkFailed
        }

        let host = Array("check.torproject.org".utf8)
        guard host.count <= UInt8.max else { throw EmbeddedTorError.checkFailed }
        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(host.count)])
        request.append(contentsOf: host)
        request.append(contentsOf: [0x00, 0x50]) // HTTP port 80
        try await send(request, on: connection)

        let reply = try await receiveExactly(4, from: connection)
        guard reply[0] == 0x05, reply[1] == 0x00 else {
            throw EmbeddedTorError.checkFailed
        }
        switch reply[3] {
        case 0x01:
            _ = try await receiveExactly(6, from: connection)
        case 0x03:
            let length = Int(try await receiveExactly(1, from: connection)[0])
            _ = try await receiveExactly(length + 2, from: connection)
        case 0x04:
            _ = try await receiveExactly(18, from: connection)
        default:
            throw EmbeddedTorError.checkFailed
        }

        let http = "GET /api/ip HTTP/1.1\r\nHost: check.torproject.org\r\nConnection: close\r\n\r\n"
        try await send(Data(http.utf8), on: connection)
        let response = try await receive(maximum: 2048, from: connection)
        guard let status = String(data: response, encoding: .utf8), status.hasPrefix("HTTP/") else {
            throw EmbeddedTorError.checkFailed
        }
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
