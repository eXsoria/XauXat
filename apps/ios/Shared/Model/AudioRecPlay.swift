//
//  AudioRecPlay.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 19/11/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import Foundation
import AVFoundation
import SwiftUI
import SimpleXChat

enum XauXatVoiceMaskError: LocalizedError {
    case emptyRecording
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .emptyRecording:
            return NSLocalizedString("The recording is empty.", comment: "voice masking error")
        case .renderingFailed:
            return NSLocalizedString("The voice mask could not be applied.", comment: "voice masking error")
        }
    }
}

enum XauXatVoiceMaskPreset: String, CaseIterable, Identifiable {
    case veil
    case alloy
    case hollow
    case wisp
    #if DEBUG
    case stealth
    #endif

    static let defaultPreferenceKey = "xauxat.voiceMask.defaultPreset"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .veil: return NSLocalizedString("Veil", comment: "free voice masking preset name")
        case .alloy: return NSLocalizedString("Alloy", comment: "Plus voice masking preset name")
        case .hollow: return NSLocalizedString("Hollow", comment: "Plus voice masking preset name")
        case .wisp: return NSLocalizedString("Wisp", comment: "Plus voice masking preset name")
        #if DEBUG
        case .stealth: return NSLocalizedString("Stealth", comment: "LLVC voice masking preset name")
        #endif
        }
    }

    var detail: String {
        switch self {
        case .veil: return NSLocalizedString("Low and discreet", comment: "voice masking preset description")
        case .alloy: return NSLocalizedString("Bright and metallic", comment: "voice masking preset description")
        case .hollow: return NSLocalizedString("Deep and distant", comment: "voice masking preset description")
        case .wisp: return NSLocalizedString("Light and airy", comment: "voice masking preset description")
        #if DEBUG
        case .stealth: return NSLocalizedString("Neural voice transformation on this device", comment: "LLVC voice masking preset description")
        #endif
        }
    }

    var requiresPlus: Bool {
        #if DEBUG
        if self == .stealth { return false }
        #endif
        return self != .veil
    }

    var pitch: Float {
        switch self {
        case .veil: return -420
        case .alloy: return 320
        case .hollow: return -700
        case .wisp: return 610
        #if DEBUG
        case .stealth: return 0
        #endif
        }
    }
}

// Give the transformed speech 4 dB of gain while leaving headroom for ambience.
func xauXatBoostMaskedVoice(_ sample: Float) -> Float {
    let amplified = sample * 1.585
    let magnitude = abs(amplified)
    let knee: Float = 0.70
    guard magnitude > knee else { return amplified }
    let excess = magnitude - knee
    let limited = knee + 0.20 * excess / (0.20 + excess)
    return amplified < 0 ? -limited : limited
}

struct XauXatVoiceMask {
    private static let renderBufferSize: AVAudioFrameCount = 4096

    static func apply(to recordingURL: URL, preset: XauXatVoiceMaskPreset?, ambience: XauXatCallAmbience = .off, declaredDuration: TimeInterval = 0) throws {
        let maskedURL = recordingURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-masked.m4a")
        defer { try? FileManager.default.removeItem(at: maskedURL) }
        try render(from: recordingURL, to: maskedURL, preset: preset, ambience: ambience)

        guard AudioPlayer.hasPlayableVoiceMessage(at: maskedURL, declaredDuration: declaredDuration) else {
            throw XauXatVoiceMaskError.renderingFailed
        }
        // Keep the existing draft if the validated output cannot be committed.
        try Data(contentsOf: maskedURL).write(to: recordingURL, options: [.atomic, .completeFileProtection])
        _ = excludeFromSystemBackup(recordingURL)
    }

