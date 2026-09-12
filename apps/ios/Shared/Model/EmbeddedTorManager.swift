//
//  EmbeddedTorManager.swift
//  XauXat (iOS)
//
//  Starts an app-local Tor client and publishes only its loopback SOCKS port.
//  The SimpleX core remains fail-closed until this manager marks Tor as ready.
//

import Foundation
import OSLog
import SimpleXChat
import Tor

@MainActor
final class EmbeddedTorManager {
    static let shared = EmbeddedTorManager()

    enum State: Equatable {
        case stopped
        case starting
        case bootstrapping(Int)
        case ready(UInt16)
        case failed(String)
    }

    private(set) var state: State = .stopped

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
                var excludedDirectory = directory
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try excludedDirectory.setResourceValues(resourceValues)

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
    case timeout
    case processStopped
    case missingControlPort
    case controlConnection
    case controlTimeout
    case authentication
    case invalidSocksPort

    var errorDescription: String? {
        switch self {
        case .timeout: "Tor took too long to start."
        case .processStopped: "The embedded Tor process stopped."
        case .missingControlPort: "Tor did not create its control port."
        case .controlConnection: "XauXat could not connect to Tor locally."
        case .controlTimeout: "Tor did not open its control port in time."
        case .authentication: "XauXat could not authenticate with Tor locally."
        case .invalidSocksPort: "Tor did not return a valid local SOCKS port."
        }
    }
}
