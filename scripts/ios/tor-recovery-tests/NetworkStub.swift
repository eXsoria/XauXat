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
    public static var current: NWPathMonitor?
    public static var starts = 0
    public var pathUpdateHandler: ((NWPath) -> Void)?
    private var queue: DispatchQueue?
    public init() { Self.current = self }
    public func start(queue: DispatchQueue) { self.queue = queue; Self.starts += 1 }
    public func emit(_ path: NWPath) { queue!.async { self.pathUpdateHandler?(path) } }
}
