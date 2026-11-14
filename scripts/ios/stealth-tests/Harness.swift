import AVFoundation
import SwiftUI

// Chat transport and billing are outside this local audio/UI fixture.
final class Call { var startWithModifiedVoice = false }
enum Feature { case advancedVoiceMasking, realTimeVoiceMasking }
final class XauXatPlusEntitlements: ObservableObject {
    func isAuthorized(for feature: Feature) -> Bool { !CommandLine.arguments.contains("free") }
}
struct XauXatPlusView: View { var body: some View { Text("Plus") } }
func xauXatChampagne(_ scheme: ColorScheme) -> Color { .accentColor }
func excludeFromSystemBackup(_ url: URL) -> Bool { true }

final class XauXatRealtimeAudioDevice {
    static let shared = XauXatRealtimeAudioDevice()
    var mode = "off"
    var modes: [String] = []
    func configureMasking(enabled: Bool, preset: XauXatVoiceMaskPreset, llvc: Bool = false) {
        mode = llvc ? "neural" : (enabled ? "legacy" : "off")
        modes.append(mode)
    }
    func setAmbience(_ ambience: XauXatCallAmbience) {}
    func suspendCapture() { mode = "off" }
}

// Actual rendering is production code. This small adapter plays its preview.
final class AudioPlayer {
    private var player: AVAudioPlayer?
    init(onTimer: @escaping (TimeInterval) -> Void, onFinishPlayback: @escaping () -> Void) {}
    @discardableResult func start(data: Data) -> Bool {
        player = try? AVAudioPlayer(data: data)
        return player?.play() ?? false
    }
    func stop() { player?.stop() }
    static func hasPlayableVoiceMessage(at url: URL, declaredDuration: TimeInterval) -> Bool {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        return player.duration > 0 && player.duration >= declaredDuration - 0.128
    }
}

@main struct VoiceHarness: App {
    @StateObject var plusEntitlements = XauXatPlusEntitlements()
    var body: some Scene {
        WindowGroup { HarnessView().environmentObject(plusEntitlements) }
    }
}

struct RecordingDraft: Identifiable {
    let id = UUID()
    let url: URL
}

struct HarnessView: View {
    @EnvironmentObject var plusEntitlements: XauXatPlusEntitlements
    @StateObject var voiceMasking = XauXatRealtimeVoiceMasking.shared
    @State var call = Call()
    @State var showCallEffects = false
    @State var showVoiceSettings = false
    @State var voiceNoteMaskEnabled = false
    @State var voiceNotePreset: XauXatVoiceMaskPreset = .veil
    @State var voiceNoteAmbience: XauXatCallAmbience = .off
    @State var recordingDraft: RecordingDraft?
    @State var result = "Ready"
    @State var started = false

