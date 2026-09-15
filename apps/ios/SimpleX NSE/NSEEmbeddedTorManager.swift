//
//  NSEEmbeddedTorManager.swift
//  SimpleX NSE
//
//  Notification service extensions run outside the main app process. This
//  manager therefore owns a separate Tor client and never reuses or publishes
//  the main app's short-lived SOCKS endpoint.
//

import Foundation
import OSLog
import SimpleXChat
@preconcurrency import Tor

final class NSEEmbeddedTorManager {
    static let shared = NSEEmbeddedTorManager()

    private enum State {
        case stopped
        case starting
        case ready(UInt16)
        case failed
    }

    private let queue = DispatchQueue(label: "chat.xauxat.nse.embedded-tor")
    private var state: State = .stopped
    private var thread: TorThread?
    private var controller: TorController?
    private var configuration: TorConfiguration?
    private var circuitObserver: Any?
    private var statusObserver: Any?
    private var attempt: UUID?
    private var callbacks: [(Result<UInt16, Error>) -> Void] = []
    private var deadline: DispatchWorkItem?
    private var requestingPort = false

    private init() {}

    func start(_ completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async {
            if case let .ready(port) = self.state,
               let thread = self.thread,
               !thread.isFinished {
                completion(.success(port))
                return
            }

            self.callbacks.append(completion)
            switch self.state {
            case .starting:
                return
            case .stopped, .ready, .failed:
                self.begin()
            }
        }
    }

    private func begin() {
        let id = UUID()
        attempt = id
        state = .starting
        requestingPort = false
        logger.notice("XauXat NSE Tor: starting isolated embedded client")

        deadline?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.queue.async {
                self?.finish(.failure(NSEEmbeddedTorError.bootstrapTimeout), id: id)
            }
        }
        deadline = timeout
        // Leave enough of the extension's approximately 30 second lifetime to
        // open the database, retrieve the message and deliver a notification.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 18, execute: timeout)

        do {
            try startThreadIfNeeded()
            pollForControlPort(id: id, attemptsRemaining: 90)
        } catch {
            finish(.failure(error), id: id)
        }
    }

    private func startThreadIfNeeded() throws {
        if thread == nil || thread?.isFinished == true {
            controller = nil

            let directory = getGroupContainerDirectory()
                .appendingPathComponent("TorNSE", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard excludeFromSystemBackup(directory) else {
                throw NSEEmbeddedTorError.backupProtection
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

        guard let thread, !thread.isFinished, configuration != nil else {
            throw NSEEmbeddedTorError.processStopped
        }
    }

    private func pollForControlPort(id: UUID, attemptsRemaining: Int) {
        guard attempt == id else { return }
        guard let thread, !thread.isFinished else {
            finish(.failure(NSEEmbeddedTorError.processStopped), id: id)
            return
        }
        guard let config = configuration, let portFile = config.controlPortFile else {
            finish(.failure(NSEEmbeddedTorError.missingControlPort), id: id)
            return
        }

        if let contents = try? String(contentsOf: portFile, encoding: .utf8),
           let port = Self.loopbackPort(contents.replacingOccurrences(of: "PORT=", with: "")),
           let cookie = config.cookie, !cookie.isEmpty {
            let control = TorController(socketHost: "127.0.0.1", port: port)
            guard control.isConnected else {
                finish(.failure(NSEEmbeddedTorError.controlConnection), id: id)
                return
            }
            controller = control
            authenticate(control, cookie: cookie, id: id)
            return
        }

        guard attemptsRemaining > 1 else {
            finish(.failure(NSEEmbeddedTorError.controlTimeout), id: id)
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pollForControlPort(id: id, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func authenticate(_ control: TorController, cookie: Data, id: UUID) {
        control.authenticate(with: cookie) { [weak self] success, _ in
            self?.queue.async {
                guard let self, self.attempt == id else { return }
                guard success else {
                    self.finish(.failure(NSEEmbeddedTorError.authentication), id: id)
                    return
                }
                self.observeCircuit(control, id: id)
            }
        }
    }

    private func observeCircuit(_ control: TorController, id: UUID) {
        removeObservers()
        statusObserver = control.addObserver(forStatusEvents: { _, _, action, arguments in
            if action == "BOOTSTRAP", let progress = arguments?["PROGRESS"] {
                logger.debug("XauXat NSE Tor: bootstrap \(progress, privacy: .public)%")
            }
            return false
        })
        circuitObserver = control.addObserver(forCircuitEstablished: { [weak self] established in
            guard established else { return }
            self?.queue.async {
                guard let self, self.attempt == id, !self.requestingPort else { return }
                self.requestingPort = true
                self.requestSocksPort(control, id: id)
            }
        })
    }

    private func requestSocksPort(_ control: TorController, id: UUID) {
        control.getInfoForKeys(["net/listeners/socks"]) { [weak self] values in
            self?.queue.async {
                guard let self, self.attempt == id else { return }
                guard values.count == 1, let port = Self.loopbackPort(values[0]) else {
                    self.finish(.failure(NSEEmbeddedTorError.invalidSocksPort), id: id)
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
            state = .ready(port)
            logger.notice("XauXat NSE Tor: isolated SOCKS route is ready")
        case let .failure(error):
            state = .failed
            logger.error("XauXat NSE Tor: startup failed: \(error.localizedDescription, privacy: .public)")
        }

        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { callback in
            DispatchQueue.global(qos: .userInitiated).async {
                callback(result)
            }
        }
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

private enum NSEEmbeddedTorError: LocalizedError {
    case backupProtection
    case bootstrapTimeout
    case processStopped
    case missingControlPort
    case controlConnection
    case controlTimeout
    case authentication
    case invalidSocksPort

    var errorDescription: String? {
        switch self {
        case .backupProtection: "Could not protect the notification Tor data from backup."
        case .bootstrapTimeout: "Tor did not bootstrap within the notification extension budget."
        case .processStopped: "The notification Tor process stopped."
        case .missingControlPort: "Tor did not provide a notification control port."
        case .controlConnection: "Could not connect to the notification Tor control port."
        case .controlTimeout: "Tor did not open its notification control port in time."
        case .authentication: "Could not authenticate with the notification Tor process."
        case .invalidSocksPort: "Tor returned an invalid notification SOCKS port."
        }
    }
}
