// Portions of the AVAudioEngine/RTCAudioDevice bridge are adapted from
// https://github.com/mstyura/RTCAudioDevice (MIT, Copyright 2022 Yury Yaroshevich).

import AVFoundation
import Foundation
import UIKit
import WebRTC

enum XauXatCallAmbience: String {
    case off, rain, traffic
}

@MainActor
final class XauXatRealtimeVoiceMasking: ObservableObject {
    static let shared = XauXatRealtimeVoiceMasking()

    @Published private(set) var enabled = false
    @Published private(set) var llvcEnabled = false
    @Published private(set) var preset: XauXatVoiceMaskPreset = .veil
    @Published private(set) var ambience: XauXatCallAmbience = .off
    @Published var failureMessage: String?
    private var activeCall: ObjectIdentifier?

    private init() {}

    func beginCall(_ call: Call) {
        activeCall = ObjectIdentifier(call)
        enabled = false
        llvcEnabled = false
        setAmbience(.off)
        preset = .veil
        failureMessage = nil
        #if DEBUG
        if call.startWithModifiedVoice {
            setLLVCEnabled(true)
            return
        }
        #endif
        XauXatRealtimeAudioDevice.shared.configureMasking(enabled: false, preset: .veil)
    }

    func setEnabled(_ enabled: Bool) {
        guard activeCall != nil else { return }
        self.enabled = enabled
        failureMessage = nil
        applySelection()
    }

    func setPreset(_ preset: XauXatVoiceMaskPreset) {
        guard activeCall != nil else { return }
        self.preset = preset
        failureMessage = nil
        applySelection()
    }

    private func applySelection() {
        llvcEnabled = enabled && preset == .stealth
        if llvcEnabled { XauXatLLVCCapture.warmUp() }
        XauXatRealtimeAudioDevice.shared.configureMasking(
            enabled: enabled && !llvcEnabled, preset: preset, llvc: llvcEnabled
        )
    }

    func setAmbience(_ ambience: XauXatCallAmbience) {
        guard activeCall != nil else { return }
        self.ambience = ambience
        XauXatRealtimeAudioDevice.shared.setAmbience(ambience)
    }

    func endCall(_ call: Call) {
        guard activeCall == ObjectIdentifier(call) else { return }
        activeCall = nil
        XauXatRealtimeAudioDevice.shared.suspendCapture()
        enabled = false
        llvcEnabled = false
        ambience = .off
        failureMessage = nil
    }

    func reportFailure(_ message: String) {
        guard enabled || llvcEnabled else { return }
        failureMessage = message
    }

    #if DEBUG
    func setLLVCEnabled(_ enabled: Bool) {
        if enabled { setPreset(.stealth) }
        setEnabled(enabled)
    }
    #endif
}

final class XauXatRealtimeAudioDevice: NSObject, RTCAudioDevice {
    static let shared = XauXatRealtimeAudioDevice()

    private struct AudioRoute: Equatable {
        struct Port: Equatable {
            let uid: String
            let dataSource: NSNumber?

            init(_ description: AVAudioSessionPortDescription) {
                uid = description.uid
                dataSource = description.selectedDataSource?.dataSourceID
            }
        }

        let inputs: [Port]
        let outputs: [Port]

        init(_ route: AVAudioSessionRouteDescription) {
            inputs = route.inputs.map(Port.init)
            outputs = route.outputs.map(Port.init)
        }
    }

    private let audioSession = AVAudioSession.sharedInstance()
    private let stateQueue = DispatchQueue(label: "pt.exsoria.xauxat.realtime-audio-device")
    private var delegateStorage: RTCAudioDeviceDelegate?
    private var observers: [NSObjectProtocol] = []
    private var engineConfigurationObserver: NSObjectProtocol?
    private var audioEngine: AVAudioEngine?
    private var engineRoute: AudioRoute?
    private var audioSinkNode: AVAudioSinkNode?
    private var captureUsesLLVC: Bool?
    private var audioSourceNode: AVAudioSourceNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var shouldPlay = false
    private var shouldRecord = false
    private var interrupted = false
    private var maskingEnabled = false
    private var captureSuspended = true
    private var maskingPreset: XauXatVoiceMaskPreset = .veil
    private var suppressInputUntil: CFTimeInterval = 0
    private var maskingPipelineFailed = false
    private var llvcEnabled = false
    private var maskingGeneration: UInt64 = 0
    private var ambience: XauXatCallAmbience = .off

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

