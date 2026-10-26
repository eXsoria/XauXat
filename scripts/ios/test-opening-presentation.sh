#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

# Compile the actual presentation predicate and authentication callback. These
# adapters replace Face ID/database services, not the production decisions.
python3 - "$root" "$temp" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
content = (root / 'apps/ios/Shared/ContentView.swift').read_text()
sheet = (root / 'apps/ios/Shared/Views/Helpers/AppSheet.swift').read_text()
auth = (root / 'apps/ios/Shared/Views/Helpers/LocalAuthenticationUtils.swift').read_text()
app = (root / 'apps/ios/Shared/SimpleXApp.swift').read_text()
suspend = (root / 'apps/ios/Shared/Model/SuspendChat.swift').read_text()

def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

assert 'else if showsInitializationView {' in content
assert '.modifier(XauXatAppSwitcherProtection(showsOpeningAnimation: true))' in content
assert 'if !prefPerformLA || accessAuthenticated {' in content
assert '.accessibilityHidden(!appSheetState.scenePhaseActive)' in sheet
assert '.allowsHitTesting(appSheetState.scenePhaseActive)' in sheet
assert 'var showsOpeningAnimation = false' in sheet
assert '.disabled(!contentAuthenticationReady)' in content
for event in ['tor.state', 'chatModel.ctrlInitInProgress', 'chatModel.chatDbStatus']:
    assert '.onChange(of: ' + event + ')' in content

