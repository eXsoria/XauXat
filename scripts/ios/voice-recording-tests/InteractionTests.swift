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
        print("Voice recording interaction: \(checks) checks passed")
    }
}
