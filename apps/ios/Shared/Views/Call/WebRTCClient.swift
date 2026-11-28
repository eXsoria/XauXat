//
// Created by Avently on 09.02.2023.
// Copyright (c) 2023 SimpleX Chat. All rights reserved.
//
// Spec: spec/services/calls.md

import WebRTC
import LZString
import SwiftUI
import SimpleXChat

// Spec: spec/services/calls.md#WebRTCClient
final class WebRTCClient: NSObject, RTCVideoViewDelegate, RTCFrameEncryptorDelegate, RTCFrameDecryptorDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        videoEncoderFactory.preferredCodec = RTCVideoCodecInfo(name: kRTCVp8CodecName)
        return RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory,
            audioDevice: XauXatRealtimeAudioDevice.shared
        )
    }()
    private static let ivTagBytes: Int = 28
    private static let enableEncryption: Bool = true
    private var chat_ctrl = getChatCtrl()
    #if DEBUG
    private var audioTimingTask: Task<Void, Never>?
    #endif

    struct Call {
        var connection: RTCPeerConnection
        var iceCandidates: IceCandidates
        var localCamera: RTCVideoCapturer?
        var localAudioTrack: RTCAudioTrack?
        var localVideoTrack: RTCVideoTrack?
        var remoteAudioTrack: RTCAudioTrack?
        var remoteVideoTrack: RTCVideoTrack?
        var remoteScreenAudioTrack: RTCAudioTrack?
        var remoteScreenVideoTrack: RTCVideoTrack?
        var device: AVCaptureDevice.Position
        var aesKey: String?
        var frameEncryptor: RTCFrameEncryptor?
        var frameDecryptor: RTCFrameDecryptor?
        var peerHasOldVersion: Bool
    }

    struct NotConnectedCall {
        var audioTrack: RTCAudioTrack?
        var localCameraAndTrack: (RTCVideoCapturer, RTCVideoTrack)?
        var device: AVCaptureDevice.Position = .front
    }

    final class IceCandidates {
        private let lock = NSLock()
        private var candidates: [RTCIceCandidate] = []
        private let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        func append(_ candidate: RTCIceCandidate) {
            lock.lock()
            candidates.append(candidate)
            lock.unlock()
            signal()
        }

        func signal() { updates.continuation.yield(()) }
        func finish() { updates.continuation.finish() }

        private func takeBatch() -> [RTCIceCandidate] {
            lock.lock()
            defer { lock.unlock() }
            let batch = candidates
            candidates.removeAll()
            return batch
        }

        func initial() async -> [RTCIceCandidate] {
            // Slow TURN gathering must not block SDP. Later candidates travel as call extras.
            let timeout = Task {
                try await Task.sleep(nanoseconds: 750_000_000)
                signal()
            }
            defer { timeout.cancel() }
            var iterator = updates.stream.makeAsyncIterator()
            _ = await iterator.next()
            return takeBatch()
        }

        func sendRemaining(_ send: ([RTCIceCandidate]) async -> Void) async {
            for await _ in updates.stream {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                let batch = takeBatch()
                if !batch.isEmpty { await send(batch) }
            }
        }
    }

    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    private static let audioQueue = DispatchQueue(label: "pt.exsoria.xauxat.audio")
    private static var nativeAudioActive = false
    private static weak var audioSessionOwner: WebRTCClient?
    private let usesCallKitAudio: Bool
    // Serialized on audioQueue. Each app activation is balanced once, even across consecutive calls.
    private static var activatedAudioSession = false
    private let captureLock = NSLock()
    private weak var ownedAudioTrack: RTCAudioTrack?
    private var captureEnded = false
    private var captureAllowed = true
    private var sendCallResponse: (WVAPIMessage) async -> Void
    var activeCall: Call?
    var notConnectedCall: NotConnectedCall?
    private var localRendererAspectRatio: Binding<CGFloat?>

    var cameraRenderers: [RTCVideoRenderer] = []
    var screenRenderers: [RTCVideoRenderer] = []

    @available(*, unavailable)
    override init() {
        fatalError("Unimplemented")
    }

    required init(_ sendCallResponse: @escaping (WVAPIMessage) async -> Void, _ localRendererAspectRatio: Binding<CGFloat?>, usesCallKitAudio: Bool) {
        self.usesCallKitAudio = usesCallKitAudio
        self.sendCallResponse = sendCallResponse
        self.localRendererAspectRatio = localRendererAspectRatio
        super.init()
        claimAudioSession()
    }

    private func claimAudioSession() {
        Self.audioQueue.async {
            Self.audioSessionOwner = self
            self.rtcAudioSession.useManualAudio = self.usesCallKitAudio
            self.rtcAudioSession.isAudioEnabled = !self.usesCallKitAudio || Self.nativeAudioActive
            if self.usesCallKitAudio { self.releaseAppAudioActivation() }
        }
    }

    static var callKitAudioActive: Bool { audioQueue.sync { nativeAudioActive } }

    static func callKitAudioChanged(_ session: AVAudioSession, active: Bool) -> Bool {
        audioQueue.sync {
            let rtc = RTCAudioSession.sharedInstance()
            if nativeAudioActive != active {
                nativeAudioActive = active
                if active { rtc.audioSessionDidActivate(session) } else { rtc.audioSessionDidDeactivate(session) }
            }
            guard audioSessionOwner?.usesCallKitAudio != false else { return false }
            rtc.isAudioEnabled = active
            return true
        }
    }

    let defaultIceServers: [WebRTC.RTCIceServer] = [
        WebRTC.RTCIceServer(urlStrings: ["stuns:stun.simplex.im:443"]),
        //WebRTC.RTCIceServer(urlStrings: ["turns:turn.simplex.im:443?transport=udp"], username: "private2", credential: "Hxuq2QxUjnhj96Zq2r4HjqHRj"),
        WebRTC.RTCIceServer(urlStrings: ["turns:turn.simplex.im:443?transport=tcp"], username: "private2", credential: "Hxuq2QxUjnhj96Zq2r4HjqHRj"),
    ]

    // Spec: spec/services/calls.md#initializeCall
    func initializeCall(_ iceServers: [WebRTC.RTCIceServer]?, _ mediaType: CallMediaType, _ aesKey: String?, _ relay: Bool?) -> Call {
        let connection = createPeerConnection(iceServers ?? getWebRTCIceServers() ?? defaultIceServers, relay)
        connection.delegate = self
        let device = notConnectedCall?.device ?? .front
        var localCamera: RTCVideoCapturer? = nil
        var localAudioTrack: RTCAudioTrack? = nil
        var localVideoTrack: RTCVideoTrack? = nil
        if let localCameraAndTrack = notConnectedCall?.localCameraAndTrack {
            (localCamera, localVideoTrack) = localCameraAndTrack
        } else if notConnectedCall == nil && mediaType == .video {
            (localCamera, localVideoTrack) = createVideoTrackAndStartCapture(device)
        }
        if let audioTrack = notConnectedCall?.audioTrack {
            localAudioTrack = audioTrack
        } else if notConnectedCall == nil {
            localAudioTrack = createAudioTrack()
        }
        notConnectedCall?.localCameraAndTrack = nil
        notConnectedCall?.audioTrack = nil

        var frameEncryptor: RTCFrameEncryptor? = nil
        var frameDecryptor: RTCFrameDecryptor? = nil
        if aesKey != nil {
            let encryptor = RTCFrameEncryptor.init(sizeChange: Int32(WebRTCClient.ivTagBytes))
            encryptor.delegate = self
            frameEncryptor = encryptor

            let decryptor = RTCFrameDecryptor.init(sizeChange: -Int32(WebRTCClient.ivTagBytes))
            decryptor.delegate = self
            frameDecryptor = decryptor
        }
        return Call(
            connection: connection,
            iceCandidates: IceCandidates(),
            localCamera: localCamera,
            localAudioTrack: localAudioTrack,
            localVideoTrack: localVideoTrack,
            device: device,
            aesKey: aesKey,
            frameEncryptor: frameEncryptor,
            frameDecryptor: frameDecryptor,
            peerHasOldVersion: false
        )
    }

    // Spec: spec/services/calls.md#createPeerConnection
    func createPeerConnection(_ iceServers: [WebRTC.RTCIceServer], _ relay: Bool?) -> RTCPeerConnection {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])

        guard let connection = WebRTCClient.factory.peerConnection(
            with: getCallConfig(iceServers, relay),
            constraints: constraints, delegate: nil
        )
        else {
            fatalError("Unable to create RTCPeerConnection")
        }
        return connection
    }

    func getCallConfig(_ iceServers: [WebRTC.RTCIceServer], _ relay: Bool?) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = relay == true ? .relay : .all
        // Allows to wait 30 sec before `failing` connection if the answer from remote side is not received in time
        config.iceInactiveTimeout = 30_000
        return config
    }

    // Spec: spec/services/calls.md#addIceCandidates
    func addIceCandidates(_ connection: RTCPeerConnection, _ remoteIceCandidates: [RTCIceCandidate]) {
        remoteIceCandidates.forEach { candidate in
            connection.add(candidate.toWebRTCCandidate()) { error in
                if let error = error {
                    logger.error("Adding candidate error \(error)")
                }
            }
        }
    }

    // Spec: spec/services/calls.md#sendCallCommand
    func sendCallCommand(command: WCallCommand) async {
        var resp: WCallResponse? = nil
        let pc = activeCall?.connection
        switch command {
        case let .capabilities(media): // outgoing
            let localCameraAndTrack: (RTCVideoCapturer, RTCVideoTrack)? = media == .video
            ? createVideoTrackAndStartCapture(.front)
            : nil
            notConnectedCall = NotConnectedCall(audioTrack: createAudioTrack(), localCameraAndTrack: localCameraAndTrack, device: .front)
            resp = .capabilities(capabilities: CallCapabilities(encryption: WebRTCClient.enableEncryption))
        case let .start(media: media, aesKey, iceServers, relay): // incoming
            logger.debug("starting incoming call - create webrtc session")
            if activeCall != nil { endCall() }
            let encryption = WebRTCClient.enableEncryption
            let call = initializeCall(iceServers?.toWebRTCIceServers(), media, encryption ? aesKey : nil, relay)
            activeCall = call
            setupLocalTracks(true, call)
            let (offer, error) = await call.connection.offer()
            if let offer = offer {
                setupEncryptionForLocalTracks(call)
                resp = .offer(
                    offer: compressToBase64(input: encodeJSON(CustomRTCSessionDescription(type: offer.type.toSdpType(), sdp: offer.sdp))),
                    iceCandidates: compressToBase64(input: encodeJSON(await call.iceCandidates.initial())),
                    capabilities: CallCapabilities(encryption: encryption)
                )
            } else {
                resp = .error(message: "offer error: \(error?.localizedDescription ?? "unknown error")")
            }
        case let .offer(offer, iceCandidates, media, aesKey, iceServers, relay): // outgoing
            if activeCall != nil {
                resp = .error(message: "accept: call already started")
            } else if !WebRTCClient.enableEncryption && aesKey != nil {
                resp = .error(message: "accept: encryption is not supported")
            } else if let offer: CustomRTCSessionDescription = decodeJSON(decompressFromBase64(input: offer)),
                      let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)) {
                let call = initializeCall(iceServers?.toWebRTCIceServers(), media, WebRTCClient.enableEncryption ? aesKey : nil, relay)
                activeCall = call
                let pc = call.connection
                if let type = offer.type, let sdp = offer.sdp {
                    if (try? await pc.setRemoteDescription(RTCSessionDescription(type: type.toWebRTCSdpType(), sdp: sdp))) != nil {
                        setupLocalTracks(false, call)
                        setupEncryptionForLocalTracks(call)
                        pc.transceivers.forEach { transceiver in
                            transceiver.setDirection(.sendRecv, error: nil)
                        }
                        await adaptToOldVersion(pc.transceivers.count <= 2)
                        let (answer, error) = await pc.answer()
                        if let answer = answer {
                            self.addIceCandidates(pc, remoteIceCandidates)
                            resp = .answer(
                                answer: compressToBase64(input: encodeJSON(CustomRTCSessionDescription(type: answer.type.toSdpType(), sdp: answer.sdp))),
                                iceCandidates: compressToBase64(input: encodeJSON(await call.iceCandidates.initial()))
                            )
                        } else {
                            resp = .error(message: "answer error: \(error?.localizedDescription ?? "unknown error")")
                        }
                    } else {
                        resp = .error(message: "accept: remote description is not set")
                    }
                }
            }
        case let .answer(answer, iceCandidates): // incoming
            if pc == nil {
                resp = .error(message: "answer: call not started")
            } else if pc?.localDescription == nil {
                resp = .error(message: "answer: local description is not set")
            } else if pc?.remoteDescription != nil {
                resp = .error(message: "answer: remote description already set")
            } else if let answer: CustomRTCSessionDescription = decodeJSON(decompressFromBase64(input: answer)),
                      let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)),
                      let type = answer.type, let sdp = answer.sdp,
                      let pc = pc {
                if (try? await pc.setRemoteDescription(RTCSessionDescription(type: type.toWebRTCSdpType(), sdp: sdp))) != nil {
                    var currentDirection: RTCRtpTransceiverDirection = .sendOnly
                    pc.transceivers[2].currentDirection(&currentDirection)
                    await adaptToOldVersion(currentDirection == .sendOnly)
                    addIceCandidates(pc, remoteIceCandidates)
                    resp = .ok
                } else {
                    resp = .error(message: "answer: remote description is not set")
                }
            }
        case let .ice(iceCandidates):
            if let pc = pc,
               let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)) {
                addIceCandidates(pc, remoteIceCandidates)
                resp = .ok
            } else {
                resp = .error(message: "ice: call not started")
            }
        case let .media(source, enable):
            if activeCall == nil {
                resp = .error(message: "media: call not started")
            } else {
                await enableMedia(source, enable)
                resp = .ok
            }
        case .end:
            // TODO possibly, endCall should be called before returning .ok
            await sendCallResponse(.init(corrId: nil, resp: .ok, command: command))
            endCall()
        }
        if let resp = resp {
            await sendCallResponse(.init(corrId: nil, resp: resp, command: command))
        }
    }

    func sendRemainingIceCandidates(_ localCandidates: IceCandidates) async {
        guard activeCall?.iceCandidates === localCandidates else { return }
        await localCandidates.sendRemaining { candidates in
            guard self.activeCall?.iceCandidates === localCandidates else { return }
            await self.sendCallResponse(.init(
                corrId: nil,
                resp: .ice(iceCandidates: compressToBase64(input: encodeJSON(candidates))),
                command: nil))
        }
    }

    func setupMuteUnmuteListener(_ transceiver: RTCRtpTransceiver, _ track: RTCMediaStreamTrack) {
        // logger.log("Setting up mute/unmute listener in the call without encryption for mid = \(transceiver.mid)")
        Task {
            var lastBytesReceived: Int64 = 0
            // muted initially
            var mutedSeconds = 4
            while let call = self.activeCall, transceiver.receiver.track?.readyState == .live {
                let stats: RTCStatisticsReport = await call.connection.statistics(for: transceiver.receiver)
                let stat = stats.statistics.values.first(where: { stat in stat.type == "inbound-rtp"})
                if let stat {
                    //logger.debug("Stat \(stat.debugDescription)")
                    let bytes = stat.values["bytesReceived"] as! Int64
                    if bytes <= lastBytesReceived {
                        mutedSeconds += 1
                        if mutedSeconds == 3 {
                            await MainActor.run {
                                self.onMediaMuteUnmute(transceiver.mid, true)
                            }
                        }
                    } else {
                        if mutedSeconds >= 3 {
                            await MainActor.run {
                                self.onMediaMuteUnmute(transceiver.mid, false)
                            }
                        }
                        lastBytesReceived = bytes
                        mutedSeconds = 0
                    }
                }
                try? await Task.sleep(nanoseconds: 1000_000000)
            }
        }
    }

    @MainActor
    func onMediaMuteUnmute(_ transceiverMid: String?, _ mute: Bool) {
        guard let activeCall = ChatModel.shared.activeCall, activeCall.webRTCClient === self else { return }
        let source = mediaSourceFromTransceiverMid(transceiverMid)
        logger.log("Mute/unmute \(source.rawValue) track = \(mute) with mid = \(transceiverMid ?? "nil")")
        if source == .mic && activeCall.peerMediaSources.mic == mute {
            activeCall.peerMediaSources.mic = !mute
        } else if (source == .camera && activeCall.peerMediaSources.camera == mute) {
            activeCall.peerMediaSources.camera = !mute
        } else if (source == .screenAudio && activeCall.peerMediaSources.screenAudio == mute) {
            activeCall.peerMediaSources.screenAudio = !mute
        } else if (source == .screenVideo && activeCall.peerMediaSources.screenVideo == mute) {
            activeCall.peerMediaSources.screenVideo = !mute
        }
    }

    // Spec: spec/services/calls.md#enableMedia
    @MainActor
    func enableMedia(_ source: CallMediaSource, _ enable: Bool) {
        logger.debug("WebRTCClient: enabling media \(source.rawValue) \(enable)")
        if source == .camera {
            setCameraEnabled(enable)
        } else if ChatModel.shared.activeCall?.microphoneRequested == enable {
            setAudioEnabled(enable)
        }
    }

    @MainActor
    func adaptToOldVersion(_ peerHasOldVersion: Bool) {
        guard ChatModel.shared.activeCall?.webRTCClient === self else { return }
        activeCall?.peerHasOldVersion = peerHasOldVersion
        if peerHasOldVersion {
            logger.debug("The peer has an old version. Remote audio track is nil = \(self.activeCall?.remoteAudioTrack == nil), video = \(self.activeCall?.remoteVideoTrack == nil)")
            onMediaMuteUnmute("0", false)
            if activeCall?.remoteVideoTrack != nil {
                onMediaMuteUnmute("1", false)
            }
            if ChatModel.shared.activeCall?.localMediaSources.camera == true && ChatModel.shared.activeCall?.peerMediaSources.camera == false {
                logger.debug("Stopping video track for the old version")
                activeCall?.connection.senders[1].track = nil
                ChatModel.shared.activeCall?.localMediaSources.camera = false
                (activeCall?.localCamera as? RTCCameraVideoCapturer)?.stopCapture()
                activeCall?.localCamera = nil
                activeCall?.localVideoTrack = nil
            }
        }
    }

    func addLocalRenderer(_ renderer: RTCEAGLVideoView) {
        if let activeCall {
            if let track = activeCall.localVideoTrack {
                track.add(renderer)
            }
        } else if let notConnectedCall {
            if let track = notConnectedCall.localCameraAndTrack?.1 {
                track.add(renderer)
            }
        }
        // To get width and height of a frame, see videoView(videoView:, didChangeVideoSize)
        renderer.delegate = self
    }

    func removeLocalRenderer(_ renderer: RTCEAGLVideoView) {
        if let activeCall {
            if let track = activeCall.localVideoTrack {
                track.remove(renderer)
            }
        } else if let notConnectedCall {
            if let track = notConnectedCall.localCameraAndTrack?.1 {
                track.remove(renderer)
            }
        }
        renderer.delegate = nil
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        guard size.height > 0 else { return }
        localRendererAspectRatio.wrappedValue = size.width / size.height
    }

    // Spec: spec/services/calls.md#setupLocalTracks
    func setupLocalTracks(_ incomingCall: Bool, _ call: Call) {
        let pc = call.connection
        let transceivers = call.connection.transceivers
        let audioTrack = call.localAudioTrack
        let videoTrack = call.localVideoTrack

        if incomingCall {
            let micCameraInit = RTCRtpTransceiverInit()
            // streamIds required for old versions which adds tracks from stream, not from track property
            micCameraInit.streamIds = ["micCamera"]

            let screenAudioVideoInit = RTCRtpTransceiverInit()
            screenAudioVideoInit.streamIds = ["screenAudioVideo"]

            // incoming call, no transceivers yet. But they should be added in order: mic, camera, screen audio, screen video
            // mid = 0, mic
            if let audioTrack {
                pc.addTransceiver(with: audioTrack, init: micCameraInit)
            } else {
                pc.addTransceiver(of: .audio, init: micCameraInit)
            }
            // mid = 1, camera
            if let videoTrack {
                pc.addTransceiver(with: videoTrack, init: micCameraInit)
            } else {
                pc.addTransceiver(of: .video, init: micCameraInit)
            }
            // mid = 2, screenAudio
            pc.addTransceiver(of: .audio, init: screenAudioVideoInit)
            // mid = 3, screenVideo
            pc.addTransceiver(of: .video, init: screenAudioVideoInit)
        } else {
            // new version
            if transceivers.count > 2 {
                // Outgoing call. All transceivers are ready. Don't addTrack() because it will create new transceivers, replace existing (nil) tracks
                transceivers
                    .first(where: { elem in mediaSourceFromTransceiverMid(elem.mid) == .mic })?
                    .sender.track = audioTrack
                transceivers
                    .first(where: { elem in mediaSourceFromTransceiverMid(elem.mid) == .camera })?
                    .sender.track = videoTrack
            } else {
                // old version, only two transceivers
                if let audioTrack {
                    pc.add(audioTrack, streamIds: ["micCamera"])
                } else {
                    // it's important to have any track in order to be able to turn it on again (currently it's off)
                    let sender = pc.add(createAudioTrack(), streamIds: ["micCamera"])
                    sender?.track = nil
                }
                if let videoTrack {
                    pc.add(videoTrack, streamIds: ["micCamera"])
                } else {
                    // it's important to have any track in order to be able to turn it on again (currently it's off)
                    let localVideoSource = WebRTCClient.factory.videoSource()
                    let localVideoTrack = WebRTCClient.factory.videoTrack(with: localVideoSource, trackId: "video0")
                    let sender = pc.add(localVideoTrack, streamIds: ["micCamera"])
                    sender?.track = nil
                }
            }
        }
    }

    func mediaSourceFromTransceiverMid(_ mid: String?) -> CallMediaSource {
        switch mid {
        case "0":
            return .mic
        case "1":
            return .camera
        case "2":
            return .screenAudio
        case "3":
            return .screenVideo
        default:
            return .unknown
        }
    }

    // Should be called after local description set
    // Spec: spec/services/calls.md#setupEncryptionForLocalTracks
    func setupEncryptionForLocalTracks(_ call: Call) {
        if let encryptor = call.frameEncryptor {
            call.connection.senders.forEach { $0.setRtcFrameEncryptor(encryptor) }
        }
    }

    func frameDecryptor(_ decryptor: RTCFrameDecryptor, mediaType: RTCRtpMediaType, withFrame encrypted: Data) -> Data? {
        guard encrypted.count > 0 else { return nil }
        if var key: [CChar] = activeCall?.aesKey?.cString(using: .utf8),
           let pointer: UnsafeMutableRawPointer = malloc(encrypted.count) {
            memcpy(pointer, (encrypted as NSData).bytes, encrypted.count)
            let isKeyFrame = encrypted[0] & 1 == 0
            let clearTextBytesSize = mediaType.rawValue == 0 ? 1 : isKeyFrame ? 10 : 3
            logCrypto("decrypt", chat_decrypt_media(&key, pointer.advanced(by: clearTextBytesSize), Int32(encrypted.count - clearTextBytesSize)))
            return Data(bytes: pointer, count: encrypted.count - WebRTCClient.ivTagBytes)
        } else {
            return nil
        }
    }

    func frameEncryptor(_ encryptor: RTCFrameEncryptor, mediaType: RTCRtpMediaType, withFrame unencrypted: Data) -> Data? {
        guard unencrypted.count > 0 else { return nil }
        if var key: [CChar] = activeCall?.aesKey?.cString(using: .utf8),
           let pointer: UnsafeMutableRawPointer = malloc(unencrypted.count + WebRTCClient.ivTagBytes) {
            memcpy(pointer, (unencrypted as NSData).bytes, unencrypted.count)
            let isKeyFrame = unencrypted[0] & 1 == 0
            let clearTextBytesSize = mediaType.rawValue == 0 ? 1 : isKeyFrame ? 10 : 3
            logCrypto("encrypt", chat_encrypt_media(chat_ctrl, &key, pointer.advanced(by: clearTextBytesSize), Int32(unencrypted.count + WebRTCClient.ivTagBytes - clearTextBytesSize)))
            return Data(bytes: pointer, count: unencrypted.count + WebRTCClient.ivTagBytes)
        } else {
            return nil
        }
    }

    private func logCrypto(_ op: String, _ r: UnsafeMutablePointer<CChar>?) {
        if let r = r {
            let err = fromCString(r)
            if err != "" {
                logger.error("\(op) error: \(err)")
//            } else {
//                logger.debug("\(op) ok")
            }
        }
    }

    func addRemoteCameraRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteVideoTrack != nil {
            activeCall?.remoteVideoTrack?.add(renderer)
        } else {
            cameraRenderers.append(renderer)
        }
    }

    func removeRemoteCameraRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteVideoTrack != nil {
            activeCall?.remoteVideoTrack?.remove(renderer)
        } else {
            cameraRenderers.removeAll(where: { $0.isEqual(renderer) })
        }
    }

    func addRemoteScreenRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteScreenVideoTrack != nil {
            activeCall?.remoteScreenVideoTrack?.add(renderer)
        } else {
            screenRenderers.append(renderer)
        }
    }

    func removeRemoteScreenRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteScreenVideoTrack != nil {
            activeCall?.remoteScreenVideoTrack?.remove(renderer)
        } else {
            screenRenderers.removeAll(where: { $0.isEqual(renderer) })
        }
    }

    // Spec: spec/services/calls.md#startCaptureLocalVideo
    func startCaptureLocalVideo(_ device: AVCaptureDevice.Position?, _ capturer: RTCVideoCapturer?) {
#if targetEnvironment(simulator)
        guard
            let capturer = (activeCall?.localCamera ?? notConnectedCall?.localCameraAndTrack?.0) as? RTCFileVideoCapturer
        else {
            logger.error("Unable to work with a file capturer")
            return
        }
        capturer.stopCapture()
        // Drag video file named `video.mp4` to `sounds` directory in the project from any other path in filesystem
        capturer.startCapturing(fromFileNamed: "sounds/video.mp4")
#else
        guard
            let capturer = capturer as? RTCCameraVideoCapturer,
            let camera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == device })
        else {
            logger.error("Unable to find a camera or local track")
            return
        }

        let supported = RTCCameraVideoCapturer.supportedFormats(for: camera)
        let height: (AVCaptureDevice.Format) -> Int32 = { (format: AVCaptureDevice.Format) in CMVideoFormatDescriptionGetDimensions(format.formatDescription).height }
        let format = supported.first(where: { height($0) == 1280 })
                    ?? supported.first(where: { height($0) >= 480 && height($0) < 1280 })
                    ?? supported.first(where: { height($0) > 1280 })
        guard
            let format = format,
            let fps = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else {
            logger.error("Unable to find any format for camera or to choose FPS")
            return
        }

        logger.debug("Format for camera is \(format.description)")

        capturer.stopCapture()
        capturer.startCapture(with: camera,
            format: format,
            fps: Int(min(24, fps.maxFrameRate)))