    static func previewData(from recordingURL: URL, preset: XauXatVoiceMaskPreset) throws -> Data {
        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xauxat-voice-preview-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: previewURL) }
        try render(from: recordingURL, to: previewURL, preset: preset)
        return try Data(contentsOf: previewURL, options: .mappedIfSafe)
    }

    private static func render(from recordingURL: URL, to outputURL: URL, preset: XauXatVoiceMaskPreset?, ambience: XauXatCallAmbience = .off) throws {
        let sourceFile = try AVAudioFile(forReading: recordingURL)
        guard sourceFile.length > 0 else { throw XauXatVoiceMaskError.emptyRecording }

        let renderFormat = sourceFile.processingFormat
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: renderFormat.sampleRate,
            AVEncoderBitRateKey: 32000,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained,
            AVNumberOfChannelsKey: renderFormat.channelCount
        ]
        var maskedFile: AVAudioFile? = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: renderFormat.commonFormat,
            interleaved: renderFormat.isInterleaved
        )
        #if DEBUG
        if preset == .stealth, let maskedFile {
            try XauXatLLVCCapture.renderRecording(sourceFile, to: maskedFile, ambience: ambience)
        } else {
            try renderPitch()
        }
        #else
        try renderPitch()
        #endif
        if #available(iOS 18, *) { maskedFile?.close() }
        maskedFile = nil
        let sourceDuration = Double(sourceFile.length) / renderFormat.sampleRate
        guard let rendered = try? AVAudioPlayer(contentsOf: outputURL),
              rendered.duration >= max(0.001, sourceDuration - 0.128) else {
            throw XauXatVoiceMaskError.renderingFailed
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: outputURL.path)
        _ = excludeFromSystemBackup(outputURL)

        func renderPitch() throws {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            let ambienceMixer = ambience == .off ? nil : XauXatCallAmbienceMixer(sampleRate: renderFormat.sampleRate)
            engine.attach(player)
            if let preset {
                timePitch.pitch = preset.pitch
                engine.attach(timePitch)
                engine.connect(player, to: timePitch, format: renderFormat)
                engine.connect(timePitch, to: engine.mainMixerNode, format: renderFormat)
            } else {
                engine.connect(player, to: engine.mainMixerNode, format: renderFormat)
            }
            try engine.enableManualRenderingMode(
                .offline,
                format: renderFormat,
                maximumFrameCount: renderBufferSize
            )

            guard let renderBuffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: renderBufferSize
            ) else {
                throw XauXatVoiceMaskError.renderingFailed
            }

            player.scheduleFile(sourceFile, at: nil)
            try engine.start()
            player.play()

            var stalledRenderAttempts = 0
            while engine.manualRenderingSampleTime < sourceFile.length {
                let remainingFrames = sourceFile.length - engine.manualRenderingSampleTime
                let framesToRender = min(renderBufferSize, AVAudioFrameCount(remainingFrames))

                switch try engine.renderOffline(framesToRender, to: renderBuffer) {
                case .success:
                    if preset != nil, let samples = renderBuffer.floatChannelData {
                        for channel in 0..<Int(renderFormat.channelCount) {
                            for frame in 0..<Int(renderBuffer.frameLength) {
                                samples[channel][frame] = xauXatBoostMaskedVoice(samples[channel][frame])
                            }
                        }
                    }
                    try ambienceMixer?.mix(into: renderBuffer, selection: ambience, remainingFrames: remainingFrames)
                    try maskedFile?.write(from: renderBuffer)
                    stalledRenderAttempts = 0
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    stalledRenderAttempts += 1
                    if stalledRenderAttempts > 20 {
                        throw XauXatVoiceMaskError.renderingFailed
                    }
                case .error:
                    throw XauXatVoiceMaskError.renderingFailed
                @unknown default:
                    throw XauXatVoiceMaskError.renderingFailed
                }
            }

            player.stop()
            engine.stop()
        }
    }
}

