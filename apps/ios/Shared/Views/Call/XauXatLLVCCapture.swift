import AVFoundation
import CoreML
import Foundation

final class XauXatLLVCCapture {
    private static let chunk = 208
    private static let context = 32
    private static let sendCapacity = 8192
    private static let inputNames = ["encoder", "decoder", "synthesis", "prenet"]
    private static let outputNames = ["encoder_next", "decoder_next", "synthesis_next", "prenet_next"]
    private static let model = Result {
        guard let url = Bundle.main.url(forResource: "XauXatLLVC", withExtension: "mlmodelc") else {
            throw Failure.model
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        return try MLModel(contentsOf: url, configuration: config)
    }

    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async { _ = model }
    }

    private enum Failure: LocalizedError {
        case model, samples, overrun

        var errorDescription: String? {
            switch self {
            case .model: return "LLVC model is missing from the app bundle."
            case .samples: return "LLVC did not return the expected number of valid audio samples."
            case .overrun: return "LLVC could not keep up with microphone capture."
            }
        }
    }

    private let lock = NSLock()
    private let work: DispatchSourceUserDataAdd
    private let onFailure: (UInt64, String) -> Void
    private let hardwareChunk: Int
    private let channels: Int
    private let capture: AVAudioPCMBuffer
    private let reduced: AVAudioPCMBuffer
    private let converted: AVAudioPCMBuffer
    private let uplink: AVAudioPCMBuffer
    private let downsample: AVAudioConverter?
    private let upsample: AVAudioConverter
    private let send: UnsafeMutablePointer<Int16>
    private var input: Ring<Float>
    private var output: Ring<Int16>
    private var generation: UInt64?
    private var ready = false
    private var primed = false
    private var failed = false

    // Only the worker accesses the model inputs and streaming state.
    private var workerGeneration: UInt64?
    private var state: [String: MLMultiArray] = [:]
    private var window: MLMultiArray?
    private var context = [Float](repeating: 0, count: XauXatLLVCCapture.context)

