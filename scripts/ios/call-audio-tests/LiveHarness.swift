import AVFoundation
import Foundation
import SwiftUI
import WebRTC
import OSLog

let logger = Logger(subsystem: "pt.exsoria.call-audio-test", category: "audio")
final class Call { var startWithModifiedVoice = false }
enum XauXatCallTiming {
    static let enabled = false
    static func mark(_ value: String) { print(value) }
}

// The codec endpoint is synthetic; the device, graph, PCM conversion, effect
// processors, notifications and WebRTC protocol/framework are production.
final class Endpoint: NSObject, RTCAudioDeviceDelegate {
    let lock = NSLock()
    var captured = 0
    var played = 0
    var invalid = 0
    var nonzero = 0
    var generationCheck: (() -> Void)?
    var generationChecks = 0
    var device: XauXatRealtimeAudioDevice { .shared }
    var preferredInputSampleRate: Double { 48000 }
    var preferredOutputSampleRate: Double { 48000 }
    var preferredInputIOBufferDuration: TimeInterval { 0.01 }
    var preferredOutputIOBufferDuration: TimeInterval { 0.01 }
    func dispatchAsync(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
    func dispatchSync(_ block: () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.sync(execute: block) }
    }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func snapshot() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return [captured, played, invalid, nonzero, generationChecks]
    }
    lazy var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock = { [weak self] flags, _, _, frames, buffers in
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        self?.lock.lock(); self?.played += Int(frames); self?.lock.unlock()
        return noErr
    }
    lazy var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock = { [weak self] flags, time, bus, frames, data, context, render in
        guard let self else { return noErr }
        let channels = self.device.inputNumberOfChannels
        let count = Int(frames) * channels
        let memory = UnsafeMutablePointer<Int16>.allocate(capacity: count)
        defer { memory.deallocate() }
        memory.initialize(repeating: -32768, count: count)
        var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * 2), mData: memory))
        self.lock.lock()
        let check = self.generationCheck
        self.generationCheck = nil
        self.lock.unlock()
        check?()
        var status: OSStatus = noErr
        if let render { status = render(flags, time, bus, frames, &output, context) }
        else if let data, data.pointee.mNumberBuffers == 1,
                data.pointee.mBuffers.mDataByteSize == count * 2, let source = data.pointee.mBuffers.mData {
            memcpy(memory, source, count * 2)
        } else { status = kAudio_ParamError }
        let signal = UnsafeBufferPointer(start: memory, count: count).contains { $0 != 0 }
        self.lock.lock()
        self.captured += Int(frames)
        if signal { self.nonzero += Int(frames) }
        if status != noErr || (check != nil && signal) { self.invalid += 1 }
        if check != nil { self.generationChecks += 1 }
        self.lock.unlock()
        return status
    }
}