@MainActor
class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    var onTimer: ((TimeInterval) -> Void)?
    var onFinishRecording: (() -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onFinishing: (() -> Void)?
    var owner: UUID?
    var audioRecorder: AVAudioRecorder?
    var recordingTimer: Timer?
    private var ownsAudioSession = false
    private var recordingFileName: String?
    private var segmentFileName: String?
    private var pendingCapture: URL?
    private var pendingSegments: [URL] = []
    private var segmentOffset: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var cancelled = false
    private(set) var preparationError: String?
    private var operation = UUID()
    private var finalizationTask: Task<Void, Error>?
    private var exporter: AVAssetExportSession?

    // A draft can be reopened while its final segment is being joined. Keep
    // ownership here until the canonical, playable file is ready.
    private static var pendingRecorders: [String: AudioRecorder] = [:]
    static func pending(_ fileName: String) -> AudioRecorder? { pendingRecorders[fileName] }
    var canResume: Bool { !cancelled && recordingFileName != nil && finalizationTask == nil && pendingCapture == nil && pendingSegments.isEmpty && duration < MAX_VOICE_MESSAGE_LENGTH }

    init(onTimer: @escaping (TimeInterval) -> Void, onFinishRecording: @escaping () -> Void, onLevel: ((CGFloat) -> Void)? = nil, onFinishing: (() -> Void)? = nil) {
        self.onTimer = onTimer
        self.onFinishRecording = onFinishRecording
        self.onLevel = onLevel
        self.onFinishing = onFinishing
        super.init()
    }

    enum StartError {
        case permission
        case error(String)
        case cancelled
    }

    private enum RecordingError: LocalizedError {
        case unavailable
        var errorDescription: String? { NSLocalizedString("Unable to prepare the voice recording. Please try again.", comment: "voice recording export error") }
    }

    func start(fileName: String, shouldStart: () -> Bool = { true }) async -> StartError? {
        let allowed = await checkPermission()
        guard shouldStart(), !cancelled, !Task.isCancelled else { return .cancelled }
        guard allowed else { return .permission }
        recordingFileName = fileName
        do {
            try startSegment(fileName)
            return nil
        } catch {
            stop()
            logger.error("AudioRecorder start error \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }

    private func startSegment(_ fileName: String) throws {
        let av = AVAudioSession.sharedInstance()
        try av.setCategory(.playAndRecord, options: .defaultToSpeaker)
        ownsAudioSession = true
        try av.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVNumberOfChannelsKey: 1
        ]
        segmentFileName = fileName
        segmentOffset = duration
        let capture = getAppFilePath(fileName + ".caf")
        let recorder = try AVAudioRecorder(url: capture, settings: settings)
        audioRecorder = recorder
        guard recorder.prepareToRecord() else { throw RecordingError.unavailable }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: capture.path)
        _ = excludeFromSystemBackup(capture)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: MAX_VOICE_MESSAGE_LENGTH - duration) else { throw RecordingError.unavailable }
        startTimer()
    }

    // Finalize capture before encoding the compressed preview or attachment.
    func pause() -> Task<Void, Error> {
        if let finalizationTask { return finalizationTask }
        closeSegment()
        guard let fileName = recordingFileName, !cancelled else {
            return Task { throw CancellationError() }
        }
        preparationError = nil
        Self.pendingRecorders[fileName] = self
        let request = operation
        let task = Task { @MainActor [self] in
            defer { finalizationTask = nil }
            do {
                try await encodeCapture(fileName: fileName, request: request)
                try await joinSegments(fileName: fileName, request: request)
                guard operation == request, !cancelled else { throw CancellationError() }
                if Self.pendingRecorders[fileName] === self { Self.pendingRecorders[fileName] = nil }
            } catch {
                let detail = error as NSError
                preparationError = "\(detail.domain) (\(detail.code)): \(detail.localizedDescription)"
                if let underlying = detail.userInfo[NSUnderlyingErrorKey] as? NSError {
                    preparationError! += " - \(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)"
                }
                throw error
            }
        }
        finalizationTask = task
        onFinishing?()
        return task
    }

    private func encodeCapture(fileName: String, request: UUID) async throws {
        guard let input = pendingCapture else { return }
        let output = input.deletingPathExtension()
        let duration = self.duration - segmentOffset
        try await Task.detached(priority: .userInitiated) {
            try Self.encodeCapture(input: input, output: output, expectedDuration: duration)
        }.value
        guard operation == request, !cancelled else {
            removeRecordingFile(output)
            throw CancellationError()
        }
        removeRecordingFile(input)
        pendingCapture = nil
        if output != getAppFilePath(fileName) { pendingSegments.append(output) }
    }

    private nonisolated static func encodeCapture(input: URL, output: URL, expectedDuration: TimeInterval) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVEncoderBitRateKey: 32000,
            AVNumberOfChannelsKey: format.channelCount
        ]
        let temp = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw RecordingError.unavailable }
        var encoded: AVAudioFile? = try AVAudioFile(forWriting: temp, settings: settings)
        while source.framePosition < source.length {
            try source.read(into: buffer)
            guard buffer.frameLength > 0 else { throw RecordingError.unavailable }
            try encoded?.write(from: buffer)
        }
        if #available(iOS 18, *) { encoded?.close() }
        encoded = nil
        guard let player = try? AVAudioPlayer(contentsOf: temp), player.duration > 0,
              player.duration >= max(0, expectedDuration - 0.5) else { throw RecordingError.unavailable }
        try Data(contentsOf: temp).write(to: output, options: [.atomic, .completeFileProtection])
        _ = excludeFromSystemBackup(output)
    }

    func resume() -> Bool {
        guard canResume, audioRecorder == nil else { return false }
        let part = generateNewFileName("voice-part-\(UUID().uuidString)", "m4a")
        do {
            try startSegment(part)
            return true
        } catch {
            closeSegment()
            removeRecordingFile(getAppFilePath(part + ".caf"))
            pendingCapture = nil
            return false
        }
    }

    private func joinSegments(fileName: String, request: UUID) async throws {
        guard !pendingSegments.isEmpty else { return }
        let canonical = getAppFilePath(fileName)
        let parts = pendingSegments
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.unavailable
        }
        var position = CMTime.zero
        for url in [canonical] + parts {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw RecordingError.unavailable }
            let length = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: position)
            position = CMTimeAdd(position, length)
        }
        guard operation == request, !cancelled else { throw CancellationError() }
        // Prefer a packet copy; some OS/codec combinations advertise M4A
        // passthrough but reject the composition at export time.
        var lastError: Error = RecordingError.unavailable
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let session = AVAssetExportSession(asset: composition, presetName: preset),
                  session.supportedFileTypes.contains(.m4a) else { continue }
            let output = getAppFilePath(generateNewFileName("voice-joined-\(UUID().uuidString)", "m4a"))
            defer { removeRecordingFile(output) }
            exporter = session
            defer { exporter = nil }
            session.outputURL = output
            session.outputFileType = .m4a
            session.metadata = []
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        if session.status == .completed {
                            continuation.resume(returning: ())
                        } else {
                            continuation.resume(throwing: session.error ?? RecordingError.unavailable)
                        }
                    }
                }
                guard operation == request, !cancelled else { throw CancellationError() }
                guard let player = try? AVAudioPlayer(contentsOf: output),
                      player.duration >= max(0.001, position.seconds - 0.128) else { throw RecordingError.unavailable }
                // Commit through an atomic write, retaining the existing playable
                // draft if replacing it fails (for example, when storage is full).
                try Data(contentsOf: output).write(to: canonical, options: .atomic)
                for part in parts { removeRecordingFile(part) }
                pendingSegments.removeAll()
                return
            } catch {
                guard operation == request, !cancelled else { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    private func startTimer() {
        recordingTimer?.invalidate()
        AppDelegate.keepScreenOn(true)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRecording() }
        }
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateRecording() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        duration = min(MAX_VOICE_MESSAGE_LENGTH, max(duration, segmentOffset + recorder.currentTime))
        onTimer?(duration)
        recorder.updateMeters()
        onLevel?(CGFloat(pow(10, recorder.averagePower(forChannel: 0) / 40)))
        if duration >= MAX_VOICE_MESSAGE_LENGTH { complete() }
    }

    private func complete() {
        guard audioRecorder != nil else { return }
        let task = pause()
        Task { @MainActor [weak self] in
            do {
                try await task.value
                if self?.cancelled == false { self?.onFinishRecording?() }
            } catch {
                // The composer awaiting onFinishing offers retry or delete.
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioRecorder === recorder else { return }
            if flag { self.duration = MAX_VOICE_MESSAGE_LENGTH }
            self.complete()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.audioRecorder === recorder else { return }
            self.complete()
        }
    }

    private func closeSegment() {
        if let recorder = audioRecorder {
            duration = min(MAX_VOICE_MESSAGE_LENGTH, max(duration, segmentOffset + recorder.currentTime))
            onTimer?(duration)
            recorder.delegate = nil
            recorder.stop()
            audioRecorder = nil
            if let name = segmentFileName { pendingCapture = getAppFilePath(name + ".caf") }
        }
        segmentFileName = nil
        let wasRecording = recordingTimer != nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        if wasRecording { AppDelegate.keepScreenOn(false) }
        releaseAudioSession()
    }

    func stop() {
        cancelled = true
        operation = UUID()
        finalizationTask?.cancel()
        exporter?.cancelExport()
        closeSegment()
        if let name = recordingFileName, Self.pendingRecorders[name] === self { Self.pendingRecorders[name] = nil }
        recordingFileName = nil
        if let pendingCapture { removeRecordingFile(pendingCapture) }
        pendingCapture = nil
        for part in pendingSegments { removeRecordingFile(part) }
        pendingSegments.removeAll()
    }

    private func removeRecordingFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
    }

    private func checkPermission() async -> Bool {
        let av = AVAudioSession.sharedInstance()
        switch av.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                av.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }
}

