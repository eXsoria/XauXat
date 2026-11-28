import Foundation
import SimpleXChat
import Tor

extension Tests {
    private static func authManager(_ sleep: @escaping @MainActor (UInt64) async throws -> Void) -> EmbeddedTorManager {
        EmbeddedTorManager(routeProbe: { _, _ in true }, retryDelay: 2_000_000, startupTimeout: 2_000_000_000,
                           controlReplyTimeout: 0.06, initialAuthenticationTimeout: 0.06,
                           controlPollDelay: 1_000_000, authenticationSleep: sleep)
    }
    private static var authAttempts: Int { TorTestState.commands.filter { $0 == "AUTHENTICATE" }.count }

    static func delayedStartupAuthenticationSharesForegroundBackoff() async throws {
        reset()
        TorTestState.holdAuthentication = true
        var delays: [UInt64] = []
        let manager = authManager { nanoseconds in
            delays.append(nanoseconds / 1_000_000_000)
            if delays.count == 7 { TorTestState.holdAuthentication = false }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        var results: [Result<UInt16, Error>] = []
        for _ in 0..<2 { manager.startRetrying(whileAvailable: { true }) { results.append($0) } }
        try await until { results.count == 2 }
        require(delays == [5, 15, 30, 60, 90, 90, 90], "Concurrent startups must share one capped backoff through a prolonged local authentication outage")
        require(authAttempts == 10 && publishedPorts == [TorTestState.port], "Each delayed wake gets one new authenticated socket and publishes only the verified port")
        require(results.allSatisfy { (try? $0.get()) == TorTestState.port } && !manager.presentsStartupAuthenticationRetry, "Both startup callbacks must finish once and clear the recoverable alert")

        reset()
        let denied = authManager { _ in fatalError("A rejection must never enter timeout recovery") }
        TorTestState.failCommandContaining = "AUTHENTICATE"
        var refusal: Result<UInt16, Error>?
        denied.startRetrying(whileAvailable: { true }) { refusal = $0 }
        try await until { refusal != nil }
        require((try? refusal!.get()) == nil && authAttempts == 1 && publishedTorPort == nil, "An explicit negative AUTHENTICATE response must stop immediately and remain closed")

        reset()
        TorTestState.holdAuthentication = true
        var delayCount = 0
        let subsequentlyDenied = authManager { _ in
            delayCount += 1
            TorTestState.holdAuthentication = false
            TorTestState.failCommandContaining = "AUTHENTICATE"
        }
        refusal = nil
        subsequentlyDenied.startRetrying(whileAvailable: { true }) { refusal = $0 }
        try await until { refusal != nil }
        require((try? refusal!.get()) == nil && delayCount == 1 && authAttempts == 4 && publishedTorPort == nil && !subsequentlyDenied.presentsStartupAuthenticationRetry, "A rejection during extended recovery must close the alert, remain offline and stop further authentication")
    }

    static func staggeredStartupCannotAuthenticateAfterCancel() async throws {
        reset()
        TorTestState.holdAuthentication = true
        let manager = EmbeddedTorManager(routeProbe: { _, _ in true }, retryDelay: 100_000_000,
                                         startupTimeout: 4_000_000_000, controlReplyTimeout: 0.08,
                                         initialAuthenticationTimeout: 0.08,
                                         authenticationSleep: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) })
        var results: [Result<UInt16, Error>] = []
        manager.startRetrying(whileAvailable: { true }) { results.append($0) }
        try await until { authAttempts == 2 }
        manager.startRetrying(whileAvailable: { true }) { results.append($0) }
        try await until { manager.presentsStartupAuthenticationRetry }
        require(authAttempts == 3, "A late foreground caller must join the entire cold startup sequence")
        manager.cancelStartupAuthentication()
        try await until { results.count == 2 }
        try await Task.sleep(nanoseconds: 250_000_000)
        require(authAttempts == 3 && results.allSatisfy { (try? $0.get()) == nil }, "Cancel must also stop every overlapping caller's fast retry")
    }

    static func startupAuthenticationRetryRespectsUserAndLifecycle() async throws {
        for scenario in ["cancel_wait", "cancel_auth", "retry", "offline", "foreground_lost", "background_auth"] {
            reset()
            TorTestState.holdAuthentication = true
            var available = true
            let manager = authManager { _ in
                try await Task.sleep(nanoseconds: ["cancel_auth", "foreground_lost", "background_auth"].contains(scenario) ? 100_000_000 : 20_000_000_000)
            }
            var results: [Result<UInt16, Error>] = []
            manager.startRetrying(whileAvailable: { available }) { results.append($0) }
            try await until { manager.presentsStartupAuthenticationRetry }
            if ["cancel_auth", "background_auth"].contains(scenario) { try await until { authAttempts == 4 } }
            let before = authAttempts
            let lateReply = TorTestState.pendingAuthentication
            switch scenario {
            case "cancel_wait", "cancel_auth": manager.cancelStartupAuthentication()
            case "retry":
                TorTestState.holdAuthentication = false
                manager.retryStartupAuthenticationNow()
            case "background_auth":
                available = false
                manager.pauseStartupAuthenticationRecovery()
            case "offline":
                available = false
                manager.networkAvailabilityChanged(online: false)
            default: available = false
            }
            try await until { results.count == 1 }
            require(!manager.presentsStartupAuthenticationRetry, "The alert must close when the recovery settles")
            if scenario == "retry" {
                require((try? results[0].get()) == TorTestState.port && authAttempts == before + 1, "Manual Retry must interrupt the outstanding delay and use a single new socket")
                continue
            }
            lateReply?()
            try await Task.sleep(nanoseconds: 15_000_000)
            require(authAttempts == before && publishedTorPort == nil && (try? results[0].get()) == nil, "Cancel or loss of foreground/network must suppress delayed auth work and late replies")
            if scenario.hasPrefix("cancel") {
                manager.startRetrying(whileAvailable: { true }) { results.append($0) }
                try await until { results.count == 2 }
                require(authAttempts == before && (try? results[1].get()) == nil, "An incidental callback in the same foreground cannot override Cancel")
            }
            available = true
            if scenario == "offline" { manager.networkAvailabilityChanged(online: true) }
            manager.allowStartupAuthentication()
            TorTestState.holdAuthentication = false
            var fresh: Result<UInt16, Error>?
            manager.startRetrying(whileAvailable: { available }) { fresh = $0 }
            try await until { fresh != nil }
            require((try? fresh!.get()) == TorTestState.port && authAttempts == before + 1, "A fresh foreground/network attempt must verify the surviving Tor runtime")
        }
    }
}
