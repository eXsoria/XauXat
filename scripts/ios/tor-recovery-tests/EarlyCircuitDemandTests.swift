import Foundation
import SimpleXChat
import Tor

extension Tests {
    private enum EarlyCircuitResult: CaseIterable { case reachable, relayUnavailable, circuitUnconfirmed }

    static func warmCircuitDemandUsesOneStallBudget() async throws {
        for scenario in EarlyCircuitResult.allCases {
            reset()
            var resuming = false
            var budgets: [TimeInterval] = []
            let tor = EmbeddedTorManager(routeProbe: { _, budget in
                guard resuming else { return true }
                require(publishedTorPort == nil, "An early private stream may never expose an unverified listener")
                budgets.append(budget)
                if scenario == .reachable { TorTestState.circuitEstablished = true }
                return scenario != .relayUnavailable
            }, retryDelay: 0, startupTimeout: 2_000_000_000)
            let initialPort = try await tor.ensureReady()
            tor.invalidateReadiness()
            TorTestState.circuitEstablished = false
            resuming = true
            let result = try? await tor.ensureReady()
            require(!budgets.isEmpty, "A verified runtime with enough directory information must request a circuit before the stall timer")
            require(budgets[0] > 24 && budgets[0] <= 25, "Only the early stream may spend the existing 25-second stall window")
            require(TorTestState.commands.contains("GETINFO status/enough-dir-info"), "Early demand requires directory information from the current runtime")
            let repairs = TorTestState.commands.filter { $0 == "SETCONF SocksPort=0" }.count
            if scenario == .reachable {
                require(result == initialPort && budgets.count == 1 && repairs == 0, "A successful early stream must keep the current verified listener without repair")
            } else {
                require(result == nil && publishedTorPort == nil, "Either failed relay access or failed circuit confirmation must keep the route closed")
                require(budgets.count == 4 && repairs == 1, "A failed early stream must lead directly to one repair and at most three ordinary probes")
                require(budgets[1] > 31 && budgets[1] <= 32, "Repair keeps its full existing verification window")
            }
        }
    }

    static func pathLossDuringEarlyDemandCannotPublishTheOldListener() async throws {
        reset()
        let probe = ScriptedProbe(), tor = probe.manager()
        let initialPort = try await tor.ensureReady()
        tor.networkAvailabilityChanged(online: false)
        let count = TorTestState.commands.count
        var result: Result<UInt16, Error>?
        tor.start { result = $0 }
        require(TorTestState.commands.count == count && probe.calls == 1 && publishedTorPort == nil, "An offline foreground request must remain paused even after a previously verified route")
        TorTestState.circuitEstablished = false
        var held: CheckedContinuation<Bool, Error>?
        probe.handler = { _ in try await withCheckedThrowingContinuation { held = $0 } }
        tor.networkAvailabilityChanged(online: true)
        tor.refreshPendingStartup()
        try await until { held != nil }
        tor.networkAvailabilityChanged(online: false)
        held!.resume(returning: true)
        try await Task.sleep(nanoseconds: 15_000_000)
        require(result == nil && publishedTorPort == nil && publishedPorts == [initialPort], "A delayed successful stream from a lost path must not publish")
        probe.handler = { _ in true }
        TorTestState.circuitEstablished = true
        TorTestState.port += 1
        tor.networkAvailabilityChanged(online: true)
        tor.refreshPendingStartup()
        try await until { result != nil }
        require(try result!.get() == TorTestState.port && publishedPorts == [initialPort, TorTestState.port], "Only the new path's verified listener may release the waiting caller")
    }
}
