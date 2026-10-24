#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

# Exercise the actual onboarding actions and shared permission API. Only iOS
# permission prompts, APNs registration and persistence are replaced by adapters.
python3 - "$root" "$temp" <<'PY'
from pathlib import Path
import sys

root, temp = map(Path, sys.argv[1:])
home = (root / 'apps/ios/Shared/Views/XauXatHomeView.swift').read_text()
api = (root / 'apps/ios/Shared/Model/SimpleXAPI.swift').read_text()

def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

welcome = declaration(home, 'struct XauXatWelcomeView: View')
assert '@State private var notificationMode: NotificationsMode?' in welcome
assert 'ForEach(0..<4' in welcome and 'of 4' in welcome
assert 'notificationsStep(geometry)' in welcome
assert 'action: advanceToNotifications' in welcome
assert 'enabled: notificationMode != nil && !isCompleting' in welcome
assert 'guard validName, validPIN, notificationMode != nil, !isCompleting' in welcome
assert '.sheet(item: $proposedNotificationMode)' in welcome
assert 'onCancel: { proposedNotificationMode = nil }' in welcome
assert 'onEnable: { acceptNotificationMode(candidate) }' in welcome
assert 'XauXatNotificationPrivacyNotice(' in welcome
assert 'applyDefaultNotificationMode' not in welcome
notice = declaration(home, 'private struct XauXatNotificationPrivacyNotice: View')
assert notice.index('onEnable()') < notice.index('dismiss()'), 'Accept before sheet dismissal can clear its pending mode'
finish = declaration(welcome, 'private func finishOnboarding()')
assert finish.index('kcAppPassword.set(pin)') < finish.index('applySimpleXOnboardingDefaults()')
defaults = declaration(welcome, 'private func applySimpleXOnboardingDefaults()')
assert defaults.index('try await acceptConditions(') < defaults.index('applySelectedNotificationMode {')
assert defaults.index('applySelectedNotificationMode {') < defaults.index('onboardingStageDefault.set(.onboardingComplete)')

