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

adapters = r'''
import Foundation
@propertyWrapper final class State<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
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
}
enum LAResult { case success, failed, unavailable }
enum Mode: Equatable { case system, passcode }
struct ModeDefault { func get() -> Mode { mode } }
var mode: Mode = .system
let privacyLocalAuthModeDefault = ModeDefault()
var result: LAResult?
func authenticate(reason: String, selfDestruct: Bool, completed: (LAResult) -> Void) {
    precondition(selfDestruct)
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
    @State var waitingForOrPassedAuth = true
    @State var prefPerformLA = true
    @State var canConnectViewCall = false
    @State var lastSuccessfulUnlock: TimeInterval? = nil
'''
predicate = declaration(content, 'private var showsInitializationView: Bool')
callback = declaration(content, 'private func authenticateContentViewAccess()')
checks = r'''
    func check(_ expected: Bool, _ name: String) {
        precondition(showsInitializationView == expected, name)
    }
    func run() {
        result = nil
        authenticateContentViewAccess()
        check(true, "cold Face ID request keeps opening visible")
        precondition(!chatModel.contentViewAccessAuthenticated)
        result = .success
        authenticateContentViewAccess()
        check(true, "Face ID success while database pending")
        precondition(chatModel.contentViewAccessAuthenticated)
        precondition(lastSuccessfulUnlock != nil)
        chatModel.chatDbStatus = .ok
        chatModel.ctrlInitInProgress = true
        check(true, "database opened but initialization still running")
        chatModel.ctrlInitInProgress = false
        check(true, "database ready but no initial content yet")
        chatModel.onboardingStage = .complete
        check(false, "ready chats replace opening")
        chatModel.onboardingStage = .createProfile
        check(false, "onboarding must remain accessible")
        chatModel.chatDbStatus = .error
        check(false, "database error must remain accessible")
        chatModel.chatDbStatus = .ok
        chatModel.onboardingStage = nil
        chatModel.v3DBMigration.startChat = false
        check(false, "migration must remain accessible")
        chatModel.v3DBMigration.startChat = true
        AppChatState.shared.value = .stopped
        check(false, "explicitly stopped chat is not loading")
        AppChatState.shared.value = .suspended
        chatModel.chatDbStatus = nil
        result = .failed
        authenticateContentViewAccess()
        check(false, "cancelled Face ID restores unlock instead of infinite loading")
        precondition(!chatModel.contentViewAccessAuthenticated)
        precondition(AlertManager.shared.alerts.isEmpty)
        mode = .passcode
        authenticateContentViewAccess()
        check(false, "PIN failure also restores unlock")
        precondition(AlertManager.shared.alerts == ["failed"])
        result = .success
        authenticateContentViewAccess()
        check(true, "retry resumes pending opening")
        result = .unavailable
        authenticateContentViewAccess()
        check(true, "unavailable authentication preserves existing fallback")
        precondition(!prefPerformLA)
        precondition(AlertManager.shared.alerts.last == "unavailable")
    }
}
Harness().run()
print("13 opening/authentication transition checks passed.")
'''
(temp / 'main.swift').write_text(adapters + predicate + '\n' + callback + '\n' + checks)
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
