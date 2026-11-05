import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main struct TouchCancellationTests {
    static func main() {
        var checks = 0
        var failures = 0
        func expect(_ value: Bool, _ name: String) {
            checks += 1
            if !value {
                failures += 1
                print("FAIL: " + name)
            }
        }
        func run(_ cancelled: Bool, down: TimeInterval = 2244.232948624,
                 up: TimeInterval = 2244.299615290, ready: TimeInterval? = 2246.498170570,
                 locked: Bool = false, missing: Bool = false) -> String {
            let probe = Probe()
            probe.locked = locked
            let view = TouchView()
            view.actions = Actions(touchDown: { probe.begin() },
                                   release: { probe.releaseVoiceMessageRecording($0) },
                                   cancel: { probe.cancelVoiceMessageTouch($0) })
            view.touchesBegan([UITouch(down)], with: nil)
            if let ready {
                _ = probe.voiceInteraction.started(probe.voiceInteraction.requestID!, at: ready)
            }
            let end: Set<UITouch> = missing ? [] : [UITouch(up)]
            if cancelled {
                view.touchesCancelled(end, with: nil)
            } else {
                view.touchesEnded(end, with: nil)
            }
            return probe.outcome
        }
        expect(run(false) == "discard", "Observed 66.7ms ENDED discards late-ready audio")
        expect(run(true) == "discard", "The same physical interval with CANCELLED must also discard")
        expect(run(true, down: 10, up: 10.067, ready: 10.01) == "discard",
               "An early-ready cancelled tap cannot retain audio recorded after the physical event")
        expect(run(false, down: 10, up: 15, ready: 15.1) == "discard",
               "ENDED discards capture only ready after physical release")
        expect(run(true, down: 10, up: 15, ready: 15.1) == "discard",
               "CANCELLED cannot bypass the physical readiness check")
        expect(run(true, down: 10, up: 15, ready: 14.98) == "discard",
               "Cancellation cannot inflate twenty milliseconds of useful capture")
        expect(run(true, down: 10, up: 15, ready: 13.647) == "finish",
               "A confirmed held recording survives system interruption")
        expect(run(false, down: 10, up: 15, ready: 13.647) == "finish",
               "A normal confirmed held recording still previews")
        expect(run(true, ready: nil) == "discard", "Cancellation during pending permission discards")
        expect(run(true, locked: true) == "finish", "Explicit hands-free intent keeps interruption behavior")
        expect(run(true, ready: nil, locked: true) == "discard",
               "An unready locked interruption retains the existing discard behavior")
        expect(run(true, missing: true) == "discard", "Missing cancellation timing fails closed while holding")
        print("Touch cancellation regression: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