    init?(format: AVAudioFormat, channels: Int, onFailure: @escaping (UInt64, String) -> Void) {
        let rate = format.sampleRate
        // shortcut: cover the built-in 48 kHz route and 16 kHz PCM, extend after the first device test.
        guard (rate == 48000 || rate == 16000), format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let hardware = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let model = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let uplinkFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true) else {
            return nil
        }
        let frames = Int(rate / 16000) * Self.chunk
        guard let capture = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: AVAudioFrameCount(frames)),
              let reduced = AVAudioPCMBuffer(pcmFormat: model, frameCapacity: AVAudioFrameCount(Self.chunk)),
              let converted = AVAudioPCMBuffer(pcmFormat: model, frameCapacity: AVAudioFrameCount(Self.chunk)),
              let uplink = AVAudioPCMBuffer(pcmFormat: uplinkFormat, frameCapacity: AVAudioFrameCount(frames)),
              let upsample = AVAudioConverter(from: model, to: uplinkFormat) else { return nil }
        let downsample = rate == 16000 ? nil : AVAudioConverter(from: hardware, to: model)
        guard rate == 16000 || downsample != nil else { return nil }
        downsample?.primeMethod = .none
        upsample.primeMethod = .none
        self.capture = capture
        self.reduced = reduced
        self.converted = converted
        self.uplink = uplink
        self.downsample = downsample
        self.upsample = upsample
        self.hardwareChunk = frames
        self.channels = channels
        self.onFailure = onFailure
        send = UnsafeMutablePointer<Int16>.allocate(capacity: Self.sendCapacity)
        input = Ring(capacity: frames * 8, zero: 0)
        output = Ring(capacity: frames * 8, zero: 0)
        work = DispatchSource.makeUserDataAddSource(queue: DispatchQueue(label: "pt.exsoria.xauxat.llvc", qos: .userInitiated))
        work.setEventHandler { [weak self] in self?.drain() }
        work.activate()
    }

    deinit {
        work.cancel()
        send.deallocate()
    }

    func render(_ buffers: UnsafePointer<AudioBufferList>, count: Int, generation next: UInt64) -> AudioBufferList? {
        guard count > 0, count <= Self.sendCapacity / channels,
              buffers.pointee.mNumberBuffers > 0,
              buffers.pointee.mBuffers.mDataByteSize >= count * MemoryLayout<Float>.stride,
              let samples = buffers.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return nil }
        let sampleCount = count * channels
        send.update(repeating: 0, count: sampleCount)
        if lock.try() {
            if generation != next {
                generation = next
                ready = false
                primed = false
                failed = false
                input.clear()
                output.clear()
            }
            if ready && !failed {
                if output.count >= (primed ? count : max(count, 2 * hardwareChunk)) {
                    primed = true
                    for frame in 0..<count {
                        let sample = output.pop()
                        for channel in 0..<channels { send[frame * channels + channel] = sample }
                    }
                } else {
                    primed = false
                }
                if input.space >= count {
                    for index in 0..<count { input.push(samples[index]) }
                } else {
                    failed = true
                    send.update(repeating: 0, count: sampleCount)
                }
            }
            lock.unlock()
            work.add(data: 1)
        }
        return AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(sampleCount * MemoryLayout<Int16>.stride), mData: send
        ))
    }

    private func drain() {
        lock.lock()
        let active = generation
        let overrun = failed
        lock.unlock()
        guard let active else { return }
        do {
            if overrun { throw Failure.overrun }
            let model = try Self.model.get()
            if workerGeneration != active {
                try reset(model)
                workerGeneration = active
                lock.lock()
                if generation == active { ready = true }
                lock.unlock()
            }
            while true {
                lock.lock()
                guard generation == active, !failed, input.count >= hardwareChunk else {
                    lock.unlock()
                    return
                }
                let source = capture.floatChannelData![0]
                for index in 0..<hardwareChunk { source[index] = input.pop() }
                lock.unlock()
                capture.frameLength = AVAudioFrameCount(hardwareChunk)
                try process(model)
                let samples = uplink.int16ChannelData![0]
                lock.lock()
                if generation == active && !failed {
                    guard output.space >= hardwareChunk else {
                        lock.unlock()
                        throw Failure.overrun
                    }
                    for index in 0..<hardwareChunk { output.push(samples[index]) }
                }
                lock.unlock()
            }
        } catch {
            lock.lock()
            let isCurrent = generation == active
            if isCurrent {
                generation = nil
                ready = false
                failed = true
            }
            lock.unlock()
            if isCurrent { onFailure(active, error.localizedDescription) }
        }
    }

    private func reset(_ model: MLModel) throws {
        state.removeAll(keepingCapacity: true)
        for name in ["audio"] + Self.inputNames {
            guard let shape = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape else {
                throw Failure.model
            }
            let array = try MLMultiArray(shape: shape, dataType: .float32)
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            pointer.update(repeating: 0, count: array.count)
            if name == "audio" { window = array } else { state[name] = array }
        }
        context = [Float](repeating: 0, count: Self.context)
        downsample?.reset()
        upsample.reset()
    }

    private func process(_ model: MLModel) throws {
        if let downsample {
            try resample(downsample, from: capture, to: reduced, frames: Self.chunk)
        }
        let samples = (downsample == nil ? capture : reduced).floatChannelData![0]
        try convertVoice(model, samples: samples, destination: converted.floatChannelData![0])
        converted.frameLength = AVAudioFrameCount(Self.chunk)
        try resample(upsample, from: converted, to: uplink, frames: hardwareChunk)
    }

    private func convertVoice(_ model: MLModel, samples: UnsafePointer<Float>, destination: UnsafeMutablePointer<Float>) throws {
        guard let window else { throw Failure.model }
        let audio = window.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<Self.context { audio[index] = context[index] }
        audio.advanced(by: Self.context).update(from: samples, count: Self.chunk)
        for index in 0..<Self.context { context[index] = samples[Self.chunk - Self.context + index] }

        var features = state
        features["audio"] = window
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        guard let result = prediction.featureValue(for: "converted")?.multiArrayValue,
              result.dataType == .float32, result.count == Self.chunk, result.strides.count == 3 else { throw Failure.samples }
        let values = result.dataPointer.assumingMemoryBound(to: Float.self)
        let stride = result.strides[2].intValue
        for index in 0..<Self.chunk {
            let value = values[index * stride]
            guard value.isFinite else { throw Failure.samples }
            destination[index] = xauXatBoostMaskedVoice(value)
        }
        for (input, output) in zip(Self.inputNames, Self.outputNames) {
            guard let value = prediction.featureValue(for: output)?.multiArrayValue else { throw Failure.model }
            state[input] = value
        }
    }

    static func renderRecording(_ source: AVAudioFile, to output: AVAudioFile, ambience: XauXatCallAmbience) throws {
        let format = source.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1,
              format.commonFormat == .pcmFormatFloat32,
              let processor = XauXatLLVCCapture(format: format, channels: 1, onFailure: { _, _ in }),
              let input = processor.capture.floatChannelData?[0],
              let destination = processor.converted.floatChannelData?[0] else { throw Failure.samples }

        let model = try Self.model.get()
        try processor.reset(model)
        let mixer = ambience == .off ? nil : XauXatCallAmbienceMixer(sampleRate: format.sampleRate)
        var remaining = source.length
        while remaining > 0 {
            input.update(repeating: 0, count: Self.chunk)
            try source.read(into: processor.capture, frameCount: AVAudioFrameCount(min(Int64(Self.chunk), remaining)))
            let frames = processor.capture.frameLength
            guard frames > 0 else { throw Failure.samples }
            if frames < Self.chunk {
                input.advanced(by: Int(frames)).update(repeating: 0, count: Self.chunk - Int(frames))
            }
            try processor.convertVoice(model, samples: input, destination: destination)
            processor.converted.frameLength = frames
            try mixer?.mix(into: processor.converted, selection: ambience, remainingFrames: remaining)
            try output.write(from: processor.converted)
            remaining -= Int64(frames)
        }
    }

    private func resample(_ converter: AVAudioConverter, from input: AVAudioPCMBuffer, to output: AVAudioPCMBuffer, frames: Int) throws {
        output.frameLength = 0
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            status.pointee = provided ? .noDataNow : .haveData
            if provided { return nil }
            provided = true
            return input
        }
        if let error { throw error }
        guard status != .error, output.frameLength == frames else { throw Failure.samples }
    }

    private struct Ring<Sample> {
        private var values: [Sample]
        private var head = 0
        private var tail = 0
        private(set) var count = 0
        var space: Int { values.count - count }

        init(capacity: Int, zero: Sample) { values = [Sample](repeating: zero, count: capacity) }

        mutating func clear() {
            head = 0
            tail = 0
            count = 0
        }

        mutating func push(_ sample: Sample) {
            values[tail] = sample
            tail = (tail + 1) % values.count
            count += 1
        }

        mutating func pop() -> Sample {
            let sample = values[head]
            head = (head + 1) % values.count
            count -= 1
            return sample
        }
    }
}