#endif
    }

    private func createAudioTrack() -> RTCAudioTrack {
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = WebRTCClient.factory.audioSource(with: audioConstrains)
        let audioTrack = WebRTCClient.factory.audioTrack(with: audioSource, trackId: "audio0")
        captureLock.lock()
        defer { captureLock.unlock() }
        ownedAudioTrack?.isEnabled = false
        audioTrack.isEnabled = !captureEnded && captureAllowed
        ownedAudioTrack = audioTrack
        return audioTrack
    }

    func setCaptureAllowed(_ allowed: Bool) {
        captureLock.lock()
        defer { captureLock.unlock() }
        captureAllowed = allowed
        ownedAudioTrack?.isEnabled = !captureEnded && allowed
    }

    func stopSendingAudio() {
        captureLock.lock()
        defer { captureLock.unlock() }
        captureEnded = true
        ownedAudioTrack?.isEnabled = false
    }

    private func createVideoTrackAndStartCapture(_ device: AVCaptureDevice.Position) -> (RTCVideoCapturer, RTCVideoTrack) {
        let localVideoSource = WebRTCClient.factory.videoSource()

        #if targetEnvironment(simulator)
        let localCamera = RTCFileVideoCapturer(delegate: localVideoSource)
        #else
        let localCamera = RTCCameraVideoCapturer(delegate: localVideoSource)
        #endif

        let localVideoTrack = WebRTCClient.factory.videoTrack(with: localVideoSource, trackId: "video0")
        startCaptureLocalVideo(device, localCamera)
        return (localCamera, localVideoTrack)
    }

    // Spec: spec/services/calls.md#endCall
    func endCall() {
        if #available(iOS 16.0, *) {
            _endCall()
        } else {
            // Fixes `connection.close()` getting locked up in iOS15
            DispatchQueue.global(qos: .utility).async { self._endCall() }
        }
    }

    private func _endCall() {
        #if DEBUG
        audioTimingTask?.cancel()
        audioTimingTask = nil
        #endif
        (notConnectedCall?.localCameraAndTrack?.0 as? RTCCameraVideoCapturer)?.stopCapture()
        guard let call = activeCall else {
            audioSessionToDefaults()
            return
        }
        logger.debug("WebRTCClient: ending the call")
        activeCall = nil
        call.iceCandidates.finish()
        call.connection.close()
        call.connection.delegate = nil
        call.frameEncryptor?.delegate = nil
        call.frameDecryptor?.delegate = nil
        (call.localCamera as? RTCCameraVideoCapturer)?.stopCapture()
        audioSessionToDefaults()
    }

}


