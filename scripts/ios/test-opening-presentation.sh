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
final class Model {
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
PY

swiftc "$temp/main.swift" -o "$temp/opening-tests"
"$temp/opening-tests"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 5 -typecheck -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
  "$temp/OpeningViews.swift"
echo 'Actual opening/privacy views type-checked for iOS 15; private content remains hidden while inactive.'
