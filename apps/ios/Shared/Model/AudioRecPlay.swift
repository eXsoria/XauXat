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

    fileprivate var pitch: Float {
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

class AudioRecorder {
    var onTimer: ((TimeInterval) -> Void)?
    var onFinishRecording: (() -> Void)?

    var audioRecorder: AVAudioRecorder?
    var recordingTimer: Timer?

    init(onTimer: @escaping ((TimeInterval) -> Void), onFinishRecording: @escaping (() -> Void)) {
        self.onTimer = onTimer
        self.onFinishRecording = onFinishRecording
    }

    enum StartError {
        case permission
        case error(String)
    }

    func start(fileName: String) async -> StartError? {
        let av = AVAudioSession.sharedInstance()
        if !(await checkPermission()) { return .permission }
        do {
            try av.setCategory(AVAudioSession.Category.playAndRecord, options: .defaultToSpeaker)
            try av.setActive(true)
            let settings: [String : Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000,
                AVEncoderBitRateKey: 32000,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained,
                AVNumberOfChannelsKey: 1
            ]
            let url = getAppFilePath(fileName)
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record(forDuration: MAX_VOICE_MESSAGE_LENGTH)

            await MainActor.run {
                AppDelegate.keepScreenOn(true)
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
                    guard let time = self.audioRecorder?.currentTime else { return }
                    self.onTimer?(time)
                    if time >= MAX_VOICE_MESSAGE_LENGTH {
                        self.stop()
                        self.onFinishRecording?()
                    }
                }
            }
            return nil
        } catch let error {
            await MainActor.run {
                AppDelegate.keepScreenOn(false)
            }
            try? av.setCategory(AVAudioSession.Category.soloAmbient)
            logger.error("AudioRecorder startAudioRecording error \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }

    func stop() {
        if let recorder = audioRecorder {
            recorder.stop()
        }
        audioRecorder = nil
        if let timer = recordingTimer {
            timer.invalidate()
        }
        recordingTimer = nil
        AppDelegate.keepScreenOn(false)
        try? AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.soloAmbient)
    }

    private func checkPermission() async -> Bool {
        let av = AVAudioSession.sharedInstance()
        switch av.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                DispatchQueue.main.async {
                    av.requestRecordPermission { allowed in
                        cont.resume(returning: allowed)
                    }
                }
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
