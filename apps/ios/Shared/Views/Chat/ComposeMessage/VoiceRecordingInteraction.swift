import Foundation

// A request identifies one recording, including the microphone permission wait.
// Releasing/cancelling invalidates it so a late permission result cannot record.
struct VoiceRecordingInteraction {
    enum Phase { case idle, holding, locked, preview }
    enum Action { case none, cancel, lock, finish }

    private(set) var phase: Phase = .idle
    private(set) var requestID: UUID?
    private(set) var ready = false
    private(set) var cancelProgress: Double = 0
    private(set) var lockProgress: Double = 0

    var active: Bool { phase == .holding || phase == .locked }

    mutating func begin(locked: Bool = false) -> UUID? {
        guard phase == .idle else { return nil }
        let id = UUID()
        requestID = id
        phase = locked ? .locked : .holding
        ready = false
        return id
    }

    mutating func started(_ id: UUID) -> Bool {
        guard requestID == id, active else { return false }
        ready = true
        return true
    }

    mutating func move(x: Double, y: Double) -> Action {
        guard phase == .holding else { return .none }
        cancelProgress = min(1, max(0, -x / 88))
        lockProgress = min(1, max(0, -y / 76))
        if cancelProgress >= 1 && -x / 88 >= -y / 76 { return .cancel }
        if lockProgress >= 1 {
            phase = .locked
            cancelProgress = 0
            lockProgress = 0
            return .lock
        }
        return .none
    }

    mutating func release() -> Action {
        guard phase == .holding else { return .none }
        return ready ? .finish : .cancel
    }

    mutating func finish() {
        phase = .preview
        requestID = nil
        ready = false
        cancelProgress = 0
        lockProgress = 0
    }

    mutating func resume() {
        guard phase == .preview else { return }
        phase = .locked
        ready = true
    }

    mutating func reset() { self = Self() }
}