class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    static func minimumVoiceMessageDuration(_ declaredDuration: TimeInterval) -> TimeInterval {
        // The duration stored with a message is rounded to seconds.
        declaredDuration > 0 ? max(0.1, declaredDuration - 1) : 0
    }

    static func hasPlayableVoiceMessage(at url: URL, declaredDuration: TimeInterval) -> Bool {
        let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
        let valid = duration > 0 && duration >= minimumVoiceMessageDuration(declaredDuration)
        #if DEBUG
        if !valid {
            logger.notice("Voice duration check rejected expected=\(declaredDuration, privacy: .public) actual=\(duration, privacy: .public)")
        }
        #endif
        return valid
    }

    var onTimer: ((TimeInterval) -> Void)?
    var onFinishPlayback: (() -> Void)?

    var audioPlayer: AVAudioPlayer?
    var playbackTimer: Timer?

    init(onTimer: @escaping ((TimeInterval) -> Void), onFinishPlayback: @escaping (() -> Void)) {
        self.onTimer = onTimer
        self.onFinishPlayback = onFinishPlayback
    }

    @discardableResult
    func start(fileSource: CryptoFile, at: TimeInterval?, minimumDuration: TimeInterval = 0) -> Bool {
        let url = getAppFilePath(fileSource.filePath)
        do {
            let player: AVAudioPlayer
            if let args = fileSource.cryptoArgs {
                let data = try readCryptoFile(path: url.path, cryptoArgs: args)
                player = try AVAudioPlayer(data: data)
            } else {
                player = try AVAudioPlayer(contentsOf: url)
            }
            guard player.duration >= minimumDuration else { return false }
            return start(player, at: at)
        } catch {
            logger.error("Voice playback could not open the attachment: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    @discardableResult
    func start(data: Data, at: TimeInterval? = nil) -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        return start(player, at: at)
    }

    private func start(_ player: AVAudioPlayer, at: TimeInterval?) -> Bool {
        stop()
        player.delegate = self
        if let at, at.isFinite, at >= 0, at < player.duration { player.currentTime = at }
        guard player.prepareToPlay(), activatePlayback(), player.play() else {
            Self.changeAudioSession(false)
            return false
        }
        audioPlayer = player
        AppDelegate.keepScreenOn(true)
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer, player.isPlaying else { return }
            self.onTimer?(player.currentTime)
        }
        return true
    }

    private func activatePlayback() -> Bool {
        Self.changeAudioSession(true)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            logger.error("Voice playback could not activate the audio session: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func pause() {
        audioPlayer?.pause()
        AppDelegate.keepScreenOn(false)
    }

    @discardableResult
    func play() -> Bool {
        guard let player = audioPlayer, activatePlayback(), player.play() else { return false }
        AppDelegate.keepScreenOn(true)
        return true
    }

    func seek(_ to: TimeInterval) {
        if audioPlayer?.isPlaying == true {
            audioPlayer?.pause()
            audioPlayer?.currentTime = to
            audioPlayer?.play()
        } else {
            audioPlayer?.currentTime = to
        }
        self.onTimer?(to)
    }

    func stop() {
        if let player = audioPlayer {
            player.stop()
            AppDelegate.keepScreenOn(false)
            AudioPlayer.changeAudioSession(false)
        }
        audioPlayer = nil
        if let timer = playbackTimer {
            timer.invalidate()
        }
        playbackTimer = nil
    }

    static func changeAudioSession(_ playback: Bool) {
        // When there is a audio recording, setting any other category will disable sound
        if AVAudioSession.sharedInstance().category == .playAndRecord {
            return
        }
        if playback {
            if AVAudioSession.sharedInstance().category != .playback {
                logger.log("AudioSession: playback")
                try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            }
        } else {
            if AVAudioSession.sharedInstance().category != .soloAmbient {
                logger.log("AudioSession: soloAmbient")
                try? AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.soloAmbient)
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
        self.onFinishPlayback?()
    }
}
