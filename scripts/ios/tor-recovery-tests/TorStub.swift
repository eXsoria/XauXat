// Deterministic adapter for the pinned framework's control protocol. No Tor runtime.
import Foundation

public enum TorTestState {
    public static var commands: [String] = []
    public static var completedCommands: [String] = []
    public static var threadStarts = 0
    public static var controllers = 0
    public static var port: UInt16 = 19050
    public static var failNextCommand = false
    public static var failCommandContaining: String?
    public static var networkDisabled = false
    public static var circuitEstablished = true
    public static var establishAfterRepair = false
    public static var statusObservers: [UUID: (String, String, String, [String: String]?) -> Bool] = [:]
    public static var injectStatusBeforeReply = false
    public static var lastThread: TorThread?
    public static func reset() {
        commands = []; completedCommands = []; threadStarts = 0; controllers = 0; port = 19050
        failNextCommand = false; failCommandContaining = nil; networkDisabled = false; injectStatusBeforeReply = false; lastThread = nil
        circuitEstablished = true; establishAfterRepair = false; statusObservers = [:]
    }
    public static func emitProgress(_ progress: Int) {
        for observer in Array(statusObservers.values) { _ = observer("STATUS_CLIENT", "NOTICE", "BOOTSTRAP", ["PROGRESS": String(progress)]) }
    }
    public static func emitCircuit() {
        for observer in Array(statusObservers.values) { _ = observer("STATUS_CLIENT", "NOTICE", "CIRCUIT_ESTABLISHED", [:]) }
    }
}
public final class TorConfiguration {
    public var ignoreMissingTorrc = false
    public var cookieAuthentication = false
    public var dataDirectory: URL?
    public var autoControlPort = false
    public var clientOnly = false
    public var avoidDiskWrites = false
    public var arguments: [String] = []
    public var cookie: Data? { Data(repeating: 1, count: 32) }
    public let controlPortFile: URL? = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    public init() {}
    deinit { if let controlPortFile { try? FileManager.default.removeItem(at: controlPortFile) } }
}
public final class TorThread {
    public var isFinished = false
    public init(configuration: TorConfiguration) {
        try! "PORT=127.0.0.1:19051".write(to: configuration.controlPortFile!, atomically: true, encoding: .utf8)
    }
    public func start() { TorTestState.threadStarts += 1; TorTestState.lastThread = self }
}
public final class TorController {
    public var isConnected = true
    public init(socketHost: String, port: UInt16) { TorTestState.controllers += 1 }
    public func disconnect() { fatalError("The pinned framework disconnect() shuts down Tor; never use it for socket recovery") }
    public func authenticate(with cookie: Data, completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async { completion(true, nil) }
    }
    public func addObserver(forStatusEvents observer: @escaping (String, String, String, [String: String]?) -> Bool) -> Any {
        let token = UUID()
        TorTestState.statusObservers[token] = observer
        return token
    }
    public func addObserver(forCircuitEstablished observer: @escaping (Bool) -> Void) -> Any {
        DispatchQueue.main.async { observer(!TorTestState.networkDisabled) }
        return UUID()
    }
    public func getInfoForKeys(_ keys: [String], completion: @escaping ([String]) -> Void) {
        DispatchQueue.main.async { completion(["\"127.0.0.1:\(TorTestState.port)\""]) }
    }
    public func removeObserver(_ observer: Any?) {
        if let token = observer as? UUID { TorTestState.statusObservers.removeValue(forKey: token) }
    }
    public func sendCommand(_ command: String, arguments: [String]?, data: Data?, observer: @escaping ([NSNumber], [Data], UnsafeMutablePointer<ObjCBool>) -> Bool) {
        let text = ([command] + (arguments ?? [])).joined(separator: " ")
        TorTestState.commands.append(text)
        let matchesFailure = TorTestState.failCommandContaining.map { text.contains($0) } ?? false
        let fail = TorTestState.failNextCommand || matchesFailure
        TorTestState.failNextCommand = false
        if matchesFailure { TorTestState.failCommandContaining = nil }
        if !fail, arguments?.contains("DisableNetwork=1") == true { TorTestState.networkDisabled = true }
        if !fail, arguments?.contains("DisableNetwork=0") == true { TorTestState.networkDisabled = false }
        if !fail, arguments?.contains("SocksPort=\"127.0.0.1:auto\"") == true {
            TorTestState.port += 1
            if TorTestState.establishAfterRepair { TorTestState.circuitEstablished = true }
        }
        DispatchQueue.main.async {
            var stop: ObjCBool = false
            if TorTestState.injectStatusBeforeReply {
                let handled = observer([650], [Data("STATUS_CLIENT NOTICE BOOTSTRAP PROGRESS=90".utf8)], &stop)
                if handled || stop.boolValue { return }
            }
            let codes: [NSNumber]
            let lines: [Data]
            if !fail, command == "GETINFO", let key = arguments?.first {
                let value = key == "status/circuit-established" ? (TorTestState.networkDisabled || !TorTestState.circuitEstablished ? "0" : "1") : "\"127.0.0.1:\(TorTestState.port)\""
                codes = [250, 250]; lines = [Data((key + "=" + value).utf8), Data("OK".utf8)]
            } else {
                codes = [NSNumber(value: fail ? 551 : 250)]
                lines = [Data((fail ? "Failure" : "OK").utf8)]
            }
            _ = observer(codes, lines, &stop)
            TorTestState.completedCommands.append(text)
        }
    }
}
