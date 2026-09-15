// Portions of the AVAudioEngine/RTCAudioDevice bridge are adapted from
// https://github.com/mstyura/RTCAudioDevice (MIT, Copyright 2022 Yury Yaroshevich).

import AVFoundation
import Foundation
import WebRTC

@MainActor
final class XauXatRealtimeVoiceMasking: ObservableObject {
    static let shared = XauXatRealtimeVoiceMasking()

    @Published private(set) var enabled = false
    @Published private(set) var preset: XauXatVoiceMaskPreset = .veil
    @Published var failureMessage: String?

    private init() {}

    func beginCall() {
        enabled = false
        preset = .veil
        failureMessage = nil
        XauXatRealtimeAudioDevice.shared.configureMasking(enabled: false, preset: .veil)
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        failureMessage = nil
        XauXatRealtimeAudioDevice.shared.configureMasking(enabled: enabled, preset: preset)
    }

    func setPreset(_ preset: XauXatVoiceMaskPreset) {
        self.preset = preset
        failureMessage = nil
        XauXatRealtimeAudioDevice.shared.configureMasking(enabled: enabled, preset: preset)
    }

    func endCall() {
        enabled = false
        failureMessage = nil
        XauXatRealtimeAudioDevice.shared.configureMasking(enabled: false, preset: .veil)
    }

    func reportFailure(_ message: String) {
        guard enabled else { return }
        failureMessage = message
    }
}

final class XauXatRealtimeAudioDevice: NSObject, RTCAudioDevice {
    static let shared = XauXatRealtimeAudioDevice()

    private let audioSession = AVAudioSession.sharedInstance()
    private let stateQueue = DispatchQueue(label: "pt.exsoria.xauxat.realtime-audio-device")
    private var delegateStorage: RTCAudioDeviceDelegate?
    private var observers: [NSObjectProtocol] = []
    private var engineConfigurationObserver: NSObjectProtocol?
    private var audioEngine: AVAudioEngine?
    private var audioSinkNode: AVAudioSinkNode?
    private var audioSourceNode: AVAudioSourceNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var shouldPlay = false
    private var shouldRecord = false
    private var interrupted = false
    private var maskingEnabled = false
    private var maskingPreset: XauXatVoiceMaskPreset = .veil
    private var suppressInputUntil: CFTimeInterval = 0
    private var maskingPipelineFailed = false

    private var audioInputFormat: AVAudioFormat?
    private var audioOutputFormat: AVAudioFormat?
    private var cachedInputLatency: TimeInterval = 0
    private var cachedOutputLatency: TimeInterval = 0

    private var delegate: RTCAudioDeviceDelegate? {
        get { stateQueue.sync { delegateStorage } }
        set { stateQueue.sync { delegateStorage = newValue } }
    }

    private override init() {
        super.init()
    }

    func configureMasking(enabled: Bool, preset: XauXatVoiceMaskPreset) {
        stateQueue.sync {
            maskingEnabled = enabled
            maskingPreset = preset
            maskingPipelineFailed = false
            suppressInputUntil = CACurrentMediaTime() + 0.08
        }
        let update = { [weak self] in
            guard let self else { return }
            self.timePitch?.pitch = enabled ? preset.pitch : 0
        }
        if let delegate {
            delegate.dispatchAsync(update)
        } else {
            update()
        }
    }

    private func currentMaskingState() -> (enabled: Bool, suppress: Bool, failed: Bool) {
        stateQueue.sync {
            (maskingEnabled, CACurrentMediaTime() < suppressInputUntil, maskingPipelineFailed)
        }
    }

    private func reportPipelineFailure(_ message: String) {
        let shouldReport = stateQueue.sync { () -> Bool in
            guard maskingEnabled else { return false }
            maskingPipelineFailed = true
            return true
        }
        guard shouldReport else { return }
        DispatchQueue.main.async {
            XauXatRealtimeVoiceMasking.shared.reportFailure(
                NSLocalizedString(
                    "Voice masking is unavailable on the current audio route. Your microphone is muted until you disable masking or change route.",
                    comment: "real-time voice masking safe fallback"
                )
            )
        }
        logger.error("Realtime voice masking pipeline failed: \(message)")
    }

    private func shutdownEngine() {
        guard let audioEngine else { return }
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
        if audioEngine.isRunning { audioEngine.stop() }
        if let audioSinkNode {
            audioEngine.detach(audioSinkNode)
            self.audioSinkNode = nil
            delegate?.notifyAudioInputInterrupted()
        }
        if let audioSourceNode {
            audioEngine.detach(audioSourceNode)
            self.audioSourceNode = nil
            delegate?.notifyAudioOutputInterrupted()
        }
        if let timePitch {
            audioEngine.detach(timePitch)
            self.timePitch = nil
        }
        self.audioEngine = nil
    }