extension WebRTC.RTCPeerConnection {
    func mediaConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
    }

    func offer() async -> (RTCSessionDescription?, Error?) {
        await withCheckedContinuation { cont in
            offer(for: mediaConstraints()) { (sdp, error) in
                self.processSDP(cont, sdp, error)
            }
        }
    }

    func answer() async -> (RTCSessionDescription?, Error?)  {
        await withCheckedContinuation { cont in
            answer(for: mediaConstraints()) { (sdp, error) in
                self.processSDP(cont, sdp, error)
            }
        }
    }

    private func processSDP(_ cont: CheckedContinuation<(RTCSessionDescription?, Error?), Never>, _ sdp: RTCSessionDescription?, _ error: Error?) {
        if let sdp = sdp {
            self.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    cont.resume(returning: (nil, error))
                } else {
                    cont.resume(returning: (sdp, nil))
                }
            })
        } else {
            cont.resume(returning: (nil, error))
        }
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ connection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        logger.debug("Connection new signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ connection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger.debug("Connection did add stream")
    }

    func peerConnection(_ connection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        logger.debug("Connection did remove stream")
    }

    func peerConnectionShouldNegotiate(_ connection: RTCPeerConnection) {
        logger.debug("Connection should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track {
            DispatchQueue.main.async {
                // Doesn't work for outgoing video call (audio in video call works ok still, same as incoming call)
//                if let decryptor = self.activeCall?.frameDecryptor {
//                    transceiver.receiver.setRtcFrameDecryptor(decryptor)
//                }
                let source = self.mediaSourceFromTransceiverMid(transceiver.mid)
                switch source {
                case .mic: self.activeCall?.remoteAudioTrack = track as? RTCAudioTrack
                case .camera:
                    self.activeCall?.remoteVideoTrack = track as? RTCVideoTrack
                    self.cameraRenderers.forEach({ renderer in
                        self.activeCall?.remoteVideoTrack?.add(renderer)
                    })
                    self.cameraRenderers.removeAll()
                case .screenAudio: self.activeCall?.remoteScreenAudioTrack = track as? RTCAudioTrack
                case .screenVideo:
                    self.activeCall?.remoteScreenVideoTrack = track as? RTCVideoTrack
                    self.screenRenderers.forEach({ renderer in
                        self.activeCall?.remoteScreenVideoTrack?.add(renderer)
                    })
                    self.screenRenderers.removeAll()
                case .unknown: ()
                }
            }
            self.setupMuteUnmuteListener(transceiver, track)
        }
    }

    func peerConnection(_ connection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        debugPrint("Connection new connection state: \(newState.toString() ?? "" + newState.rawValue.description) \(connection.receivers)")

        guard let connectionStateString = newState.toString(),
              let iceConnectionStateString = connection.iceConnectionState.toString(),
              let iceGatheringStateString = connection.iceGatheringState.toString(),
              let signalingStateString = connection.signalingState.toString()
        else {
            return
        }
        if XauXatCallTiming.enabled {
            XauXatCallTiming.mark("ice.\(connectionStateString)")
        }
        // WebRTC can recover from disconnected. The chat core treats that status as a final hangup.
        guard newState != .disconnected else { return }
        Task {
            await sendCallResponse(.init(
                corrId: nil,
                resp: .connection(state: ConnectionState(
                    connectionState: connectionStateString,
                    iceConnectionState: iceConnectionStateString,
                    iceGatheringState: iceGatheringStateString,
                    signalingState: signalingStateString)
                ),
                command: nil)
            )

            switch newState {
            case .checking:
                #if DEBUG
                if XauXatCallTiming.enabled, audioTimingTask == nil {
                    audioTimingTask = Task { await Self.measureFirstAudio(connection) }
                }
                #endif
                if let frameDecryptor = activeCall?.frameDecryptor {
                    connection.receivers.forEach { $0.setRtcFrameDecryptor(frameDecryptor) }
                }
                let enableSpeaker: Bool = ChatModel.shared.activeCall?.localMediaSources.hasVideo == true
                setSpeakerEnabledAndConfigureSession(enableSpeaker)
            case .connected: sendConnectedEvent(connection)
            case .failed: endCall()
            default: ()
            }
        }
    }

    #if DEBUG
    private static func measureFirstAudio(_ connection: RTCPeerConnection) async {
        var pending: Set<String> = ["audio.source.energy", "audio.rtp.sent", "audio.rtp.received", "audio.inbound.energy"]
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while !Task.isCancelled, !pending.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
                connection.statistics { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            for stat in report.statistics.values {
                let kind = (stat.values["kind"] ?? stat.values["mediaType"]) as? String
                guard kind == "audio" else { continue }
                func markWhenPositive(_ field: String, _ stage: String) {
                    if let value = stat.values[field] as? NSNumber, value.doubleValue > 0,
                       pending.remove(stage) != nil {
                        XauXatCallTiming.mark(stage)
                    }
                }
                switch stat.type {
                case "media-source":
                    markWhenPositive("totalAudioEnergy", "audio.source.energy")
                case "outbound-rtp":
                    markWhenPositive("packetsSent", "audio.rtp.sent")
                case "inbound-rtp":
                    markWhenPositive("packetsReceived", "audio.rtp.received")
                    markWhenPositive("totalAudioEnergy", "audio.inbound.energy")
                default: break
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !Task.isCancelled, !pending.isEmpty {
            XauXatCallTiming.mark("audio.probe.timeout.missing=\(pending.sorted().joined(separator: ","))")
        }
    }
    #endif

    func peerConnection(_ connection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete, let call = activeCall, call.connection === connection {
            call.iceCandidates.signal()
        }
        logger.debug("connection new gathering state: \(newState.toString() ?? "" + newState.rawValue.description)")
    }

    func peerConnection(_ connection: RTCPeerConnection, didGenerate candidate: WebRTC.RTCIceCandidate) {
        if let call = activeCall, call.connection === connection {
            call.iceCandidates.append(candidate.toCandidate(nil, nil))
        }
    }

    func peerConnection(_ connection: RTCPeerConnection, didRemove candidates: [WebRTC.RTCIceCandidate]) {
        logger.debug("Connection did remove candidates")
    }

    func peerConnection(_ connection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ connection: RTCPeerConnection,
                        didChangeLocalCandidate local: WebRTC.RTCIceCandidate,
                        remoteCandidate remote: WebRTC.RTCIceCandidate,
                        lastReceivedMs lastDataReceivedMs: Int32,
                        changeReason reason: String) {
//        logger.debug("Connection changed candidate \(reason) \(remote.debugDescription) \(remote.description)")
    }

    func sendConnectedEvent(_ connection: WebRTC.RTCPeerConnection) {
        connection.statistics { (stats: RTCStatisticsReport) in
            stats.statistics.values.forEach { stat in
//                logger.debug("Stat \(stat.debugDescription)")
                if stat.type == "candidate-pair", stat.values["state"] as? String == "succeeded",
                   let localId = stat.values["localCandidateId"] as? String,
                   let remoteId = stat.values["remoteCandidateId"] as? String,
                   let localStats = stats.statistics[localId],
                   let remoteStats = stats.statistics[remoteId]
                {
                    Task {
                        await self.sendCallResponse(.init(
                            corrId: nil,
                            resp: .connected(connectionInfo: ConnectionInfo(
                                localCandidate: RTCIceCandidate(
                                    candidateType: RTCIceCandidateType.init(rawValue: localStats.values["candidateType"] as! String),
                                    protocol: localStats.values["protocol"] as? String,
                                    sdpMid: nil,
                                    sdpMLineIndex: nil,
                                    candidate: ""
                                ),
                                remoteCandidate: RTCIceCandidate(
                                    candidateType: RTCIceCandidateType.init(rawValue: remoteStats.values["candidateType"] as! String),
                                    protocol: remoteStats.values["protocol"] as? String,
                                    sdpMid: nil,
                                    sdpMLineIndex: nil,
                                    candidate: ""))),
                            command: nil)
                        )
                    }
                }
            }
        }
    }
}

extension WebRTCClient {
    static func isAuthorized(for type: AVMediaType) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: type)
        var isAuthorized = status == .authorized
        if status == .notDetermined {
            isAuthorized = await AVCaptureDevice.requestAccess(for: type)
        }
        return isAuthorized
    }

    static func showUnauthorizedAlert(for type: AVMediaType) {
        if type == .audio {
            AlertManager.shared.showAlert(Alert(
                title: Text("No permission to record speech"),
                message: Text("To record speech please grant permission to use Microphone."),
                primaryButton: .default(Text("Open Settings")) {
                    DispatchQueue.main.async {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                    }
                },
                secondaryButton: .cancel()
            ))
        } else if type == .video {
            AlertManager.shared.showAlert(Alert(
                title: Text("No permission to record video"),
                message: Text("To record video please grant permission to use Camera."),
                primaryButton: .default(Text("Open Settings")) {
                    DispatchQueue.main.async {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                    }
                },
                secondaryButton: .cancel()
            ))
        }
    }

    func setSpeakerEnabledAndConfigureSession( _ enabled: Bool, skipExternalDevice: Bool = false) {
        logger.debug("WebRTCClient: configuring session with speaker enabled \(enabled)")
        Self.audioQueue.async { [weak self] in
            guard let self, Self.audioSessionOwner === self else { return }
            self.rtcAudioSession.lockForConfiguration()
            defer {
                self.rtcAudioSession.unlockForConfiguration()
            }
            do {
                let hasExternalAudioDevice = self.rtcAudioSession.session.hasExternalAudioDevice()
                if enabled {
                    try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: [.defaultToSpeaker, .allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                    try self.rtcAudioSession.setMode(AVAudioSession.Mode.videoChat.rawValue)
                    if hasExternalAudioDevice && !skipExternalDevice, let preferred = self.rtcAudioSession.session.preferredInputDevice() {
                        try self.rtcAudioSession.setPreferredInput(preferred)
                    } else {
                        try self.rtcAudioSession.overrideOutputAudioPort(.speaker)
                    }
                } else {
                    try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                    try self.rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
                    try self.rtcAudioSession.overrideOutputAudioPort(.none)
                }
                if hasExternalAudioDevice && !skipExternalDevice {
                    logger.debug("WebRTCClient: configuring session with external device available, skip configuring speaker")
                }
                if !self.usesCallKitAudio, !Self.activatedAudioSession {
                    try self.rtcAudioSession.setActive(true)
                    Self.activatedAudioSession = true
                }
                logger.debug("WebRTCClient: configuring session with speaker enabled \(enabled) success")
            } catch let error {
                logger.debug("Error configuring AVAudioSession: \(error)")
            }
        }
    }

    // Called on audioQueue. CallKit owns its system activation separately.
    private func releaseAppAudioActivation() {
        guard Self.activatedAudioSession else { return }
        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }
        do {
            try rtcAudioSession.setActive(false)
            Self.activatedAudioSession = false
        } catch {
            logger.error("Error deactivating call audio: \(error)")
        }
    }

    func audioSessionToDefaults() {
        logger.debug("WebRTCClient: audioSession to defaults")
        Self.audioQueue.async {
            guard Self.audioSessionOwner === self else { return }
            self.releaseAppAudioActivation()
            Self.audioSessionOwner = nil
            self.rtcAudioSession.lockForConfiguration()
            defer { self.rtcAudioSession.unlockForConfiguration() }
            do {
                try self.rtcAudioSession.setCategory(AVAudioSession.Category.ambient.rawValue)
                try self.rtcAudioSession.setMode(AVAudioSession.Mode.default.rawValue)
                logger.debug("WebRTCClient: audioSession to defaults success")
            } catch let error {
                logger.debug("Error configuring AVAudioSession with defaults: \(error)")
            }
        }
    }

    @MainActor
    func setAudioEnabled(_ enabled: Bool) {
        guard let owner = ChatModel.shared.activeCall, owner.webRTCClient === self else { return }
        owner.microphoneRequested = enabled
        setCaptureAllowed(enabled)
        if activeCall != nil {
            activeCall?.localAudioTrack = enabled ? createAudioTrack() : nil
            activeCall?.connection.transceivers.first(where: { t in mediaSourceFromTransceiverMid(t.mid) == .mic })?.sender.track = activeCall?.localAudioTrack
        } else if notConnectedCall != nil {
            notConnectedCall?.audioTrack = enabled ? createAudioTrack() : nil
        }
        owner.updateMicrophonePermission(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    @MainActor
    func setCameraEnabled(_ enabled: Bool) {
        guard ChatModel.shared.activeCall?.webRTCClient === self else { return }
        if let call = activeCall {
            if enabled {
                if call.localVideoTrack == nil {
                    let device = activeCall?.device ?? notConnectedCall?.device ?? .front
                    let (camera, track) = createVideoTrackAndStartCapture(device)
                    activeCall?.localCamera = camera
                    activeCall?.localVideoTrack = track
                }
            } else {
                (call.localCamera as? RTCCameraVideoCapturer)?.stopCapture()
                activeCall?.localCamera = nil
                activeCall?.localVideoTrack = nil
            }
            call.connection.transceivers
                .first(where: { t in mediaSourceFromTransceiverMid(t.mid) == .camera })?
                .sender.track = activeCall?.localVideoTrack
            ChatModel.shared.activeCall?.localMediaSources.camera = activeCall?.localVideoTrack != nil
        } else if let call = notConnectedCall {
            if enabled {
                let device = activeCall?.device ?? notConnectedCall?.device ?? .front
                notConnectedCall?.localCameraAndTrack = createVideoTrackAndStartCapture(device)
            } else {
                (call.localCameraAndTrack?.0 as? RTCCameraVideoCapturer)?.stopCapture()
                notConnectedCall?.localCameraAndTrack = nil
            }
            ChatModel.shared.activeCall?.localMediaSources.camera = notConnectedCall?.localCameraAndTrack != nil
        }
    }

    func flipCamera() {
        let device = activeCall?.device ?? notConnectedCall?.device
        if activeCall != nil {
            activeCall?.device = device == .front ? .back : .front
        } else {
            notConnectedCall?.device = device == .front ? .back : .front
        }
        startCaptureLocalVideo(
            activeCall?.device ?? notConnectedCall?.device,
            (activeCall?.localCamera ?? notConnectedCall?.localCameraAndTrack?.0) as? RTCCameraVideoCapturer
        )
    }
}

extension AVAudioSession {
    func hasExternalAudioDevice() -> Bool {
        availableInputs?.allSatisfy({ $0.portType == .builtInMic }) != true
    }

    func preferredInputDevice() -> AVAudioSessionPortDescription? {
//        logger.debug("Preferred input device: \(String(describing: self.availableInputs?.filter({ $0.portType != .builtInMic })))")
        return availableInputs?.filter({ $0.portType != .builtInMic }).last
    }
}

struct CustomRTCSessionDescription: Codable {
    public var type: RTCSdpType?
    public var sdp: String?
}

enum RTCSdpType: String, Codable {
    case answer
    case offer
    case pranswer
    case rollback
}

extension RTCIceCandidate {
    func toWebRTCCandidate() -> WebRTC.RTCIceCandidate {
        WebRTC.RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: Int32(sdpMLineIndex ?? 0),
            sdpMid: sdpMid
        )
    }
}

extension WebRTC.RTCIceCandidate {
    func toCandidate(_ candidateType: RTCIceCandidateType?, _ protocol: String?) -> RTCIceCandidate {
        RTCIceCandidate(
            candidateType: candidateType,
            protocol: `protocol`,
            sdpMid: sdpMid,
            sdpMLineIndex: Int(sdpMLineIndex),
            candidate: sdp
        )
    }
}


extension [RTCIceServer] {
    func toWebRTCIceServers() -> [WebRTC.RTCIceServer] {
        self.map {
            WebRTC.RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            ) }
    }
}