    func configureMasking(enabled: Bool, preset: XauXatVoiceMaskPreset, llvc: Bool = false) {
        stateQueue.sync {
            captureSuspended = false
            maskingEnabled = enabled
            maskingPreset = preset
            llvcEnabled = llvc
            maskingGeneration &+= 1
            maskingPipelineFailed = false
            suppressInputUntil = CACurrentMediaTime() + 0.08
        }
        let update = { [weak self] in
            guard let self else { return }
            let current = self.stateQueue.sync { (self.maskingPreset, self.maskingEnabled, self.llvcEnabled) }
            if let captureUsesLLVC = self.captureUsesLLVC, captureUsesLLVC != current.2 {
                // Stealth receives microphone PCM directly, without the legacy
                // TimePitch converter in its live capture graph.
                self.shutdownEngine()
                self.updateEngine()
            } else {
                self.timePitch?.pitch = current.1 ? current.0.pitch : 0
            }
        }
        if let delegate {
            delegate.dispatchAsync(update)
        } else {
            update()
        }
    }

    func suspendCapture() {
        stateQueue.sync {
            captureSuspended = true
            ambience = .off
            maskingGeneration &+= 1
        }
    }

    func setAmbience(_ ambience: XauXatCallAmbience) {
        stateQueue.sync { self.ambience = ambience }
    }

    private func currentMaskingState() -> (enabled: Bool, suppress: Bool, failed: Bool, llvc: Bool, generation: UInt64, suspended: Bool, ambience: XauXatCallAmbience) {
        stateQueue.sync {
            (maskingEnabled, CACurrentMediaTime() < suppressInputUntil, maskingPipelineFailed, llvcEnabled, maskingGeneration, captureSuspended, ambience)
        }
    }