    private func updateEngine() {
        guard let delegate, (shouldPlay || shouldRecord), !interrupted else {
            shutdownEngine()
            return
        }

        if let audioEngine,
           !audioEngine.xauxatMatchesHardwareSampleRate(audioSession) {
            shutdownEngine()
        }

        let shouldUseVoiceProcessing = audioSession.xauxatSupportsVoiceProcessing
        if let audioEngine,
           audioEngine.outputNode.isVoiceProcessingEnabled != shouldUseVoiceProcessing {
            shutdownEngine()
        }

        let engine: AVAudioEngine
        if let audioEngine {
            engine = audioEngine
        } else {
            engine = AVAudioEngine()
            engine.isAutoShutdownEnabled = true
            do {
                if engine.outputNode.isVoiceProcessingEnabled != shouldUseVoiceProcessing {
                    try engine.outputNode.setVoiceProcessingEnabled(shouldUseVoiceProcessing)
                }
            } catch {
                reportPipelineFailure("voice processing setup: \(error.localizedDescription)")
                return
            }
            engineConfigurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.delegate?.dispatchAsync { [weak self] in
                    self?.shutdownEngine()
                    self?.updateEngine()
                }
            }
            self.audioEngine = engine
        }

        let ioUnit = engine.outputNode.auAudioUnit
        if ioUnit.isInputEnabled != shouldRecord || ioUnit.isOutputEnabled != shouldPlay {
            if engine.isRunning { engine.stop() }
            ioUnit.isInputEnabled = shouldRecord
            ioUnit.isOutputEnabled = shouldPlay
        }

