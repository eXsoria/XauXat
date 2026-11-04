import Foundation

struct VoiceRecordingTouchTiming {
    let beganAt: TimeInterval
    let endedAt: TimeInterval
}

// A request identifies one recording, including the microphone permission wait.
// Releasing/cancelling invalidates it so a late permission result cannot record.
struct VoiceRecordingInteraction {
    static let minimumRecordingDuration: TimeInterval = 0.3
    enum Phase { case idle, holding, locked, finishing, preview }
    enum Action { case none, cancel, lock, finish }

    private(set) var phase: Phase = .idle
    private(set) var requestID: UUID?
    private(set) var ready = false
    private(set) var readyAt: TimeInterval?
    private(set) var cancelProgress: Double = 0
    private(set) var lockProgress: Double = 0

    var active: Bool { phase == .holding || phase == .locked || phase == .finishing }

    mutating func begin(locked: Bool = false) -> UUID? {
        guard phase == .idle else { return nil }
        let id = UUID()
        requestID = id
        phase = locked ? .locked : .holding
        ready = false
        readyAt = nil
        return id
    }

    mutating func started(_ id: UUID, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard requestID == id, active, time.isFinite, time >= 0 else { return false }
        ready = true
        readyAt = time
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

    mutating func release(touch: VoiceRecordingTouchTiming? = nil) -> Action {
        guard phase == .holding else { return .none }
        guard ready else { return .cancel }
        if let touch {
            // Audio preparation can block delivery of touchesEnded. Use UIKit's
            // physical event times, so queued release cannot turn a tap into audio.
            guard let readyAt, touch.beganAt.isFinite, touch.endedAt.isFinite,
                  touch.beganAt >= 0, touch.endedAt >= touch.beganAt,
                  touch.endedAt - max(touch.beganAt, readyAt) >= Self.minimumRecordingDuration else {
                return .cancel
            }
        }
        return .finish
    }

    mutating func finish() {
        phase = .preview
        requestID = nil
        ready = false
        readyAt = nil
        cancelProgress = 0
        lockProgress = 0
    }

    mutating func prepareToFinish() {
        phase = .finishing
        ready = false
        readyAt = nil
        requestID = nil
        cancelProgress = 0
        lockProgress = 0
    }

    mutating func finishFailed() {
        phase = .locked
        ready = true
        readyAt = nil
    }

    mutating func resume() {
        guard phase == .preview else { return }
        phase = .locked
        ready = true
        readyAt = nil
    }

    mutating func reset() { self = Self() }
}
