"""Exercise the real UIKit touch and composer handlers without an iOS runtime."""
from pathlib import Path
import sys
import textwrap

root = Path(sys.argv[1])
out = Path(sys.argv[2])
compose = root / "apps/ios/Shared/Views/Chat/ComposeMessage"
controls = (compose / "VoiceRecordingControls.swift").read_text(encoding="utf-8")
controller = (compose / "ComposeView.swift").read_text(encoding="utf-8")
audio = (root / "apps/ios/Shared/Model/AudioRecPlay.swift").read_text(encoding="utf-8")


def declaration(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    # Include any default-argument closure in the marker so its opening brace
    # cannot be mistaken for the function body.
    brace = source.index("{", start + len(marker))
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError("Unclosed production handler: " + marker)


touch_handlers = "\n".join(declaration(controls, "override func " + name + "(")
                           for name in ("touchesBegan", "touchesEnded", "touchesCancelled"))
compose_handlers = "\n".join(declaration(controller, "private func " + name + "(")
                             .replace("private func", "func", 1)
                             for name in ("releaseVoiceMessageRecording", "cancelVoiceMessageTouch"))
source = """
import Foundation

// These adapters provide event data, not decisions. All five handlers below
// come from production; the finish/discard counters expose their routing.
class UIView {
    var window: UIView?
    func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}
class UIEvent {}
final class UITouch: Hashable {
    let timestamp: TimeInterval
    init(_ timestamp: TimeInterval) { self.timestamp = timestamp }
    func location(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: 0) }
    static func == (a: UITouch, b: UITouch) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
struct Actions {
    let enabled = true
    let touchDown: () -> Void
    let release: (VoiceRecordingTouchTiming) -> Void
    let cancel: (VoiceRecordingTouchTiming) -> Void
}
final class TouchView: UIView {
    var actions: Actions?
    private var origin: CGPoint?
    private var beganAt: TimeInterval?
"""
source += textwrap.indent(touch_handlers, "    ") + "\n}\n"
source += """
final class Probe {
    var voiceInteraction = VoiceRecordingInteraction()
    var voiceSendOnFinish = false
    var outcome = "none"
    var locked = false
    func begin() { _ = voiceInteraction.begin(locked: locked) }
    func finishVoiceMessageRecording() {
        // Model the real finish handler's guard for pending preparation.
        guard voiceInteraction.ready else {
            if voiceInteraction.active { discardVoiceMessageRecording() }
            return
        }
        outcome = "finish"
        voiceInteraction.finish()
    }
    func discardVoiceMessageRecording() {
        outcome = "discard"
        voiceInteraction.reset()
    }
"""
source += textwrap.indent(compose_handlers, "    ") + "\n}\n"
source += """
// Only the AV permission boundary and capture side effects are adapters. The
// asynchronous start method, including all post-await guards, is production.
struct PermissionTestLogger { func error(_ message: String) {} }
private let logger = PermissionTestLogger()
@MainActor final class PermissionRecorder {
    enum StartError: Equatable { case permission, error(String), cancelled }
    var cancelled = false
    var recordingFileName: String?
    var segmentStarts = 0
    private var permission: CheckedContinuation<Bool, Never>?
    private var requested = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    func checkPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            permission = continuation
            requested = true
            let waiting = observers
            observers.removeAll()
            waiting.forEach { $0.resume() }
        }
    }
    func waitForPermissionRequest() async {
        if requested { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func grant(_ allowed: Bool) { permission!.resume(returning: allowed); permission = nil }
    func startSegment(_ name: String) throws { segmentStarts += 1 }
    func stop() { cancelled = true }
"""
source += textwrap.indent(declaration(audio,
    "func start(fileName: String, shouldStart: () -> Bool = { true }) async -> StartError?"), "    ") + "\n}\n"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(source, encoding="utf-8")
