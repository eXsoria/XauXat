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

    static let defaultPreferenceKey = "xauxat.voiceMask.defaultPreset"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .veil: return NSLocalizedString("Veil", comment: "free voice masking preset name")
        case .alloy: return NSLocalizedString("Alloy", comment: "Plus voice masking preset name")
        case .hollow: return NSLocalizedString("Hollow", comment: "Plus voice masking preset name")
        case .wisp: return NSLocalizedString("Wisp", comment: "Plus voice masking preset name")
        }
    }

    var detail: String {
        switch self {
        case .veil: return NSLocalizedString("Low and discreet", comment: "voice masking preset description")
        case .alloy: return NSLocalizedString("Bright and metallic", comment: "voice masking preset description")
        case .hollow: return NSLocalizedString("Deep and distant", comment: "voice masking preset description")
        case .wisp: return NSLocalizedString("Light and airy", comment: "voice masking preset description")
        }
    }

    var requiresPlus: Bool { self != .veil }

    var pitch: Float {
        switch self {
        case .veil: return -420
        case .alloy: return 320
        case .hollow: return -700
        case .wisp: return 610
        }
    }
}

struct XauXatVoiceMask {
    private static let renderBufferSize: AVAudioFrameCount = 4096

    static func apply(to recordingURL: URL, preset: XauXatVoiceMaskPreset) throws {
        let maskedURL = recordingURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-masked.m4a")
        defer { try? FileManager.default.removeItem(at: maskedURL) }
        try render(from: recordingURL, to: maskedURL, preset: preset)

        _ = try FileManager.default.replaceItemAt(
            recordingURL,
            withItemAt: maskedURL,
            backupItemName: nil,
            options: []
        )
        _ = excludeFromSystemBackup(recordingURL)
    }

