#!/usr/bin/env python3
"""Exercise the internal call view's real SwiftUI lifecycle in an invisible macOS window."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2] / "apps/ios/Shared"
content = (root / "ContentView.swift").read_text()
active = (root / "Views/Call/ActiveCallView.swift").read_text()

def region(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]

host_body = region(content, "            if chatModel.showCallView, let call = chatModel.activeCall", "\n\n")
internal_view = region(content, "            ActiveCallView(call: call, canConnectCall: $canConnectViewCall)", "            if prefPerformLA")
appear = region(active, "\n        .onAppear {", "        .onChange(of: m.activeCallViewIsCollapsed)")
disappear = region(active, "\n        .onDisappear {", "        .background(m.activeCallViewIsCollapsed")
hooks = "\n".join(line for line in (appear + disappear).splitlines()
                  if "logger.debug(" not in line)

source = r"""
import AppKit
import SwiftUI

final class Call: ObservableObject {
    var hasClient = false
    var permissions = 0
    func attachWebRTC() { hasClient = true }
}
final class Model: ObservableObject {
    @Published var showCallView = false
    @Published var activeCall: Call?
    @Published var authorized = true
}
enum AppDelegate {
    static var keepOn = false
    static func keepScreenOn(_ on: Bool) { keepOn = on }
}
struct ActiveCallView: View {
    @EnvironmentObject var m: Model
    @ObservedObject var call: Call
    @Binding var canConnectCall: Bool
    @State var prevColorScheme: ColorScheme = .dark
    @Environment(\.colorScheme) var colorScheme
    func askRequiredPermissions() async { call.permissions += 1 }
    func dismissAllSheets() {}
    func hideKeyboard() {}
    var body: some View {
        Text("Local call fixture")
        HOOKS
    }
}
struct Host: View {
    @ObservedObject var chatModel: Model
    @Binding var canConnectViewCall: Bool
    init(chatModel: Model) {
        self.chatModel = chatModel
        _canConnectViewCall = Binding(get: { chatModel.authorized }, set: { chatModel.authorized = $0 })
    }
    var body: some View {
        ZStack {
            HOST
        }
    }
    @ViewBuilder func callView(_ call: Call) -> some View {
        INTERNAL
    }
}
@MainActor func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.22))
}
func check(_ value: Bool, _ requirement: String) {
    guard value else { print("FAIL: " + requirement); exit(1) }
}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let model = Model()
let host = NSHostingView(rootView: Host(chatModel: model).environmentObject(model))
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                      styleMask: .borderless, backing: .buffered, defer: false)
window.alphaValue = 0
window.contentView = host
window.orderBack(nil)
let first = Call()
model.activeCall = first
model.showCallView = true
settle()
check(first.hasClient && first.permissions == 1, "first authorized call appears and attaches")
let second = Call()
model.showCallView = false
model.activeCall = nil
model.activeCall = second
model.showCallView = true
settle()
check(second.hasClient && second.permissions == 1, "replacement call must mount and attach its own client")
check(AppDelegate.keepOn, "screen remains awake for replacement call")
let locked = Call()
model.authorized = false
model.activeCall = locked
settle()
check(!locked.hasClient, "replacement cannot connect while authorization is closed")
model.authorized = true
settle()
check(locked.hasClient, "unlock attaches the current client")
model.showCallView = false
settle()
check(!AppDelegate.keepOn, "ending the last call releases screen wake")
print("PASS: consecutive internal calls, screen wake and PIN-gated WebRTC attachment.")
}
"""
source = source.replace("HOOKS", hooks).replace("HOST", host_body).replace("INTERNAL", internal_view)
with tempfile.TemporaryDirectory() as d:
    directory = Path(d)
    main = directory / "main.swift"
    main.write_text(source)
    executable = directory / "CallViewIdentity"
    module_cache = os.environ.get("CLANG_MODULE_CACHE_PATH", str(directory / "modules"))
    subprocess.run(["swiftc", "-module-cache-path", module_cache, str(main), "-o", str(executable)], check=True)
    raise SystemExit(subprocess.run([str(executable)], timeout=30).returncode)