adapters = r'''
import Foundation

@propertyWrapper final class State<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum NotificationsMode: Equatable { case off, instant, periodic }
final class ChatModel {
    static let shared = ChatModel()
    var notificationMode: NotificationsMode = .off
    var notificationRegistrationError: String?
    var deviceToken: String? = "synthetic-token"
}
final class UIApplication {
    static let shared = UIApplication()
    var registrations = 0
    func registerForRemoteNotifications() { registrations += 1 }
}
final class NtfManager {
    static let shared = NtfManager()
    var requests = 0
    var allowed: (() -> Void)?
    var denied: (() -> Void)?
    func requestAuthorization(onDeny: @escaping () -> Void, onAuthorized: @escaping () -> Void) {
        requests += 1
        denied = onDeny
        allowed = onAuthorized
    }
}
var xauXatNotificationServerConfigured = true
var persistedIntent: NotificationsMode = .off
var reconciliations = 0
func xauXatSetNotificationModeIntent(_ mode: NotificationsMode) { persistedIntent = mode }
func reconcileXauXatNotificationRegistration(token: String?) { reconciliations += 1 }
var checks = 0
func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    checks += 1
}
func reset() {
    ChatModel.shared.notificationMode = .off
    UIApplication.shared.registrations = 0
    NtfManager.shared.requests = 0
    NtfManager.shared.allowed = nil
    NtfManager.shared.denied = nil
    persistedIntent = .off
    reconciliations = 0
}
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
@MainActor struct Harness {
    @State var notificationMode: NotificationsMode? = nil
    @State var proposedNotificationMode: NotificationsMode? = nil
    @State var isCompleting = false
    @State var focusedField: String? = "pin"
    @State var step = 2
    var validName = true
    var validPIN = true
'''
actions = '\n'.join(declaration(welcome, marker).replace('private func ', 'func ', 1) for marker in (
    'private func advanceToNotifications()',
    'private func selectNotificationMode(',
    'private func acceptNotificationMode(',
    'private func applySelectedNotificationMode(',
))
shared = '@MainActor\n' + declaration(api, 'func xauXatApplyNotificationMode(')
tests = r'''
}
@main struct Runner {
    @MainActor static func main() async {
        let h = Harness()
        expect(h.notificationMode == nil, "No onboarding mode is preselected")
        var completions = 0
        h.applySelectedNotificationMode { completions += 1 }
        expect(completions == 0 && NtfManager.shared.requests == 0, "A missing choice cannot complete or prompt")
        var invalid = Harness()
        invalid.validPIN = false
        invalid.advanceToNotifications()
        expect(invalid.step == 2, "Invalid PIN cannot reach notification selection")
        h.advanceToNotifications()
        expect(h.step == 3 && h.focusedField == nil, "PIN advances to the fourth step and dismisses its keyboard")
        expect(NtfManager.shared.requests == 0, "Entering the step does not request permission")

        h.selectNotificationMode(.instant)
        expect(h.proposedNotificationMode == .instant && h.notificationMode == nil, "Instant opens the notice without selecting")
        expect(NtfManager.shared.requests == 0 && UIApplication.shared.registrations == 0, "Selecting before consent cannot contact iOS or APNs")
        h.proposedNotificationMode = nil // The shared notice's actual cancel/swipe binding.
        h.acceptNotificationMode(.instant)
        expect(h.notificationMode == nil, "Cancelled or stale notice acceptance cannot enable a mode")
        h.selectNotificationMode(.off)
        expect(h.notificationMode == .off && h.proposedNotificationMode == nil, "Off needs no notice")
        h.applySelectedNotificationMode { completions += 1 }
        expect(completions == 1 && persistedIntent == .off, "Off completes and persists")
        expect(NtfManager.shared.requests == 0 && UIApplication.shared.registrations == 0, "Off never requests permission or an APNs token")

        reset()
        h.selectNotificationMode(.instant)
        h.proposedNotificationMode = nil
        expect(h.notificationMode == .off, "Cancelling a new mode retains the previous Off choice")
        h.selectNotificationMode(.instant)
        h.acceptNotificationMode(.instant)
        expect(h.notificationMode == .instant && h.proposedNotificationMode == nil, "Notice acceptance records the chosen mode")
        expect(NtfManager.shared.requests == 0 && persistedIntent == .off, "Accepted choice stays local until setup finishes")
        completions = 0
        h.applySelectedNotificationMode { completions += 1 }
        expect(NtfManager.shared.requests == 1 && completions == 0, "Finishing waits for iOS permission")
        expect(UIApplication.shared.registrations == 0 && persistedIntent == .off, "Pending permission does not register or persist Instant")
        NtfManager.shared.allowed?()
        await drainMainQueue()
        expect(completions == 1 && persistedIntent == .instant, "Authorized Instant finishes once with the selected intent")
        expect(UIApplication.shared.registrations == 1 && reconciliations == 1, "Authorized mode uses the existing registration reconciler")

        reset()
        let denied = Harness()
        denied.selectNotificationMode(.periodic)
        denied.acceptNotificationMode(.periodic)
        completions = 0
        denied.applySelectedNotificationMode { completions += 1 }
        NtfManager.shared.denied?()
        await drainMainQueue()
        expect(denied.notificationMode == .off && persistedIntent == .off, "Denied permission falls back to Off")
        expect(completions == 1 && NtfManager.shared.requests == 1, "Denied permission completes setup without another prompt")
        expect(UIApplication.shared.registrations == 0 && ChatModel.shared.notificationMode == .off, "Denied permission never registers an APNs token")

        reset()
        let periodic = Harness()
        periodic.selectNotificationMode(.periodic)
        periodic.acceptNotificationMode(.periodic)
        periodic.applySelectedNotificationMode { completions += 1 }
        NtfManager.shared.allowed?()
        await drainMainQueue()
        expect(persistedIntent == .periodic, "Periodic remains Periodic after finishing")
        periodic.isCompleting = true
        periodic.selectNotificationMode(.instant)
        expect(periodic.proposedNotificationMode == nil, "A finishing setup cannot change its choice")

        reset()
        xauXatNotificationServerConfigured = false
        let unconfigured = Harness()
        unconfigured.selectNotificationMode(.instant)
        expect(unconfigured.notificationMode == nil && unconfigured.proposedNotificationMode == nil, "Unconfigured builds cannot select push modes")
        unconfigured.selectNotificationMode(.off)
        unconfigured.applySelectedNotificationMode { completions += 1 }
        expect(unconfigured.notificationMode == .off && NtfManager.shared.requests == 0, "Unconfigured builds can finish with Off")
        print("\(checks) production onboarding notification consent checks passed.")
    }
}
'''
(temp / 'main.swift').write_text(adapters + actions + tests + '\n' + shared)
print('Onboarding wiring: four steps, mandatory choice, shared notice, permission after profile/PIN/conditions.')
PY

swiftc -swift-version 5 -parse-as-library "$temp/main.swift" -o "$temp/onboarding-notification-tests"
"$temp/onboarding-notification-tests"
