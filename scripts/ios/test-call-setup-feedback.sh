#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
out=${CALL_SETUP_OUTPUT:-"$temp/proof"}
mkdir -p "$out"
python3 - "$root" "$temp/main.swift" <<'PY'
from pathlib import Path
import sys
root, output = Path(sys.argv[1]), Path(sys.argv[2])
model = (root/'apps/ios/Shared/Views/Call/WebRTC.swift').read_text(encoding='utf-8')
model = model.split('class Call: ObservableObject, Equatable {', 1)[1].split('\nstruct WVAPICall:', 1)[0]
view = (root/'apps/ios/Shared/Views/Call/ActiveCallView.swift').read_text(encoding='utf-8')
view = view.split('struct XauXatCallSetupStatusView: View {', 1)[1].split('\nprivate struct XauXatRealtimeVoiceMaskingView:', 1)[0]
output.write_text('''import Foundation
import SwiftUI
import AVFoundation
import AppKit

// Only external model boundaries are adapted; Call, its state observer,
// timeline and the feedback view below are extracted unchanged from the app.
struct Contact { let apiId: Int64 }
enum CallMediaType { case audio, video }
struct CallCapabilities { let encryption: Bool }
struct ConnectionInfo { var text: LocalizedStringKey { "relay" } }
struct CallMediaSources {
    var mic = false
    var camera = false
    var hasVideo: Bool { camera }
}
class Call: ObservableObject, Equatable {''' + model + '\nstruct XauXatCallSetupStatusView: View {' + view + '''

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
var now: TimeInterval = 100
let outgoing = XauXatCallSetupTimeline(direction: .outgoing, state: .waitCapabilities, clock: { now })
now += 90
outgoing.record(.invitationSent)
expect(outgoing.elapsedSeconds == 0, "Ringing must not count as connection delay")
outgoing.record(.offerReceived)
now += 9
expect(outgoing.elapsedSeconds == 9, "Start at the actual offer, not the original dial time")
outgoing.record(.negotiated)
now += 6
expect(outgoing.elapsedSeconds == 15, "Changing stages must retain total elapsed time")
outgoing.record(.connected)
now += 60
outgoing.record(.connected)
expect(outgoing.elapsedSeconds == 15, "Connected duration must not inflate setup time")
outgoing.record(.ended)
expect(outgoing.elapsedSeconds == 15, "Ending must preserve the measured connection time")
expect(outgoing.diagnosticText.components(separatedBy: " connected").count == 2, "Ignore duplicate callbacks")

let incoming = XauXatCallSetupTimeline(direction: .incoming, state: .invitationAccepted, clock: { now })
now += 15
incoming.record(.offerSent)
expect(incoming.elapsedSeconds == 15, "Incoming preparation starts when the user accepts")
expect(XauXatCallSetupTimeline.latestDiagnosticText.contains("direction=incoming"), "Export only the latest call")
outgoing.record(.answerReceived)
expect(XauXatCallSetupTimeline.latestDiagnosticText.contains("direction=incoming"), "A stale old call cannot replace the new diagnostic")
for _ in 0..<40 { incoming.record(.offerSent); incoming.record(.answerReceived) }
expect(incoming.diagnosticText.split(separator: "\\n").count == 26, "Bound the timeline to 24 events plus header")
expect(!incoming.diagnosticText.contains("@") && !incoming.diagnosticText.contains("127.0.0.1"), "Export coarse states only")
expect(!CallState.invitationSent.isEstablishing && !CallState.connected.isEstablishing && !CallState.ended.isEstablishing, "No connection warning while ringing, connected or ended")

let call = Call(direction: .incoming, contact: Contact(apiId: 987654321), callUUID: "private-test-call-id", callState: .invitationAccepted, initialCallType: .audio)
call.callState = .offerSent
expect(call.setupTimeline.diagnosticText.contains("offerSent"), "Exercise the actual Call state observer")
expect(!XauXatCallSetupTimeline.latestDiagnosticText.contains("987654321") && !XauXatCallSetupTimeline.latestDiagnosticText.contains("private-test-call-id"), "No contact/call identifiers in copied diagnostics")

@MainActor func render(_ call: Call, _ name: String, _ size: DynamicTypeSize = .large) {
    let content = XauXatCallSetupStatusView(call: call)
        .environment(\\.dynamicTypeSize, size)
        .foregroundColor(.white).font(.subheadline).padding(24)
        .frame(width: 390, height: 330).background(.black)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Feedback rendering failed") }
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
}
MainActor.assumeIsolated { render(call, "connecting") }
Thread.sleep(forTimeInterval: 15)
expect(call.setupTimeline.elapsedSeconds >= 15, "Elapsed time survives view recreation")
MainActor.assumeIsolated {
    render(call, "delayed")
    render(call, "delayed-large-text", .accessibility3)
    call.callState = .connected
    render(call, "connected")
}
print("Call setup timing, state integration, privacy and four feedback renders passed")
''', encoding='utf-8')
PY
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" "$temp/main.swift" -o "$temp/feedback"
"$temp/feedback" "$out"
plutil -lint "$root/apps/ios/en.lproj/Localizable.strings" "$root/apps/ios/pt.lproj/Localizable.strings"
