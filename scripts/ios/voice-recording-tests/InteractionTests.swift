import Foundation

@main struct InteractionTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ name: String) {
            precondition(value, name)
            checks += 1
        }
        var recording = VoiceRecordingInteraction()
        let first = recording.begin()!
        expect(recording.begin() == nil, "A second finger cannot start a second recorder")
        expect(recording.release() == .cancel, "Release during permission wait cancels")
        recording.reset()
        expect(!recording.started(first), "Late permission cannot start a cancelled request")
        let second = recording.begin()!
        expect(!recording.started(first), "Old request cannot replace a new recording")
        expect(recording.started(second), "Current request can start")
        expect(recording.release() == .finish, "Release always stops a ready recording")
        recording.finish()
        expect(!recording.active && recording.phase == .preview, "Release leaves a preview")
        expect(!recording.started(second), "Late callbacks cannot reopen a preview")
        recording.resume()
        expect(recording.active && recording.ready && recording.phase == .locked, "Resume is hands-free")
        expect(recording.release() == .none, "Lifting after locking does not stop")
        expect(recording.move(x: -200, y: 0) == .none, "Locked recordings ignore the old drag")
        recording.prepareToFinish()
        expect(recording.active && !recording.ready, "Finalization keeps the composer busy without recording")
        expect(recording.release() == .none && recording.begin() == nil, "Finalization cannot start a second capture")
        recording.finishFailed()
        expect(recording.phase == .locked, "A failed join can be retried or deleted")
        recording.reset()
        _ = recording.begin()
        expect(recording.move(x: -44, y: 0) == .none && recording.cancelProgress == 0.5, "Cancel hint follows finger")
        expect(recording.move(x: 0, y: 0) == .none && recording.cancelProgress == 0, "Drag can return before cancelling")
        expect(recording.move(x: -89, y: 0) == .cancel, "Left drag cancels")
        recording.reset()
        _ = recording.begin()
        expect(recording.move(x: 0, y: -77) == .lock, "Up drag locks")
        expect(recording.release() == .none, "Lock also survives release while permission is pending")
        recording.reset()
        _ = recording.begin()
        expect(recording.move(x: -176, y: -80) == .cancel, "Dominant diagonal chooses cancel")
        recording.reset()
        _ = recording.begin(locked: true)
        expect(recording.phase == .locked && recording.release() == .none, "VoiceOver activation records hands-free")
        recording.reset()
        expect(!recording.active && recording.requestID == nil, "Leaving resets all recording ownership")

        func timedRelease(down: TimeInterval, up: TimeInterval, ready: TimeInterval) -> VoiceRecordingInteraction.Action {
            var interaction = VoiceRecordingInteraction()
            let request = interaction.begin()!
            expect(interaction.started(request, at: ready), "The current microphone request becomes ready")
            return interaction.release(touch: VoiceRecordingTouchTiming(beganAt: down, endedAt: up))
        }
        // Observed on iOS: this 66.7ms tap was delivered after synchronous audio
        // preparation, producing 0.531s of AAC despite the finger already being up.
        expect(timedRelease(down: 2244.232948624, up: 2244.299615290, ready: 2246.498) == .cancel,
               "Queued release must discard audio started after the physical quick tap ended")
        expect(timedRelease(down: 10, up: 10.067, ready: 10.01) == .cancel,
               "A quick tap stays cancelled even if the microphone became ready before physical release")
        expect(timedRelease(down: 10, up: 15, ready: 15.1) == .cancel,
               "A long hold cannot accept capture that only started after physical release")
        expect(timedRelease(down: 10, up: 15, ready: 14.98) == .cancel,
               "A delayed UP cannot inflate twenty milliseconds of useful capture into a voice message")
        expect(timedRelease(down: 10, up: 15, ready: 13.647) == .finish,
               "A held recording with enough capture before physical release still becomes a preview")
        expect(timedRelease(down: 10, up: 12, ready: 11.568) == .finish,
               "Soundboard preparation may consume part of a hold without discarding the valid remainder")
        expect(timedRelease(down: 10, up: 10.5, ready: 9) == .finish,
               "Only the physical hold counts when readiness precedes the touch")
        expect(timedRelease(down: 0, up: VoiceRecordingInteraction.minimumRecordingDuration, ready: 0) == .finish,
               "The minimum useful physical recording interval is accepted")
        expect(timedRelease(down: 0, up: 0.299, ready: 0) == .cancel,
               "A physical interval below the minimum is discarded")
        for touch in [
            VoiceRecordingTouchTiming(beganAt: .nan, endedAt: 11),
            VoiceRecordingTouchTiming(beganAt: 10, endedAt: .nan),
            VoiceRecordingTouchTiming(beganAt: 10, endedAt: .infinity),
            VoiceRecordingTouchTiming(beganAt: -.infinity, endedAt: 11),
            VoiceRecordingTouchTiming(beganAt: -1, endedAt: 11),
            VoiceRecordingTouchTiming(beganAt: 11, endedAt: 10)
        ] {
            recording.reset()
            let request = recording.begin()!
            _ = recording.started(request, at: 10)
            expect(recording.release(touch: touch) == .cancel, "Missing or invalid physical timing fails closed")
        }
        recording.reset()
        let timed = recording.begin()!
        expect(!recording.started(timed, at: .nan) && !recording.ready,
               "Invalid readiness timing cannot confirm capture")
        expect(recording.started(timed, at: 20) && recording.readyAt == 20, "Readiness belongs to the current request")
        expect(!recording.started(UUID(), at: 30) && recording.readyAt == 20,
               "An old request cannot replace readiness timing")
        recording.prepareToFinish()
        expect(recording.readyAt == nil, "Finalization clears touch readiness timing")
        recording.finishFailed()
        expect(recording.readyAt == nil && recording.release(touch: .init(beganAt: 1, endedAt: 1.01)) == .none,
               "Retrying finalization stays locked rather than inheriting a physical hold")
        recording.finish()
        recording.resume()
        expect(recording.readyAt == nil && recording.release(touch: .init(beganAt: 1, endedAt: 1.01)) == .none,
               "Resuming stays hands-free and ignores finger release")
        recording.reset()
        _ = recording.begin(locked: true)
        expect(recording.release(touch: .init(beganAt: .nan, endedAt: .nan)) == .none,
               "VoiceOver hands-free capture does not depend on physical touch timestamps")
        recording.reset()
        _ = recording.begin()
        _ = recording.move(x: 0, y: -77)
        expect(recording.release(touch: .init(beganAt: 1, endedAt: 1.01)) == .none,
               "An explicit slide-up lock survives release during microphone preparation")
        recording.reset()
        expect(recording.readyAt == nil, "Leaving clears readiness timing with ownership")
        print("Voice recording interaction: \(checks) checks passed")
    }
}