    static func previewData(from recordingURL: URL, preset: XauXatVoiceMaskPreset) throws -> Data {
        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xauxat-voice-preview-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: previewURL) }
        try render(from: recordingURL, to: previewURL, preset: preset)
        return try Data(contentsOf: previewURL, options: .mappedIfSafe)
    }

    private static func render(from recordingURL: URL, to outputURL: URL, preset: XauXatVoiceMaskPreset) throws {
        let sourceFile = try AVAudioFile(forReading: recordingURL)
        guard sourceFile.length > 0 else { throw XauXatVoiceMaskError.emptyRecording }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let renderFormat = sourceFile.processingFormat
        timePitch.pitch = preset.pitch
        timePitch.rate = 1

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: renderFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: renderFormat)
        try engine.enableManualRenderingMode(
            .offline,
            format: renderFormat,
            maximumFrameCount: renderBufferSize
        )

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
        maskedFile = nil
        let maskedFileSize = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard maskedFileSize > 0 else {
            throw XauXatVoiceMaskError.renderingFailed
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: outputURL.path)
        _ = excludeFromSystemBackup(outputURL)
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
    private var pendingSegments: [URL] = []
    private var segmentOffset: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var cancelled = false
    private var operation = UUID()
    private var finalizationTask: Task<Void, Error>?
    private var exporter: AVAssetExportSession?

    // A draft can be reopened while its final segment is being joined. Keep
    // ownership here until the canonical, playable file is ready.
    private static var pendingRecorders: [String: AudioRecorder] = [:]
    static func pending(_ fileName: String) -> AudioRecorder? { pendingRecorders[fileName] }
    var canResume: Bool { !cancelled && recordingFileName != nil && finalizationTask == nil && pendingSegments.isEmpty && duration < MAX_VOICE_MESSAGE_LENGTH }

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
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVEncoderBitRateKey: 32000,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained,
            AVNumberOfChannelsKey: 1
        ]
        segmentFileName = fileName
        segmentOffset = duration
        let recorder = try AVAudioRecorder(url: getAppFilePath(fileName), settings: settings)
        audioRecorder = recorder
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: MAX_VOICE_MESSAGE_LENGTH - duration) else { throw RecordingError.unavailable }
        startTimer()
    }

    // Closing AAC writes its container header. AVAudioRecorder.pause() leaves
    // an unfinished M4A that AVAudioPlayer cannot preview.
    func pause() -> Task<Void, Error> {
        if let finalizationTask { return finalizationTask }
        closeSegment()
        guard let fileName = recordingFileName, !cancelled else {
            return Task { throw CancellationError() }
        }
        Self.pendingRecorders[fileName] = self
        let request = operation
        let task = Task { @MainActor [self] in
            defer { finalizationTask = nil }
            try await joinSegments(fileName: fileName, request: request)
            guard operation == request, !cancelled else { throw CancellationError() }
            if Self.pendingRecorders[fileName] === self { Self.pendingRecorders[fileName] = nil }
        }
        finalizationTask = task
        onFinishing?()
        return task
    }

    func resume() -> Bool {
        guard canResume, audioRecorder == nil else { return false }
        let part = generateNewFileName("voice-part-\(UUID().uuidString)", "m4a")
        do {
            try startSegment(part)
            return true
        } catch {
            closeSegment()
            if let url = pendingSegments.last, url == getAppFilePath(part) {
                pendingSegments.removeLast()
            }
            removeRecordingFile(getAppFilePath(part))
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
        // All parts have identical AAC settings, so joining can usually copy
        // packets without another lossy encode.
        var session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        if session?.supportedFileTypes.contains(.m4a) != true {
            session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        }
        guard let session else { throw RecordingError.unavailable }
        let output = getAppFilePath(generateNewFileName("voice-joined-\(UUID().uuidString)", "m4a"))
        defer { removeRecordingFile(output) }
        exporter = session
        defer { exporter = nil }
        session.outputURL = output
        session.outputFileType = .m4a
        session.metadata = []
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
        _ = try FileManager.default.replaceItemAt(canonical, withItemAt: output)
        for part in parts { removeRecordingFile(part) }
        pendingSegments.removeAll()
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
            if let name = segmentFileName, name != recordingFileName {
                pendingSegments.append(getAppFilePath(name))
            }
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
    var onTimer: ((TimeInterval) -> Void)?
    var onFinishPlayback: (() -> Void)?

    var audioPlayer: AVAudioPlayer?
    var playbackTimer: Timer?

    init(onTimer: @escaping ((TimeInterval) -> Void), onFinishPlayback: @escaping (() -> Void)) {
        self.onTimer = onTimer
        self.onFinishPlayback = onFinishPlayback
    }

    func start(fileSource: CryptoFile, at: TimeInterval?) {
        let url = getAppFilePath(fileSource.filePath)
        if let cfArgs = fileSource.cryptoArgs {
            if let data = try? readCryptoFile(path: url.path, cryptoArgs: cfArgs) {
                audioPlayer = try? AVAudioPlayer(data: data)
            }
        } else {
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
        }
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()
        if let at = at {
            audioPlayer?.currentTime = at
        }
        audioPlayer?.play()

        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
            if self.audioPlayer?.isPlaying ?? false {
                AppDelegate.keepScreenOn(true)
                guard let time = self.audioPlayer?.currentTime else { return }
                self.onTimer?(time)
                AudioPlayer.changeAudioSession(true)
            } else {
                AudioPlayer.changeAudioSession(false)
            }
        }
    }

    func start(data: Data, at: TimeInterval? = nil) {
        audioPlayer = try? AVAudioPlayer(data: data)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()
        if let at { audioPlayer?.currentTime = at }
        audioPlayer?.play()

        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if self.audioPlayer?.isPlaying ?? false {
                AppDelegate.keepScreenOn(true)
                guard let time = self.audioPlayer?.currentTime else { return }
                self.onTimer?(time)
                AudioPlayer.changeAudioSession(true)
            } else {
                AudioPlayer.changeAudioSession(false)
            }
        }
    }

    func pause() {
        audioPlayer?.pause()
        AppDelegate.keepScreenOn(false)
    }

    func play() {
        audioPlayer?.play()
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
                try? AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback, options: [.duckOthers, .allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
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
