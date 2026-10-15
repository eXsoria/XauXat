// Deterministic adapter for the pinned framework's control protocol. No Tor runtime.
import Foundation

public enum TorTestState {
    public static var commands: [String] = []
    public static var threadStarts = 0
    public static var controllers = 0
    public static var port: UInt16 = 19050
    public static var failNextCommand = false
    public static var lastThread: TorThread?
    public static func reset() {
        commands = []; threadStarts = 0; controllers = 0; port = 19050
        failNextCommand = false; lastThread = nil
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
    public func disconnect() { isConnected = false }
    public func authenticate(with cookie: Data, completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async { completion(true, nil) }
    }
    public func addObserver(forStatusEvents observer: @escaping (String, String, String, [String: String]?) -> Bool) -> Any { UUID() }
    public func addObserver(forCircuitEstablished observer: @escaping (Bool) -> Void) -> Any {
        DispatchQueue.main.async { observer(true) }
        return UUID()
    }
    public func getInfoForKeys(_ keys: [String], completion: @escaping ([String]) -> Void) {
        DispatchQueue.main.async { completion(["\"127.0.0.1:\(TorTestState.port)\""]) }
    }
    public func removeObserver(_ observer: Any?) {}
    public func sendCommand(_ command: String, arguments: [String]?, data: Data?, observer: @escaping ([NSNumber], [Data], UnsafeMutablePointer<ObjCBool>) -> Bool) {
        TorTestState.commands.append(([command] + (arguments ?? [])).joined(separator: " "))
        let fail = TorTestState.failNextCommand
        TorTestState.failNextCommand = false
        if !fail, arguments?.contains("SocksPort=\"127.0.0.1:auto\"") == true { TorTestState.port += 1 }
        DispatchQueue.main.async {
            var stop: ObjCBool = false
            _ = observer([NSNumber(value: fail ? 551 : 250)], [], &stop)
        }
    }
}
