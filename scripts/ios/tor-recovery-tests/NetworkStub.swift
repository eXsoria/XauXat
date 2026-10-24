import Foundation

// Controlled monitor snapshots for the unmodified production NetworkObserver.
public struct NWInterface {
    public enum InterfaceType { case wiredEthernet, wifi, cellular, other }
}
public struct NWPath: Equatable {
    public enum Status { case satisfied, unsatisfied }
    public let status: Status
    public let interface: NWInterface.InterfaceType
    public let route: Int
    public init(_ status: Status, _ interface: NWInterface.InterfaceType, route: Int) {
        self.status = status; self.interface = interface; self.route = route
    }
    public func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool { interface == type }
}
public final class NWPathMonitor {
    private static let lock = NSLock()
    private static var currentMonitor: NWPathMonitor?
    private static var startCount = 0
    public static var current: NWPathMonitor? {
        lock.lock(); defer { lock.unlock() }; return currentMonitor
    }
    public static var starts: Int {
        lock.lock(); defer { lock.unlock() }; return startCount
    }
    public var pathUpdateHandler: ((NWPath) -> Void)?
    private var queue: DispatchQueue?
    public init() {}
    public func start(queue: DispatchQueue) {
        self.queue = queue
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.startCount += 1
        Self.currentMonitor = self
    }
    public func emit(_ path: NWPath) { queue!.async { self.pathUpdateHandler?(path) } }
}