        if shouldRecord {
            if audioSinkNode == nil {
                let inputFormat = engine.inputNode.outputFormat(forBus: 1)
                guard inputFormat.xauxatIsUsable else {
                    reportPipelineFailure("invalid input format")
                    return
                }
                let channels = AVAudioChannelCount(min(2, inputFormat.channelCount))
                guard let rtcRecordFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: inputFormat.sampleRate,
                    channels: channels,
                    interleaved: true
                ), let converter = XauXatRealtimeAudioConverter(from: inputFormat, to: rtcRecordFormat) else {
                    reportPipelineFailure("recording converter unavailable")
                    return
                }

                let pitchNode = AVAudioUnitTimePitch()
                let preset = stateQueue.sync { maskingPreset }
                let enabled = stateQueue.sync { maskingEnabled }
                pitchNode.pitch = enabled ? preset.pitch : 0
                pitchNode.rate = 1
                engine.attach(pitchNode)
                engine.connect(engine.inputNode, to: pitchNode, format: inputFormat)

                let deliverRecordedData = delegate.deliverRecordedData
                let renderBlock: RTCAudioDeviceRenderRecordedDataBlock = { _, _, _, frameCount, output, context in
                    guard let context else { return kAudio_ParamError }
                    let pair = context.assumingMemoryBound(
                        to: (Unmanaged<XauXatRealtimeAudioConverter>, UnsafeMutablePointer<AudioBufferList>).self
                    ).pointee
                    return pair.0.takeUnretainedValue().convert(
                        frameCount: frameCount,
                        from: pair.1,
                        to: output
                    )
                }
                let sink = AVAudioSinkNode { [weak self] timestamp, frameCount, inputData in
                    guard let self else { return noErr }
                    let masking = self.currentMaskingState()
                    if masking.enabled && (masking.suppress || masking.failed) {
                        return noErr
                    }
                    var flags: AudioUnitRenderActionFlags = []
                    var context = (Unmanaged.passUnretained(converter), inputData)
                    return deliverRecordedData(&flags, timestamp, 1, frameCount, nil, &context, renderBlock)
                }
                engine.attach(sink)
                engine.connect(pitchNode, to: sink, format: inputFormat)
                timePitch = pitchNode
                audioSinkNode = sink
                audioInputFormat = rtcRecordFormat
                cachedInputLatency = audioSession.inputLatency
                delegate.notifyAudioInputParametersChange()
            }
        } else if let audioSinkNode {
            engine.detach(audioSinkNode)
            self.audioSinkNode = nil
            if let timePitch {
                engine.detach(timePitch)
                self.timePitch = nil
            }
        }

        if shouldPlay {
            if audioSourceNode == nil {
                let outputFormat = engine.outputNode.outputFormat(forBus: 0)
                guard outputFormat.xauxatIsUsable,
                      let rtcPlayFormat = AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: outputFormat.sampleRate,
                        channels: outputFormat.channelCount,
                        interleaved: true
                      ) else {
                    reportPipelineFailure("invalid output format")
                    return
                }
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
                let getPlayoutData = delegate.getPlayoutData
                let source = AVAudioSourceNode(format: rtcPlayFormat) { silence, timestamp, frameCount, outputData in
                    var flags: AudioUnitRenderActionFlags = []
                    let result = getPlayoutData(&flags, timestamp, 0, frameCount, outputData)
                    silence.pointee = ObjCBool(flags.contains(.unitRenderAction_OutputIsSilence))
                    return result
                }
                engine.attach(source)
                engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
                audioSourceNode = source
                audioOutputFormat = rtcPlayFormat
                cachedOutputLatency = audioSession.outputLatency
                delegate.notifyAudioOutputParametersChange()
            }
        } else if let audioSourceNode {
            engine.detach(audioSourceNode)
            self.audioSourceNode = nil
        }

        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            reportPipelineFailure("engine start: \(error.localizedDescription)")
        }
    }

    private func subscribeToAudioSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: audioSession, queue: nil) { [weak self] note in
                guard let self,
                      let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType.uintValue) else { return }
                self.stateQueue.sync { self.interrupted = type == .began }
                self.delegate?.dispatchAsync { [weak self] in self?.updateEngine() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.delegate?.dispatchAsync { [weak self] in
                    self?.shutdownEngine()
                    self?.updateEngine()
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: audioSession, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.delegate?.dispatchAsync { [weak self] in
                    self?.shutdownEngine()
                    self?.updateEngine()
                }
            }
        ]
    }

    private func unsubscribeFromAudioSession() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = []
    }

    var deviceInputSampleRate: Double { audioInputFormat?.sampleRate ?? max(8_000, audioSession.sampleRate) }
    var inputIOBufferDuration: TimeInterval { max(0.005, audioSession.ioBufferDuration) }
    var inputNumberOfChannels: Int { Int(audioInputFormat?.channelCount ?? 1) }
    var inputLatency: TimeInterval { cachedInputLatency }
    var deviceOutputSampleRate: Double { audioOutputFormat?.sampleRate ?? max(8_000, audioSession.sampleRate) }
    var outputIOBufferDuration: TimeInterval { max(0.005, audioSession.ioBufferDuration) }
    var outputNumberOfChannels: Int { Int(audioOutputFormat?.channelCount ?? 1) }
    var outputLatency: TimeInterval { cachedOutputLatency }
    var isInitialized: Bool { delegate != nil }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        guard self.delegate == nil else { return false }
        self.delegate = delegate
        subscribeToAudioSession()
        return true
    }

    func terminateDevice() -> Bool {
        shouldPlay = false
        shouldRecord = false
        updateEngine()
        unsubscribeFromAudioSession()
        delegate = nil
        return true
    }

    var isPlayoutInitialized: Bool { isInitialized }
    func initializePlayout() -> Bool { isPlayoutInitialized }
    var isPlaying: Bool { shouldPlay }
    func startPlayout() -> Bool {
        shouldPlay = true
        updateEngine()
        return true
    }
    func stopPlayout() -> Bool {
        shouldPlay = false
        updateEngine()
        return true
    }

    var isRecordingInitialized: Bool { isInitialized }
    func initializeRecording() -> Bool { isRecordingInitialized }
    var isRecording: Bool { shouldRecord }
    func startRecording() -> Bool {
        shouldRecord = true
        updateEngine()
        return true
    }
    func stopRecording() -> Bool {
        shouldRecord = false
        updateEngine()
        return true
    }
}

private final class XauXatRealtimeAudioConverter {
    private var converter: AudioConverterRef?

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard from.sampleRate == to.sampleRate,
              AudioConverterNew(from.streamDescription, to.streamDescription, &converter) == noErr else {
            return nil
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    func convert(
        frameCount: AVAudioFrameCount,
        from input: UnsafePointer<AudioBufferList>,
        to output: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let converter else { return kAudio_ParamError }
        return AudioConverterConvertComplexBuffer(converter, frameCount, input, output)
    }
}

private extension AVAudioSession {
    var xauxatSupportsVoiceProcessing: Bool {
        category == .playAndRecord && (mode == .voiceChat || mode == .videoChat)
    }
}

private extension AVAudioEngine {
    func xauxatMatchesHardwareSampleRate(_ audioSession: AVAudioSession) -> Bool {
        let sampleRate = audioSession.sampleRate
        return inputNode.inputFormat(forBus: 1).sampleRate == sampleRate
            && outputNode.outputFormat(forBus: 0).sampleRate == sampleRate
    }
}

private extension AVAudioFormat {
    var xauxatIsUsable: Bool {
        sampleRate > 0 && sampleRate.isFinite && channelCount > 0
    }
}
