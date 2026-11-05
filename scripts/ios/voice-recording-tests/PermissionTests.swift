import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main @MainActor struct PermissionTests {
    static func main() async {
        var checks = 0
        var failures = 0
        func expect(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + name) }
        }
        // Real touch/composer handlers cancel the intent while the real start
        // method is suspended at the controlled AV permission boundary.
        for cancelled in [false, true] {
            let probe = Probe()
            let view = TouchView()
            view.actions = Actions(touchDown: { probe.begin() },
                release: { probe.releaseVoiceMessageRecording($0) },
                cancel: { probe.cancelVoiceMessageTouch($0) })
            view.touchesBegan([UITouch(10)], with: nil)
            let request = probe.voiceInteraction.requestID!
            let recorder = PermissionRecorder()
            let task = Task { await recorder.start(fileName: "old.m4a", shouldStart: {
                probe.voiceInteraction.requestID == request && probe.voiceInteraction.active
            }) }
            await recorder.waitForPermissionRequest()
            if cancelled { view.touchesCancelled([UITouch(10.2)], with: nil) }
            else { view.touchesEnded([UITouch(10.2)], with: nil) }
            expect(probe.outcome == "discard", "Pending \(cancelled ? "CANCELLED" : "ENDED") clears intent")
            recorder.grant(true)
            let result = await task.value
            expect(result == .cancelled, "A late grant cannot revive a released or cancelled intent")
            expect(recorder.segmentStarts == 0 && recorder.recordingFileName == nil, "No audio or file after late grant")
            let next = probe.voiceInteraction.begin(locked: true)!
            let newRecorder = PermissionRecorder()
            let recovery = Task { await newRecorder.start(fileName: "new.m4a", shouldStart: {
                probe.voiceInteraction.requestID == next && probe.voiceInteraction.active
            }) }
            await newRecorder.waitForPermissionRequest()
            newRecorder.grant(true)
            let recovered = await recovery.value
            expect(recovered == nil && newRecorder.segmentStarts == 1, "A new explicit intent can record")
            expect(newRecorder.recordingFileName == "new.m4a" && recorder.segmentStarts == 0,
                   "Recovery starts only the new filename")
        }
        do {
            let interaction = Probe()
            interaction.begin()
            let old = interaction.voiceInteraction.requestID!
            let recorder = PermissionRecorder()
            let task = Task { await recorder.start(fileName: "replaced.m4a", shouldStart: {
                interaction.voiceInteraction.requestID == old && interaction.voiceInteraction.active
            }) }
            await recorder.waitForPermissionRequest()
            interaction.voiceInteraction.reset()
            interaction.begin()
            recorder.grant(true)
            let result = await task.value
            expect(result == .cancelled && recorder.segmentStarts == 0,
                   "A replaced request cannot start after its late grant")
        }
        for stopRecorder in [false, true] {
            let recorder = PermissionRecorder()
            let task = Task { await recorder.start(fileName: "stopped.m4a") }
            await recorder.waitForPermissionRequest()
            if stopRecorder { recorder.stop() } else { task.cancel() }
            recorder.grant(true)
            let result = await task.value
            expect(result == .cancelled && recorder.segmentStarts == 0,
                   "\(stopRecorder ? "Stopped recorder" : "Cancelled task") cannot capture after grant")
        }
        for allowed in [false, true] {
            let recorder = PermissionRecorder()
            let task = Task { await recorder.start(fileName: "active.m4a") }
            await recorder.waitForPermissionRequest()
            recorder.grant(allowed)
            let result = await task.value
            expect(allowed ? result == nil : result == .permission, "Active permission result is preserved")
            expect(recorder.segmentStarts == (allowed ? 1 : 0), "Only an allowed active intent captures")
        }
        print("Permission continuation regression: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