adapters = r'''
import Foundation
@propertyWrapper final class State<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum Phase: Equatable { case active, inactive, background }
final class UIApplication {
    static let shared = UIApplication()
    var applicationState = Phase.active
}
final class AppSheetState {
    static let shared = AppSheetState()
    var scenePhaseActive = true
}
enum TorState { case starting, ready(UInt16) }
final class Tor { var state: TorState = .starting }
var socksReady = false
func isXauXatTorReady() -> Bool { socksReady }
final class Key {
    var value: String?
    func get() -> String? { value }
}
let kcAppPassword = Key()
let kcSelfDestructPassword = Key()
let kcDecoyPassword = Key()
var checks = 0
func expect(_ condition: Bool, _ name: String) {
    precondition(condition, name)
    checks += 1
}
enum DBStatus: Equatable { case ok, error }
enum Onboarding: Equatable { case complete, createProfile }
enum AppState: Equatable { case active, suspended, stopped }
final class AppChatState {
    static let shared = AppChatState()
    var value: AppState = .suspended
}
struct Migration { var startChat = true }
struct NetworkInfo { var online = true }
final class Model {
    var networkInfo = NetworkInfo()
    var migrationState: Int?
    var chatDbStatus: DBStatus?
    var ctrlInitInProgress = false
    var onboardingStage: Onboarding?
    var v3DBMigration = Migration()
    var chatId: String? = "test"
    var contentViewAccessAuthenticated = false
    var chatInitialized = false
    var showCallView = false
    var activeCall: Int?
}
var activeModel: Model?
var initializations = 0
func initChatAndMigrate() {
    precondition(activeModel?.contentViewAccessAuthenticated == true)
    initializations += 1
    activeModel?.chatInitialized = true
}
struct CallController {
    static func useCallKit() -> Bool { true }
}
enum LAResult { case success, failed, unavailable }
enum Mode: Equatable { case system, passcode }
struct ModeDefault { func get() -> Mode { mode } }
var mode: Mode = .system
let privacyLocalAuthModeDefault = ModeDefault()
var result: LAResult?
var requests = 0
func authenticate(reason: String, selfDestruct: Bool, completed: (LAResult) -> Void) {
    precondition(selfDestruct)
    requests += 1
    if let result { completed(result) }
}
func dismissAllSheets(animated: Bool, _ completed: () -> Void) { completed() }
struct Log { func debug(_ text: String) {} }
let logger = Log()
func xauXatRecordStartup(_ event: String, capturedScene: String) {}
final class AlertManager {
    static let shared = AlertManager()
    var alerts: [String] = []
    func showAlert(_ alert: String) { alerts.append(alert) }
}
func laFailedAlert() -> String { "failed" }
func laUnavailableTurningOffAlert() -> String { "unavailable" }
struct Harness {
    let chatModel = Model()
    let tor = Tor()
    @State var scenePhase: Phase = .active
    @State var contentAccessAuthenticationExtended = false
    @State var automaticAuthenticationAttempted = false
    @State var waitingForOrPassedAuth = true
    @State var prefPerformLA = true
    @State var canConnectViewCall = false
    @State var lastSuccessfulUnlock: TimeInterval? = nil
'''
predicate = declaration(content, 'private var showsInitializationView: Bool')
callback = declaration(content, 'private func authenticateContentViewAccess()')
readiness = declaration(content, 'private var contentAuthenticationReady: Bool')
automatic = declaration(content, 'private func authenticateContentWhenReady()')
selection = declaration(auth, 'func xauXatRequiresUnlockBeforeInitialization()')
checks_source = r'''
    func check(_ expected: Bool, _ name: String) {
        expect(showsInitializationView == expected, name)
    }
    func run() {
        activeModel = chatModel
        authenticateContentWhenReady()
        authenticateContentViewAccess()
        expect(requests == 0, "neither automatic nor manual auth before Tor")
        check(true, "cold loading remains visible")
        tor.state = .ready(12345)
        authenticateContentWhenReady()
        expect(requests == 0, "published Tor state alone is insufficient")
        socksReady = true
        authenticateContentWhenReady()
        expect(requests == 0, "normal auth waits for database initialization")
        chatModel.chatDbStatus = .ok
        chatModel.ctrlInitInProgress = true
        authenticateContentWhenReady()
        expect(requests == 0, "no auth while initialization runs")
        check(true, "database open is not content ready")
        chatModel.ctrlInitInProgress = false
        authenticateContentWhenReady()
        expect(requests == 0, "normal auth waits for an initial screen")
        check(true, "missing initial screen stays covered")
        chatModel.onboardingStage = .complete
        socksReady = false
        tor.state = .starting
        expect(contentAuthenticationReady, "prepared local screen stays unlockable offline")
        tor.state = .ready(12345)
        socksReady = true
        result = nil
        authenticateContentWhenReady()
        expect(requests == 1 && automaticAuthenticationAttempted, "Face ID at prepared unlock stage")
        expect(!chatModel.contentViewAccessAuthenticated, "request alone never grants access")
        authenticateContentWhenReady()
        expect(requests == 1, "one automatic request per foreground attempt")
        scenePhase = .inactive
        authenticateContentViewAccess()
        expect(requests == 1, "no nested request during native Face ID inactivity")
        scenePhase = .active
        result = .failed
        authenticateContentViewAccess()
        check(false, "Face ID cancellation restores unlock")
        expect(!chatModel.contentViewAccessAuthenticated, "Face ID failure stays locked")
        let cancelledRequests = requests
        authenticateContentWhenReady()
        expect(requests == cancelledRequests, "cancel does not loop Face ID automatically")
        mode = .passcode
        automaticAuthenticationAttempted = false
        result = nil
        authenticateContentWhenReady()
        expect(requests == cancelledRequests + 1, "PIN uses the same prepared unlock stage")
        result = .failed
        authenticateContentViewAccess()
        expect(AlertManager.shared.alerts == ["failed"], "PIN failure keeps its existing alert")
        result = .success
        authenticateContentViewAccess()
        expect(chatModel.contentViewAccessAuthenticated && lastSuccessfulUnlock != nil, "successful unlock grants access")
        expect(initializations == 0, "prepared normal database is not initialized twice")
        check(false, "ready chats replace opening")
        chatModel.onboardingStage = .createProfile
        check(false, "onboarding is accessible")
        chatModel.chatDbStatus = .error
        chatModel.onboardingStage = nil
        check(false, "database errors are accessible")
        expect(contentAuthenticationReady, "authentication can unlock an error screen")
        chatModel.chatDbStatus = .ok
        chatModel.v3DBMigration.startChat = false
        check(false, "migration is accessible")
        expect(contentAuthenticationReady, "authentication can unlock migration")
        chatModel.v3DBMigration.startChat = true
        AppChatState.shared.value = .stopped
        check(false, "stopped chat is not loading")
        AppChatState.shared.value = .suspended
        chatModel.chatDbStatus = nil
        chatModel.contentViewAccessAuthenticated = false
        kcAppPassword.value = "test-only"
        kcDecoyPassword.value = "test-only-decoy"
        tor.state = .starting
        expect(!contentAuthenticationReady, "cold alternate PIN waits for startup before selecting store")
        tor.state = .ready(12345)
        expect(contentAuthenticationReady, "decoy PIN must precede database selection")
        result = nil
        authenticateContentViewAccess()
        expect(initializations == 0, "a pending PIN does not open a store")
        // The real PIN view initializes the selected primary/decoy store before
        // completing authentication. The callback must preserve that choice.
        chatModel.chatInitialized = true
        result = .success
        authenticateContentViewAccess()
        expect(initializations == 0, "selected PIN store is not reopened or replaced")
        kcDecoyPassword.value = nil
        kcSelfDestructPassword.value = "test-only-duress"
        chatModel.chatInitialized = false
        chatModel.contentViewAccessAuthenticated = false
        result = nil
        authenticateContentViewAccess()
        expect(initializations == 0, "deferred system startup waits for successful auth")
        result = .success
        authenticateContentViewAccess()
        expect(initializations == 1 && chatModel.chatInitialized, "system success releases deferred primary startup")
        kcAppPassword.value = nil
        expect(!xauXatRequiresUnlockBeforeInitialization(), "alternate PIN without app PIN does not defer startup")
        kcSelfDestructPassword.value = nil
        chatModel.chatDbStatus = .ok
        chatModel.onboardingStage = .complete
        chatModel.contentViewAccessAuthenticated = false
        automaticAuthenticationAttempted = false
        chatModel.ctrlInitInProgress = true
        let busyRequests = requests
        authenticateContentWhenReady()
        expect(requests == busyRequests, "restart initialization also delays auth")
        chatModel.ctrlInitInProgress = false
        chatModel.showCallView = true
        chatModel.activeCall = 1
        authenticateContentWhenReady()
        expect(requests == busyRequests, "CallKit view retains authentication exception")
        chatModel.showCallView = false
        AppChatState.shared.value = .stopped
        authenticateContentWhenReady()
        expect(requests == busyRequests, "stopped chat does not prompt automatically")
        AppChatState.shared.value = .suspended
        scenePhase = .background
        authenticateContentWhenReady()
        expect(requests == busyRequests, "background never prompts")
        scenePhase = .active
        contentAccessAuthenticationExtended = true
        authenticateContentWhenReady()
        expect(requests == busyRequests && chatModel.contentViewAccessAuthenticated, "existing unlock grace is preserved")
        result = .unavailable
        authenticateContentViewAccess()
        expect(!prefPerformLA && AlertManager.shared.alerts.last == "unavailable", "existing unavailable fallback is preserved")
    }
}
'''
(temp / 'main.swift').write_text(adapters + predicate + '\n' + readiness + '\n' + automatic + '\n' + callback + '\n' + checks_source + '\n' + selection + '\nHarness().run()\nprint("\(checks) opening/authentication transition checks passed.")\n')
ui = 'import SwiftUI\n' + declaration(sheet, 'class AppSheetState: ObservableObject')
ui += '''
@MainActor final class EmbeddedTorManager: ObservableObject {
    static let shared = EmbeddedTorManager()
    @Published var refreshingConnection = false
}
struct NetworkInfo { var online = true }
@MainActor final class ChatModel: ObservableObject {
    static let shared = ChatModel()
    @Published var networkInfo = NetworkInfo()
}
func isXauXatTorReady() -> Bool { false }
'''
ui += '\n' + declaration(sheet, 'struct XauXatAppSwitcherProtection: ViewModifier')
ui += '\n' + declaration(content, 'struct XauXatOpeningView: View')
ui += '''
struct OpeningUsage: View {
    var body: some View {
        Text("Private test content")
            .modifier(XauXatAppSwitcherProtection())
            .modifier(XauXatAppSwitcherProtection(showsOpeningAnimation: true))
    }
}
'''
(temp / 'OpeningViews.swift').write_text(ui)

