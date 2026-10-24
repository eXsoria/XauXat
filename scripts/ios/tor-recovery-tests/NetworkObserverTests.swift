import Foundation
import Network

enum UserNetworkType { case wifi, cellular, ethernet, other, none }
struct UserNetworkInfo: Equatable { var networkType: UserNetworkType; var online: Bool }
final class ChatModel {
    static let shared = ChatModel()
    var networkInfo = UserNetworkInfo(networkType: .none, online: false)
    var chatInitialized = true
}
func hasChatCtrl() -> Bool { true }
private let coreLock = NSLock()
private var coreUpdates = 0
func apiSetNetworkInfo(_ info: UserNetworkInfo) throws {
    coreLock.lock(); defer { coreLock.unlock() }
    coreUpdates += 1
}
func updateCount() -> Int { coreLock.lock(); defer { coreLock.unlock() }; return coreUpdates }
struct Logger { func error(_ text: String) {} }
let logger = Logger()

@MainActor final class Fixture {
    static let shared = Fixture()
    var invalidations = 0
    var forces: [Bool] = []
    var commands = 0
    var held: CheckedContinuation<Void, Never>?
    lazy var manager = XauXatConnectionRecoveryManager(dependencies: .init(
        context: { .init(userId: 1, online: ChatModel.shared.networkInfo.online, active: true) },
        ensureTor: { force in
            self.forces.append(force)
            if self.forces.count == 1 { await withCheckedContinuation { self.held = $0 } }
            return .init(port: 19050, replaced: false)
        },
        invalidateTor: { self.invalidations += 1 },
        applyTor: { false },
        failedRelays: { [:] },
        reconnect: { _ in self.commands += 1 }
    ), networkSettleDelay: 0.002)
}
@MainActor extension XauXatConnectionRecoveryManager {
    static var shared: XauXatConnectionRecoveryManager { Fixture.shared.manager }
}

@main @MainActor struct NetworkObserverTests {
    static var checks = 0
    static func require(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError(message) }
    }
    static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("Timed out waiting for production network adapter")
    }
    static func main() async throws {
        let observer = NetworkObserver.shared, f = Fixture.shared
        observer.startMonitor()
        try await until { NWPathMonitor.current != nil }
        let monitor = NWPathMonitor.current!
        let cellular = NWPath(.satisfied, .cellular, route: 1)
        monitor.emit(cellular)
        try await until { f.held != nil }
        for _ in 0..<20 { monitor.emit(cellular) }
        try await until { f.manager.diagnosticText.contains("unchanged_path_updates=20") }
        require(f.invalidations == 1 && f.forces == [true], "Equal path callbacks cannot invalidate or replace an in-flight Tor verification")
        require(updateCount() == 1, "Repeated path snapshots cannot repeat native network-info commands")
        f.held!.resume(); f.held = nil
        try await until { f.commands == 1 }
        require(f.forces.count == 1, "Recovery must finish despite a burst of duplicate mobile path updates")
        monitor.emit(NWPath(.satisfied, .cellular, route: 2))
        try await until { f.commands == 2 }
        require(f.invalidations == 2, "A genuinely different route on the same cellular interface still needs repair")
        require(updateCount() == 1, "Route identity changes do not require redundant availability updates")
        monitor.emit(NWPath(.satisfied, .wifi, route: 3))
        try await until { f.commands == 3 && updateCount() == 2 }
        require(f.invalidations == 3 && updateCount() == 2, "Cellular to Wi-Fi must update both the core and recovery")
        observer.updateCoreNetworkInfo()
        try await until { updateCount() == 3 }
        require(NWPathMonitor.starts == 1 && f.invalidations == 3, "Opening a core must reuse availability without restarting the monitor or Tor")
        monitor.emit(NWPath(.unsatisfied, .wifi, route: 3))
        try await until { !ChatModel.shared.networkInfo.online }
        require(f.invalidations == 4 && f.commands == 3, "Losing the network must invalidate readiness without reconnecting offline")
        f.manager.pause()
        print("Production network observer regression checks passed: \(checks)")
    }
}