final class HarnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let endpoint = Endpoint()
    var results: [[String: Any]] = []
    var name = CommandLine.arguments.last!
    var failure: String?

    func save() {
        let result: [String: Any] = ["case": name, "failure": failure ?? NSNull(), "checks": results, "stage": failure == nil ? "passed" : "failed"]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".json")
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    func check(_ label: String, _ body: @escaping () throws -> Void) throws {
        try ObjC.catchException {
            do { try body() } catch { self.failure = label + ": " + error.localizedDescription }
        }
        if let failure { throw NSError(domain: failure, code: 1) }
        results.append(["check": label, "stage": "passed"])
    }

    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }

    func settle(_ label: String, record: Bool = true, play: Bool = true, signal: Bool = false, next: @escaping () -> Void) {
        let before = endpoint.snapshot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            do {
                let after = self.endpoint.snapshot()
                try self.require(!record || after[0] > before[0], label + " received no microphone PCM")
                try self.require(!play || after[1] > before[1], label + " received no playout callbacks")
                try self.require(after[2] == 0, label + " invalid/stale PCM")
                try self.require(!signal || after[3] > before[3], label + " ambience PCM missing")
                self.results.append(["check":label, "stage":"passed", "captured":after[0]-before[0], "played":after[1]-before[1]])
                next()
            } catch { self.failure = error.localizedDescription; self.finish() }
        }
    }

    func finish() {
        _ = XauXatRealtimeAudioDevice.shared.terminateDevice()
        save()
    }

    func runPitchProof() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        input.frameLength = 480
        for preset in XauXatVoiceMaskPreset.allCases where preset != .stealth {
            let processor = try XauXatRealtimePitch(format: format, pitch: preset.pitch)
            var last: Float = 0
            var crossings = 0
            var energy: Float = 0
            for block in 0..<120 {
                for frame in 0..<480 { input.floatChannelData![0][frame] = 0.2 * sin(Float(block * 480 + frame) * 2 * .pi * 220 / 48000) }
                guard let output = processor.render(input.audioBufferList, frames: 480) else { throw NSError(domain:"pitch did not render",code:1) }
                if block >= 40 {
                    let samples = output.pointee.mBuffers.mData!.assumingMemoryBound(to:Float.self)
                    for frame in 0..<480 {
                        let sample = samples[frame]
                        try require(sample.isFinite, "pitch emitted non-finite PCM")
                        if sample > 0 && last <= 0 { crossings += 1 }
                        energy += abs(sample)
                        last = sample
                    }
                }
            }
            let frequency = Double(crossings) / 0.8
            let expected = 220 * pow(2, Double(preset.pitch) / 1200)
            try require(energy > 100 && abs(frequency - expected) < 12, "pitch effect frequency incorrect: \(preset) \(frequency), expected \(expected)")
            results.append(["check":"pitch-"+preset.rawValue, "frequency":frequency, "expected":expected, "stage":"passed"])
        }
    }

    func start() {
        do {
            try check("manual-pitch-signal") { try self.runPitchProof() }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: name.hasSuffix("voice") ? .voiceChat : .default, options: [.defaultToSpeaker])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            let device = XauXatRealtimeAudioDevice.shared
            try require(device.initialize(with: endpoint), "initialize failed")
            device.configureMasking(enabled:false, preset:.veil)
            // Recording precedes playout in one variant; the other mirrors the
            // opposite WebRTC start order. Both must really deliver frames.
            if name.hasPrefix("record") {
                _ = device.startRecording()
                settle("capture-only", play:false) { self.beginDuplex() }
            } else {
                _ = device.startPlayout()
                settle("playout-only", record:false) { self.beginDuplex() }
            }
        } catch { failure = error.localizedDescription; finish() }
    }
    func beginDuplex() {
        let device = XauXatRealtimeAudioDevice.shared
        _ = device.startPlayout(); _ = device.startRecording()
        device.setAmbience(.rain)
        settle("normal-duplex", signal:true) { self.preset(0) }
    }
    func preset(_ index: Int) {
        let presets = XauXatVoiceMaskPreset.allCases
        guard index < presets.count else { routes(); return }
        let selected = presets[index]
        XauXatRealtimeAudioDevice.shared.configureMasking(enabled:selected != .stealth, preset:selected, llvc:selected == .stealth)
        settle("live-"+selected.rawValue, signal:true) { self.preset(index + 1) }
    }
    func routes() {
        let device = XauXatRealtimeAudioDevice.shared
        device.configureMasking(enabled:false, preset:.veil)
        do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none) }
        catch { failure = error.localizedDescription; finish(); return }
        settle("receiver-route", signal:true) {
            do { try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker) }
            catch { self.failure = error.localizedDescription; self.finish(); return }
            self.settle("speaker-route", signal:true) { self.interruption() }
        }
    }
    func interruption() {
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object:session, userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.began.rawValue])
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object:session, userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.ended.rawValue])
            self.settle("interruption-resume", signal:true) { self.reset() }
        }
    }
    func reset() {
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object:AVAudioSession.sharedInstance())
        settle("media-reset", signal:true) {
            self.endpoint.lock.lock()
            self.endpoint.generationCheck = { XauXatRealtimeAudioDevice.shared.configureMasking(enabled:true, preset:.veil) }
            self.endpoint.lock.unlock()
            self.settle("generation-privacy", signal:true) {
                if self.endpoint.snapshot()[4] != 1 { self.failure = "generation probe not exercised"; self.finish(); return }
                self.restart(0)
            }
        }
    }
    func restart(_ index: Int) {
        let device = XauXatRealtimeAudioDevice.shared
        _ = device.stopRecording(); _ = device.stopPlayout()
        device.configureMasking(enabled:false,preset:.veil)
        _ = device.startPlayout(); _ = device.startRecording()
        settle("repeat-call-\(index)", signal:true) {
            if index < 2 { self.restart(index + 1) } else { self.finish() }
        }
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey:Any]?) -> Bool {
        let window = UIWindow(frame:UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible(); self.window = window
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.start() }
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(HarnessApp.self))