# Execute the actual visibility gate and post-refresh initialization, including
# the alternate-PIN boundary. The action must also work after startup timed out.
refresh_gate = declaration(content, 'private var canRefreshConnection: Bool').replace('private ', '', 1)
initializer = declaration(app, 'private func initializeAfterTor()').replace('private ', '', 1)
(temp / 'Refresh.swift').write_text(adapters[:adapters.index('struct Harness {')] + selection + '\n' + declaration(suspend, 'func xauXatAppIsForeground()') + '''
final class RefreshHarness {
    var showsProgress = true
    var refreshConnection: (() -> Void)? = {}
    var scenePhase: Phase = .active
    let chatModel = Model()
''' + refresh_gate + '\n' + initializer + '''
    func run() {
        socksReady = false
        expect(canRefreshConnection, "a stalled online launch can offer refresh")
        showsProgress = false
        expect(!canRefreshConnection, "privacy and lock opening views never offer refresh")
        showsProgress = true
        refreshConnection = nil
        expect(!canRefreshConnection, "an opening view without a recovery action cannot offer refresh")
        refreshConnection = {}
        scenePhase = .background
        expect(!canRefreshConnection, "background cannot offer refresh")
        scenePhase = .inactive
        expect(!canRefreshConnection, "inactive app cannot offer refresh")
        scenePhase = .active
        chatModel.networkInfo.online = false
        expect(!canRefreshConnection, "offline app cannot offer refresh")
        chatModel.networkInfo.online = true
        socksReady = true
        expect(!canRefreshConnection, "database loading after Tor readiness cannot offer Tor refresh")
        activeModel = chatModel
        chatModel.contentViewAccessAuthenticated = true
        kcAppPassword.value = "test-only"
        kcDecoyPassword.value = "test-only-decoy"
        initializeAfterTor()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(initializations == 0, "refresh cannot select a store before the alternate PIN")
        kcDecoyPassword.value = nil
        // Startup callbacks captured an inactive App value. The live UIKit
        // state must let the initial screen open once the process is active.
        scenePhase = .inactive
        initializeAfterTor()
        initializeAfterTor()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(initializations == 1, "startup and refresh completions initialize exactly once")
        chatModel.chatInitialized = false
        initializeAfterTor()
        kcDecoyPassword.value = "test-only-decoy"
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(initializations == 1, "deferred initialization rechecks the selected-store boundary")
        kcDecoyPassword.value = nil
        initializeAfterTor()
        socksReady = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(initializations == 1, "readiness lost during the delay cannot initialize the core")
        socksReady = true
        initializeAfterTor()
        scenePhase = .active // The captured view can still say active after backgrounding.
        UIApplication.shared.applicationState = .background
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(initializations == 1, "backgrounding during refresh cannot open a store")
    }
}
@main struct RefreshChecks {
    static func main() {
        RefreshHarness().run()
        print("\\(checks) connection refresh presentation/startup checks passed.")
    }
}
''')
PY

swiftc "$temp/main.swift" -o "$temp/opening-tests"
"$temp/opening-tests"
swiftc -parse-as-library "$temp/Refresh.swift" -o "$temp/refresh-tests"
"$temp/refresh-tests"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 5 -typecheck -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
  "$temp/OpeningViews.swift"
echo 'Actual opening/privacy views type-checked for iOS 15; private content remains hidden while inactive.'