    var body: some View {
        VStack(spacing: 20) {
            Button("Call effects") { showCallEffects = true }
            Button("Voice note settings") { showVoiceSettings = true }
            Button("Recording effects") {
                do {
                    recordingDraft = RecordingDraft(url: try AudioChecks.recording())
                } catch { result = "Failed: \(error.localizedDescription)" }
            }
            Text("Call \(voiceMasking.preset.rawValue) / \(voiceMasking.enabled ? "on" : "off") / \(XauXatRealtimeAudioDevice.shared.mode)")
                .accessibilityIdentifier("fixture.call")
            Text("Ambience \(voiceMasking.ambience.rawValue)").accessibilityIdentifier("fixture.ambience")
            Text("Initial path \(XauXatRealtimeAudioDevice.shared.modes.first ?? "none")").accessibilityIdentifier("fixture.initialPath")
            Text("Voice note \(voiceNotePreset.rawValue)").accessibilityIdentifier("fixture.note")
            Text(result).accessibilityIdentifier("fixture.result")
        }
        .padding()
        .onAppear {
            if !started {
                call.startWithModifiedVoice = CommandLine.arguments.contains("start-stealth")
                voiceMasking.beginCall(call)
                started = true
            }
        }
        .sheet(isPresented: $showCallEffects) {
            XauXatRealtimeVoiceMaskingView(allowsVoiceMasking: plusEntitlements.isAuthorized(for: .realTimeVoiceMasking))
        }
        .sheet(isPresented: $showVoiceSettings) { voiceNoteSettings }
        .sheet(item: $recordingDraft) { draft in
            let recordingURL = draft.url
            XauXatVoiceMaskPickerView(recordingURL: recordingURL, initialPreset: .veil) { preset, _ in
                result = "Rendering"
                Task {
                    let outcome = await Task.detached(priority: .userInitiated) {
                        Result { try AudioChecks.verify(recordingURL, preset: preset) }
                    }.value
                    switch outcome {
                    case let .success(message): result = message
                    case let .failure(error): result = "Failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

enum AudioChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func recording(rate: Double = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        // A partial final LLVC chunk must be retained in the exported recording.
        let frames = AVAudioFrameCount(rate + 137)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            buffer.floatChannelData![0][i] = Float(0.25 * sin(2 * .pi * 170 * t) + 0.1 * sin(2 * .pi * 440 * t))
        }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ])
        try file?.write(from: buffer)
        if #available(iOS 18, *) { file?.close() }
        file = nil
        return url
    }

    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func verify(_ url: URL, preset: XauXatVoiceMaskPreset) throws -> String {
        defer { try? FileManager.default.removeItem(at: url) }
        try require(preset == .stealth, "The actual Stealth preset must be selected")
        let original = try Data(contentsOf: url)
        let originalSamples = try samples(url)
        let duration = try AVAudioPlayer(contentsOf: url).duration
        if CommandLine.arguments.contains("expect-missing-model") {
            try require(Bundle.main.url(forResource: "XauXatLLVC", withExtension: "mlmodelc") == nil, "Negative fixture unexpectedly has a model")
            do {
                try XauXatVoiceMask.apply(to: url, preset: preset, declaredDuration: duration)
            } catch {
                try require(error.localizedDescription.contains("model is missing"), "Expected the missing-model failure, got \(error)")
                try require(try Data(contentsOf: url) == original, "A failed transformation replaced the original draft")
                return "Model missing · original preserved"
            }
            throw Failure(message: "Missing model silently fell back to unmasked audio")
        }
        try XauXatVoiceMask.apply(to: url, preset: preset, declaredDuration: duration)
        try require(try Data(contentsOf: url) != original, "Stealth did not render a new recording")
        let transformed = try samples(url)
        try require(abs(try AVAudioPlayer(contentsOf: url).duration - duration) < 0.15, "Stealth truncated the recording")
        try require(transformed.contains { abs($0) > 0.0001 }, "Stealth rendered only silence")
        let difference = zip(originalSamples, transformed).map { abs($0.0 - $0.1) }.reduce(0, +)
        try require(difference > 0.1, "Stealth returned the original PCM")
        let incompatible = try recording(rate: 44_100)
        defer { try? FileManager.default.removeItem(at: incompatible) }
        let incompatibleBytes = try Data(contentsOf: incompatible)
        var rejected = false
        do { try XauXatVoiceMask.apply(to: incompatible, preset: preset) } catch { rejected = true }
        try require(rejected && (try Data(contentsOf: incompatible)) == incompatibleBytes, "Unsupported recording was sent through a raw fallback")
        let withRain = try recording()
        defer { try? FileManager.default.removeItem(at: withRain) }
        try XauXatVoiceMask.apply(to: withRain, preset: preset, ambience: .rain)
        try require(try AVAudioPlayer(contentsOf: withRain).duration > 1, "Stealth with background sound was not playable")
        try verifyCapture(rate: 16_000)
        try verifyCapture(rate: 48_000)
        return "Stealth verified · recording and 16/48 kHz capture"
    }

    static func verifyCapture(rate: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let lock = NSLock()
        var failures: [String] = []
        let capture = XauXatLLVCCapture(format: format, channels: 1) { _, message in
            lock.lock(); failures.append(message); lock.unlock()
        }!
        let previewURL = try recording()
        defer { try? FileManager.default.removeItem(at: previewURL) }
        let previews = DispatchGroup()
        previews.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { previews.leave() }
            do {
                let data = try XauXatVoiceMask.previewData(from: previewURL, preset: .stealth)
                try require(try AVAudioPlayer(data: data).duration > 1, "Concurrent preview was not playable")
            } catch {
                lock.lock(); failures.append("Concurrent preview: \(error)"); lock.unlock()
            }
        }
        let frames = Int(rate / 16_000) * 208
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        input.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { input.floatChannelData![0][i] = Float(0.3 * sin(2 * .pi * 170 * Double(i) / rate)) }
        var audible = false
        for block in 0..<50 {
            guard let output = capture.render(input.audioBufferList, count: frames, generation: 1) else {
                throw Failure(message: "Supported capture route was rejected")
            }
            let values = UnsafeBufferPointer(start: output.mBuffers.mData!.assumingMemoryBound(to: Int16.self), count: frames)
            if block == 0 { try require(values.allSatisfy { $0 == 0 }, "Startup leaked original microphone frames") }
            audible = audible || values.contains { $0 != 0 }
            // Pace above real time: this tests conversion, not phone performance.
            Thread.sleep(forTimeInterval: 0.04)
        }
        let switched = capture.render(input.audioBufferList, count: frames, generation: 2)!
        let transition = UnsafeBufferPointer(start: switched.mBuffers.mData!.assumingMemoryBound(to: Int16.self), count: frames)
        try require(transition.allSatisfy { $0 == 0 }, "A new processing generation leaked previous audio")
        try require(previews.wait(timeout: .now() + 30) == .success, "Concurrent preview did not complete")
        lock.lock(); let errors = failures; lock.unlock()
        try require(errors.isEmpty, "Capture failed at \(rate) Hz: \(errors)")
        try require(audible, "Capture never emitted transformed audio at \(rate) Hz")
    }
}
