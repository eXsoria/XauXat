import Foundation
import SimpleXChat
import Tor

extension Tests {
    private enum ListenerScenario: CaseIterable {
        case sameListener, changedPort, rebuiltOnSamePort, stoppedRuntime, newRuntimeOnSamePort, blockedRoute, healthySubscriptions
    }

    static func selectiveRecoveryDuringForegroundVerification() async throws {
        for scenario in ListenerScenario.allCases {
            try await exerciseListenerRecovery(scenario)
        }
    }

    private static func exerciseListenerRecovery(_ scenario: ListenerScenario) async throws {
        typealias Recovery = XauXatConnectionRecoveryManager
        reset()
        let probe = ScriptedProbe()
        let original = probe.manager()
        let initialPort = try await original.ensureReady()
        let tor: EmbeddedTorManager
        if scenario == .newRuntimeOnSamePort {
            TorTestState.lastThread?.isFinished = true
            publishedTorPort = nil
            tor = probe.manager()
        } else {
            tor = original
        }
        TorTestState.reusePortOnRepair = scenario == .rebuiltOnSamePort
        if scenario == .changedPort { TorTestState.port += 1 }

        let relay = Recovery.Relay(userId: 1, server: "fixture.invalid")
        var commands: [Recovery.Scope] = []
        var applied = 0
        let recovery = Recovery(dependencies: .init(
            context: { .init(userId: 1, online: true, active: true) },
            ensureTor: { try await tor.verifiedRecoveryRoute(force: $0) },
            invalidateTor: { tor.invalidateReadiness() },
            applyTor: {
                require(publishedTorPort != nil, "A blocked route must never configure the core")
                applied += 1
                return false
            },
            failedRelays: { scenario == .healthySubscriptions ? [:] : [relay: 0] },
            reconnect: { commands.append($0) },
            sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        ))
        defer { recovery.pause() }

        var releaseProbe: CheckedContinuation<Void, Never>?
        var firstCheck = true
        var failures = scenario == .rebuiltOnSamePort ? 3 : 0
        probe.handler = { _ in
            if firstCheck {
                firstCheck = false
                await withCheckedContinuation { releaseProbe = $0 }
            }
            if scenario == .blockedRoute { return false }
            if failures > 0 { failures -= 1; return false }
            return true
        }
        let foreground = Task { try await tor.ensureReady() }
        try await until { releaseProbe != nil }
        guard case .verifying = tor.state else { fatalError("The foreground probe must be running") }
        require(publishedTorPort == nil, "An in-flight verification must keep new traffic blocked")
        let selective = Task { try await recovery.reconnect(.automatic, reason: .pendingWork) }
        if scenario == .healthySubscriptions {
            try await selective.value
        } else {
            try await until { tor.diagnosticText.contains("tor joined") }
        }
        if scenario == .stoppedRuntime { TorTestState.lastThread?.isFinished = true }
        releaseProbe?.resume()

        let foregroundResult = await foreground.result
        let repairResult = await selective.result
        switch scenario {
        case .blockedRoute, .stoppedRuntime:
            guard case .failure = foregroundResult, case .failure = repairResult else {
                fatalError("A failed route must prevent both foreground and selective recovery")
            }
            require(publishedTorPort == nil && applied == 0 && commands.isEmpty, "Failed verification must stay closed")
            if scenario == .stoppedRuntime {
                require(tor.requiresRelaunch && TorTestState.threadStarts == 1, "A terminated runtime must require a new process")
            }
        default:
            let verifiedPort = try foregroundResult.get()
            try repairResult.get()
            require(verifiedPort == publishedTorPort, "The core must receive the verified endpoint")
            require((initialPort != verifiedPort) == (scenario == .changedPort), "The fixture returned an unexpected port")
            let expected: [Recovery.Scope]
            switch scenario {
            case .sameListener: expected = [.relays([relay])]
            case .healthySubscriptions: expected = []
            default: expected = [.all]
            }
            require(commands == expected, "Unexpected recovery scope when testing \(scenario)")
            require(applied == (commands.isEmpty ? 0 : 1), "The configuration should be checked once per actual repair")
            if scenario == .newRuntimeOnSamePort {
                require(TorTestState.threadStarts == 2, "The same number must belong to a fresh runtime")
            }
        }
    }
}