extension RTCSdpType {
    func toWebRTCSdpType() -> WebRTC.RTCSdpType {
        switch self {
        case .answer: return WebRTC.RTCSdpType.answer
        case .offer: return WebRTC.RTCSdpType.offer
        case .pranswer: return WebRTC.RTCSdpType.prAnswer
        case .rollback: return WebRTC.RTCSdpType.rollback
        }
    }
}

extension WebRTC.RTCSdpType {
    func toSdpType() -> RTCSdpType {
        switch self {
        case .answer: return RTCSdpType.answer
        case .offer: return RTCSdpType.offer
        case .prAnswer: return RTCSdpType.pranswer
        case .rollback: return RTCSdpType.rollback
        default: return RTCSdpType.answer // should never be here
        }
    }
}

extension RTCPeerConnectionState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return"failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return nil // unknown
        }
    }
}

extension RTCIceConnectionState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return nil // unknown or unused on the other side
        }
    }
}

extension RTCIceGatheringState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        default: return nil // unknown
        }
    }
}

extension RTCSignalingState {
    func toString() -> String? {
        switch self {
        case .stable: return "stable"
        case .haveLocalOffer: return "have-local-offer"
        case .haveLocalPrAnswer: return "have-local-pranswer"
        case .haveRemoteOffer: return "have-remote-offer"
        case .haveRemotePrAnswer: return "have-remote-pranswer"
        case .closed: return "closed"
        default: return nil // unknown
        }
    }
}