    private func reportPipelineFailure(_ message: String, generation: UInt64? = nil) {
        let shouldReport = stateQueue.sync { () -> Bool in
            guard !captureSuspended, (maskingEnabled || llvcEnabled), !maskingPipelineFailed,
                  generation == nil || generation == maskingGeneration else { return false }
            maskingPipelineFailed = true
            return true
        }
        guard shouldReport else { return }
        DispatchQueue.main.async {
            if let generation, self.currentMaskingState().generation != generation { return }
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
            captureUsesLLVC = nil
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
        engineRoute = nil
    }

    private func updateEngine() {
        guard let delegate, (shouldPlay || shouldRecord), !interrupted else {
            shutdownEngine()
            return
        }

        if let engineRoute, engineRoute != AudioRoute(audioSession.currentRoute) {
            XauXatCallTiming.mark("audio.engine.rebuild.route_changed")
            shutdownEngine()
        }

        if let audioEngine {
            let inputChanged = shouldRecord && audioSinkNode != nil && {
                let format = audioEngine.inputNode.outputFormat(forBus: 1)
                return audioInputFormat?.sampleRate != format.sampleRate
                    || audioInputFormat?.channelCount != min(2, format.channelCount)
            }()
            let outputChanged = shouldPlay && audioSourceNode != nil && {
                let format = audioEngine.outputNode.outputFormat(forBus: 0)
                return audioOutputFormat?.sampleRate != format.sampleRate
                    || audioOutputFormat?.channelCount != format.channelCount
            }()
            if inputChanged || outputChanged {
                XauXatCallTiming.mark("audio.engine.rebuild.format")
                shutdownEngine()
            }
        }

        let shouldUseVoiceProcessing = audioSession.xauxatSupportsVoiceProcessing
        if let audioEngine,
           audioEngine.outputNode.isVoiceProcessingEnabled != shouldUseVoiceProcessing {
            XauXatCallTiming.mark("audio.engine.rebuild.voice_processing")
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
            ) { [weak self, weak engine] _ in
                guard let self else { return }
                self.delegate?.dispatchAsync { [weak self, weak engine] in
                    guard let self, let engine, self.audioEngine === engine else { return }
                    self.updateEngine()
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

                let captureConfiguration = stateQueue.sync { () -> (Bool, UInt64) in
                    maskingGeneration &+= 1
                    maskingPipelineFailed = false
                    suppressInputUntil = CACurrentMediaTime() + 0.08
                    return (llvcEnabled, maskingGeneration)
                }
                let usesLLVC = captureConfiguration.0
                DispatchQueue.main.async {
                    let current = self.currentMaskingState()
                    if current.generation == captureConfiguration.1 && !current.failed {
                        XauXatRealtimeVoiceMasking.shared.failureMessage = nil
                    }
                }
                var pitchNode: AVAudioUnitTimePitch?
                if !usesLLVC {
                    let node = AVAudioUnitTimePitch()
                    let (preset, enabled) = stateQueue.sync { (maskingPreset, maskingEnabled) }
                    node.pitch = enabled ? preset.pitch : 0
                    node.rate = 1
                    engine.attach(node)
                    engine.connect(engine.inputNode, to: node, format: inputFormat)
                    pitchNode = node
                }

                let deliverRecordedData = delegate.deliverRecordedData
                let ambienceMixer = XauXatCallAmbienceMixer(sampleRate: inputFormat.sampleRate)
                let llvc: XauXatLLVCCapture?
                if usesLLVC {
                    llvc = XauXatLLVCCapture(format: inputFormat, channels: Int(channels)) { [weak self] generation, message in
                        self?.reportPipelineFailure(message, generation: generation)
                    }
                } else {
                    llvc = nil
                }
                let renderBlock: RTCAudioDeviceRenderRecordedDataBlock = { [weak self] _, _, _, frameCount, output, context in
                    guard let context else { return kAudio_ParamError }
                    let input = context.assumingMemoryBound(
                        to: (UnsafeMutablePointer<AudioBufferList>, XauXatCallAmbience, UInt64).self
                    ).pointee
                    let result = converter.convert(
                        frameCount: frameCount,
                        from: input.0,
                        to: output
                    )
                    if result == noErr {
                        ambienceMixer.mix(into: output, frames: Int(frameCount), selection: input.1)
                    }
                    // WebRTC can pull this block after a mode change was
                    // requested. Never return PCM from the previous generation.
                    if self?.currentMaskingState().generation != input.2 {
                        for buffer in UnsafeMutableAudioBufferListPointer(output) {
                            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                        }
                    }
                    return result
                }
                let sink = AVAudioSinkNode { [weak self] timestamp, frameCount, inputData in
                    guard let self else { return noErr }
                    let masking = self.currentMaskingState()
                    guard !masking.suspended else { return noErr }
                    // Configuration is published before the delegate rebuilds
                    // the graph. Drop frames from the previous processing path.
                    guard masking.llvc == usesLLVC else { return noErr }
                    var flags: AudioUnitRenderActionFlags = []
                    if masking.llvc {
                        guard frameCount > 0, !masking.suppress, !masking.failed else { return noErr }
                        guard var samples = llvc?.render(inputData, count: Int(frameCount), generation: masking.generation) else {
                            self.reportPipelineFailure("LLVC capture format is unsupported", generation: masking.generation)
                            return noErr
                        }
                        ambienceMixer.mix(into: &samples, frames: Int(frameCount), selection: masking.ambience)
                        guard self.currentMaskingState().generation == masking.generation else { return noErr }
                        return deliverRecordedData(&flags, timestamp, 1, frameCount, &samples, nil, nil)
                    }
                    if masking.enabled && (masking.suppress || masking.failed) {
                        return noErr
                    }
                    var context = (inputData, masking.ambience, masking.generation)
                    return deliverRecordedData(&flags, timestamp, 1, frameCount, nil, &context, renderBlock)
                }
                engine.attach(sink)
                if let pitchNode {
                    engine.connect(pitchNode, to: sink, format: inputFormat)
                } else {
                    engine.connect(engine.inputNode, to: sink, format: inputFormat)
                }
                timePitch = pitchNode
                audioSinkNode = sink
                captureUsesLLVC = usesLLVC
                audioInputFormat = rtcRecordFormat
                cachedInputLatency = audioSession.inputLatency
                delegate.notifyAudioInputParametersChange()
            }
        } else if let audioSinkNode {
            engine.detach(audioSinkNode)
            self.audioSinkNode = nil
            captureUsesLLVC = nil
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
            engineRoute = AudioRoute(audioSession.currentRoute)
            if XauXatCallTiming.enabled {
                XauXatCallTiming.mark("audio.engine.started.capture=\(shouldRecord).playout=\(shouldPlay)")
            }
        } catch {
            XauXatCallTiming.mark("audio.engine.failed")
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
                guard let delegate = self.delegate else { return }
                delegate.dispatchAsync { [weak self, weak delegate] in
                    guard let self, let delegate, self.delegate === delegate else { return }
                    self.interrupted = type == .began
                    self.updateEngine()
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: nil) { [weak self] _ in
                guard let self else { return }
                // The session can post route notifications without changing devices.
                self.delegate?.dispatchAsync { [weak self] in
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
        interrupted = false
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

// Owned by the capture callback. Assets load before the audio engine starts.
final class XauXatCallAmbienceMixer {
    private static let rain = samples(named: "CallAmbienceRain")
    private static let traffic = samples(named: "CallAmbienceTraffic")
    private let rainSamples: [Int16]
    private let trafficSamples: [Int16]
    private let step: Double
    private let fadeStep: Float
    private var phase = 0.0
    private var rainGain: Float = 0
    private var trafficGain: Float = 0

    init(sampleRate: Double) {
        rainSamples = Self.rain
        trafficSamples = Self.traffic
        step = 16_000 / sampleRate
        fadeStep = Float(1 / (0.02 * sampleRate))
    }

    func mix(into buffer: UnsafeMutablePointer<AudioBufferList>, frames: Int, selection: XauXatCallAmbience) {
        guard selection != .off || rainGain > 0 || trafficGain > 0,
              frames > 0, buffer.pointee.mNumberBuffers == 1,
              let data = buffer.pointee.mBuffers.mData else { return }
        let channels = Int(buffer.pointee.mBuffers.mNumberChannels)
        guard channels > 0, frames <= Int(buffer.pointee.mBuffers.mDataByteSize) / (channels * MemoryLayout<Int16>.stride) else { return }
        let samples = data.assumingMemoryBound(to: Int16.self)
        let length = max(rainSamples.count, trafficSamples.count)
        guard length > 0 else { return }
        for frame in 0..<frames {
            let noise = Int(nextSample(selection: selection, length: length))
            for channel in 0..<channels {
                let index = frame * channels + channel
                samples[index] = Int16(clamping: Int(samples[index]) + noise)
            }
        }
    }

    func mix(into buffer: AVAudioPCMBuffer, selection: XauXatCallAmbience, remainingFrames: AVAudioFramePosition) throws {
        let length = max(rainSamples.count, trafficSamples.count)
        guard (selection == .rain ? !rainSamples.isEmpty : !trafficSamples.isEmpty),
              let channels = buffer.floatChannelData, !buffer.format.isInterleaved else {
            throw XauXatVoiceMaskError.renderingFailed
        }
        let frames = Int(buffer.frameLength)
        for frame in 0..<frames {
            let fadeOut = min(1, max(0, Float(remainingFrames - AVAudioFramePosition(frame + 1)) * fadeStep))
            let noise = nextSample(selection: selection, length: length) / 32_768 * fadeOut
            for channel in 0..<Int(buffer.format.channelCount) {
                channels[channel][frame] = min(1, max(-1, channels[channel][frame] + noise))
            }
        }
    }

    private func nextSample(selection: XauXatCallAmbience, length: Int) -> Float {
        rainGain = nextGain(rainGain, selected: selection == .rain)
        trafficGain = nextGain(trafficGain, selected: selection == .traffic)
        let noise = sample(rainSamples, gain: rainGain) + sample(trafficSamples, gain: trafficGain)
        phase += step
        if phase >= Double(length) { phase.formTruncatingRemainder(dividingBy: Double(length)) }
        return noise
    }

    private func nextGain(_ gain: Float, selected: Bool) -> Float {
        selected ? min(1, gain + fadeStep) : max(0, gain - fadeStep)
    }

    private func sample(_ samples: [Int16], gain: Float) -> Float {
        guard gain > 0, !samples.isEmpty else { return 0 }
        let offset = Int(phase)
        let index = offset % samples.count
        let first = Float(samples[index])
        let next = Float(samples[(index + 1) % samples.count])
        return (first + (next - first) * Float(phase - Double(offset))) * gain
    }

    private static func samples(named name: String) -> [Int16] {
        guard let data = NSDataAsset(name: name)?.data, data.count.isMultiple(of: MemoryLayout<Int16>.stride) else { return [] }
        var samples = [Int16](repeating: 0, count: data.count / MemoryLayout<Int16>.stride)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples
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

private extension AVAudioFormat {
    var xauxatIsUsable: Bool {
        sampleRate > 0 && sampleRate.isFinite && channelCount > 0
    }
}
